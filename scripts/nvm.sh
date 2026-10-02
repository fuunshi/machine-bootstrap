#!/usr/bin/env bash
#
# nvm.sh — install nvm and a Node.js version, for the invoking user.
#
#   curl -fsSL <url>/scripts/nvm.sh | sudo bash -s -- --node lts
#
# nvm is a per-user tool: it lives in $HOME/.nvm and is a shell function rather
# than a binary, so it has to be sourced before it can be called. That shapes
# this whole script — everything happens as the invoking user, in their home
# directory, never as root.

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

export MB_SELF_URL="${MB_BASE_URL}/scripts/nvm.sh"

# Pinned rather than resolved at runtime so a run is reproducible. Bump this
# line when nvm cuts a release, or pass --nvm-latest to float.
NVM_VERSION="v0.40.8"

# --- Options ----------------------------------------------------------------

NODE=""
TARGET_USER=""
NVM_TAG=""
NO_RC=""
FORCE=""

usage() {
  cat <<'EOF'
nvm.sh — install nvm and Node.js for a user

Usage:
  nvm.sh [options]

Options:
  --node lts|latest|VERSION   Node version to install (default: lts)
                              VERSION can be a major ("22") or exact ("22.11.0")
  --user NAME                 Install for this user (default: the invoking user)
  --nvm-version TAG           nvm release tag (default: pinned in this script)
  --nvm-latest                Resolve the newest nvm tag from the GitHub API
  --no-rc                     Do not edit shell rc files; print the lines instead
  --force                     Reinstall even if nvm is already present
  --dry-run                   Print what would happen, change nothing
  -y, --yes                   Never prompt; use defaults
  -h, --help                  Show this help

lts or latest?

  lts     The current Long Term Support line. This is what you want on a
          server: it gets security fixes for years.
  latest  The newest release, including the current (non-LTS) major. New
          features land here first, and so do the bugs.
  VERSION Pin explicitly, e.g. --node 22.11.0. The most reproducible choice.

A note on how this runs:
  nvm installs into $HOME/.nvm, so installing it "as root" would put Node in
  /root/.nvm where no normal user can reach it. This script therefore installs
  for the invoking user — the account that ran sudo — and uses sudo only where
  it is actually needed.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)        NODE="${2:-}"; shift 2 ;;
    --node=*)      NODE="${1#*=}"; shift ;;
    --user)        TARGET_USER="${2:-}"; shift 2 ;;
    --user=*)      TARGET_USER="${1#*=}"; shift ;;
    --nvm-version) NVM_TAG="${2:-}"; shift 2 ;;
    --nvm-version=*) NVM_TAG="${1#*=}"; shift ;;
    --nvm-latest)  NVM_TAG="latest"; shift ;;
    --no-rc)       NO_RC=1; shift ;;
    --force)       FORCE=1; shift ;;
    --dry-run)     export MB_DRY_RUN=1; shift ;;
    -y|--yes)      export MB_NONINTERACTIVE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             mb_die "unknown option: $1 (try --help)" ;;
  esac
done

# --- Helpers ----------------------------------------------------------------

# Run a command as the target user, with a login-ish environment. nvm needs a
# real HOME, so -H matters here.
as_user() {
  local user="$1"; shift
  if [[ "$user" == "root" ]]; then
    run env HOME=/root bash -c "$*"
  else
    run sudo -u "$user" -H bash -c "$*"
  fi
}

resolve_nvm_tag() {
  # Only called for --nvm-latest. If the API is unreachable we fall back to the
  # pin rather than failing — a slightly old nvm is not worth aborting over.
  local tag=""
  tag="$(curl -fsSL --max-time 10 \
          https://api.github.com/repos/nvm-sh/nvm/releases/latest 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | head -n1 \
        | sed 's/.*"\(v[^"]*\)".*/\1/')" || true

  if [[ -n "$tag" ]]; then
    printf '%s' "$tag"
  else
    mb_warn "could not reach the GitHub API — using the pinned ${NVM_VERSION}"
    printf '%s' "$NVM_VERSION"
  fi
}

# --- Steps ------------------------------------------------------------------

install_nvm() {
  local user="$1" tag="$2" home

  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -d "$home" ]] || mb_die "home directory for ${user} does not exist: ${home}"

  if [[ -s "${home}/.nvm/nvm.sh" ]] && [[ -z "$FORCE" ]]; then
    mb_log "nvm is already installed for ${user}"
    return 0
  fi

  mb_log "installing nvm ${tag} for ${user}"

  if [[ -n "$MB_DRY_RUN" ]]; then
    printf '%s[dry-run]%s install nvm %s into %s/.nvm\n' \
      "$_MB_C_DIM" "$_MB_C_RESET" "$tag" "$home" >&2
    return 0
  fi

  local installer
  installer="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${tag}/install.sh" -o "$installer" \
    || { rm -f "$installer"; mb_die "failed to fetch the nvm installer"; }

  if [[ -n "$NO_RC" ]]; then
    # PROFILE=/dev/null tells the nvm installer not to touch any rc file.
    as_user "$user" "PROFILE=/dev/null bash ${installer}" \
      || { rm -f "$installer"; mb_die "the nvm installer failed"; }
  else
    as_user "$user" "bash ${installer}" \
      || { rm -f "$installer"; mb_die "the nvm installer failed"; }
  fi

  rm -f "$installer"
}

install_node() {
  local user="$1" want="$2"

  # nvm is a shell function, so it must be sourced in the same shell that calls
  # it. bash -c with an explicit source is the only reliable way in a script.
  local cmd
  case "$want" in
    lts)    cmd='nvm install --lts && nvm alias default "lts/*" && nvm use default' ;;
    latest) cmd='nvm install node && nvm alias default node && nvm use default' ;;
    *)      cmd="nvm install ${want} && nvm alias default ${want} && nvm use default" ;;
  esac

  mb_log "installing Node.js (${want}) for ${user}"

  if [[ -n "$MB_DRY_RUN" ]]; then
    printf '%s[dry-run]%s %s\n' "$_MB_C_DIM" "$_MB_C_RESET" "$cmd" >&2
    return 0
  fi

  as_user "$user" "
    export NVM_DIR=\"\$HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] || { echo 'nvm.sh not found' >&2; exit 1; }
    . \"\$NVM_DIR/nvm.sh\"
    ${cmd}
  " || mb_die "installing Node.js ${want} failed"
}

verify() {
  local user="$1"

  mb_dry_run_done "nvm" && return 0

  mb_heading "nvm and Node.js installed"

  local home; home="$(getent passwd "$user" | cut -d: -f6)"

  if [[ -s "${home}/.nvm/nvm.sh" ]]; then
    mb_ok "nvm present at ${home}/.nvm"
  else
    mb_err "nvm.sh not found at ${home}/.nvm — install failed"
    return 1
  fi

  local node_version
  node_version="$(sudo -u "$user" -H bash -c '
    export NVM_DIR="$HOME/.nvm"
    . "$NVM_DIR/nvm.sh"
    printf "node %s / npm %s" "$(node --version 2>/dev/null)" "$(npm --version 2>/dev/null)"
  ' 2>/dev/null || true)"

  if [[ -n "$node_version" ]]; then
    mb_ok "$node_version"
  else
    mb_warn "could not determine the installed Node version"
  fi

  printf '\n' >&2
  mb_dim "as ${user}, run:  nvm use default"
  mb_dim "the installer added the source lines to ~/.bashrc (and ~/.zshrc if present)"
}

main() {
  mb_require_root "$@"
  mb_require_supported_os

  local user="${TARGET_USER:-$(mb_invoking_user)}"
  id "$user" >/dev/null 2>&1 || mb_die "no such user: ${user}"

  if [[ "$user" == "root" ]]; then
    mb_warn "installing nvm for root — it will live in /root/.nvm and be"
    mb_warn "reachable only by root. Pass --user NAME for a normal account."
  fi

  if [[ -z "$NODE" ]]; then
    mb_choose NODE "Which Node.js version?" "lts" lts latest
  fi

  local tag="$NVM_VERSION"
  case "$NVM_TAG" in
    "")       tag="$NVM_VERSION" ;;
    "latest") tag="$(resolve_nvm_tag)" ;;
    *)        tag="$NVM_TAG" ;;
  esac

  mb_heading "Installing nvm for ${user}"
  install_nvm "$user" "$tag"
  install_node "$user" "$NODE"
  verify "$user"
}

main "$@"
