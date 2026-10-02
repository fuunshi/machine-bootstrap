#!/usr/bin/env bash
#
# certbot.sh — install certbot, via snap (default) or apt.
#
#   curl -fsSL <url>/scripts/certbot.sh | sudo bash -s -- --plugin nginx
#
# Certbot can be installed two ways and they do not coexist peacefully. Both
# variants install a renewal timer pointed at the same /etc/letsencrypt tree,
# so having both means two timers racing over the same certificates. This
# script detects the other variant and asks before changing anything.

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

export MB_SELF_URL="${MB_BASE_URL}/scripts/certbot.sh"

# --- Options ----------------------------------------------------------------

METHOD=""
PLUGIN=""
EMAIL=""
KEEP_OTHER=""
FORCE=""

usage() {
  cat <<'EOF'
certbot.sh — install certbot

Usage:
  certbot.sh [options]

Options:
  --method snap|apt    How to install certbot (default: snap)
  --plugin nginx|apache|none
                       Also install the matching authenticator (default: nginx)
  --email ADDR         Pre-register the ACME account with this address
  --keep-other         Refuse to remove the other variant instead of asking
  --force              Install even if certbot is already present
  --dry-run            Print what would happen, change nothing
  -y, --yes            Never prompt; use defaults
  -h, --help           Show this help

Which method?

  snap   What the Certbot maintainers recommend. Tracks upstream releases and
         updates itself in the background. Needs snapd.

  apt    Ships with the distribution. Older, but receives security patches via
         unattended-upgrades and avoids adding snapd to the box.

  Pick one. Installing both leaves two renewal timers pointed at the same
  /etc/letsencrypt directory, which is a genuine hazard rather than a
  theoretical one.

About the plugin:
  The nginx/apache plugins modify your web server configuration to prove
  domain ownership. They are convenient but they rewrite your config and are
  not idempotent. If you prefer to own your own config, install with
  --plugin none and use `certbot certonly --webroot` instead.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --method)     METHOD="${2:-}"; shift 2 ;;
    --method=*)   METHOD="${1#*=}"; shift ;;
    --plugin)     PLUGIN="${2:-}"; shift 2 ;;
    --plugin=*)   PLUGIN="${1#*=}"; shift ;;
    --email)      EMAIL="${2:-}"; shift 2 ;;
    --email=*)    EMAIL="${1#*=}"; shift ;;
    --keep-other) KEEP_OTHER=1; shift ;;
    --force)      FORCE=1; shift ;;
    --dry-run)    export MB_DRY_RUN=1; shift ;;
    -y|--yes)     export MB_NONINTERACTIVE=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            mb_die "unknown option: $1 (try --help)" ;;
  esac
done

# --- Detection --------------------------------------------------------------

# Prints "snap", "apt", "both" or "" so callers can branch on the exact state
# rather than on a chain of guesses.
installed_variant() {
  local has_snap="" has_apt=""

  mb_has snap && snap list certbot >/dev/null 2>&1 && has_snap=1
  # The apt package is python3-certbot; the /usr/bin/certbot symlink that snap
  # creates would otherwise make this look like an apt install.
  { mb_pkg_installed python3-certbot || mb_pkg_installed certbot; } && has_apt=1

  if [[ -n "$has_snap" && -n "$has_apt" ]]; then printf 'both'
  elif [[ -n "$has_snap" ]]; then printf 'snap'
  elif [[ -n "$has_apt" ]]; then printf 'apt'
  fi
}

remove_apt_variant() {
  local -a pkgs=()
  local p
  for p in certbot python3-certbot python3-certbot-nginx python3-certbot-apache; do
    mb_pkg_installed "$p" && pkgs+=("$p")
  done
  [[ ${#pkgs[@]} -eq 0 ]] && return 0

  mb_log "removing the apt certbot: ${pkgs[*]}"
  # Disable the timer before purging, or it can fire mid-removal.
  run systemctl disable --now certbot.timer 2>/dev/null || true
  run apt-get purge -y -qq "${pkgs[@]}"
  run apt-get autoremove -y -qq
}

remove_snap_variant() {
  mb_log "removing the snap certbot"
  run snap remove --purge certbot
}

handle_conflict() {
  local variant; variant="$(installed_variant)"

  [[ "$variant" == "$METHOD" ]] && return 0
  [[ -z "$variant" ]] && return 0

  if [[ "$variant" == "both" ]]; then
    mb_warn "both snap and apt certbot are installed — this is the bad state"
    mb_warn "two renewal timers are pointed at the same /etc/letsencrypt"
  else
    mb_warn "certbot is installed via ${variant}, but you asked for ${METHOD}"
  fi

  if [[ -n "$KEEP_OTHER" ]]; then
    mb_die "refusing to remove the ${variant} certbot (--keep-other was given)"
  fi

  if [[ -n "$MB_NONINTERACTIVE" ]]; then
    # Removing software is not something to do silently on someone's behalf.
    mb_die "non-interactive run will not remove the ${variant} certbot.

Remove it yourself, then re-run:
  apt:  sudo apt purge certbot python3-certbot python3-certbot-nginx && sudo systemctl disable --now certbot.timer
  snap: sudo snap remove --purge certbot"
  fi

  local -a matched=()
  if [[ "$variant" == "both" ]]; then
    matched=("the apt certbot" "the snap certbot")
  else
    matched=("the ${variant} certbot")
  fi

  for label in "${matched[@]}"; do
    if ! mb_confirm "Remove ${label}?" y; then
      mb_die "leaving both variants installed is not supported — aborting"
    fi
    case "$label" in
      *snap*) remove_snap_variant ;;
      *)      remove_apt_variant ;;
    esac
  done

  # Actively check the removal worked rather than assuming it.
  variant="$(installed_variant)"
  if [[ -n "$variant" ]]; then
    mb_err "certbot variant still present after removal: ${variant}"
    mb_err "resolve this by hand before continuing"
    exit 1
  fi
  mb_ok "conflicting certbot removed"
}

# --- Install ----------------------------------------------------------------

install_snap() {
  mb_apt_install snapd
  mb_service enable-now snapd

  # snapd needs a moment after first start before it will accept commands.
  if [[ -z "$MB_DRY_RUN" ]]; then
    for _ in $(seq 1 30); do
      snap wait system seed.loaded 2>/dev/null && break
      sleep 1
    done
  fi

  run snap install --classic certbot

  # snap puts the binary in /snap/bin, which is not always on root's PATH.
  if [[ ! -e /usr/bin/certbot ]]; then
    run ln -sf /snap/bin/certbot /usr/bin/certbot
  fi
}

install_apt() {
  local -a pkgs=(certbot)
  case "$PLUGIN" in
    nginx)  pkgs+=(python3-certbot-nginx) ;;
    apache) pkgs+=(python3-certbot-apache) ;;
  esac
  mb_apt_install "${pkgs[@]}"
}

install_plugin() {
  [[ "$METHOD" == "apt" ]] && return 0   # handled inside install_apt
  case "$PLUGIN" in
    nginx|apache) run snap install "$PLUGIN" 2>/dev/null || true ;;
    none)         ;;
  esac
}

register_account() {
  [[ -n "$EMAIL" ]] || return 0
  mb_log "registering the ACME account for ${EMAIL}"
  run certbot register --non-interactive --agree-tos --email "$EMAIL" || {
    mb_warn "account registration failed — you can register later on first use"
  }
}

verify() {
  mb_dry_run_done "certbot" && return 0

  mb_heading "certbot installed"

  if ! mb_has certbot; then
    mb_err "certbot not found after install"
    return 1
  fi
  mb_ok "$(mb_version_of certbot --version)"

  local variant; variant="$(installed_variant)"
  mb_ok "installed via ${variant:-unknown}"

  # Report which renewal timer is armed — the whole point of picking one.
  if mb_has systemctl; then
    local timer
    for timer in certbot.timer snap.certbot.renew.timer; do
      if systemctl list-unit-files "$timer" >/dev/null 2>&1; then
        local state
        state="$(systemctl is-enabled "$timer" 2>/dev/null || true)"
        [[ -n "$state" ]] && mb_ok "renewal timer ${timer}: ${state}"
      fi
    done
  fi

  printf '\n' >&2
  mb_dim "obtain a certificate:  sudo certbot --nginx -d example.com"
  mb_dim "renewal is automatic; check with:  systemctl list-timers | grep certbot"
}

main() {
  mb_require_root "$@"
  mb_require_supported_os

  if [[ -z "$METHOD" ]]; then
    mb_choose METHOD "Install certbot via?" "snap" snap apt
  fi
  case "$METHOD" in
    snap|apt) ;;
    *) mb_die "unknown method '${METHOD}' (expected snap or apt)" ;;
  esac

  if [[ -z "$PLUGIN" ]]; then
    mb_choose PLUGIN "Which authenticator plugin?" "nginx" nginx apache none
  fi
  case "$PLUGIN" in
    nginx|apache|none) ;;
    *) mb_die "unknown plugin '${PLUGIN}' (expected nginx, apache or none)" ;;
  esac

  local variant; variant="$(installed_variant)"
  if [[ "$variant" == "$METHOD" ]] && [[ -z "$FORCE" ]]; then
    mb_log "certbot is already installed via ${METHOD}"
    mb_log "re-run with --force to reinstall"
    verify
    exit 0
  fi

  mb_heading "Installing certbot via ${METHOD}"
  handle_conflict

  case "$METHOD" in
    snap) install_snap; install_plugin ;;
    apt)  install_apt ;;
  esac

  register_account
  verify
}

main "$@"
