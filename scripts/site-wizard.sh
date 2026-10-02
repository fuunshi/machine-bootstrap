#!/usr/bin/env bash
#
# site-wizard.sh — serve a domain over HTTPS with nginx and certbot.
#
#   curl -fsSL <url>/scripts/site-wizard.sh | sudo bash -s -- \
#     --domain example.com --email you@example.com
#
# This owns the nginx configuration rather than letting `certbot --nginx`
# rewrite it. That plugin edits your server blocks in place, is not idempotent,
# and takes ownership of files you may want to edit by hand — so instead this
# issues the certificate with `certbot certonly --webroot` and writes the TLS
# configuration itself.

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

export MB_SELF_URL="${MB_BASE_URL}/scripts/site-wizard.sh"

# --- Options ----------------------------------------------------------------

DOMAIN=""
EMAIL=""
WEBROOT=""

NO_WWW=""
HSTS=""
PROXY=""
SKIP_DNS=""
TEST_RENEWAL=""

usage() {
  cat <<'EOF'
site-wizard.sh — serve a domain over HTTPS

Usage:
  site-wizard.sh --domain example.com --email you@example.com [options]

Options:
  --domain FQDN        Domain to serve (required)
  --email ADDR         Contact address for Let's Encrypt (required)
  --www                Also serve and certify www.<domain> (default)
  --no-www             Only serve the bare domain
  --webroot PATH       Document root (default: /var/www/<domain>)
  --proxy host:port    Reverse-proxy to a local backend instead of serving files
  --hsts               Send a strict-transport-security header
  --skip-dns-check     Do not verify that the domain points here
  --test-renewal       Run `certbot renew --dry-run` at the end
  --dry-run, -y/--yes, -h/--help as usual

Before you run this:
  The domain must already resolve to this machine, and port 80 must be open.
  Let's Encrypt validates control of the domain by fetching a file over plain
  HTTP — if DNS is not pointed here yet, issuance fails and you have spent one
  of the rate-limited attempts.

  This script checks DNS first and stops if it looks wrong, unless you pass
  --skip-dns-check.

About HSTS:
  Strict-Transport-Security tells browsers to refuse plain HTTP for this domain
  *and every subdomain*, for as long as the max-age. It is easy to enable and
  painful to undo — a subdomain that cannot serve TLS becomes unreachable.
  It is off unless you ask for it.
EOF
}

need_arg() { [[ -n "${2:-}" ]] || mb_die "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)           need_arg "$1" "${2:-}"; DOMAIN="$2"; shift 2 ;;
    --domain=*)         DOMAIN="${1#*=}"; shift ;;
    --email)            need_arg "$1" "${2:-}"; EMAIL="$2"; shift 2 ;;
    --email=*)          EMAIL="${1#*=}"; shift ;;
    --www)              NO_WWW=""; shift ;;
    --no-www)           NO_WWW=1; shift ;;
    --webroot)          need_arg "$1" "${2:-}"; WEBROOT="$2"; shift 2 ;;
    --webroot=*)        WEBROOT="${1#*=}"; shift ;;
    --proxy)            need_arg "$1" "${2:-}"; PROXY="$2"; shift 2 ;;
    --proxy=*)          PROXY="${1#*=}"; shift ;;
    --hsts)             HSTS=1; shift ;;
    --skip-dns-check)   SKIP_DNS=1; shift ;;
    --test-renewal)     TEST_RENEWAL=1; shift ;;
    --dry-run)          export MB_DRY_RUN=1; shift ;;
    -y|--yes)           export MB_NONINTERACTIVE=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  mb_die "unknown option: $1 (try --help)" ;;
  esac
done

# --- Helpers ----------------------------------------------------------------

conf_dir() {
  # nginx.org builds use conf.d; Debian/Ubuntu builds use sites-available.
  # Writing to the wrong one means the site silently never loads.
  if [[ -d /etc/nginx/conf.d ]]; then
    printf '/etc/nginx/conf.d'
  elif [[ -d /etc/nginx/sites-available ]]; then
    printf '/etc/nginx/sites-available'
  else
    mb_die "cannot find an nginx configuration directory — is nginx installed?"
  fi
}

public_ip() {
  local ip=""
  ip="$(curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -fsSL --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  printf '%s' "$ip"
}

check_dns() {
  [[ -n "$SKIP_DNS" ]] && { mb_dim "skipping the DNS check"; return 0; }

  local want; want="$(public_ip)"
  if [[ -z "$want" ]]; then
    mb_warn "could not determine this machine's public IP — skipping the DNS check"
    return 0
  fi

  # Compare against *all* addresses the name resolves to. Checking only the
  # first would pass or fail wrongly on hosts that prefer IPv6.
  local -a resolved=()
  mapfile -t resolved < <(getent ahosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)

  if [[ ${#resolved[@]} -eq 0 ]]; then
    mb_err "${DOMAIN} does not resolve at all."
    mb_err "create the DNS record first, or pass --skip-dns-check to override."
    return 1
  fi

  local ip
  for ip in "${resolved[@]}"; do
    if [[ "$ip" == "$want" ]]; then
      mb_ok "${DOMAIN} resolves to ${want} — matches this machine"
      return 0
    fi
  done

  mb_err "${DOMAIN} resolves to ${resolved[*]}, but this machine is ${want}."
  mb_err ""
  mb_err "Let's Encrypt validates over HTTP from the public internet, so this"
  mb_err "will fail and consume a rate-limited attempt."
  if [[ -n "$MB_NONINTERACTIVE" ]] || ! mb_tty; then
    return 1
  fi
  mb_confirm "Continue anyway?" n
}

write_http_block() {
  local dir target
  dir="$(conf_dir)"
  target="${dir}/${DOMAIN}.conf"

  mb_log "writing ${target}"

  if [[ -n "$PROXY" ]]; then
    write_file "$target" <<EOF
# Managed by machine-bootstrap. Edits may be overwritten on re-run.
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAMES};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT_RESOLVED};
    }

    location / {
        proxy_pass http://${PROXY};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  else
    write_file "$target" <<EOF
# Managed by machine-bootstrap. Edits may be overwritten on re-run.
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAMES};

    root ${WEBROOT_RESOLVED};
    index index.html;

    location /.well-known/acme-challenge/ {
        root ${WEBROOT_RESOLVED};
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  fi

  # Debian-style layouts need the symlink into sites-enabled.
  if [[ "$dir" == "/etc/nginx/sites-available" ]]; then
    run ln -sf "$target" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
  fi
}

write_https_block() {
  local dir target
  dir="$(conf_dir)"
  target="${dir}/${DOMAIN}.conf"

  local hsts_line=""
  if [[ -n "$HSTS" ]]; then
    hsts_line='add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;'
  fi

  local location_block
  if [[ -n "$PROXY" ]]; then
    location_block="$(cat <<EOF
    location / {
        proxy_pass http://${PROXY};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
EOF
)"
  else
    location_block="$(cat <<EOF
    root ${WEBROOT_RESOLVED};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
EOF
)"
  fi

  write_file "$target" <<EOF
# Managed by machine-bootstrap. Edits may be overwritten on re-run.

server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAMES};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT_RESOLVED};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${SERVER_NAMES};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ${hsts_line}

${location_block}
}
EOF

  if [[ "$dir" == "/etc/nginx/sites-available" ]]; then
    run ln -sf "$target" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
  fi
}

reload_nginx() {
  # Validate, and roll back our own file if it does not pass. A broken config
  # would otherwise stop nginx from starting on the next reboot.
  local dir target
  dir="$(conf_dir)"
  target="${dir}/${DOMAIN}.conf"

  if [[ -n "$MB_DRY_RUN" ]]; then
    printf '%s[dry-run]%s nginx -t && systemctl reload nginx\n' "$_MB_C_DIM" "$_MB_C_RESET" >&2
    return 0
  fi

  if ! nginx -t 2>/dev/null; then
    mb_err "the generated configuration is invalid:"
    nginx -t 2>&1 | sed 's/^/    /' >&2 || true
    mb_err "removing ${target}"
    rm -f "$target"
    if [[ "$dir" == "/etc/nginx/sites-available" ]]; then
      rm -f "/etc/nginx/sites-enabled/${DOMAIN}.conf"
    fi
    mb_err "nginx was left running with its previous configuration"
    return 1
  fi
  mb_ok "configuration validated"

  mb_service reload nginx 2>/dev/null || mb_service restart nginx
  mb_ok "nginx reloaded"
}

# --- Main -------------------------------------------------------------------

main() {
  mb_require_root "$@"

  if [[ -z "$DOMAIN" ]]; then
    mb_ask DOMAIN "Domain name" ""
    [[ -n "$DOMAIN" ]] || mb_die "--domain is required"
  fi
  if [[ -z "$EMAIL" ]]; then
    mb_ask EMAIL "Email for Let's Encrypt" ""
    [[ -n "$EMAIL" ]] || mb_die "--email is required"
  fi

  WEBROOT_RESOLVED="${WEBROOT:-/var/www/${DOMAIN}}"

  SERVER_NAMES="$DOMAIN"
  CERT_NAMES_WWW=""
  if [[ -z "$NO_WWW" ]]; then
    SERVER_NAMES="${DOMAIN} www.${DOMAIN}"
    CERT_NAMES_WWW="www.${DOMAIN}"
  fi

  mb_heading "Setting up ${DOMAIN}"
  mb_dim "document root: ${WEBROOT_RESOLVED}"
  [[ -n "$PROXY" ]] && mb_dim "proxying to:   http://${PROXY}"

  mb_has nginx  || mb_die "nginx is not installed — run scripts/nginx.sh first"
  mb_has certbot || mb_die "certbot is not installed — run scripts/certbot.sh first"

  check_dns || mb_die "DNS check failed — nothing was changed"

  # --- Serve over HTTP first, so the ACME challenge can be answered.
  run mkdir -p "$WEBROOT_RESOLVED/.well-known/acme-challenge"
  if [[ -z "$PROXY" && ! -e "${WEBROOT_RESOLVED}/index.html" ]]; then
    write_file "${WEBROOT_RESOLVED}/index.html" <<EOF
<!doctype html>
<title>${DOMAIN}</title>
<h1>${DOMAIN} is up</h1>
EOF
  fi

  write_http_block
  reload_nginx || mb_die "nginx configuration failed — nothing was certified"

  # --- Issue the certificate.
  local -a cert_args=(certonly --webroot -w "$WEBROOT_RESOLVED"
                      -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
                      --keep-until-expiring)
  [[ -n "$CERT_NAMES_WWW" ]] && cert_args+=(-d "www.${DOMAIN}")

  mb_log "requesting a certificate for ${SERVER_NAMES}"
  if ! run certbot "${cert_args[@]}"; then
    mb_err "certificate issuance failed."
    mb_err "${DOMAIN} is still served over HTTP — nothing is broken,"
    mb_err "but there is no certificate. Fix the cause and re-run."
    return 1
  fi
  mb_ok "certificate issued"

  # --- Now that the certificate exists, switch to serving HTTPS.
  write_https_block
  reload_nginx || mb_die "the HTTPS configuration failed — check /etc/nginx"

  if [[ -n "$TEST_RENEWAL" ]]; then
    mb_log "testing renewal (dry run)"
    run certbot renew --dry-run || mb_warn "renewal dry-run reported a problem"
  fi

  mb_heading "${DOMAIN} is live"
  mb_ok "https://${DOMAIN}"
  printf '\n' >&2
  mb_dim "config:      $(conf_dir)/${DOMAIN}.conf"
  mb_dim "certificate: /etc/letsencrypt/live/${DOMAIN}/"
  mb_dim "renewal:     systemctl list-timers | grep certbot"
}

main "$@"
