#!/usr/bin/env bash
#
# install.sh — run any of the individual scripts by name.
#
#   curl -fsSL <url>/install.sh | sudo bash -s -- postgres --version 17
#
# This is only a convenience. Each script in scripts/ is standalone and can be
# fetched and run directly; this just saves you remembering the URL.

set -Eeuo pipefail

MB_BASE_URL="${MB_BASE_URL:-https://raw.githubusercontent.com/fuunshi/machine-bootstrap/main}"

TOOLS="postgres docker redis nginx certbot nvm wormhole base site-wizard server-setup"

usage() {
  cat <<EOF
install.sh — run a machine-bootstrap script by name

Usage:
  install.sh <tool> [options]

Tools:
  postgres       PostgreSQL 16, 17 or 18
  docker         Docker Engine from Docker's official repository
  redis          Redis 7.4 or 8
  nginx          nginx, stable or mainline
  certbot        certbot via snap or apt
  nvm            nvm and Node.js
  wormhole       magic-wormhole
  base           Baseline server setup (upgrade, swap, firewall, SSH)
  site-wizard    Serve a domain over HTTPS
  server-setup   The interactive all-in-one

Examples:
  curl -fsSL ${MB_BASE_URL}/install.sh | sudo bash -s -- postgres --version 17
  curl -fsSL ${MB_BASE_URL}/install.sh | sudo bash -s -- nginx --branch mainline
  curl -fsSL ${MB_BASE_URL}/install.sh | sudo bash -s -- server-setup

Run a tool with --help to see its own options:
  curl -fsSL ${MB_BASE_URL}/install.sh | sudo bash -s -- nginx --help

Environment:
  MB_BASE_URL   Where to fetch the scripts from (default: the main branch).
                Point it at a tag for a reproducible run.
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

case "$1" in
  -h|--help|help) usage; exit 0 ;;
esac

TOOL="$1"; shift

# Reject anything not in the list rather than fetching an arbitrary path.
if [[ " ${TOOLS} " != *" ${TOOL} "* ]]; then
  printf 'unknown tool: %s\n\n' "$TOOL" >&2
  usage >&2
  exit 1
fi

URL="${MB_BASE_URL}/scripts/${TOOL}.sh"
TMP="$(mktemp -t "mb-${TOOL}.XXXXXX.sh")"
trap 'rm -f "$TMP"' EXIT

printf '==> fetching %s\n' "$URL" >&2
if ! curl -fsSL --retry 3 --connect-timeout 15 "$URL" -o "$TMP"; then
  printf 'could not fetch %s\n' "$URL" >&2
  exit 1
fi

# Check it parses before handing it to bash — a truncated download should fail
# here, not halfway through an install.
if ! bash -n "$TMP" 2>/dev/null; then
  printf 'the downloaded script is not valid bash — aborting\n' >&2
  exit 1
fi

# Run it. stdin stays the terminal so the child's prompts work normally, which
# is the advantage this has over piping the child straight to bash.
exec bash "$TMP" "$@"
