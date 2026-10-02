#!/usr/bin/env bash
#
# base.sh — baseline setup for a fresh server.
#
#   curl -fsSL <url>/scripts/base.sh | sudo bash -s -- --all-safe
#
# Everything here is individually opt-in, and the two operations that can lock
# you out of the machine — enabling the firewall and hardening SSH — are
# written to fail closed rather than leave the box in a state you cannot
# reconnect to.

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

export MB_SELF_URL="${MB_BASE_URL}/scripts/base.sh"

SSHD_DROPIN="/etc/ssh/sshd_config.d/99-machine-bootstrap.conf"

# --- Options ----------------------------------------------------------------

DO_UPGRADE=""; DO_TIMEZONE=""; DO_SWAP=""; DO_UFW=""; DO_UNATTENDED=""
DO_USER=""; DO_SSH_HARDEN=""

TZ=""
SWAP_SIZE=""
SWAPPINESS="10"
SUDO_USERNAME=""
SSH_KEY=""
SSH_PORT=""
PERMIT_ROOT="prohibit-password"

usage() {
  cat <<'EOF'
base.sh — baseline setup for a fresh server

Usage:
  base.sh [options]

If you pass no options at all, this script prints this help rather than
guessing: every action here changes the system in a way you should choose
deliberately.

System:
  --upgrade                apt update && apt upgrade (not full-upgrade)
  --timezone TZ            Set the timezone, e.g. Etc/UTC, Asia/Kolkata
  --swap SIZE              Create a swapfile, e.g. 2G (skipped on k8s/zram)
  --swappiness N           vm.swappiness (default: 10, implies --swap)
  --unattended-upgrades    Install and enable automatic security updates

Network access:
  --ufw                    Enable the firewall, allowing the SSH port first
  --ssh-port N             SSH port for the firewall rule (default: detected
                           from sshd itself, not assumed to be 22)

Accounts and access:
  --user NAME              Create a sudo user
  --ssh-key KEY|FILE       Add an authorized key for --user (repeatable)
  --harden-ssh             Disable SSH password auth, via a drop-in file
  --permit-root-login MODE prohibit-password (default) or no

Convenience:
  --all-safe               upgrade + timezone UTC + swap + unattended-upgrades
                           (everything that cannot lock you out)

  --dry-run, -y/--yes, -h/--help as usual

The two dangerous options:
  --ufw and --harden-ssh are the only ones that can strand you. Both are
  written so that a mistake fails safe:

    --ufw         allows the SSH port *before* enabling, and takes the port
                  from `sshd -T` rather than assuming 22.
    --harden-ssh  refuses to run unless a sudo-capable account already has a
                  non-empty authorized_keys, validates the config with
                  `sshd -t` before reloading, and rolls the drop-in back if
                  validation fails.
EOF
}

need_arg() { [[ -n "${2:-}" ]] || mb_die "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upgrade)            DO_UPGRADE=1; shift ;;
    --timezone)           need_arg "$1" "${2:-}"; TZ="$2"; DO_TIMEZONE=1; shift 2 ;;
    --timezone=*)         TZ="${1#*=}"; DO_TIMEZONE=1; shift ;;
    --swap)               need_arg "$1" "${2:-}"; SWAP_SIZE="$2"; DO_SWAP=1; shift 2 ;;
    --swap=*)             SWAP_SIZE="${1#*=}"; DO_SWAP=1; shift ;;
    --swappiness)         need_arg "$1" "${2:-}"; SWAPPINESS="$2"; DO_SWAP=1; shift 2 ;;
    --swappiness=*)       SWAPPINESS="${1#*=}"; DO_SWAP=1; shift ;;
    --unattended-upgrades) DO_UNATTENDED=1; shift ;;
    --ufw)                DO_UFW=1; shift ;;
    --ssh-port)           need_arg "$1" "${2:-}"; SSH_PORT="$2"; shift 2 ;;
    --ssh-port=*)         SSH_PORT="${1#*=}"; shift ;;
    --user)               need_arg "$1" "${2:-}"; SUDO_USERNAME="$2"; DO_USER=1; shift 2 ;;
    --user=*)             SUDO_USERNAME="${1#*=}"; DO_USER=1; shift ;;
    --ssh-key)            need_arg "$1" "${2:-}"; SSH_KEY="$2"; shift 2 ;;
    --ssh-key=*)          SSH_KEY="${1#*=}"; shift ;;
    --harden-ssh)         DO_SSH_HARDEN=1; shift ;;
    --permit-root-login)  need_arg "$1" "${2:-}"; PERMIT_ROOT="$2"; shift 2 ;;
    --permit-root-login=*) PERMIT_ROOT="${1#*=}"; shift ;;
    --all-safe)           DO_UPGRADE=1; DO_TIMEZONE=1; TZ="${TZ:-Etc/UTC}"
                          DO_SWAP=1; DO_UNATTENDED=1; shift ;;
    --dry-run)            export MB_DRY_RUN=1; shift ;;
    -y|--yes)             export MB_NONINTERACTIVE=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *)                    mb_die "unknown option: $1 (try --help)" ;;
  esac
done

# --- Individual steps -------------------------------------------------------

do_upgrade() {
  mb_heading "System upgrade"
  mb_apt_refresh
  mb_log "apt-get upgrade"
  run apt-get upgrade -y -qq \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold
  mb_ok "packages upgraded"
}

do_timezone() {
  mb_heading "Timezone"

  # timedatectl needs systemd and a running dbus; it errors confusingly in a
  # container without them.
  if [[ ! -d /run/systemd/system ]]; then
    mb_warn "systemd is not running — skipping timezone (would need timedatectl)"
    return 0
  fi

  if [[ -z "$TZ" ]]; then
    mb_ask TZ "Timezone" "Etc/UTC"
  fi

  if [[ ! -e "/usr/share/zoneinfo/${TZ}" ]]; then
    mb_warn "unknown timezone '${TZ}' — skipping"
    return 0
  fi

  local current; current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [[ "$current" == "$TZ" ]]; then
    mb_dim "timezone already ${TZ}"
    return 0
  fi

  run timedatectl set-timezone "$TZ"
  mb_ok "timezone set to ${TZ}"
}

do_swap() {
  mb_heading "Swap"

  # Kubernetes nodes refuse to run with swap on, and zram swap is a different
  # mechanism that must not be shadowed by a swapfile.
  if swapon --show 2>/dev/null | grep -qi zram; then
    mb_warn "zram swap is active — not adding a swapfile alongside it"
    return 0
  fi
  if swapon --show --noheadings 2>/dev/null | grep -q .; then
    mb_dim "swap is already configured:"
    swapon --show >&2
    return 0
  fi
  if [[ -f /etc/kubernetes/kubelet.conf ]] || systemctl is-active kubelet >/dev/null 2>&1; then
    mb_warn "this looks like a Kubernetes node — swap is deliberately left off"
    return 0
  fi

  local size="$SWAP_SIZE"
  if [[ -z "$size" ]]; then
    local mem_mb; mem_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
    if (( mem_mb < 4096 )); then size="$(( mem_mb / 1024 + 1 ))G"; else size="2G"; fi
    mb_ask size "Swapfile size" "$size"
  fi

  if [[ -e /swapfile ]]; then
    mb_warn "/swapfile already exists — not overwriting it"
    return 0
  fi

  mb_log "creating a ${size} swapfile at /swapfile"
  run fallocate -l "$size" /swapfile
  run chmod 600 /swapfile
  run mkswap /swapfile
  run swapon /swapfile

  mb_managed_block /etc/fstab "swap" <<'EOF'
# Swapfile added by machine-bootstrap.
/swapfile none swap sw 0 0
EOF

  # Swappiness tuning is only meaningful if the file is actually mounted.
  write_file /etc/sysctl.d/99-machine-bootstrap-swap.conf <<EOF
# Added by machine-bootstrap.
vm.swappiness = ${SWAPPINESS}
EOF
  run sysctl --system >/dev/null 2>&1 || true

  mb_ok "swap enabled (${size}), swappiness ${SWAPPINESS}"
}

do_unattended_upgrades() {
  mb_heading "Unattended security upgrades"

  mb_apt_install unattended-upgrades apt-listchanges

  write_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  # The default ships with automatic reboots enabled on some releases, which
  # will restart a production box at 06:00 without warning. Turn it off and
  # make the choice visible.
  write_file /etc/apt/apt.conf.d/52-machine-bootstrap-unattended <<'EOF'
// Added by machine-bootstrap.
// Security updates install automatically. Rebooting does not happen without
// a human deciding to: unattended reboots on a production host are a
// surprise, not a feature.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

  mb_service enable-now unattended-upgrades
  mb_ok "unattended-upgrades enabled (security updates only, no auto-reboot)"
}

detect_ssh_port() {
  if [[ -n "$SSH_PORT" ]]; then printf '%s' "$SSH_PORT"; return; fi
  local port=""
  if mb_has sshd; then
    port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  fi
  printf '%s' "${port:-22}"
}

do_ufw() {
  mb_heading "Firewall (ufw)"

  local port; port="$(detect_ssh_port)"
  mb_log "SSH is listening on port ${port}"

  if [[ -n "$MB_NONINTERACTIVE" ]] || ! mb_tty; then
    mb_warn "non-interactive run will not enable the firewall"
    mb_warn "enabling a firewall unattended is how people lock themselves out"
    mb_warn "re-run interactively, or with an explicit port, to do this"
    return 0
  fi

  if ! mb_confirm "Enable the firewall (allowing ${port}/tcp first)?" n; then
    mb_log "firewall left alone"
    return 0
  fi

  mb_apt_install ufw

  # Allow SSH *before* enabling. This is the whole ballgame.
  run ufw allow "${port}/tcp"
  run ufw allow 80/tcp
  run ufw allow 443/tcp

  mb_log "enabling ufw"
  run ufw --force enable
  run ufw --force reload

  mb_ok "firewall enabled: ${port}/tcp, 80/tcp, 443/tcp allowed"
  mb_dim "note: ports 80 and 443 were allowed for certbot; remove them if unused"
}

do_user() {
  mb_heading "Sudo user"

  local name="$SUDO_USERNAME"
  if [[ -z "$name" ]]; then
    mb_ask name "Username to create" ""
    [[ -n "$name" ]] || { mb_warn "no username given — skipping"; return 0; }
  fi

  if id "$name" >/dev/null 2>&1; then
    mb_dim "user ${name} already exists"
  else
    run useradd --create-home --shell /bin/bash "$name"
    mb_ok "created user ${name}"
  fi

  run usermod -aG sudo "$name"
  mb_ok "${name} is in the sudo group"

  if [[ -n "$SSH_KEY" ]]; then
    local home; home="$(getent passwd "$name" | cut -d: -f6)"
    local keydir="${home}/.ssh"
    run install -d -m 700 -o "$name" -g "$name" "$keydir"

    if [[ -f "$SSH_KEY" ]]; then
      run install -m 600 -o "$name" -g "$name" "$SSH_KEY" "${keydir}/authorized_keys"
      mb_ok "installed key from ${SSH_KEY}"
    else
      printf '%s\n' "$SSH_KEY" > /tmp/.mb-key.$$
      run install -m 600 -o "$name" -g "$name" /tmp/.mb-key.$$ "${keydir}/authorized_keys"
      rm -f /tmp/.mb-key.$$
      mb_ok "installed the key you passed"
    fi
  fi

  printf '\n' >&2
  mb_dim "set a password with:  passwd ${name}"
}

# Is there any account that could still get in over SSH once password auth is
# off? If not, hardening would be a lockout.
find_keyed_sudo_user() {
  local u home
  for u in $(getent group sudo 2>/dev/null | cut -d: -f4 | tr ',' ' '); do
    [[ -n "$u" ]] || continue
    home="$(getent passwd "$u" | cut -d: -f6)"
    if [[ -s "${home}/.ssh/authorized_keys" ]]; then
      printf '%s' "$u"; return 0
    fi
  done
  return 1
}

do_ssh_hardening() {
  mb_heading "SSH hardening"

  local keyed
  if ! keyed="$(find_keyed_sudo_user)"; then
    mb_err "no sudo-capable account has an authorized_keys file."
    mb_err "disabling password authentication now would lock you out."
    mb_err ""
    mb_err "create a user with a key first:"
    mb_err "  base.sh --user deploy --ssh-key 'ssh-ed25519 AAAA...'"
    return 1
  fi

  mb_log "account '${keyed}' has an authorized key — safe to continue"

  if [[ -n "$MB_NONINTERACTIVE" ]] || ! mb_tty; then
    mb_warn "non-interactive run will not change SSH authentication"
    return 0
  fi

  if ! mb_confirm "Disable SSH password authentication?" y; then
    mb_log "SSH configuration left alone"
    return 0
  fi

  write_file "$SSHD_DROPIN" <<EOF
# Added by machine-bootstrap.
# Password authentication is off: key-based access is already proven to work
# for '${keyed}', so this removes an entire class of brute-force attacks.
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin ${PERMIT_ROOT}
EOF

  # Validate before reloading. A config that fails `sshd -t` must not be left
  # in place — the next sshd restart would refuse to start.
  if ! sshd -t 2>/dev/null; then
    mb_err "the new SSH configuration is invalid — rolling it back"
    run rm -f "$SSHD_DROPIN"
    mb_err "nothing was changed; SSH is still as it was"
    return 1
  fi
  mb_ok "configuration validated with sshd -t"

  if mb_service restart ssh 2>/dev/null || mb_service restart sshd 2>/dev/null; then
    mb_ok "SSH restarted with password authentication disabled"
    printf '\n' >&2
    mb_warn "KEEP THIS SESSION OPEN until you have confirmed you can log in"
    mb_warn "in another terminal as ${keyed}. If you cannot, restore with:"
    mb_warn "  sudo rm ${SSHD_DROPIN} && sudo systemctl restart ssh"
  else
    mb_err "could not restart SSH — rolling back"
    run rm -f "$SSHD_DROPIN"
    return 1
  fi
}

# --- Main -------------------------------------------------------------------

main() {
  mb_require_root "$@"
  mb_require_supported_os

  # No options at all is ambiguous in a way that matters here: every action
  # changes the system, so show what is available instead of guessing.
  if [[ -z "$DO_UPGRADE$DO_TIMEZONE$DO_SWAP$DO_UFW$DO_UNATTENDED$DO_USER$DO_SSH_HARDEN" ]]; then
    usage
    exit 0
  fi

  mb_heading "Base server setup"
  printf 'host: %s %s (%s)\n' "$(mb_os)" "$(mb_os_version)" "$(mb_codename)" >&2

  [[ -n "$DO_UPGRADE" ]]    && do_upgrade
  [[ -n "$DO_TIMEZONE" ]]   && do_timezone
  [[ -n "$DO_SWAP" ]]       && do_swap
  [[ -n "$DO_UNATTENDED" ]] && do_unattended_upgrades
  [[ -n "$DO_USER" ]]       && do_user
  [[ -n "$DO_UFW" ]]        && do_ufw

  # Hardening last: it depends on the user and key created above.
  if [[ -n "$DO_SSH_HARDEN" ]]; then
    do_ssh_hardening || mb_warn "SSH hardening was not applied"
  fi

  mb_heading "Base setup complete"
}

main "$@"
