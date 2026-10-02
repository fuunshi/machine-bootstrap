#!/usr/bin/env bash
#
# docker.sh — install Docker Engine from Docker's official apt repository.
#
#   curl -fsSL <url>/scripts/docker.sh | sudo bash -s -- --channel stable
#
# This deliberately does NOT use get.docker.com. Docker's own documentation
# recommends against the convenience script for production: it gives you no
# version pinning, no clean upgrade path, and no proper uninstall.

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

export MB_SELF_URL="${MB_BASE_URL}/scripts/docker.sh"

DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

# --- Options ----------------------------------------------------------------

CHANNEL=""
ADD_USER=""
NO_USER=""
FORCE=""

usage() {
  cat <<'EOF'
docker.sh — install Docker Engine from Docker's official apt repository

Usage:
  docker.sh [options]

Options:
  --channel stable|test   Which release channel (default: stable)
  --user NAME             Add NAME to the docker group (default: the invoking user)
  --no-user               Do not add anyone to the docker group
  --force                 Reinstall even if Docker is already present
  --dry-run               Print what would happen, change nothing
  -y, --yes               Never prompt; use defaults
  -h, --help              Show this help

Installed:
  docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin,
  docker-compose-plugin

  Use `docker compose` (a plugin), not the legacy `docker-compose` binary.

A warning about the docker group:
  Membership of the `docker` group is equivalent to root. Anyone in it can
  start a container that mounts the host filesystem and edit anything on the
  box. That is why this script does not add you to the group unless you ask
  for it — use sudo, or pass --user $(whoami) and accept the trade-off.

  `test` channel is for pre-release builds and is not recommended for
  anything you care about.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)   CHANNEL="${2:-}"; shift 2 ;;
    --channel=*) CHANNEL="${1#*=}"; shift ;;
    --user)      ADD_USER="${2:-}"; shift 2 ;;
    --user=*)    ADD_USER="${1#*=}"; shift ;;
    --no-user)   NO_USER=1; shift ;;
    --force)     FORCE=1; shift ;;
    --dry-run)   export MB_DRY_RUN=1; shift ;;
    -y|--yes)    export MB_NONINTERACTIVE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           mb_die "unknown option: $1 (try --help)" ;;
  esac
done

# --- Steps ------------------------------------------------------------------

add_docker_repo() {
  local os codename repo
  os="$(mb_os)"
  codename="$(mb_codename)"

  # Docker publishes to download.docker.com/linux/{ubuntu,debian}.
  case "$os" in
    ubuntu|debian) ;;
    *) mb_die "unsupported OS '$(mb_os)' — this script supports Ubuntu and Debian" ;;
  esac

  repo="https://download.docker.com/linux/${os}"

  # curl has to be present before the probe below can mean anything.
  mb_apt_prereqs

  # Unlike the other scripts, an unsupported release is fatal rather than a
  # fallback: the distro 'docker.io' package is usually years behind, and
  # silently installing it would defeat the point of using this script.
  local rc=0
  mb_repo_probe "$repo" "$codename" || rc=$?
  if [[ -z "$codename" ]] || (( rc == 1 )); then
    mb_die "Docker does not publish a repository for '${codename:-unknown}'.

There is no distribution fallback here worth taking: the distro 'docker.io'
package is usually years behind and this script is meant to give you a
maintained, upgradeable Docker. Use your distribution's docker.io if you
must, or wait for Docker to publish for this release."
  fi
  (( rc == 2 )) && mb_warn "could not verify the Docker repository for ${codename} — proceeding anyway"

  mb_add_keyring "https://download.docker.com/linux/${os}/gpg" "$DOCKER_KEYRING"

  mb_apt_source "docker.list" <<EOF
deb [arch=$(mb_arch) signed-by=${DOCKER_KEYRING}] ${repo} ${codename} ${CHANNEL}
EOF

  mb_apt_refresh
}

remove_conflicting_packages() {
  # These all provide docker/containerd binaries and conflict with docker-ce.
  local -a conflicts=() p
  for p in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    mb_pkg_installed "$p" && conflicts+=("$p")
  done
  [[ ${#conflicts[@]} -eq 0 ]] && return 0

  mb_warn "removing conflicting packages: ${conflicts[*]}"
  run apt-get remove -y -qq "${conflicts[@]}"
}

install_packages() {
  local -a pkgs=("${DOCKER_PACKAGES[@]}")

  # The test channel names its packages differently.
  if [[ "$CHANNEL" == "test" ]]; then
    pkgs=(docker-ce-test docker-ce-cli-test containerd.io docker-buildx-plugin docker-compose-plugin)
  fi

  mb_apt_install "${pkgs[@]}"
}

configure_user() {
  [[ -n "$NO_USER" ]] && return 0

  local user="$ADD_USER"
  if [[ -z "$user" ]]; then
    if [[ -n "$MB_NONINTERACTIVE" ]] || ! mb_tty; then
      mb_log "not adding anyone to the docker group (pass --user NAME to do so)"
      return 0
    fi
    if ! mb_confirm "Add the invoking user to the 'docker' group? (root-equivalent)" n; then
      return 0
    fi
    user="$(mb_invoking_user)"
  fi

  if ! id "$user" >/dev/null 2>&1; then
    mb_warn "no such user: ${user} — skipping group membership"
    return 0
  fi

  mb_warn "adding '${user}' to the docker group — this is root-equivalent access"
  run usermod -aG docker "$user"
  mb_dim "log out and back in for the new group to take effect"
}

verify() {
  mb_dry_run_done "Docker" && return 0

  mb_heading "Docker installed"

  if mb_has docker; then
    mb_ok "docker $(docker --version 2>/dev/null | sed 's/^Docker version //;s/,.*//')"
  else
    mb_err "docker binary not found after install"
    return 1
  fi

  local state; state="$(mb_service_status docker)"
  [[ "$state" == "active" ]] && mb_ok "service docker: ${state}" \
                             || mb_warn "service docker: ${state:-unknown}"

  if mb_has docker; then
    printf '\n' >&2
    if docker compose version >/dev/null 2>&1; then
      mb_ok "$(docker compose version 2>/dev/null | head -n1)"
    fi
    if docker buildx version >/dev/null 2>&1; then
      mb_ok "$(docker buildx version 2>/dev/null | head -n1)"
    fi
  fi

  printf '\n' >&2
  mb_dim "try:  sudo docker run --rm hello-world"
}

main() {
  mb_require_root "$@"
  mb_require_supported_os

  if [[ -z "$CHANNEL" ]]; then
    mb_choose CHANNEL "Which Docker release channel?" "stable" stable test
  fi
  case "$CHANNEL" in
    stable|test) ;;
    *) mb_die "unknown channel '${CHANNEL}' (expected stable or test)" ;;
  esac

  if mb_has docker && [[ -z "$FORCE" ]]; then
    mb_log "docker is already installed: $(docker --version 2>/dev/null)"
    mb_log "re-run with --force to reinstall"
    verify
    exit 0
  fi

  mb_heading "Installing Docker (${CHANNEL})"
  remove_conflicting_packages
  add_docker_repo
  install_packages
  mb_service enable-now docker

  # The socket is what the CLI talks to; it can lag the service on slow boots.
  mb_service enable-now docker.socket

  configure_user
  verify
}

main "$@"
