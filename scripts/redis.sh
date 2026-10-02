#!/usr/bin/env bash
#
# redis.sh — install Redis from the official packages.redis.io repository.
#
#   curl -fsSL <url>/scripts/redis.sh | sudo bash -s -- --version 8
#
# The distribution repositories carry an old Redis. The official repo gives you
# a current one and a version you can actually pin.

set -Eeuo pipefail

# --- Locate the shared library ---------------------------------------------
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

export MB_SELF_URL="${MB_BASE_URL}/scripts/redis.sh"

REDIS_KEYRING="/usr/share/keyrings/redis-archive-keyring.gpg"
REDIS_REPO="https://packages.redis.io/deb"

# --- Options ----------------------------------------------------------------

REDIS_SERIES=""
FORCE=""
FALLBACK_DISTRO=""

usage() {
  cat <<'EOF'
redis.sh — install Redis from the official packages.redis.io repository

Usage:
  redis.sh [options]

Options:
  --version 7.4|8      Which Redis series (default: 8)
  --force              Reinstall even if Redis is already present
  --dry-run            Print what would happen, change nothing
  -y, --yes            Never prompt; use defaults
  -h, --help           Show this help

Which version?

  8.x    Current. Bundles the former Redis Stack modules (JSON, Search,
         TimeSeries, Bloom) into one distribution. Licensed AGPLv3 — a
         deliberate change from the BSD licensing of the 7.x line. If you are
         building something proprietary on top of Redis, read the licence.

  7.4.x  The last BSD-licensed line. Receives fixes, but is no longer where
         new development happens. Choose this if the licence matters to you.

Security note:
  Redis has no authentication by default and is a well-known target. The
  default configuration from this package binds to localhost with protected
  mode on, which is safe on a single host. If you intend to expose it, set a
  password and a bind address in /etc/redis/redis.conf first. Do not simply
  open port 6379 to the internet.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   REDIS_SERIES="${2:-}"; shift 2 ;;
    --version=*) REDIS_SERIES="${1#*=}"; shift ;;
    --force)     FORCE=1; shift ;;
    --dry-run)   export MB_DRY_RUN=1; shift ;;
    -y|--yes)    export MB_NONINTERACTIVE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           mb_die "unknown option: $1 (try --help)" ;;
  esac
done

# --- Steps ------------------------------------------------------------------

replace_distro_redis() {
  # The distro's redis-server would otherwise shadow or conflict with the
  # packages.redis.io build. Removing it is a destructive act on a box that
  # may already hold data, so it needs consent.
  local -a present=() p
  for p in redis-server redis-tools; do
    mb_pkg_installed "$p" && present+=("$p")
  done
  [[ ${#present[@]} -eq 0 ]] && return 0

  mb_warn "the distribution's Redis is already installed: ${present[*]}"
  mb_warn "it must be replaced for the official packages to take over."

  if [[ -f /var/lib/redis/dump.rdb ]]; then
    mb_warn "there is data at /var/lib/redis/dump.rdb — back it up if it matters"
  fi

  if [[ -n "$MB_NONINTERACTIVE" ]]; then
    mb_warn "non-interactive: leaving the distribution Redis in place"
    mb_warn "re-run interactively, or remove it yourself, to switch"
    FALLBACK_DISTRO=1
    return 0
  fi

  if ! mb_confirm "Remove the distribution Redis and continue?" n; then
    mb_log "leaving the distribution Redis in place"
    FALLBACK_DISTRO=1
    return 0
  fi

  run apt-get remove -y -qq "${present[@]}"
}

add_redis_repo() {
  local codename
  codename="$(mb_codename)"

  # curl has to be present before the probe below can mean anything.
  mb_apt_prereqs

  if [[ -z "$codename" ]] || ! mb_use_vendor_repo "packages.redis.io" "$REDIS_REPO" "$codename"; then
    mb_warn "Falling back to the distribution's Redis — it will be older."
    FALLBACK_DISTRO=1
    return 0
  fi

  mb_add_keyring "https://packages.redis.io/gpg" "$REDIS_KEYRING"

  mb_apt_source "redis.list" <<EOF
deb [signed-by=${REDIS_KEYRING}] ${REDIS_REPO} ${codename} main
EOF

  # Pin the series so a later `apt upgrade` cannot walk us onto the other
  # major and change the licence or the module set underneath the user.
  write_file /etc/apt/preferences.d/redis <<EOF
Package: redis redis-server redis-sentinel redis-tools
Pin: version 6:${REDIS_SERIES}.*
Pin-Priority: 1001
EOF

  mb_apt_refresh
}

install_package() {
  if [[ -n "$FALLBACK_DISTRO" ]]; then
    mb_apt_install redis-server
    return 0
  fi

  if ! mb_apt_has_candidate redis-server; then
    mb_warn "no candidate for redis-server after adding the repo —"
    mb_warn "falling back to the distribution package"
    FALLBACK_DISTRO=1
    mb_apt_install redis-server
    return 0
  fi

  mb_apt_install redis redis-server redis-tools
}

verify() {
  mb_dry_run_done "Redis" && return 0

  mb_heading "Redis installed"

  if ! mb_has redis-server; then
    mb_err "redis-server not found after install"
    return 1
  fi

  local version; version="$(redis-server --version 2>/dev/null)"
  mb_ok "${version:-redis-server present}"

  local state; state="$(mb_service_status redis-server)"
  if [[ "$state" == "active" ]]; then
    mb_ok "service redis-server: ${state}"
  elif [[ -n "$FALLBACK_DISTRO" ]]; then
    mb_warn "service redis-server: ${state:-unknown}"
  else
    # The official package starts the service itself; if it is not up, say so
    # loudly rather than attempting a start that may mask a config problem.
    mb_warn "service redis-server: ${state:-unknown} (expected active)"
    mb_warn "check: journalctl -u redis-server"
  fi

  if [[ -n "$FALLBACK_DISTRO" ]]; then
    mb_warn "installed from the distribution, not packages.redis.io"
  fi

  printf '\n' >&2
  mb_dim "connect with:  redis-cli"
  mb_dim "config:        /etc/redis/redis.conf"
}

main() {
  mb_require_root "$@"
  mb_require_supported_os

  if [[ -z "$REDIS_SERIES" ]]; then
    mb_choose REDIS_SERIES "Which Redis series?" "8" 8 7.4
  fi
  case "$REDIS_SERIES" in
    8|7.4) ;;
    *) mb_die "unsupported version '${REDIS_SERIES}' (this script supports 7.4 and 8)" ;;
  esac

  if mb_has redis-server && [[ -z "$FORCE" ]]; then
    mb_log "redis is already installed: $(redis-server --version 2>/dev/null)"
    mb_log "re-run with --force to reinstall"
    verify
    exit 0
  fi

  mb_heading "Installing Redis ${REDIS_SERIES}"
  replace_distro_redis
  add_redis_repo
  install_package
  verify
}

main "$@"
