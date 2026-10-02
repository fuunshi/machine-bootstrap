#!/usr/bin/env bash
#
# nginx.sh — install nginx from the official nginx.org repository.
#
#   curl -fsSL <url>/scripts/nginx.sh | sudo bash -s -- --branch mainline
#
# nginx ships two branches: "stable" (even minor versions, fixes only) and
# "mainline" (odd minor versions, actively developed). nginx themselves
# recommend mainline for production, which is why it is the default here.
#
# Both the distro package and the nginx.org package provide `nginx`; this
# script deliberately installs the nginx.org build because the distro one lags
# badly (Ubuntu 24.04 ships 1.24 while nginx.org is on 1.29).

set -Eeuo pipefail

# --- Locate the shared library ---------------------------------------------
# Sources lib/common.sh from a local checkout when one exists, otherwise
# fetches it. ${BASH_SOURCE[0]} is empty under `curl | bash` and points at
# /dev/fd/NN under process substitution, so both correctly fall through.
_mb_lib() {
  local here=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  if [[ -n "$here" && -f "$here/lib/common.sh" ]]; then
    printf '%s' "$here/lib/common.sh"; return 0
  fi
  local tmp; tmp="$(mktemp -t mb-common.XXXXXX.sh)"
  curl -fsSL "${MB_BASE_URL:-https://raw.githubusercontent.com/fuunshi/machine-bootstrap/main}/scripts/lib/common.sh" -o "$tmp" || {
    echo "failed to fetch common.sh" >&2; exit 1; }
  printf '%s' "$tmp"
}
# shellcheck source=/dev/null
source "$(_mb_lib)"
mb_set_trap

export MB_SELF_URL="${MB_BASE_URL}/scripts/nginx.sh"

# --- Options ----------------------------------------------------------------

BRANCH=""
FORCE=""
FALLBACK_DISTRO=""

usage() {
  cat <<'EOF'
nginx.sh — install nginx from the official nginx.org repository

Usage:
  nginx.sh [options]

Options:
  --branch stable|mainline   Which nginx branch to install (default: mainline)
  --force                    Reinstall even if nginx is already present
  --dry-run                  Print what would happen, change nothing
  -y, --yes                  Never prompt; use defaults
  -h, --help                 Show this help

Choosing a branch:

  mainline   Actively developed. Gets new features and all fixes every 4-6
             weeks. nginx recommends this for production. (odd minors: 1.29.x)
  stable     Critical fixes only, minimal change between updates. For setups
             with strict change control. (even minors: 1.28.x)

Notes:
  The nginx.org package differs from the distro one:
    - it runs workers as user `nginx`, not `www-data`
    - config lives in /etc/nginx/conf.d/, not sites-available/sites-enabled
    - it does NOT start itself after install
  This script handles the last point. The first two are worth knowing before
  you go looking for a sites-enabled directory that isn't there.

  If nginx.org has not yet published a build for your release, this script
  falls back to the distribution package and tells you it has done so.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)    BRANCH="${2:-}"; shift 2 ;;
    --branch=*)  BRANCH="${1#*=}"; shift ;;
    --force)     FORCE=1; shift ;;
    --dry-run)   export MB_DRY_RUN=1; shift ;;
    -y|--yes)    export MB_NONINTERACTIVE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           mb_die "unknown option: $1 (try --help)" ;;
  esac
done

# --- Steps ------------------------------------------------------------------

install_from_nginx_org() {
  local os codename base repo_url
  os="$(mb_os)"
  codename="$(mb_codename)"

  case "$os" in
    ubuntu|debian) ;;
    *) mb_die "unsupported OS '$(mb_os)' — this script supports Ubuntu and Debian" ;;
  esac

  base="https://nginx.org/packages"
  [[ "$BRANCH" == "mainline" ]] && base="${base}/mainline"
  repo_url="${base}/${os}"

  # curl has to be present before the probe below can mean anything.
  mb_apt_prereqs

  if [[ -z "$codename" ]] || ! mb_use_vendor_repo "nginx.org" "$repo_url" "$codename"; then
    mb_warn "Falling back to the distribution's nginx package — it is older and"
    mb_warn "may lack modules you expect."
    FALLBACK_DISTRO=1
    return 0
  fi

  mb_add_keyring "https://nginx.org/keys/nginx_signing.key" \
                 /usr/share/keyrings/nginx-archive-keyring.gpg

  mb_apt_source "nginx.list" <<EOF
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] ${repo_url} ${codename} nginx
EOF

  # Without a pin, a later `apt upgrade` can quietly replace the nginx.org
  # build with the older distro one.
  write_file /etc/apt/preferences.d/nginx <<EOF
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
EOF

  mb_apt_refresh
}

install_package() {
  # When the distro package is already present, apt replaces it with the
  # nginx.org build because of the pin above. That is what we want, but it means
  # `apt` may restart nginx mid-install — worth telling the user rather than
  # letting them discover it from a dropped connection.
  if mb_pkg_installed nginx && [[ -z "$FALLBACK_DISTRO" ]]; then
    mb_log "replacing the distribution nginx with the nginx.org build"
  fi
  mb_apt_install nginx
}

verify() {
  mb_dry_run_done "nginx" && return 0

  mb_heading "nginx installed"

  if mb_has nginx; then
    mb_ok "$(mb_version_of nginx -v)"
  else
    mb_err "nginx binary not found after install"
    return 1
  fi

  local state; state="$(mb_service_status nginx)"
  [[ "$state" == "active" ]] && mb_ok "service nginx: ${state}" \
                             || mb_warn "service nginx: ${state:-unknown}"

  if [[ -n "$FALLBACK_DISTRO" ]]; then
    mb_warn "installed from the distribution, not nginx.org"
  fi
}

main() {
  mb_require_root "$@"
  mb_require_supported_os

  if [[ -z "$BRANCH" ]]; then
    mb_choose BRANCH "Which nginx branch?" "mainline" stable mainline
  fi
  case "$BRANCH" in
    stable|mainline) ;;
    *) mb_die "unknown branch '${BRANCH}' (expected stable or mainline)" ;;
  esac

  if mb_has nginx && [[ -z "$FORCE" ]]; then
    mb_log "nginx is already installed: $(mb_version_of nginx -v)"
    mb_log "re-run with --force to reinstall or switch branches"
    exit 0
  fi

  mb_heading "Installing nginx (${BRANCH})"
  install_from_nginx_org
  install_package

  # The nginx.org package does not start itself the way the distro one does.
  mb_service enable-now nginx

  verify
}

main "$@"
