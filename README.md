# Bagisto Installer (Optional Varnish) for Ubuntu VPS

This repository contains `bagisto_installation.sh`, an interactive installer for setting up Bagisto on Ubuntu with optional Varnish caching. The script supports two modes:
- **With Varnish**: Nginx serves Bagisto on port `8080`, Varnish caches content on port `80` for improved performance.
- **Without Varnish**: Nginx serves Bagisto directly on port `80` for simpler setups.

Key features include MySQL database creation, PHP-FPM and Composer setup, automatic Bagisto admin user creation, conditional Varnish package installation with VCL deployment, an **optional CyberPanel** control panel (dashboard on port `10000`), and an **optional Let's Encrypt SSL certificate** (also available later through the standalone `bagisto_ssl.sh`).

The script is designed for a fresh Ubuntu server. By default it installs an HTTP-only stack; HTTPS is added only when you choose SSL.

## Requirements

- Ubuntu `22.04` or `24.04` (a real server or VM with systemd; **not** a plain Docker container)
- Root access
- Internet access on the server
- If Varnish is enabled: Ports `80` (Varnish) and `8080` (Nginx) must be free
- If Varnish is disabled: Only port `80` (Nginx) must be free
- If CyberPanel is selected: a **fresh server** with MySQL, Nginx, Apache and Varnish **not** installed, ports `80`, `443` and `10000` free, at least 1 GB RAM and 10 GB free disk
- If SSL is selected: a domain whose DNS A record points to this server, and ports `80` and `443` open in the firewall / security group

## Files

- `bagisto_installation.sh`: Main installer script (optional Varnish, CyberPanel and SSL)
- `bagisto_ssl.sh`: Standalone SSL script. Use it to add HTTPS to an existing Bagisto install at any later time (see [SSL Configuration](#ssl-configuration-lets-encrypt))

## Quick Start

```bash
# UPLOAD: Copy this script to your server.
scp PATH_TO_bagisto_installation.sh root@YOUR_SERVER_IP:/root/

#Using .pem file
scp -i /path/to/your-key.pem -r \ PATH_TO_bagisto_installation.sh \ root@YOUR_SERVER_IP:/root/

# LOGIN: Connect to your server via SSH
ssh root@YOUR_SERVER_IP
or
ssh -i /path/to/your-key.pem root@YOUR_SERVER_IP

# PERMISSIONS: Make script executable
chmod +x bagisto_installation.sh

# RUN: Execute the installation script
./bagisto_installation.sh
```

To add SSL later, upload `bagisto_ssl.sh` the same way and run `sudo ./bagisto_ssl.sh`.

## Interactive Inputs

When you run the script, all questions are asked **at the beginning**, before anything is installed (defaults shown where applicable):

| Item | Default |
|------|---------|
| Enable Varnish | None (must select `y`/`Y` or `n`/`N`) |
| Install CyberPanel (dashboard on port `10000`) | None (must select `y`/`n`) |
| CyberPanel admin password *(only if CyberPanel)* | `r` (random, 16 chars); `s` to set your own (min 8 chars, confirmed) |
| CyberPanel: Postfix, PowerDNS, Pure-FTPd *(only if CyberPanel)* | `y` each |
| CyberPanel: Memcached and Redis add-ons *(only if CyberPanel)* | `n` |
| Configure SSL certificate | `N` |
| SSL domain, email, Let's Encrypt terms *(only if SSL = yes)* | None (all required and validated; type `skip` to cancel SSL) |
| Bagisto version | None (auto-prefixed with `v`, e.g., `2.4.2` → `v2.4.2`) |
| PHP version | `8.3` |
| Database name | `bagisto` |
| Database username | `bagisto_user` |
| Database password | `webkul` |
| Setup demo data | `n` |

## What the Script Does

### Pre-flight Checks
Before asking questions the script verifies:
- It is running as `root` on Ubuntu with `apt` available
- `curl` and `ca-certificates` are present (installed automatically on minimal images) and `getcomposer.org` is reachable. The real curl error is shown if it is not
- If CyberPanel is selected: no existing MySQL/Nginx/Apache/Varnish, ports `80`, `443`, `10000` are free, and RAM/disk meet the minimums

### 0. Varnish Toggle
Prompts to enable or disable Varnish caching. This choice determines:
- Nginx listening port (`8080` if Varnish enabled, `80` if disabled)
- Whether Varnish packages and Bagisto Varnish integration are installed

### 0b. CyberPanel Installation (Conditional)
Only executed if CyberPanel is selected. It runs **before** Bagisto so it gets the clean server it requires:
- Downloads and runs the official CyberPanel installer **unattended**, using the answers collected at the start (OpenLiteSpeed edition, admin password, optional services via `-m`, add-ons via `-a`)
- Changes the CyberPanel dashboard port from `8090` to `10000` (`/usr/local/lscp/conf/bind.conf`, `httpd_config.xml`) and opens it in `ufw` / `firewalld` if active
- Disables CyberPanel's bundled OpenLiteSpeed so ports `80`/`443` stay free for Nginx/Varnish. Only the dashboard remains running
- Waits up to 30 seconds for the dashboard to answer on port `10000`, otherwise stops with an error
- Reads the MariaDB root password from `/etc/cyberpanel/mysqlPassword`. Bagisto then uses **CyberPanel's MariaDB** instead of installing `mysql-server` (installing both would conflict)

Dashboard: `https://YOUR_SERVER_IP:10000`, login `admin` with the password chosen (or generated) at the start.

**Where to find the random password:** if you keep the default (`r`), the script generates a 16-character password. It is printed in the final summary (`CyberPanel Login: admin / <password>`) and also saved to `/root/cyberpanel_credentials.txt` (readable by root only), so it is not lost if the output scrolls away:
```bash
sudo cat /root/cyberpanel_credentials.txt
```
Forgot or want to change it later? Run `sudo /usr/local/CyberCP/bin/python /usr/local/CyberCP/plogical/adminPass.py --password 'NEW_PASSWORD'` (verify the path on your CyberPanel version).

### 1. System Preparation
- Runs `apt update && apt upgrade -y`
- Installs base packages:
  - `software-properties-common`
  - `curl`
  - `unzip`
  - `git`
  - `nginx`
  - `mysql-server` (skipped when CyberPanel is installed; its MariaDB is used)
  - `varnish` (only if Varnish is enabled)

### 2. PHP Installation
- Adds the `ppa:ondrej/php` repository
- Installs the selected PHP version and extensions:
  - `fpm`
  - `cli`
  - `common`
  - `mysql`
  - `gd`
  - `curl`
  - `mbstring`
  - `xml`
  - `bcmath`
  - `zip`
  - `intl`
  - `soap`
  - `opcache`

### 3. Composer Installation
- Downloads Composer via official installer
- Moves it to `/usr/local/bin/composer` with executable permissions

### 4. MySQL Configuration
- Enables and starts the database service (`mysql`, or `mariadb` when CyberPanel is installed)
- Creates the database if it does not exist
- Creates the database user if it does not exist
- Grants all privileges on the selected database

### 5. Bagisto Installation
- Creates Bagisto project via Composer into `/var/www/bagisto`:
  ```bash
  composer create-project bagisto/bagisto /var/www/bagisto "${BAGISTO_VERSION}" --no-interaction --prefer-dist
  ```

### 6. Environment Configuration
- Copies `.env.example` to `.env` (preserves existing `.env` via `cp -n`)
- Updates `.env` variables:
  - `APP_URL=http://SERVER_IP`
  - `APP_DEBUG=false`
  - `DB_DATABASE`
  - `DB_USERNAME`
  - `DB_PASSWORD`

### 7. Laravel Setup
- Runs Bagisto installer (skips env check and admin creation):
  ```bash
  php artisan bagisto:install --skip-env-check --skip-admin-creation --skip-github-star
  ```
- Optionally installs demo data if selected:
  ```bash
  php artisan db:seed --class="Webkul\\Installer\\Database\\Seeders\\ProductTableSeeder" --force
  php artisan indexer:index --mode=full
  ```
- Clears caches with `php artisan optimize:clear`

### 8. Nginx Configuration
Creates `/etc/nginx/sites-available/bagisto` with dynamic port assignment:
- Port `8080` if Varnish is enabled
- Port `80` if Varnish is disabled

Sample Nginx configuration (port value varies):
```nginx
server {
    listen ${NGINX_PORT};
    listen [::]:${NGINX_PORT};
    server_name _;
    root /var/www/bagisto/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;
    charset utf-8;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
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
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
```

Post-configuration steps:
- Sets ownership to `www-data:www-data`
- Sets permissions on `storage` and `bootstrap/cache` to `775`
- Restarts PHP-FPM and Nginx

### 9. Varnish Integration (Conditional)
Only executed if Varnish is enabled:
- Installs the Bagisto Varnish package:
  ```bash
  composer require bagisto/bagisto-varnish --no-interaction
  ```
- Temporarily changes `/var/www/bagisto` ownership to `root:root` for Composer operations
- Marks the directory as safe for Git
- Registers `Webkul\Varnish\Providers\VarnishServiceProvider::class` in `bootstrap/providers.php` (if missing)
- Publishes package configuration via Artisan
- Copies `vendor/bagisto/bagisto-varnish/vcls/6.0.vcl` to `/etc/varnish/default.vcl`
- Updates VCL backend port to `8080` to point to Nginx

### 10. Varnish Startup (Conditional)
Only executed if Varnish is enabled:
- Stops existing Varnish processes
- Starts Varnish manually with:
  ```bash
  varnishd -a :80 -T localhost:6082 -f /etc/varnish/default.vcl -s malloc,256m
  ```
- Verifies Varnish is listening on port `80`

### 11. SSL Configuration (Conditional)
Only executed if you answered **yes** to SSL **and** provided a valid domain, email and accepted the Let's Encrypt terms. It runs last, once the site is live on port `80`, because Let's Encrypt validates the domain over HTTP. See [SSL Configuration](#ssl-configuration-lets-encrypt).

If the SSL step fails, the installation is **not** rolled back: Bagisto stays available over HTTP, the error is shown, and the script prints the `certbot` command to retry.

## SSL Configuration (Let's Encrypt)

SSL can be configured in two ways. Both use the same logic and ask the same questions.

1. **During installation**: answer `y` to "Do you want to configure an SSL certificate?" (default `N`)
2. **Any time later** (for example when a client asks for SSL days after installation): run the standalone script

```bash
sudo ./bagisto_ssl.sh
```

The standalone script auto-detects the Bagisto folder, PHP version and Nginx port (`8080` when Varnish is in front) from `/etc/nginx/sites-available/bagisto`, then asks for:

| Item | Validation |
|------|------------|
| Domain | Must be a fully qualified domain (no IP, wildcard, URL or `localhost`) and its A record must resolve to this server. Cloudflare-style proxies must be off |
| Email | Valid email format (used for expiry notices) |
| Terms of Service | Must accept the Let's Encrypt terms |
| Final confirmation | Default `N` |

What it does:
1. Re-checks DNS and that the `.well-known/acme-challenge` path is reachable
2. Installs `certbot` and requests the certificate (webroot method, works with and without Varnish)
3. Rewrites `/etc/nginx/sites-available/bagisto`: HTTP redirects to HTTPS, plus an HTTPS server block (TLS 1.2/1.3) on port `443`. The original is backed up to `bagisto.pre-ssl.bak` and restored automatically if `nginx -t` fails
4. Sets `APP_URL=https://YOUR_DOMAIN` in `.env` and clears the Laravel cache
5. Verifies: HTTPS answers with a trusted certificate, certificate validity (at least 7 days left), HTTP to HTTPS redirect, and an automatic-renewal dry run

Renewal is handled automatically by certbot. When Varnish is enabled, HTTPS is served directly by Nginx on `443` and bypasses the Varnish cache (Varnish cannot terminate HTTPS).

## Final Access Details

Script prints the following on successful completion:
- Store URL: `http://YOUR_SERVER_IP` (or `https://YOUR_DOMAIN` if SSL was configured)
- Admin URL: `http://YOUR_SERVER_IP/admin` (or `https://YOUR_DOMAIN/admin` if SSL was configured)
- CyberPanel URL and login (only if CyberPanel was installed): `https://YOUR_SERVER_IP:10000`
- Database username
- Database name
- Admin email: `admin@example.com`
- Admin password: `admin123`

### Access by Mode
#### With Varnish Enabled
- Public store/admin: `http://YOUR_SERVER_IP` (via Varnish :80)
- Direct Nginx backend: `http://YOUR_SERVER_IP:8080` (for debugging)

#### Without Varnish
- Public store/admin: `http://YOUR_SERVER_IP` (via Nginx :80)

## Traffic Flow

### With Varnish
```text
Client -> Varnish (:80) -> Nginx (:8080) -> PHP-FPM -> Bagisto
```

### Without Varnish
```text
Client -> Nginx (:80) -> PHP-FPM -> Bagisto
```

### With SSL (either mode)
```text
Client -> Nginx (:443, TLS) -> PHP-FPM -> Bagisto
Client -> :80 -> 301 redirect to https://YOUR_DOMAIN
```

### CyberPanel Dashboard
```text
Client -> CyberPanel (lscpd, :10000)
```

## Important Notes

- Script must be run as `root`
- HTTP-only by default; HTTPS is configured only if you choose SSL (installer or `bagisto_ssl.sh`)
- CyberPanel requires a fresh server and cannot be installed inside a Docker container (no systemd). The script stops early with a clear message in that case
- With CyberPanel, its OpenLiteSpeed web server is disabled; only the dashboard runs, and Bagisto is served by Nginx/Varnish
- Uses `composer create-project` to install Bagisto (fails if `/var/www/bagisto` already exists)
- Preserves existing `.env` (uses `cp -n` to avoid overwrites)
- Server IP is auto-detected via `hostname -I`
- Varnish is started manually via `nohup varnishd` (no persistent systemd unit configured by default)
- Admin credentials are printed to output on successful installation

## Troubleshooting

### Nginx Check
Adjust port based on Varnish choice:
```bash
nginx -t
systemctl status nginx
# If Varnish enabled: check Nginx on 8080
curl -I http://127.0.0.1:8080
# If Varnish disabled: check Nginx on 80
curl -I http://127.0.0.1:80
```

### PHP-FPM Check
```bash
systemctl status php${PHP_VERSION}-fpm
```
Replace `${PHP_VERSION}` with your selected version (e.g., `8.3`).

### MySQL Check
```bash
systemctl status mysql
```

### Varnish Check (If Enabled)
```bash
ss -tulpn | grep ':80'
ps aux | grep varnishd
```

### CyberPanel Check (If Installed)
```bash
systemctl status lscpd
ss -tulpn | grep ':10000'
```
If the panel is unreachable, make sure port `10000` is open in your cloud firewall / security group.

### SSL Check (If Configured)
```bash
nginx -t
certbot certificates
curl -I https://YOUR_DOMAIN
certbot renew --dry-run
tail -n 50 /var/log/letsencrypt/letsencrypt.log
```
Common causes of failure: the DNS A record does not point to the server, ports `80`/`443` are blocked, or a proxy (for example Cloudflare) is enabled for the domain.

### Laravel Permissions
If Bagisto loads with permission errors:
```bash
chown -R www-data:www-data /var/www/bagisto
chmod -R 775 /var/www/bagisto/storage /var/www/bagisto/bootstrap/cache
```

## Default Install Paths

| Item | Value |
|------|-------|
| App path | `/var/www/bagisto` |
| Nginx site | `/etc/nginx/sites-available/bagisto` |
| Enabled site | `/etc/nginx/sites-enabled/bagisto` |
| Varnish VCL (if enabled) | `/etc/varnish/default.vcl` |
| CyberPanel dashboard (if installed) | `https://YOUR_SERVER_IP:10000` |
| Let's Encrypt certificates (if SSL) | `/etc/letsencrypt/live/YOUR_DOMAIN/` |
| Nginx backup before SSL | `/etc/nginx/sites-available/bagisto.pre-ssl.bak` |

## Run Again
If rerunning the script on the same server, review existing data first. Database, package, and environment changes may affect an existing installation. Remove `/var/www/bagisto` if you want to perform a fresh installation, as `composer create-project` will fail if the directory already exists.
