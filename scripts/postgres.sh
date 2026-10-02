#!/usr/bin/env bash
#
# postgres.sh — install PostgreSQL 16, 17 or 18 from the PGDG repository.
#
#   curl -fsSL <url>/scripts/postgres.sh | sudo bash -s -- --version 17
#
# The distribution repositories only carry one PostgreSQL major (the one that
# shipped with the release), which is why this uses the PostgreSQL Global
# Development Group repo — it carries every supported major side by side, so
# you can run 16 and 18 on the same box.

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

export MB_SELF_URL="${MB_BASE_URL}/scripts/postgres.sh"

PGDG_KEY_URL="https://www.postgresql.org/media/keys/ACCC4CF8.asc"
PGDG_KEYRING="/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc"
PGDG_REPO="https://apt.postgresql.org/pub/repos/apt"

# --- Options ----------------------------------------------------------------

PG_VERSION=""
FORCE=""
STRICT=""
FALLBACK_DISTRO=""

usage() {
  cat <<'EOF'
postgres.sh — install PostgreSQL from the PGDG repository

Usage:
  postgres.sh [options]

Options:
  --version 16|17|18   PostgreSQL major version to install (default: 17)
  --strict-version     Fail rather than substitute a different major
  --force              Reinstall / re-run even if already present
  --dry-run            Print what would happen, change nothing
  -y, --yes            Never prompt; use defaults
  -h, --help           Show this help

Notes:
  PostgreSQL majors are supported for 5 years. At the time of writing 16, 17 and
  18 are all current; 16 is the oldest and 18 the newest.

  Multiple majors can coexist on one host — each gets its own cluster and its
  own port (5432, 5433, ...). This script installs one and leaves existing
  clusters alone.

  This script does not touch pg_hba.conf. A fresh PGDG install authenticates
  local connections with peer auth, which is deliberate: it means the database
  is not reachable off-box until you decide how it should be.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)        PG_VERSION="${2:-}"; shift 2 ;;
    --version=*)      PG_VERSION="${1#*=}"; shift ;;
    --strict-version) STRICT=1; shift ;;
    --force)          FORCE=1; shift ;;
    --dry-run)        export MB_DRY_RUN=1; shift ;;
    -y|--yes)         export MB_NONINTERACTIVE=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                mb_die "unknown option: $1 (try --help)" ;;
  esac
done

# --- Steps ------------------------------------------------------------------

add_pgdg_repo() {
  local codename suite
  codename="$(mb_codename)"
  suite="${codename}-pgdg"

  # curl has to be present before the probe below can mean anything.
  mb_apt_prereqs

  if [[ -z "$codename" ]] || ! mb_use_vendor_repo "PGDG" "$PGDG_REPO" "$suite"; then
    mb_warn "Falling back to the distribution's PostgreSQL package — it is a"
    mb_warn "single older major and cannot be chosen."
    FALLBACK_DISTRO=1
    return 0
  fi

  mb_add_keyring "$PGDG_KEY_URL" "$PGDG_KEYRING"

  mb_apt_source "pgdg.sources" <<EOF
Types: deb
URIs: ${PGDG_REPO}
Suites: ${suite}
Components: main
Signed-By: ${PGDG_KEYRING}
EOF

  mb_apt_refresh
}

install_package() {
  if [[ -n "$FALLBACK_DISTRO" ]]; then
    mb_apt_install postgresql postgresql-contrib
    return 0
  fi

  local pkg="postgresql-${PG_VERSION}"

  # The suite can exist while this particular major was never built for it.
  if ! mb_apt_has_candidate "$pkg"; then
    local have; have="$(mb_apt_candidate postgresql)"
    if [[ -n "$STRICT" ]]; then
      mb_die "PGDG has no ${pkg} for $(mb_codename), and --strict-version was given"
    fi
    mb_warn "PGDG has no package '${pkg}' for $(mb_codename)."
    mb_warn "Installing the distribution's PostgreSQL instead${have:+ (${have})} — THAT IS NOT VERSION ${PG_VERSION}."
    mb_apt_install postgresql postgresql-contrib
    FALLBACK_DISTRO=1
    return 0
  fi

  mb_apt_install "$pkg" "postgresql-contrib-${PG_VERSION}"
}

verify() {
  mb_dry_run_done "PostgreSQL" && return 0

  mb_heading "PostgreSQL installed"

  if ! mb_has psql; then
    mb_err "psql not found after install"
    return 1
  fi
  mb_ok "$(mb_version_of psql --version)"

  # pg_lsclusters ships with postgresql-common and lists every cluster,
  # not just the one we installed.
  if mb_has pg_lsclusters; then
    printf '\n' >&2
    pg_lsclusters >&2 || true
  fi

  if [[ -n "$FALLBACK_DISTRO" ]]; then
    mb_warn "installed from the distribution, not PGDG"
    mb_warn "the major version is whatever your release ships, not ${PG_VERSION}"
  fi

  printf '\n' >&2
  mb_dim "connect with:  sudo -u postgres psql"
  mb_dim "logs:          journalctl -u postgresql"
}

main() {
  mb_require_root "$@"
  mb_require_supported_os

  if [[ -z "$PG_VERSION" ]]; then
    mb_choose PG_VERSION "Which PostgreSQL major version?" "17" 16 17 18
  fi

  case "$PG_VERSION" in
    16|17|18) ;;
    *) mb_die "unsupported version '${PG_VERSION}' (this script supports 16, 17, 18)" ;;
  esac

  if mb_pkg_installed "postgresql-${PG_VERSION}" && [[ -z "$FORCE" ]]; then
    mb_log "postgresql-${PG_VERSION} is already installed"
    mb_log "re-run with --force to reinstall"
    verify
    exit 0
  fi

  mb_heading "Installing PostgreSQL ${PG_VERSION}"
  add_pgdg_repo
  install_package
  verify
}

main "$@"
