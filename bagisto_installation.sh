# ==========================================================
# Bagisto Installer (Optional Varnish)
# PHP + MySQL + Nginx + Varnish + Composer + Bagisto
# ==========================================================

set -euo pipefail

APP_DIR="/var/www/bagisto"
CYBERPANEL_PORT=10000
SERVER_IP="$(hostname -I | awk '{print $1}')"

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
    echo -e "${RED}ERROR: $1${NC}"
    exit 1
}

# ----------------------------------------------------------
# SSL (Let's Encrypt, certbot webroot method).
# Runs in a subshell: ssl_fail aborts only the SSL step, never the whole
# installation. Inputs (SSL_DOMAIN, SSL_EMAIL) were validated up front.
# ----------------------------------------------------------
ssl_fail() {
    echo -e "${RED}SSL ERROR: $1${NC}" >&2
    exit 1
}

configure_ssl() {
DOMAIN="$SSL_DOMAIN"
EMAIL="$SSL_EMAIL"
HTTP_PORT="$NGINX_PORT"

NGINX_SITE="/etc/nginx/sites-available/bagisto"
NGINX_BACKUP="${NGINX_SITE}.pre-ssl.bak"

[[ -d "${APP_DIR}/public" ]] || ssl_fail "Bagisto public directory not found: ${APP_DIR}/public"
[[ -f "$NGINX_SITE" ]] || ssl_fail "Nginx site file not found: ${NGINX_SITE}"
command -v nginx >/dev/null 2>&1 || ssl_fail "Nginx is not installed"
[[ -S "/run/php/php${PHP_VERSION}-fpm.sock" ]] || ssl_fail "PHP-FPM socket /run/php/php${PHP_VERSION}-fpm.sock not found (is php${PHP_VERSION}-fpm running?)"

# ----------------------------------------------------------
# DNS: the domain must point at this server or Let's Encrypt cannot validate it
# ----------------------------------------------------------
step "Checking DNS for ${DOMAIN}..."

RESOLVED_IPS="$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u || true)"
[[ -n "$RESOLVED_IPS" ]] || ssl_fail "${DOMAIN} does not resolve to any IPv4 address. Create the DNS A record first."

LOCAL_IPS="$(hostname -I 2>/dev/null || true)"
PUBLIC_IP="$(curl -4 -fsS -m 8 https://api.ipify.org 2>/dev/null || true)"

DNS_OK=false
for ip in $RESOLVED_IPS; do
    if [[ "$ip" == "$PUBLIC_IP" ]] || [[ " $LOCAL_IPS " == *" $ip "* ]]; then
        DNS_OK=true
    fi
done

if [[ "$DNS_OK" != true ]]; then
    ssl_fail "${DOMAIN} resolves to $(echo $RESOLVED_IPS) but this server is ${PUBLIC_IP:-${LOCAL_IPS}}. Point the A record to this server (and disable any proxy such as Cloudflare) and try again."
fi
echo "${DOMAIN} -> $(echo $RESOLVED_IPS) (matches this server)"

# ----------------------------------------------------------
# Install certbot
# ----------------------------------------------------------
step "Installing certbot..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || ssl_fail "apt-get update failed"
apt-get install -y -qq certbot openssl curl || ssl_fail "Could not install certbot"

# ----------------------------------------------------------
# Make sure plain HTTP on this domain reaches Nginx and serves the ACME
# challenge path before asking Let's Encrypt to validate
# ----------------------------------------------------------
step "Preparing HTTP challenge path..."

CHALLENGE_DIR="${APP_DIR}/public/.well-known/acme-challenge"
mkdir -p "$CHALLENGE_DIR" || ssl_fail "Cannot create ${CHALLENGE_DIR}"
chmod 755 "${APP_DIR}/public/.well-known" "$CHALLENGE_DIR"
TOKEN="bagisto-ssl-check-$$"
echo "ok" > "${CHALLENGE_DIR}/${TOKEN}"
chmod 644 "${CHALLENGE_DIR}/${TOKEN}"

if ! curl -fsS -m 15 --resolve "${DOMAIN}:80:127.0.0.1" "http://${DOMAIN}/.well-known/acme-challenge/${TOKEN}" 2>/dev/null | grep -q '^ok$'; then
    rm -f "${CHALLENGE_DIR}/${TOKEN}"
    ssl_fail "http://${DOMAIN}/.well-known/acme-challenge/ is not reachable from this server. Check that port 80 is open in the firewall/security group and that Nginx (or Varnish) is running."
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
    || ssl_fail "certbot could not obtain a certificate. See /var/log/letsencrypt/letsencrypt.log"

CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
[[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]] || ssl_fail "Certificate files not found in ${CERT_DIR}"

# ----------------------------------------------------------
# Nginx: HTTP -> HTTPS redirect + HTTPS server block
# ----------------------------------------------------------
step "Configuring Nginx for HTTPS..."

cp -f "$NGINX_SITE" "$NGINX_BACKUP" || ssl_fail "Cannot back up ${NGINX_SITE}"

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
    ssl_fail "New Nginx config failed validation; the previous config has been restored."
fi

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl reload nginx || { cp -f "$NGINX_BACKUP" "$NGINX_SITE"; nginx -t && systemctl reload nginx; ssl_fail "Nginx reload failed; previous config restored."; }
else
    service nginx reload || { cp -f "$NGINX_BACKUP" "$NGINX_SITE"; service nginx reload || true; ssl_fail "Nginx reload failed; previous config restored."; }
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
    ssl_fail "SSL was installed but verification failed (see above). Nginx backup: ${NGINX_BACKUP}"
fi

step "SSL CONFIGURED SUCCESSFULLY"
echo -e "${YELLOW}Store URL:${NC} https://${DOMAIN}"
echo -e "${YELLOW}Admin URL:${NC} https://${DOMAIN}/admin"
}

[[ $EUID -eq 0 ]] || fail "Run this script as root"

# ---- Pre-flight checks ----
. /etc/os-release 2>/dev/null || true
[[ "${ID:-}" == "ubuntu" ]] || fail "This installer supports Ubuntu only"
command -v apt >/dev/null 2>&1 || fail "apt not found"
[[ -d /run/systemd/system ]] || fail "systemd is not running (typical inside a Docker container). This installer needs a real server or VM with systemd."

# curl / ca-certificates may be missing on minimal images (e.g. Docker); install them first
if ! command -v curl >/dev/null 2>&1 || [[ ! -d /etc/ssl/certs ]]; then
    apt-get update -qq && apt-get install -y -qq curl ca-certificates \
        || fail "Could not install curl/ca-certificates - check the server's DNS and internet access (apt could not reach its mirrors)"
fi
if ! CURL_ERR="$(curl -sS -m 20 -o /dev/null https://getcomposer.org/installer 2>&1)"; then
    fail "Cannot reach getcomposer.org: ${CURL_ERR}"
fi

echo "======================================"
echo " Bagisto First-Time Installation Setup"
echo "======================================"
echo

echo -e "${YELLOW}NOTE: Make sure both ports 80 and 8080 are available.${NC}"
echo ==========================================================

read -p "Do you want to enable Varnish? (y/n): " ENABLE_VARNISH

case "$ENABLE_VARNISH" in
    y|Y)
        USE_VARNISH=true
        NGINX_PORT=8080
        APP_URL="http://${SERVER_IP}"
        ;;
    n|N)
        USE_VARNISH=false
        NGINX_PORT=80
        APP_URL="http://${SERVER_IP}"
        ;;
    *)
        fail "Invalid input. Please enter only y/Y or n/N."
        ;;
esac

while true; do
    read -r -p "Do you want to install and configure CyberPanel (server control panel) on port ${CYBERPANEL_PORT}? (y/n): " ENABLE_CYBERPANEL
    case "$ENABLE_CYBERPANEL" in
        y|Y) INSTALL_CYBERPANEL=true; break ;;
        n|N) INSTALL_CYBERPANEL=false; break ;;
        *)   echo "Invalid input. Please enter only y/Y or n/N." ;;
    esac
done

if [[ "$INSTALL_CYBERPANEL" = true ]]; then
    echo -e "${YELLOW}NOTE: CyberPanel ships its own OpenLiteSpeed web server (ports 80/443).${NC}"
    echo -e "${YELLOW}      It will be disabled so it does not clash with Nginx/Varnish; only the${NC}"
    echo -e "${YELLOW}      CyberPanel dashboard will be served, on port ${CYBERPANEL_PORT}.${NC}"
    echo

    # --- CyberPanel admin password ---
    echo "CyberPanel admin password:"
    echo "  r) Generate a random password (recommended)"
    echo "  s) Set my own password"
    while true; do
        read -r -p "Choose [r/s] (default r): " CP_PASS_MODE
        CP_PASS_MODE=$(echo "${CP_PASS_MODE:-r}" | tr '[:upper:]' '[:lower:]')
        case "$CP_PASS_MODE" in
            r)
                CYBERPANEL_ADMIN_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)"
                break
                ;;
            s)
                read -r -s -p "Enter CyberPanel admin password (min 8 chars): " CYBERPANEL_ADMIN_PASS
                echo
                read -r -s -p "Confirm password: " CP_PASS_CONFIRM
                echo
                if [[ ${#CYBERPANEL_ADMIN_PASS} -lt 8 ]]; then
                    echo "Password must be at least 8 characters."
                elif [[ "$CYBERPANEL_ADMIN_PASS" != "$CP_PASS_CONFIRM" ]]; then
                    echo "Passwords do not match."
                else
                    break
                fi
                ;;
            *) echo "Invalid input. Please enter r or s." ;;
        esac
    done

    # --- Optional CyberPanel services ---
    ask_yn() {  # ask_yn "question" default(y/n) -> sets REPLY_YN to true/false
        local ans
        while true; do
            read -r -p "$1 [y/n] (default $2): " ans
            ans=$(echo "${ans:-$2}" | tr '[:upper:]' '[:lower:]')
            case "$ans" in
                y) REPLY_YN=true; return ;;
                n) REPLY_YN=false; return ;;
                *) echo "Invalid input. Please enter y or n." ;;
            esac
        done
    }

    CP_ARGS=(-v ols -p "$CYBERPANEL_ADMIN_PASS")

    ask_yn "CyberPanel: install Postfix (mail server)?" y;      CP_POSTFIX=$REPLY_YN
    ask_yn "CyberPanel: install PowerDNS (DNS server)?" y;      CP_POWERDNS=$REPLY_YN
    ask_yn "CyberPanel: install Pure-FTPd (FTP server)?" y;     CP_PUREFTPD=$REPLY_YN
    ask_yn "CyberPanel: install Memcached and Redis add-ons?" n; CP_ADDONS=$REPLY_YN

    if [[ "$CP_POSTFIX" = false && "$CP_POWERDNS" = false && "$CP_PUREFTPD" = false ]]; then
        CP_ARGS+=(-m)
    elif [[ "$CP_POSTFIX" = true && "$CP_POWERDNS" = true && "$CP_PUREFTPD" = true ]]; then
        :   # full installation is the installer default
    else
        CP_ARGS+=(-m)
        [[ "$CP_POSTFIX"  = true ]] && CP_ARGS+=(postfix)
        [[ "$CP_POWERDNS" = true ]] && CP_ARGS+=(powerdns)
        [[ "$CP_PUREFTPD" = true ]] && CP_ARGS+=(pureftpd)
    fi
    [[ "$CP_ADDONS" = true ]] && CP_ARGS+=(-a)
fi


if [[ "$INSTALL_CYBERPANEL" = true ]]; then
    # CyberPanel needs a clean server: its own MariaDB/OpenLiteSpeed must not clash with existing ones
    for pkg in mysql-server mysql-server-8.0 nginx apache2 varnish; do
        dpkg -s "$pkg" >/dev/null 2>&1 && fail "'$pkg' is already installed. CyberPanel requires a fresh server (use a clean Ubuntu install or answer 'n' to CyberPanel)."
    done
    for port in 80 443 ${CYBERPANEL_PORT}; do
        ss -tln | awk '{print $4}' | grep -qE "[:.]${port}$" && fail "Port ${port} is already in use. Free it before installing CyberPanel."
    done
    [[ $(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo) -ge 1024 ]] || fail "CyberPanel needs at least 1 GB RAM"
    [[ $(df --output=avail -BG / | tail -1 | tr -dc 0-9) -ge 10 ]] || fail "CyberPanel needs at least 10 GB free disk space"
fi

# ----------------------------------------------------------
# Optional SSL certificate (Let's Encrypt). Default: No.
# All details are collected and validated here, up front; the SSL script
# SSL step (configure_ssl) only runs at the end, once the site is live on port 80.
# ----------------------------------------------------------
CONFIGURE_SSL=false
SSL_OK=false
SSL_DOMAIN=""
SSL_EMAIL=""

while true; do
    read -r -p "Do you want to configure an SSL certificate (Let's Encrypt)? [y/N]: " ENABLE_SSL
    ENABLE_SSL=$(echo "${ENABLE_SSL:-n}" | tr '[:upper:]' '[:lower:]')
    case "$ENABLE_SSL" in
        y|n) break ;;
        *)   echo "Invalid input. Please enter only y or n." ;;
    esac
done

if [[ "$ENABLE_SSL" == "y" ]]; then
    echo -e "${YELLOW}NOTE: The domain's DNS A record must already point to this server, and${NC}"
    echo -e "${YELLOW}      ports 80 and 443 must be open. Type 'skip' at any prompt to cancel SSL.${NC}"

    SSL_PUBLIC_IP="$(curl -4 -fsS -m 8 https://api.ipify.org 2>/dev/null || true)"
    SSL_LOCAL_IPS="$(hostname -I 2>/dev/null || true)"
    SSL_CANCELLED=false

    while true; do
        read -r -p "Domain name for the SSL certificate (e.g. shop.example.com): " SSL_DOMAIN
        SSL_DOMAIN=$(echo "$SSL_DOMAIN" | tr '[:upper:]' '[:lower:]')

        if [[ "$SSL_DOMAIN" == "skip" ]]; then SSL_CANCELLED=true; break; fi

        if [[ ! "$SSL_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
            echo "Invalid domain. Use a fully qualified domain such as shop.example.com (no http://, paths, wildcards or IP addresses)."
            continue
        fi

        SSL_RESOLVED="$(getent ahostsv4 "$SSL_DOMAIN" | awk '{print $1}' | sort -u || true)"
        if [[ -z "$SSL_RESOLVED" ]]; then
            echo "${SSL_DOMAIN} does not resolve to an IP address yet. Create the DNS A record, wait for it to propagate, then enter the domain again."
            continue
        fi

        SSL_DNS_OK=false
        for ip in $SSL_RESOLVED; do
            if [[ "$ip" == "$SSL_PUBLIC_IP" ]] || [[ " $SSL_LOCAL_IPS " == *" $ip "* ]]; then
                SSL_DNS_OK=true
            fi
        done
        if [[ "$SSL_DNS_OK" != true ]]; then
            echo "${SSL_DOMAIN} resolves to $(echo $SSL_RESOLVED) but this server is ${SSL_PUBLIC_IP:-$SSL_LOCAL_IPS}."
            echo "Point the A record to this server (and turn off any proxy such as Cloudflare), or enter a different domain."
            continue
        fi
        break
    done

    if [[ "$SSL_CANCELLED" != true ]]; then
        while true; do
            read -r -p "Email address for certificate expiry notices: " SSL_EMAIL
            if [[ "$SSL_EMAIL" == "skip" ]]; then SSL_CANCELLED=true; break; fi
            if [[ "$SSL_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then break; fi
            echo "Invalid email address."
        done
    fi

    if [[ "$SSL_CANCELLED" != true ]]; then
        while true; do
            read -r -p "Do you agree to the Let's Encrypt Terms of Service (https://letsencrypt.org/repository/)? [y/n]: " SSL_TOS
            SSL_TOS=$(echo "$SSL_TOS" | tr '[:upper:]' '[:lower:]')
            case "$SSL_TOS" in
                y)    break ;;
                n|skip) SSL_CANCELLED=true; break ;;
                *)    echo "Please enter y or n." ;;
            esac
        done
    fi

    if [[ "$SSL_CANCELLED" == true ]]; then
        echo -e "${YELLOW}SSL configuration skipped.${NC}"
    else
        CONFIGURE_SSL=true
        echo -e "${GREEN}SSL will be configured for ${SSL_DOMAIN} (${SSL_EMAIL}) at the end of the installation.${NC}"
    fi
fi

while true; do
    read -p "Enter Bagisto version to install: " BAGISTO_VERSION

    if [[ -n "$BAGISTO_VERSION" ]]; then
        BAGISTO_VERSION="v${BAGISTO_VERSION#v}"
        break
    else
        echo "Bagisto version is required. Please enter a valid version."
    fi
done

read -p "Enter PHP version [8.3]: " PHP_VERSION
PHP_VERSION=${PHP_VERSION:-8.3}
read -p "Choose a database name [bagisto]: " DB_NAME
DB_NAME=${DB_NAME:-bagisto}
read -p "Choose a database username [bagisto_user]: " DB_USER
DB_USER=${DB_USER:-bagisto_user}
read -s -p "Choose a database password[webkul]: " DB_PASS
DB_PASS=${DB_PASS:-webkul}
echo
while true; do
    read -r -p "Would you like to set up demo data? [y/n]: " DB_DATA
    DB_DATA=${DB_DATA:-n}

    # convert to lowercase
    DB_DATA=$(echo "$DB_DATA" | tr '[:upper:]' '[:lower:]')

    if [[ "$DB_DATA" == "y" || "$DB_DATA" == "n" ]]; then
        break
    else
        echo "Invalid input!!. Please enter only y/Y or n/N."
    fi
done
echo

step "Updating system..."
apt update && apt upgrade -y

if [[ "$INSTALL_CYBERPANEL" = true ]]; then
    step "Installing CyberPanel (before Bagisto, on a clean server)..."

    curl -fsSL https://cyberpanel.net/install.sh -o /root/cyberpanel_install.sh \
        || fail "Could not download the CyberPanel installer"
    sh /root/cyberpanel_install.sh "${CP_ARGS[@]}" || fail "CyberPanel installation failed"

    step "Configuring CyberPanel on port ${CYBERPANEL_PORT}..."

    # CyberPanel's panel daemon (lscpd) listens on 8090 by default
    [[ -f /usr/local/lscp/conf/bind.conf ]] && echo "*:${CYBERPANEL_PORT}" > /usr/local/lscp/conf/bind.conf
    [[ -f /usr/local/lscp/conf/httpd_config.xml ]] && \
        sed -i "s|\*:8090|*:${CYBERPANEL_PORT}|g" /usr/local/lscp/conf/httpd_config.xml

    # Open the new port in whichever firewall is active
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow ${CYBERPANEL_PORT}/tcp
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port=${CYBERPANEL_PORT}/tcp
        firewall-cmd --reload
    fi

    # Free ports 80/443 for Nginx/Varnish (OpenLiteSpeed would otherwise hold them)
    systemctl disable --now lsws >/dev/null 2>&1 || true
    pkill -f openlitespeed >/dev/null 2>&1 || true

    systemctl restart lscpd

    # Wait (up to 30s) for the panel to answer on the new port
    CP_UP=false
    for _ in $(seq 1 15); do
        if curl -ksf -o /dev/null "https://127.0.0.1:${CYBERPANEL_PORT}"; then CP_UP=true; break; fi
        sleep 2
    done
    [[ "$CP_UP" = true ]] || fail "CyberPanel is not responding on port ${CYBERPANEL_PORT}"
    echo -e "${GREEN}CyberPanel is running on port ${CYBERPANEL_PORT}.${NC}"

    # Save the login so a random password is never lost (readable by root only)
    CP_CRED_FILE="/root/cyberpanel_credentials.txt"
    ( umask 077
      {
        echo "CyberPanel URL:      https://${SERVER_IP}:${CYBERPANEL_PORT}"
        echo "CyberPanel username: admin"
        echo "CyberPanel password: ${CYBERPANEL_ADMIN_PASS}"
      } > "$CP_CRED_FILE" )
    echo -e "${YELLOW}CyberPanel login saved to ${CP_CRED_FILE} (root only).${NC}"

    # CyberPanel provides MariaDB; Bagisto will use it instead of installing MySQL
    [[ -f /etc/cyberpanel/mysqlPassword ]] || fail "CyberPanel MariaDB password file not found"
    MYSQL_ROOT_PASS="$(tr -d '\n' < /etc/cyberpanel/mysqlPassword)"
    DB_SERVICE="mariadb"
fi

step "Installing dependencies..."
DEPS="software-properties-common curl unzip git nginx"
[[ "$USE_VARNISH" = true ]] && DEPS="$DEPS varnish"
# CyberPanel already installed MariaDB; installing mysql-server would replace it
[[ "$INSTALL_CYBERPANEL" = true ]] || DEPS="$DEPS mysql-server"
apt install -y $DEPS

step "Installing PHP ${PHP_VERSION}..."
add-apt-repository ppa:ondrej/php -y
apt update

apt install -y \
php${PHP_VERSION} \
php${PHP_VERSION}-fpm \
php${PHP_VERSION}-cli \
php${PHP_VERSION}-common \
php${PHP_VERSION}-mysql \
php${PHP_VERSION}-gd \
php${PHP_VERSION}-curl \
php${PHP_VERSION}-mbstring \
php${PHP_VERSION}-xml \
php${PHP_VERSION}-bcmath \
php${PHP_VERSION}-zip \
php${PHP_VERSION}-intl \
php${PHP_VERSION}-soap \
php${PHP_VERSION}-opcache

step "Installing Composer..."
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer
chmod +x /usr/local/bin/composer

step "Starting database server..."
DB_SERVICE="${DB_SERVICE:-mysql}"
systemctl enable --now "${DB_SERVICE}"

step "Creating database..."
if [[ "$INSTALL_CYBERPANEL" = true ]]; then
    SQL=(mysql -uroot -p"${MYSQL_ROOT_PASS}")
else
    SQL=(mysql)
fi
"${SQL[@]}" -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"
"${SQL[@]}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
"${SQL[@]}" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
"${SQL[@]}" -e "FLUSH PRIVILEGES;"

step "Installing Bagisto ${BAGISTO_VERSION}..."
mkdir -p /var/www
cd /var/www

export COMPOSER_ALLOW_SUPERUSER=1

# Install Bagisto directly
composer create-project bagisto/bagisto /var/www/bagisto "${BAGISTO_VERSION}" --no-interaction --prefer-dist

cd ${APP_DIR}

step "Configuring environment..."
cp -n .env.example .env

sed -i "s|^APP_URL=.*|APP_URL=${APP_URL}|" .env
sed -i "s/^APP_DEBUG=.*/APP_DEBUG=false/" .env
sed -i "s/^DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" .env
sed -i "s/^DB_USERNAME=.*/DB_USERNAME=${DB_USER}/" .env
sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/" .env

php artisan bagisto:install --skip-env-check --skip-admin-creation --skip-github-star

if [[ "$DB_DATA" == "y" ]]; then
    echo "Setting up demo data..."

    php artisan db:seed --class="Webkul\\Installer\\Database\\Seeders\\ProductTableSeeder" --force
    php artisan indexer:index --mode=full

    echo "Demo data installed successfully."
fi

php artisan optimize:clear

step "Configuring Nginx on Port :${NGINX_PORT}"

cat > /etc/nginx/sites-available/bagisto <<EOF
server {
    listen ${NGINX_PORT};
    listen [::]:${NGINX_PORT};
    server_name _;
    root ${APP_DIR}/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;

    charset utf-8;

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

ln -sf /etc/nginx/sites-available/bagisto /etc/nginx/sites-enabled/bagisto
rm -f /etc/nginx/sites-enabled/default

chown -R www-data:www-data ${APP_DIR}
chmod -R 775 ${APP_DIR}/storage ${APP_DIR}/bootstrap/cache

systemctl restart php${PHP_VERSION}-fpm
systemctl restart nginx

if [[ "$USE_VARNISH" = true ]]; then
    step "Installing Bagisto Varnish package..."
    
    cd ${APP_DIR}
    
    chown -R root:root ${APP_DIR}
    git config --global --add safe.directory ${APP_DIR}
    
    # Allow Composer as root
    export COMPOSER_ALLOW_SUPERUSER=1
    
    composer require bagisto/bagisto-varnish --no-interaction
    
    # Restore web server ownership
    chown -R www-data:www-data ${APP_DIR}
    chmod -R 775 ${APP_DIR}/storage ${APP_DIR}/bootstrap/cache
    
    # -------------------------
    # REGISTER SERVICE PROVIDER
    # -------------------------
    step "Registering Varnish Service Provider..."
    
    php -r "
    \$file = 'bootstrap/providers.php';
    \$content = file_get_contents(\$file);
    
    \$provider = '    Webkul\\\\Varnish\\\\Providers\\\\VarnishServiceProvider::class,';
    
    if (strpos(\$content, 'Webkul\\\\Varnish\\\\Providers\\\\VarnishServiceProvider::class') === false) {
        \$content = preg_replace(
            '/\];\s*$/',
            \$provider . PHP_EOL . '];',
            \$content
        );
    
        file_put_contents(\$file, \$content);
    }
    "
    
    # -------------------------
    # PUBLISH CONFIG
    # -------------------------
    step "Publishing Varnish configuration..."
    
    php artisan vendor:publish --provider="Webkul\\Varnish\\Providers\\VarnishServiceProvider" --force
    
    # -------------------------
    # COPY VCL
    # -------------------------
    step "Installing VCL configuration..."
    
    if ! cp vendor/bagisto/bagisto-varnish/vcls/6.0.vcl /etc/varnish/default.vcl; then
        echo -e "\e[31mERROR: Failed to copy Varnish VCL file from vendor/bagisto/bagisto-varnish/vcls/6.0.vcl\e[0m"
        exit 1
    else
        echo -e "\e[32mSUCCESS: Varnish VCL file copied successfully.\e[0m"
    fi
    
    # Ensure backend points to nginx:8080
    sed -i 's/\.port = "80"/.port = "8080"/g' /etc/varnish/default.vcl
    
    # Start varnish with custom arguments
    nohup varnishd \
    -a :80 \
    -T localhost:6082 \
    -f /etc/varnish/default.vcl \
    -s malloc,256m \
    >/dev/null 2>&1 &
    
    sleep 3
    ss -tulpn | grep ':80' || fail "Varnish failed to start on port 80"
    fi

if [[ "$CONFIGURE_SSL" = true && -n "$SSL_DOMAIN" && -n "$SSL_EMAIL" ]]; then
    step "Configuring SSL for ${SSL_DOMAIN}..."

    # Bagisto is already installed and working over HTTP at this point, so an SSL
    # failure must not undo it: report it and print how to retry.
    if ( configure_ssl ); then
        SSL_OK=true
        APP_URL="https://${SSL_DOMAIN}"
    else
        SSL_OK=false
        echo -e "${RED}SSL configuration failed. Bagisto is still available over HTTP.${NC}"
        echo -e "${YELLOW}Check the message above and /var/log/letsencrypt/letsencrypt.log, fix the cause (DNS, firewall ports 80/443), then run:${NC}"
        echo -e "  certbot certonly --webroot -w ${APP_DIR}/public -d ${SSL_DOMAIN} --email ${SSL_EMAIL} --agree-tos"
    fi
fi

step "INSTALLATION COMPLETE"

if [[ "$SSL_OK" = true ]]; then
    echo -e "${YELLOW}Store URL:${NC} https://${SSL_DOMAIN}"
    echo -e "${YELLOW}Admin URL:${NC} https://${SSL_DOMAIN}/admin"
else
    echo -e "${YELLOW}Store URL:${NC} http://${SERVER_IP}"
    echo -e "${YELLOW}Admin URL:${NC} http://${SERVER_IP}/admin"
fi
if [[ "$INSTALL_CYBERPANEL" = true ]]; then
    echo -e "${YELLOW}CyberPanel URL:${NC} https://${SERVER_IP}:${CYBERPANEL_PORT}"
    echo -e "${YELLOW}CyberPanel Login:${NC} admin / ${CYBERPANEL_ADMIN_PASS}"
    echo -e "${YELLOW}CyberPanel login saved in:${NC} ${CP_CRED_FILE}"
fi
echo -e "${YELLOW}DB User:${NC} ${DB_USER}"
echo -e "${YELLOW}DB Name:${NC} ${DB_NAME}"
echo -e "${YELLOW}Admin Email:${NC} admin@example.com"
echo -e "${YELLOW}Admin Password:${NC} admin123"
echo -e "${YELLOW}NOTE: Change the admin password to improve security.${NC}"

