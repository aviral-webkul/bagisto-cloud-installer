#!/usr/bin/env bash
# ==========================================================
# Bagisto SSL Configuration (Let's Encrypt / certbot)
#
# Standalone script: run it any time after Bagisto was installed with
# bagisto_installation.sh (even days later) to add HTTPS:
#
#   sudo ./bagisto_ssl.sh
#
# It detects the existing install, asks for the domain and email,
# validates them, installs the certificate, configures Nginx and
# verifies that SSL works.
# ==========================================================

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

step() {
    echo -e "\n${BLUE}=================================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${BLUE}=================================================${NC}\n"
}

fail() {
    echo -e "${RED}SSL ERROR: $1${NC}" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || fail "Run this script as root"

. /etc/os-release 2>/dev/null || true
[[ "${ID:-}" == "ubuntu" ]] || fail "This script supports Ubuntu only"
command -v apt-get >/dev/null 2>&1 || fail "apt not found"

echo "======================================"
echo " Bagisto SSL Certificate Setup"
echo "======================================"
echo

# ----------------------------------------------------------
# Detect the existing Bagisto + Nginx setup
# ----------------------------------------------------------
NGINX_SITE="/etc/nginx/sites-available/bagisto"
NGINX_BACKUP="${NGINX_SITE}.pre-ssl.bak"

command -v nginx >/dev/null 2>&1 || fail "Nginx is not installed. Install Bagisto with bagisto_installation.sh first."
[[ -f "$NGINX_SITE" ]] || fail "Nginx site ${NGINX_SITE} not found. Install Bagisto with bagisto_installation.sh first."

APP_DIR="$(grep -m1 -oP '^\s*root\s+\K[^;]+' "$NGINX_SITE" | sed 's|/public$||' || true)"
APP_DIR="${APP_DIR:-/var/www/bagisto}"
PHP_VERSION="$(grep -m1 -oP 'php\K[0-9]+\.[0-9]+(?=-fpm\.sock)' "$NGINX_SITE" || true)"
HTTP_PORT="$(grep -m1 -oP '^\s*listen\s+\K[0-9]+' "$NGINX_SITE" || true)"
HTTP_PORT="${HTTP_PORT:-80}"

[[ -d "${APP_DIR}/public" ]] || fail "Bagisto not found at ${APP_DIR} (detected from ${NGINX_SITE})"
[[ -n "$PHP_VERSION" ]] || fail "Could not detect the PHP version from ${NGINX_SITE}"

echo "Detected Bagisto at:  ${APP_DIR}"
echo "Detected PHP version: ${PHP_VERSION}"
if [[ "$HTTP_PORT" != "80" ]]; then
    echo "Nginx HTTP port:      ${HTTP_PORT} (Varnish is in front on port 80)"
fi
echo
echo -e "${YELLOW}NOTE: The domain's DNS A record must already point to this server, and${NC}"
echo -e "${YELLOW}      ports 80 and 443 must be open. Type 'skip' at any prompt to cancel.${NC}"
echo

# ----------------------------------------------------------
# Questions + validation
# ----------------------------------------------------------
PUBLIC_IP="$(curl -4 -fsS -m 8 https://api.ipify.org 2>/dev/null || true)"
LOCAL_IPS="$(hostname -I 2>/dev/null || true)"

while true; do
    read -r -p "Domain name for the SSL certificate (e.g. shop.example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')
    [[ "$DOMAIN" == "skip" ]] && { echo "SSL configuration cancelled."; exit 0; }

    if [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
        echo "Invalid domain. Use a fully qualified domain such as shop.example.com (no http://, paths, wildcards or IP addresses)."
        continue
    fi

    RESOLVED_IPS="$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u || true)"
    if [[ -z "$RESOLVED_IPS" ]]; then
        echo "${DOMAIN} does not resolve to an IP address yet. Create the DNS A record, wait for it to propagate, then enter the domain again."
        continue
    fi

    DNS_OK=false
    for ip in $RESOLVED_IPS; do
        if [[ "$ip" == "$PUBLIC_IP" ]] || [[ " $LOCAL_IPS " == *" $ip "* ]]; then
            DNS_OK=true
        fi
    done
    if [[ "$DNS_OK" != true ]]; then
        echo "${DOMAIN} resolves to $(echo $RESOLVED_IPS) but this server is ${PUBLIC_IP:-$LOCAL_IPS}."
        echo "Point the A record to this server (and turn off any proxy such as Cloudflare), or enter a different domain."
        continue
    fi
    break
done

while true; do
    read -r -p "Email address for certificate expiry notices: " EMAIL
    [[ "$EMAIL" == "skip" ]] && { echo "SSL configuration cancelled."; exit 0; }
    [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
    echo "Invalid email address."
done

while true; do
    read -r -p "Do you agree to the Let's Encrypt Terms of Service (https://letsencrypt.org/repository/)? [y/n]: " TOS
    TOS=$(echo "$TOS" | tr '[:upper:]' '[:lower:]')
    case "$TOS" in
        y) break ;;
        n|skip) echo "SSL configuration cancelled."; exit 0 ;;
        *) echo "Please enter y or n." ;;
    esac
done

while true; do
    read -r -p "Configure SSL for ${DOMAIN} now? [y/N]: " GO
    GO=$(echo "${GO:-n}" | tr '[:upper:]' '[:lower:]')
    case "$GO" in
        y) break ;;
        n) echo "SSL configuration cancelled."; exit 0 ;;
        *) echo "Please enter y or n." ;;
    esac
done

[[ -d "${APP_DIR}/public" ]] || fail "Bagisto public directory not found: ${APP_DIR}/public"
[[ -f "$NGINX_SITE" ]] || fail "Nginx site file not found: ${NGINX_SITE}"
command -v nginx >/dev/null 2>&1 || fail "Nginx is not installed"
[[ -S "/run/php/php${PHP_VERSION}-fpm.sock" ]] || fail "PHP-FPM socket /run/php/php${PHP_VERSION}-fpm.sock not found (is php${PHP_VERSION}-fpm running?)"

# ----------------------------------------------------------
# DNS: the domain must point at this server or Let's Encrypt cannot validate it
# ----------------------------------------------------------
step "Checking DNS for ${DOMAIN}..."

RESOLVED_IPS="$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u || true)"
[[ -n "$RESOLVED_IPS" ]] || fail "${DOMAIN} does not resolve to any IPv4 address. Create the DNS A record first."

LOCAL_IPS="$(hostname -I 2>/dev/null || true)"
PUBLIC_IP="$(curl -4 -fsS -m 8 https://api.ipify.org 2>/dev/null || true)"

DNS_OK=false
for ip in $RESOLVED_IPS; do
    if [[ "$ip" == "$PUBLIC_IP" ]] || [[ " $LOCAL_IPS " == *" $ip "* ]]; then
        DNS_OK=true
    fi
done

if [[ "$DNS_OK" != true ]]; then
    fail "${DOMAIN} resolves to $(echo $RESOLVED_IPS) but this server is ${PUBLIC_IP:-${LOCAL_IPS}}. Point the A record to this server (and disable any proxy such as Cloudflare) and try again."
fi
echo "${DOMAIN} -> $(echo $RESOLVED_IPS) (matches this server)"

# ----------------------------------------------------------
# Install certbot
# ----------------------------------------------------------
step "Installing certbot..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || fail "apt-get update failed"
apt-get install -y -qq certbot openssl curl || fail "Could not install certbot"

# ----------------------------------------------------------
# Make sure plain HTTP on this domain reaches Nginx and serves the ACME
# challenge path before asking Let's Encrypt to validate
# ----------------------------------------------------------
step "Preparing HTTP challenge path..."

CHALLENGE_DIR="${APP_DIR}/public/.well-known/acme-challenge"
mkdir -p "$CHALLENGE_DIR" || fail "Cannot create ${CHALLENGE_DIR}"
chmod 755 "${APP_DIR}/public/.well-known" "$CHALLENGE_DIR"
TOKEN="bagisto-ssl-check-$$"
echo "ok" > "${CHALLENGE_DIR}/${TOKEN}"
chmod 644 "${CHALLENGE_DIR}/${TOKEN}"

if ! curl -fsS -m 15 --resolve "${DOMAIN}:80:127.0.0.1" "http://${DOMAIN}/.well-known/acme-challenge/${TOKEN}" 2>/dev/null | grep -q '^ok$'; then
    rm -f "${CHALLENGE_DIR}/${TOKEN}"
    fail "http://${DOMAIN}/.well-known/acme-challenge/ is not reachable from this server. Check that port 80 is open in the firewall/security group and that Nginx (or Varnish) is running."
fi
rm -f "${CHALLENGE_DIR}/${TOKEN}"
echo "HTTP challenge path is reachable."

# ----------------------------------------------------------
# Obtain the certificate (certonly: Nginx is configured by us, not by certbot)
# ----------------------------------------------------------
step "Requesting Let's Encrypt certificate for ${DOMAIN}..."

certbot certonly \
    --webroot -w "${APP_DIR}/public" \
    -d "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    --deploy-hook "systemctl reload nginx 2>/dev/null || service nginx reload" \
    || fail "certbot could not obtain a certificate. See /var/log/letsencrypt/letsencrypt.log"

CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
[[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]] || fail "Certificate files not found in ${CERT_DIR}"

# ----------------------------------------------------------
# Nginx: HTTP -> HTTPS redirect + HTTPS server block
# ----------------------------------------------------------
step "Configuring Nginx for HTTPS..."

[[ -f "$NGINX_BACKUP" ]] || cp -f "$NGINX_SITE" "$NGINX_BACKUP" || fail "Cannot back up ${NGINX_SITE}"

cat > "$NGINX_SITE" <<EOF
# HTTP: serve the ACME challenge (renewals), redirect everything else to HTTPS
server {
    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};
    server_name ${DOMAIN} _;
    root ${APP_DIR}/public;

    location ^~ /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        return 301 https://${DOMAIN}\$request_uri;
    }
}

# HTTPS
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};
    root ${APP_DIR}/public;

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:BagistoSSL:10m;
    ssl_session_tickets off;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;

    charset utf-8;

    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~* ^\/(?!cache).*\.(?:jpg|jpeg|gif|png|ico|cur|gz|svg|svgz|mp4|ogg|ogv|webm|htc|webp|woff|woff2)$ {
      expires max;
      access_log off;
      add_header Cache-Control "public";
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ ^/index\.php(/|$) {
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

if ! nginx -t; then
    cp -f "$NGINX_BACKUP" "$NGINX_SITE"
    fail "New Nginx config failed validation; the previous config has been restored."
fi

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl reload nginx || { cp -f "$NGINX_BACKUP" "$NGINX_SITE"; nginx -t && systemctl reload nginx; fail "Nginx reload failed; previous config restored."; }
else
    service nginx reload || { cp -f "$NGINX_BACKUP" "$NGINX_SITE"; service nginx reload || true; fail "Nginx reload failed; previous config restored."; }
fi

# ----------------------------------------------------------
# Point Bagisto at the https URL
# ----------------------------------------------------------
step "Updating Bagisto APP_URL..."

ENV_FILE="${APP_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    if grep -q '^APP_URL=' "$ENV_FILE"; then
        sed -i "s|^APP_URL=.*|APP_URL=\"https://${DOMAIN}\"|" "$ENV_FILE"
    else
        echo "APP_URL=\"https://${DOMAIN}\"" >> "$ENV_FILE"
    fi
    (cd "$APP_DIR" && runuser -u www-data -- php artisan optimize:clear >/dev/null 2>&1) || \
        echo -e "${YELLOW}Could not clear Laravel cache automatically; run 'php artisan optimize:clear' in ${APP_DIR}.${NC}"
else
    echo -e "${YELLOW}${ENV_FILE} not found; set APP_URL=https://${DOMAIN} manually.${NC}"
fi

# ----------------------------------------------------------
# Verify SSL really works
# ----------------------------------------------------------
step "Verifying SSL..."

VERIFY_FAILED=false

# 1) HTTPS answers with a certificate trusted by the system store, valid for the domain
HTTPS_CODE="$(curl -sS -m 30 -o /dev/null -w '%{http_code}' --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" 2>/tmp/bagisto_ssl_curl.err || true)"
if [[ "$HTTPS_CODE" =~ ^[23][0-9][0-9]$ ]]; then
    echo -e "${GREEN}[OK]${NC} https://${DOMAIN}/ responded with HTTP ${HTTPS_CODE} and a trusted certificate"
else
    echo -e "${RED}[FAIL]${NC} https://${DOMAIN}/ check failed (HTTP '${HTTPS_CODE}'): $(cat /tmp/bagisto_ssl_curl.err 2>/dev/null)"
    VERIFY_FAILED=true
fi
rm -f /tmp/bagisto_ssl_curl.err

# 2) Certificate subject and expiry
if openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -checkend $((7*24*3600)) >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} Certificate valid, $(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -enddate)"
else
    echo -e "${RED}[FAIL]${NC} Certificate expires in less than 7 days or is unreadable"
    VERIFY_FAILED=true
fi

# 3) HTTP redirects to HTTPS on the public port
PUBLIC_HTTP_PORT=80
REDIRECT_TARGET="$(curl -sS -m 15 -o /dev/null -w '%{http_code} %{redirect_url}' --resolve "${DOMAIN}:${PUBLIC_HTTP_PORT}:127.0.0.1" "http://${DOMAIN}/" 2>/dev/null || true)"
if [[ "$REDIRECT_TARGET" == "301 https://${DOMAIN}/"* ]]; then
    echo -e "${GREEN}[OK]${NC} http://${DOMAIN}/ redirects to https://${DOMAIN}/"
else
    echo -e "${RED}[FAIL]${NC} HTTP -> HTTPS redirect not working (got: ${REDIRECT_TARGET:-no response})"
    VERIFY_FAILED=true
fi

# 4) Automatic renewal works (certbot's own timer/cron handles the schedule)
if certbot renew --dry-run --cert-name "$DOMAIN" >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} Automatic renewal dry-run succeeded"
else
    echo -e "${YELLOW}[WARN]${NC} Renewal dry-run failed; check 'certbot renew --dry-run'"
fi

if [[ "$VERIFY_FAILED" = true ]]; then
    fail "SSL was installed but verification failed (see above). Nginx backup: ${NGINX_BACKUP}"
fi

step "SSL CONFIGURED SUCCESSFULLY"
echo -e "${YELLOW}Store URL:${NC} https://${DOMAIN}"
echo -e "${YELLOW}Admin URL:${NC} https://${DOMAIN}/admin"
