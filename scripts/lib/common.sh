#!/usr/bin/env bash
# Shared helpers for the machine-bootstrap scripts.
#
# This file is sourced, never executed. It is deliberately small: logging, OS
# detection, apt plumbing, prompts that survive `curl | bash`, and a dry-run
# runner. Anything tool-specific belongs in the individual scripts.

# Guard against double-sourcing (server-setup.sh sources this, then runs child
# scripts that source it again in their own process — harmless, but within one
# process we only want the initialisation once).
[[ -n "${_MB_COMMON_LOADED:-}" ]] && return 0
_MB_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

MB_BASE_URL="${MB_BASE_URL:-https://raw.githubusercontent.com/fuunshi/machine-bootstrap/main}"
MB_DRY_RUN="${MB_DRY_RUN:-}"
MB_NONINTERACTIVE="${MB_NONINTERACTIVE:-}"
MB_FAKE_CODENAME="${MB_FAKE_CODENAME:-}"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
# Colour only when the stream we are writing to is a terminal. Under
# `curl | bash` stdout is often a tty but stderr carries the logs, so decide
# per-stream rather than once.

if [[ -t 2 ]]; then
  _MB_C_RESET=$'\033[0m'; _MB_C_INFO=$'\033[36m'; _MB_C_OK=$'\033[32m'
  _MB_C_WARN=$'\033[33m'; _MB_C_ERR=$'\033[31m';  _MB_C_DIM=$'\033[2m'
else
  _MB_C_RESET=""; _MB_C_INFO=""; _MB_C_OK=""
  _MB_C_WARN=""; _MB_C_ERR=""; _MB_C_DIM=""
fi

mb_log()  { printf '%s==>%s %s\n'    "$_MB_C_INFO" "$_MB_C_RESET" "$*" >&2; }
mb_ok()   { printf '%s  ok%s %s\n'   "$_MB_C_OK"   "$_MB_C_RESET" "$*" >&2; }
mb_warn() { printf '%swarn%s %s\n'   "$_MB_C_WARN" "$_MB_C_RESET" "$*" >&2; }
mb_err()  { printf '%serr %s %s\n'   "$_MB_C_ERR"  "$_MB_C_RESET" "$*" >&2; }
mb_dim()  { printf '%s%s%s\n'        "$_MB_C_DIM"  "$*" "$_MB_C_RESET" >&2; }

# Fatal error: report and exit non-zero.
mb_die() { mb_err "$*"; exit 1; }

# ERR trap. Scripts install this themselves via mb_set_trap so that the trap
# covers the calling script's line numbers rather than this file's.
mb_trap_err() {
  local exit_code=$? line="${1:-?}"
  mb_err "aborted at line ${line} (exit ${exit_code})"
  exit "$exit_code"
}
mb_set_trap() { trap 'mb_trap_err $LINENO' ERR; }

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------

# Run a mutating command, or describe it when --dry-run is in effect.
run() {
  if [[ -n "$MB_DRY_RUN" ]]; then
    printf '%s[dry-run]%s %s\n' "$_MB_C_DIM" "$_MB_C_RESET" "$*" >&2
    return 0
  fi
  "$@"
}

# Write a file, or describe it under --dry-run. Content arrives on stdin.
write_file() {
  local dest="$1"
  if [[ -n "$MB_DRY_RUN" ]]; then
    printf '%s[dry-run]%s write %s:\n' "$_MB_C_DIM" "$_MB_C_RESET" "$dest" >&2
    sed 's/^/    /' >&2
    return 0
  fi
  cat > "$dest"
}

# ---------------------------------------------------------------------------
# Terminal interaction
# ---------------------------------------------------------------------------
# Under `curl | bash` this script arrived on stdin, so a plain `read` would eat
# the script text instead of listening to the user. Every prompt therefore goes
# through /dev/tty.
#
# Note the check actually *opens* /dev/tty. `[[ -r /dev/tty ]]` only stats the
# device node and returns true even in a container where opening fails with
# ENXIO — which, under `set -e`, turns the fallback path into a crash.
mb_tty() { { : >/dev/tty; } 2>/dev/null; }

# Ask a question. mb_ask <varname> <prompt> [default]
# With no terminal (or MB_NONINTERACTIVE=1) the default is used silently, so a
# piped or CI run never hangs waiting for input that cannot arrive.
mb_ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __reply=""

  if [[ -n "$MB_NONINTERACTIVE" ]] || ! mb_tty; then
    printf -v "$__var" '%s' "$__default"
    return 0
  fi

  if [[ -n "$__default" ]]; then
    printf '%s [%s]: ' "$__prompt" "$__default" >/dev/tty
  else
    printf '%s: ' "$__prompt" >/dev/tty
  fi

  IFS= read -r __reply </dev/tty || __reply=""
  printf -v "$__var" '%s' "${__reply:-$__default}"
}

# Yes/no question. mb_confirm <prompt> [default: y|n]
mb_confirm() {
  local prompt="$1" default="${2:-n}" reply=""

  if [[ -n "$MB_NONINTERACTIVE" ]] || ! mb_tty; then
    [[ "$default" == "y" ]]
    return
  fi

  printf '%s [%s/%s]: ' "$prompt" \
    "$([[ "$default" == y ]] && echo Y || echo y)" \
    "$([[ "$default" == y ]] && echo n || echo N)" >/dev/tty
  IFS= read -r reply </dev/tty || reply=""
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

# Pick one of a fixed set. mb_choose <varname> <prompt> <default> <opt>...
# Accepts either the option's number or its literal text.
mb_choose() {
  local __var="$1" __prompt="$2" __default="$3"; shift 3
  local -a opts=("$@")
  local reply i

  if [[ -n "$MB_NONINTERACTIVE" ]] || ! mb_tty; then
    printf -v "$__var" '%s' "$__default"
    return 0
  fi

  printf '%s\n' "$__prompt" >/dev/tty
  for i in "${!opts[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${opts[$i]}" >/dev/tty
  done
  printf 'choice [%s]: ' "$__default" >/dev/tty

  IFS= read -r reply </dev/tty || reply=""
  reply="${reply:-$__default}"

  if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#opts[@]} )); then
    printf -v "$__var" '%s' "${opts[$((reply - 1))]}"
  else
    printf -v "$__var" '%s' "$reply"
  fi
}

# ---------------------------------------------------------------------------
# System detection
# ---------------------------------------------------------------------------

mb_has() { command -v "$1" >/dev/null 2>&1; }

# Prints ubuntu | debian | unknown
mb_os() {
  local id=""
  [[ -r /etc/os-release ]] && id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  case "$id" in
    ubuntu) printf 'ubuntu' ;;
    debian) printf 'debian' ;;
    *)      printf 'unknown' ;;
  esac
}

# Prints 22.04, 24.04, 12, ... — the raw VERSION_ID.
mb_os_version() {
  [[ -r /etc/os-release ]] && . /etc/os-release && printf '%s' "${VERSION_ID:-}"
}

# Prints noble, bookworm, ... — the apt suite name.
# MB_FAKE_CODENAME overrides it, which is how the unsupported-release fallback
# gets tested on a machine whose release *is* supported.
mb_codename() {
  if [[ -n "$MB_FAKE_CODENAME" ]]; then
    printf '%s' "$MB_FAKE_CODENAME"
    return 0
  fi
  local cn=""
  [[ -r /etc/os-release ]] && cn="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
  if [[ -z "$cn" ]] && mb_has lsb_release; then
    cn="$(lsb_release -cs 2>/dev/null || true)"
  fi
  printf '%s' "$cn"
}

# Prints amd64 | arm64 | armhf — normalised to Debian's spelling.
mb_arch() {
  case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    x86_64|amd64)   printf 'amd64' ;;
    aarch64|arm64)  printf 'arm64' ;;
    armv7l|armhf)   printf 'armhf' ;;
    *)              dpkg --print-architecture 2>/dev/null || uname -m ;;
  esac
}

mb_require_supported_os() {
  local os; os="$(mb_os)"
  if [[ "$os" == "unknown" ]]; then
    mb_warn "unrecognised distribution (expected Ubuntu or Debian) — continuing anyway"
  fi
}

# ---------------------------------------------------------------------------
# Privileges
# ---------------------------------------------------------------------------

# Re-exec under sudo when running from a file; when running from a pipe we
# cannot re-exec (stdin is the script and is already consumed), so we tell the
# user the exact command instead of silently doing nothing.
mb_require_root() {
  [[ $EUID -eq 0 ]] && return 0

  if [[ -n "${BASH_SOURCE[1]:-}" && -f "${BASH_SOURCE[1]}" ]]; then
    mb_log "root required — re-running with sudo"
    # Pass the MB_* settings explicitly rather than relying on `sudo -E`:
    # some sudo builds refuse to preserve the environment ("preserving the
    # entire environment is not supported, '-E' is ignored") and silently drop
    # them, which would lose --dry-run and a custom MB_BASE_URL across the
    # re-exec.
    exec sudo \
      MB_BASE_URL="$MB_BASE_URL" \
      MB_DRY_RUN="$MB_DRY_RUN" \
      MB_NONINTERACTIVE="$MB_NONINTERACTIVE" \
      MB_FAKE_CODENAME="$MB_FAKE_CODENAME" \
      bash "${BASH_SOURCE[1]}" "$@"
  fi

  mb_err "this script needs root."
  mb_err "re-run it as:"
  mb_err "  curl -fsSL ${MB_SELF_URL:-<script-url>} | sudo bash -s -- $*"
  exit 1
}

# The unprivileged user who invoked us, for tools installed per-user (nvm).
mb_invoking_user() {
  printf '%s' "${SUDO_USER:-${USER:-root}}"
}

mb_invoking_home() {
  local u; u="$(mb_invoking_user)"
  if [[ "$u" == "root" ]]; then printf '/root'; else getent passwd "$u" | cut -d: -f6; fi
}

# ---------------------------------------------------------------------------
# apt
# ---------------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive

_MB_APT_REFRESHED=""

mb_apt_refresh() {
  # apt-get update writes to /var/lib/apt/lists, so it is a mutation like any
  # other and is skipped under --dry-run. Anything needing a fresh index in a
  # dry run has to make do with the existing one.
  if [[ -n "$MB_DRY_RUN" ]]; then
    printf '%s[dry-run]%s apt-get update\n' "$_MB_C_DIM" "$_MB_C_RESET" >&2
    _MB_APT_REFRESHED=1
    return 0
  fi
  mb_log "apt-get update"
  apt-get update -qq
  _MB_APT_REFRESHED=1
}

# Refresh at most once per run.
#
# A fresh machine — a new cloud image, a minimal container — has an empty
# /var/lib/apt/lists. Without this, the very first `apt-get install` fails with
# "Unable to locate package", including the install of curl that everything
# else depends on. Refreshing on every install would be correct but slow, so it
# happens once and later calls ride on that index.
mb_apt_refresh_once() {
  [[ -n "$_MB_APT_REFRESHED" ]] && return 0
  mb_apt_refresh
}

mb_apt_install() {
  [[ $# -gt 0 ]] || return 0
  mb_apt_refresh_once
  mb_log "installing: $*"
  run apt-get install -y -qq \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold "$@"
}

# Ensure the packages needed to add third-party repos are present.
mb_apt_prereqs() {
  mb_apt_install ca-certificates curl gnupg
}

mb_pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

# Second gate, after the suite check: a repo can publish a suite while not
# having built the specific version you asked for (e.g. postgresql-18 before
# PGDG has built it). Ask apt rather than trusting the suite probe.
mb_apt_candidate() {
  apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2; exit}'
}

mb_apt_has_candidate() {
  # Under --dry-run the index was deliberately never refreshed, so a missing
  # candidate means "not in the stale index", not "not available". Reporting
  # absent would make the dry run describe a fallback a real run would not
  # take, which is worse than useless.
  if [[ -n "$MB_DRY_RUN" ]]; then
    mb_dim "dry run: assuming '$1' is available (package index not refreshed)"
    return 0
  fi

  local c
  c="$(mb_apt_candidate "$1")"
  [[ -n "$c" && "$c" != "(none)" ]]
}

# Install a signing key at <dest>, dearmouring if the source is ASCII-armoured.
# Idempotent: an existing keyring is left alone.
mb_add_keyring() {
  local url="$1" dest="$2" tmp
  if [[ -f "$dest" ]]; then
    mb_dim "keyring already present: $dest"
    return 0
  fi

  if [[ -n "$MB_DRY_RUN" ]]; then
    printf '%s[dry-run]%s fetch key %s -> %s\n' "$_MB_C_DIM" "$_MB_C_RESET" "$url" "$dest" >&2
    return 0
  fi

  tmp="$(mktemp)"
  curl -fsSL "$url" -o "$tmp" || { rm -f "$tmp"; mb_die "failed to fetch key: $url"; }

  mkdir -p "$(dirname "$dest")"

  # apt infers the key format from the destination's extension: a .asc is
  # expected to hold an ASCII-armoured key, a .gpg a binary keyring. Writing
  # binary data into a .asc makes apt fail to read the key and report
  # NO_PUBKEY — even though the key itself is perfectly valid. This is silent
  # and confusing, so the extension decides the format, not the source.
  local armored="" wants_armored=""
  grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$tmp" && armored=1
  case "$dest" in *.asc) wants_armored=1 ;; esac

  if [[ -n "$wants_armored" && -z "$armored" ]]; then
    mb_warn "${dest} is a .asc but the key is binary — apt may reject it"
  elif [[ -z "$wants_armored" && -n "$armored" ]]; then
    gpg --dearmor < "$tmp" > "${dest}.tmp" \
      || { rm -f "$tmp" "${dest}.tmp"; mb_die "failed to dearmor key: $url"; }
    mv "${dest}.tmp" "$dest"
    rm -f "$tmp"
  else
    mv "$tmp" "$dest"
  fi

  chmod 644 "$dest"
  mb_ok "added keyring $dest"
}

# Install an apt source file. mb_apt_source <filename> <contents-on-stdin>
mb_apt_source() {
  local name="$1"
  write_file "/etc/apt/sources.list.d/${name}"
}

# Does a vendor repo publish a suite for this codename?
#
# Returns 0 = published, 1 = not published, 2 = cannot tell.
#
# Only HTTP 200 means published. Negative controls return 404 from nginx.org,
# Docker and PGDG but 403 from packages.redis.io (S3-backed, which denies
# rather than 404s missing keys), so any other status than 200 is "not there".
#
# The 2 case matters. Without it, a missing curl or a dead network returns 000,
# which reads as "repo does not publish this release" and silently downgrades
# you to an old distribution package. Not knowing is not the same as knowing
# the answer is no, and the two need different handling.
mb_repo_probe() {
  local url="${1%/}" suite="$2" code

  # Minimal images (debian:slim, LXC templates, fresh cloud images) often have
  # neither curl nor wget. Callers should install the prerequisites first; this
  # is the backstop.
  mb_has curl || return 2

  code="$(curl -s -o /dev/null -w '%{http_code}' -I --max-time 10 \
            "${url}/dists/${suite}/Release" 2>/dev/null || echo 000)"

  case "$code" in
    200) return 0 ;;   # published
    000) return 2 ;;   # network failure or DNS — not a verdict
    *)   return 1 ;;   # 403/404 etc — genuinely not published
  esac
}

# Convenience wrapper: true only when positively confirmed as published.
mb_repo_supports() { mb_repo_probe "$1" "$2" 2>/dev/null; }

# Decide whether to use a vendor repo for the release we are running on.
# Returns 0 = configure and use it, 1 = fall back to distribution packages.
#
# Callers must install the apt prerequisites (which include curl) *before*
# probing, or a minimal image will report "cannot tell" every time.
mb_use_vendor_repo() {
  local label="$1" repo="$2" suite="$3" rc=0

  mb_repo_probe "$repo" "$suite" || rc=$?

  case "$rc" in
    0) return 0 ;;
    1) mb_warn "${label} does not publish a '${suite}' suite for $(mb_os) $(mb_os_version)."
       return 1 ;;
    *)
       mb_warn "${label}: could not check whether the '${suite}' suite exists"
       mb_warn "(no curl, or the network is unreachable)."
       mb_warn "Proceeding with ${label} rather than silently downgrading you"
       mb_warn "to an older distribution package."
       return 0 ;;
  esac
}

# Call at the top of a verify() function. Returns 0 (true) during a dry run,
# after printing why nothing can be verified — nothing was installed, so
# checking for the binary would report a failure that has not happened.
mb_dry_run_done() {
  local what="${1:-}"
  [[ -n "$MB_DRY_RUN" ]] || return 1
  mb_heading "Dry run complete"
  mb_dim "${what:+${what}: }no changes were made"
  return 0
}

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------

# Is systemd actually running, as opposed to merely installed?
#
# The systemctl binary exists in containers, chroots and WSL images where
# systemd is not PID 1 and cannot be talked to. Calling it there fails, and
# under `set -e` that failure aborts the script *after* a successful install —
# reporting an error for something that worked.
mb_systemd_running() { [[ -d /run/systemd/system ]]; }

# mb_service enable|start|restart|enable-now <unit>
mb_service() {
  local action="$1" unit="$2"

  if ! mb_has systemctl || ! mb_systemd_running; then
    mb_warn "systemd is not running — skipping '${action}' for ${unit}"
    return 0
  fi

  case "$action" in
    enable)     run systemctl enable "$unit" ;;
    start)      run systemctl start "$unit" ;;
    restart)    run systemctl restart "$unit" ;;
    enable-now) run systemctl enable --now "$unit" ;;
    *)          mb_die "mb_service: unknown action '$action'" ;;
  esac
}

# Report whether a unit is active, for the closing verification block.
mb_service_status() {
  local unit="$1"
  if ! mb_has systemctl || ! mb_systemd_running; then
    printf 'not running (no systemd)'
    return
  fi
  systemctl is-active "$unit" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

# Print the version line of a command, tolerating its absence.
#
# stderr is captured too: plenty of tools (nginx among them) print their
# version there rather than to stdout, and dropping it yields an empty string
# that reads like a failed install.
mb_version_of() {
  local cmd="$1"; shift
  if mb_has "$cmd"; then
    "$cmd" "$@" 2>&1 | head -n1
  else
    printf 'not installed'
  fi
}

mb_heading() {
  local title="$*" rule
  rule="$(printf '%*s' "${#title}" '' | tr ' ' '-')"
  printf '\n%s%s%s\n%s\n' "$_MB_C_INFO" "$title" "$_MB_C_RESET" "$rule" >&2
}

# Replace a tagged block in a file, leaving everything outside it untouched.
# Used for /etc/fstab and similar files we do not own. The block is delimited by
# `# >>> machine-bootstrap:<tag>` and `# <<< machine-bootstrap:<tag>`.
# Content for the block arrives on stdin.
mb_managed_block() {
  local file="$1" tag="$2" tmp
  local begin="# >>> machine-bootstrap:${tag}"
  local end="# <<< machine-bootstrap:${tag}"

  tmp="$(mktemp)"
  {
    if [[ -f "$file" ]]; then
      # Strip any existing block, then re-append the new one.
      awk -v b="$begin" -v e="$end" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }
      ' "$file"
    fi
    printf '%s\n' "$begin"
    cat
    printf '%s\n' "$end"
  } > "$tmp"

  if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
    mb_dim "unchanged: $file"
    rm -f "$tmp"
    return 0
  fi

  run cp -a "$file" "${file}.bak" 2>/dev/null || true
  if [[ -n "$MB_DRY_RUN" ]]; then
    printf '%s[dry-run]%s update block '%s' in %s\n' \
      "$_MB_C_DIM" "$_MB_C_RESET" "$tag" "$file" >&2
    rm -f "$tmp"
    return 0
  fi
  cat "$tmp" > "$file"
  rm -f "$tmp"
  mb_ok "updated $file"
}
