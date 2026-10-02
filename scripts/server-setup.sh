#!/usr/bin/env bash
#
# server-setup.sh — pick what to install, and install it.
#
#   curl -fsSL <url>/scripts/server-setup.sh | sudo bash
#
# This is a menu and an orchestrator, nothing more. Every install it performs is
# done by running the individual script from this repo — it never reimplements
# one. Those scripts are downloaded into a temp directory laid out to mirror the
# repository, so each one finds the shared library beside it and nothing is
# fetched twice.

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

export MB_SELF_URL="${MB_BASE_URL}/scripts/server-setup.sh"

# Canonical execution order, independent of menu order.
#
#   base    first, so the upgrade happens before packages are installed
#   nginx   before certbot, which the wizard then needs
#   wizard  last, by construction — it depends on nginx and certbot
STEPS=(base postgres docker redis nvm wormhole nginx certbot wizard)

WORK_DIR=""
LOG_DIR=""
declare -a SELECTED=()
declare -a RESULTS=()

# --- Options ----------------------------------------------------------------

WITH=""
DRY_RUN_FLAG=""
KEEP_GOING=""
YES=""

PG_VERSION=""; NGINX_BRANCH=""; CERTBOT_METHOD=""; NODE_FLAVOR=""; WORMHOLE_METHOD=""
DOMAIN=""; EMAIL=""

usage() {
  cat <<'EOF'
server-setup.sh — choose what to install, then install it

Usage:
  server-setup.sh [options]

Selection:
  --with a,b,c     Install these, skipping the menu
                   base, postgres, docker, redis, nginx, certbot, nvm,
                   wormhole, wizard
  --all            Everything except the site wizard
  --list           Print the catalog and exit

Behaviour:
  --keep-going     Continue after a failed step (default: stop and report)
  --dry-run        Pass --dry-run to every script
  -y, --yes        Pass --yes to every script: never prompt
  -h, --help       Show this help

Forwarded to the individual scripts:
  --pg-version 16|17|18        PostgreSQL major (default 17)
  --nginx-branch stable|mainline
  --certbot-method snap|apt
  --node lts|latest            Node.js flavor
  --wormhole-method apt|pipx
  --domain FQDN                For the site wizard
  --email ADDR                 For the site wizard

Environment:
  MB_BASE_URL   Where to fetch the individual scripts from. Defaults to this
                repository's main branch. Point it at a tag or a fork to test.

Examples:
  # interactive menu
  curl -fsSL <url>/scripts/server-setup.sh | sudo bash

  # unattended: nginx and a certificate, nothing else
  curl -fsSL <url>/scripts/server-setup.sh | sudo bash -s -- \
    --with nginx,certbot --domain example.com --email you@example.com --yes

  # see what a full run would do, without doing it
  curl -fsSL <url>/scripts/server-setup.sh | sudo bash -s -- --all --dry-run
EOF
}

need_arg() { [[ -n "${2:-}" ]] || mb_die "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with)             need_arg "$1" "${2:-}"; WITH="$2"; shift 2 ;;
    --with=*)           WITH="${1#*=}"; shift ;;
    --all)              WITH="base,postgres,docker,redis,nvm,wormhole,nginx,certbot"; shift ;;
    --list)             printf '%s\n' "${STEPS[@]}"; exit 0 ;;
    --keep-going)       KEEP_GOING=1; shift ;;
    --dry-run)          DRY_RUN_FLAG=1; export MB_DRY_RUN=1; shift ;;
    -y|--yes)           YES=1; export MB_NONINTERACTIVE=1; shift ;;
    --pg-version)       need_arg "$1" "${2:-}"; PG_VERSION="$2"; shift 2 ;;
    --pg-version=*)     PG_VERSION="${1#*=}"; shift ;;
    --nginx-branch)     need_arg "$1" "${2:-}"; NGINX_BRANCH="$2"; shift 2 ;;
    --nginx-branch=*)   NGINX_BRANCH="${1#*=}"; shift ;;
    --certbot-method)   need_arg "$1" "${2:-}"; CERTBOT_METHOD="$2"; shift 2 ;;
    --certbot-method=*) CERTBOT_METHOD="${1#*=}"; shift ;;
    --node)             need_arg "$1" "${2:-}"; NODE_FLAVOR="$2"; shift 2 ;;
    --node=*)           NODE_FLAVOR="${1#*=}"; shift ;;
    --wormhole-method)  need_arg "$1" "${2:-}"; WORMHOLE_METHOD="$2"; shift 2 ;;
    --wormhole-method=*) WORMHOLE_METHOD="${1#*=}"; shift ;;
    --domain)           need_arg "$1" "${2:-}"; DOMAIN="$2"; shift 2 ;;
    --domain=*)         DOMAIN="${1#*=}"; shift ;;
    --email)            need_arg "$1" "${2:-}"; EMAIL="$2"; shift 2 ;;
    --email=*)          EMAIL="${1#*=}"; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  mb_die "unknown option: $1 (try --help)" ;;
  esac
done

# --- Catalog ----------------------------------------------------------------

# key|label
CATALOG=(
  "base|Base server prep — upgrade, timezone, swap, firewall, user, SSH hardening"
  "postgres|PostgreSQL — 16, 17 or 18"
  "docker|Docker Engine + buildx + compose plugin"
  "redis|Redis — 8 (current) or 7.4 (last BSD-licensed line)"
  "nginx|nginx — stable or mainline"
  "certbot|certbot — snap or apt, with the nginx authenticator"
  "nvm|nvm + Node.js — LTS or latest"
  "wormhole|magic-wormhole — file transfer between machines"
  "wizard|Site wizard — serve a domain over HTTPS (needs nginx + certbot)"
)

catalog_label() {
  local entry
  for entry in "${CATALOG[@]}"; do
    [[ "${entry%%|*}" == "$1" ]] && { printf '%s' "${entry#*|}"; return; }
  done
}

step_script() {
  case "$1" in
    base)     printf 'base.sh' ;;
    postgres) printf 'postgres.sh' ;;
    docker)   printf 'docker.sh' ;;
    redis)    printf 'redis.sh' ;;
    nginx)    printf 'nginx.sh' ;;
    certbot)  printf 'certbot.sh' ;;
    nvm)      printf 'nvm.sh' ;;
    wormhole) printf 'wormhole.sh' ;;
    wizard)   printf 'site-wizard.sh' ;;
    *)        return 1 ;;
  esac
}

# --- Menu -------------------------------------------------------------------

show_menu() {
  {
    printf '\n  What would you like to install?\n\n'
    local i=1 key
    for key in "${STEPS[@]}"; do
      printf '  %d) %-9s %s\n' "$i" "$key" "$(catalog_label "$key")"
      i=$((i + 1))
    done
    printf '\n  Give one or more numbers, separated by spaces or commas.\n'
    printf '  Ranges work too: 2-4\n'
    printf '  a) everything except the wizard      r) recommended (base, nginx, certbot)\n'
    printf '  q) quit\n\n'
  } >/dev/tty
}

parse_selection() {
  # Accepts "1,3,5" / "1 3 5" / "2-4" / "n" / "all" / "recommended".
  local input="$1" token lo hi i idx
  local -a keys=()

  input="${input//,/ }"

  for token in $input; do
    case "$token" in
      a|all)         keys=(base postgres docker redis nvm wormhole nginx certbot); break ;;
      r|recommended) keys=(base nginx certbot); break ;;
      q|quit|exit)   return 2 ;;
      *-*)
        lo="${token%%-*}"; hi="${token##*-}"
        if [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]]; then
          for (( i = lo; i <= hi; i++ )); do
            (( i >= 1 && i <= ${#STEPS[@]} )) && keys+=("${STEPS[$((i - 1))]}")
          done
        else
          mb_warn "could not read '${token}' — ignoring"
        fi
        ;;
      *)
        if [[ "$token" =~ ^[0-9]+$ ]]; then
          idx=$((token - 1))
          if (( idx >= 0 && idx < ${#STEPS[@]} )); then
            keys+=("${STEPS[$idx]}")
          else
            mb_warn "no option numbered ${token} — ignoring"
          fi
        elif [[ " ${STEPS[*]} " == *" $token "* ]]; then
          keys+=("$token")
        else
          mb_warn "unrecognised choice '${token}' — ignoring"
        fi
        ;;
    esac
  done

  # De-duplicate, then impose the canonical order so the user's input order
  # cannot put the wizard before nginx.
  local -a chosen=() key
  for key in "${STEPS[@]}"; do
    local k
    for k in "${keys[@]}"; do
      [[ "$k" == "$key" ]] && chosen+=("$key") && break
    done
  done

  [[ ${#chosen[@]} -gt 0 ]] || return 1
  SELECTED=("${chosen[@]}")
}

choose_interactively() {
  local input=""
  while :; do
    show_menu
    printf '  > ' >/dev/tty
    IFS= read -r input </dev/tty || input=""
    [[ -n "$input" ]] || { mb_warn "nothing selected"; continue; }

    local rc=0
    parse_selection "$input" || rc=$?
    case "$rc" in
      0) return 0 ;;
      2) mb_log "nothing to do"; exit 0 ;;
      *) continue ;;
    esac
  done
}

# --- Preparation ------------------------------------------------------------

prepare_work_dir() {
  # Mirror the repository layout. This is what lets each child script find
  # lib/common.sh beside it and skip a second download.
  WORK_DIR="$(mktemp -d -t mb-setup.XXXXXX)"
  LOG_DIR="${WORK_DIR}/logs"
  mkdir -p "${WORK_DIR}/scripts/lib" "$LOG_DIR"

  local src_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  # A local checkout: use it directly rather than downloading ourselves.
  if [[ -n "$src_dir" && -f "${src_dir}/lib/common.sh" ]]; then
    mb_dim "using the local checkout at ${src_dir}"
    cp -a "${src_dir}/lib/common.sh" "${WORK_DIR}/scripts/lib/common.sh"
    local key file
    for key in "${SELECTED[@]}"; do
      file="$(step_script "$key")"
      [[ -f "${src_dir}/${file}" ]] || mb_die "missing script in checkout: ${file}"
      cp -a "${src_dir}/${file}" "${WORK_DIR}/scripts/${file}"
    done
    return 0
  fi

  mb_log "fetching scripts from ${MB_BASE_URL}"

  # Fetch even under --dry-run. Downloading reads the network and writes only
  # to our own temp dir, and without the scripts there is nothing to dry-run.
  curl -fsSL --retry 3 --connect-timeout 15 \
    "${MB_BASE_URL}/scripts/lib/common.sh" \
    -o "${WORK_DIR}/scripts/lib/common.sh" \
    || mb_die "could not fetch common.sh from ${MB_BASE_URL}"

  local key file
  for key in "${SELECTED[@]}"; do
    file="$(step_script "$key")"
    curl -fsSL --retry 3 --connect-timeout 15 \
      "${MB_BASE_URL}/scripts/${file}" \
      -o "${WORK_DIR}/scripts/${file}" \
      || mb_die "could not fetch ${file} from ${MB_BASE_URL}"
  done
  mb_ok "fetched ${#SELECTED[@]} script(s)"
}

# Build the argument list for one step from the options we were given.
step_args() {
  local key="$1"
  local -a args=()
  [[ -n "$DRY_RUN_FLAG" ]] && args+=(--dry-run)
  [[ -n "$YES" ]] && args+=(--yes)

  case "$key" in
    postgres) [[ -n "$PG_VERSION" ]] && args+=(--version "$PG_VERSION") ;;
    nginx)    [[ -n "$NGINX_BRANCH" ]] && args+=(--branch "$NGINX_BRANCH") ;;
    certbot)  { [[ -n "$CERTBOT_METHOD" ]] && args+=(--method "$CERTBOT_METHOD"); } ;;
    nvm)      [[ -n "$NODE_FLAVOR" ]] && args+=(--node "$NODE_FLAVOR") ;;
    wormhole) [[ -n "$WORMHOLE_METHOD" ]] && args+=(--method "$WORMHOLE_METHOD") ;;
    wizard)
      args+=(--plugin none)
      [[ -n "$DOMAIN" ]] && args+=(--domain "$DOMAIN")
      [[ -n "$EMAIL" ]] && args+=(--email "$EMAIL")
      ;;
  esac

  # bash 4.4+ prints an empty expansion as nothing at all
  printf '%s\n' "${args[@]+"${args[@]}"}"
}

run_step() {
  local key="$1" file log rc
  file="$(step_script "$key")"
  log="${LOG_DIR}/${key}.log"

  mb_heading "[${key}] $(catalog_label "$key")"

  # The children are run even under --dry-run, with --dry-run passed through.
  # They print every command they would run, so a top-level dry run shows the
  # real plan rather than just naming the steps.
  local -a args=()
  while IFS= read -r a; do [[ -n "$a" ]] && args+=("$a"); done < <(step_args "$key")

  # Run as a child process so a failure cannot corrupt this script's state.
  # Everything the child needs travels in the environment.
  set +e
  MB_BASE_URL="$MB_BASE_URL" \
  MB_DRY_RUN="$MB_DRY_RUN" \
  MB_NONINTERACTIVE="$MB_NONINTERACTIVE" \
    bash "${WORK_DIR}/scripts/${file}" ${args[@]+"${args[@]}"} 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e

  if (( rc == 0 )); then
    mb_ok "${key} done"
    RESULTS+=("${key}|ok|$(tail -n 3 "$log" | grep -E '^(  ok|==>)' | head -n1 | sed 's/^  ok //;s/^==> //' || true)")
  else
    mb_err "${key} failed (exit ${rc})"
    RESULTS+=("${key}|FAILED|see ${log}")
  fi
  return "$rc"
}

# --- Summary ----------------------------------------------------------------

summary() {
  local overall=0
  {
    printf '\n'
    printf '  %-10s %-9s %s\n' "STEP" "RESULT" "NOTE"
    printf '  %-10s %-9s %s\n' "----" "------" "----"
    local row key result note
    for row in "${RESULTS[@]}"; do
      IFS='|' read -r key result note <<< "$row"
      printf '  %-10s %-9s %s\n' "$key" "$result" "$note"
    done
    printf '\n'
  } >&2

  local row
  for row in "${RESULTS[@]}"; do
    [[ "${row#*|}" == FAILED* ]] && overall=1
  done

  if (( overall != 0 )); then
    mb_warn "some steps failed — re-run just those with:"
    for row in "${RESULTS[@]}"; do
      if [[ "${row#*|}" == FAILED* ]]; then
        local key="${row%%|*}"
        mb_dim "  $(step_script "$key") $(step_args "$key" 2>/dev/null | tr '\n' ' ')"
      fi
    done
    [[ -n "$LOG_DIR" ]] && mb_dim "logs: ${LOG_DIR}"
    return 1
  fi

  mb_ok "all steps completed"
  [[ -n "$LOG_DIR" && -d "$LOG_DIR" ]] && mb_dim "logs: ${LOG_DIR}"
}

# --- Main -------------------------------------------------------------------

main() {
  mb_require_root "$@"
  mb_require_supported_os

  mb_heading "Server setup"
  printf 'host: %s %s (%s, %s)\n' \
    "$(mb_os)" "$(mb_os_version)" "$(mb_codename)" "$(mb_arch)" >&2

  if [[ -n "$MB_DRY_RUN" ]]; then
    mb_warn "DRY RUN — nothing will be changed"
  fi

  # --- selection
  if [[ -n "$WITH" ]]; then
    local rc=0
    parse_selection "${WITH//,/ }" || rc=$?
    (( rc == 0 )) || mb_die "nothing valid in --with '${WITH}'"
  elif [[ -n "$MB_NONINTERACTIVE" ]] || ! mb_tty; then
    mb_warn "no terminal and no --with — installing the recommended set"
    mb_warn "pass --with base,nginx,certbot (or --all) to choose deliberately"
    SELECTED=(base nginx certbot)
  else
    choose_interactively
  fi

  # --- the wizard needs nginx and certbot to exist
  local key
  for key in "${SELECTED[@]}"; do
    if [[ "$key" == "wizard" ]]; then
      local has_nginx="" has_certbot=""
      [[ " ${SELECTED[*]} " == *" nginx "* ]] && has_nginx=1
      [[ " ${SELECTED[*]} " == *" certbot "* ]] && has_certbot=1
      mb_has nginx   && has_nginx=1
      mb_has certbot && has_certbot=1
      if [[ -z "$has_nginx" || -z "$has_certbot" ]]; then
        mb_die "the site wizard needs nginx and certbot — add them to the selection"
      fi
    fi
  done

  # --- confirmation
  mb_heading "About to run, in this order"
  for key in "${SELECTED[@]}"; do
    mb_dim "  ${key}  — $(catalog_label "$key")"
  done

  if [[ -z "$DRY_RUN_FLAG" && -z "$MB_NONINTERACTIVE" ]] && mb_tty; then
    if ! mb_confirm "Proceed?" y; then
      mb_log "nothing was changed"
      exit 0
    fi
  fi

  # --- run
  prepare_work_dir

  set +e
  for key in "${SELECTED[@]}"; do
    if ! run_step "$key"; then
      if [[ -z "$KEEP_GOING" ]]; then
        mb_warn "stopping after the failed '${key}' step"
        mb_warn "pass --keep-going to continue past failures"
        break
      fi
    fi
  done
  set -e

  summary
}

main "$@"
