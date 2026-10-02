#!/usr/bin/env bash
#
# wormhole.sh — install magic-wormhole, for sending files between machines.
#
#   curl -fsSL <url>/scripts/wormhole.sh | sudo bash -s -- --method apt
#
# magic-wormhole transfers a file or short text between two computers using a
# short one-time code. Neither side needs an open port, a shared network, or an
# account — the two ends meet at a public rendezvous server and the transfer is
# encrypted end to end.

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

export MB_SELF_URL="${MB_BASE_URL}/scripts/wormhole.sh"

# --- Options ----------------------------------------------------------------

METHOD=""
TARGET_USER=""
FORCE=""

usage() {
  cat <<'EOF'
wormhole.sh — install magic-wormhole

Usage:
  wormhole.sh [options]

Options:
  --method apt|pipx    How to install (default: apt)
  --user NAME          For --method pipx, install for this user
                       (default: the invoking user)
  --force              Reinstall even if already present
  --dry-run            Print what would happen, change nothing
  -y, --yes            Never prompt; use defaults
  -h, --help           Show this help

Which method?

  apt    The distribution's package. Coexists with everything else on the box
         and needs no extra machinery. Often a release or two behind upstream.

  pipx   The current upstream release, installed into its own isolated virtual
         environment. Choose this if you need a newer version — the relay
         protocol has changed over time, and matching versions on both ends
         avoids surprises.

  Plain `pip install magic-wormhole` is not offered. On Ubuntu 24.04 and later
  the system Python is externally managed (PEP 668) and pip will refuse;
  working around that with --break-system-packages can damage the system
  Python that apt depends on.

Once installed, the command is `wormhole`:
  wormhole send FILE        on the sending machine
  wormhole receive CODE     on the receiving machine
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --method)   METHOD="${2:-}"; shift 2 ;;
    --method=*) METHOD="${1#*=}"; shift ;;
    --user)     TARGET_USER="${2:-}"; shift 2 ;;
    --user=*)   TARGET_USER="${1#*=}"; shift ;;
    --force)    FORCE=1; shift ;;
    --dry-run)  export MB_DRY_RUN=1; shift ;;
    -y|--yes)   export MB_NONINTERACTIVE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          mb_die "unknown option: $1 (try --help)" ;;
  esac
done

# --- Steps ------------------------------------------------------------------

install_apt() {
  mb_apt_install magic-wormhole
}

install_pipx() {
  local user="$1"

  mb_apt_install pipx

  if [[ -n "$MB_DRY_RUN" ]]; then
    printf '%s[dry-run]%s pipx install magic-wormhole (as %s)\n' \
      "$_MB_C_DIM" "$_MB_C_RESET" "$user" >&2
    return 0
  fi

  # pipx installs into the *user's* ~/.local, so it must run as that user —
  # running it as root would put wormhole in /root/.local/bin where the human
  # cannot reach it.
  if [[ "$user" == "root" ]]; then
    run pipx install magic-wormhole --force --pip-args=--upgrade || mb_die "pipx install failed"
    run pipx ensurepath || true
  else
    run sudo -u "$user" -H pipx install magic-wormhole --force || mb_die "pipx install failed"
    run sudo -u "$user" -H pipx ensurepath || true
  fi
}

verify() {
  local user="$1"

  mb_dry_run_done "magic-wormhole" && return 0

  mb_heading "magic-wormhole installed"

  local out=""
  if [[ "$METHOD" == "pipx" && "$user" != "root" ]]; then
    # pipx's shim is in ~/.local/bin, which root's PATH does not include.
    out="$(sudo -u "$user" -H bash -lc 'command -v wormhole >/dev/null 2>&1 && wormhole --version 2>&1 | head -n1' 2>/dev/null || true)"
  elif mb_has wormhole; then
    out="$(wormhole --version 2>&1 | head -n1 || true)"
  fi

  if [[ -n "$out" ]]; then
    mb_ok "$out"
  else
    mb_warn "could not run 'wormhole --version' from this shell"
    [[ "$METHOD" == "pipx" ]] && mb_dim "it is on PATH after a new login shell (~/.local/bin)"
  fi

  printf '\n' >&2
  mb_dim "send:    wormhole send FILE"
  mb_dim "receive: wormhole receive CODE"
  if [[ "$METHOD" == "pipx" ]]; then
    mb_dim "both machines should run a similar version — check with wormhole --version"
  fi
}

main() {
  mb_require_root "$@"
  mb_require_supported_os

  if [[ -z "$METHOD" ]]; then
    mb_choose METHOD "Install magic-wormhole via?" "apt" apt pipx
  fi
  case "$METHOD" in
    apt|pipx) ;;
    *) mb_die "unknown method '${METHOD}' (expected apt or pipx)" ;;
  esac

  local user="${TARGET_USER:-$(mb_invoking_user)}"
  if [[ "$METHOD" == "pipx" ]]; then
    id "$user" >/dev/null 2>&1 || mb_die "no such user: ${user}"
  fi

  if mb_has wormhole && [[ -z "$FORCE" ]]; then
    mb_log "magic-wormhole is already installed"
    mb_log "re-run with --force to reinstall"
    verify "$user"
    exit 0
  fi

  mb_heading "Installing magic-wormhole (${METHOD})"
  case "$METHOD" in
    apt)  install_apt ;;
    pipx) install_pipx "$user" ;;
  esac
  verify "$user"
}

main "$@"
