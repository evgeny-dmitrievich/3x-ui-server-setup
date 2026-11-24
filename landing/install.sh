#!/usr/bin/env bash
# PROJECT_VERSION=2.5.0
# Install an entirely offline public landing page and the pre-import HTTPS router.
# Invoked by setup.sh or resume-after-fail2ban.sh on a CLEAN VPS.
set -Eeuo pipefail
umask 022
(($# == 5)) || { echo 'Usage: install.sh HOST CERT KEY PANEL_PORT REPO_RAW_BASE' >&2; exit 2; }
HOST=$1
CERT=$2
KEY=$3
PANEL_PORT=$4
REPO_RAW_BASE=${5%/}
[[ "$HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo 'Invalid host' >&2; exit 2; }
[[ "$PANEL_PORT" =~ ^[0-9]+$ ]] || { echo 'Invalid port' >&2; exit 2; }
[[ -f "$CERT" && -f "$KEY" ]] || { echo 'Certificate files not found' >&2; exit 2; }
# No remote third-party assets in the HTML page: everything is local, including illustration.
LANDING_DIR=/var/www/3x-ui-landing
install -d -m 755 "$LANDING_DIR" /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/stream.conf.d
curl -fLsS --retry 3 --connect-timeout 20 "$REPO_RAW_BASE/landing/index.html" -o "$LANDING_DIR/index.html.new"
[[ -s "$LANDING_DIR/index.html.new" ]] || { echo 'Empty landing page' >&2; exit 1; }
grep -q '<title>Тихие маршруты' "$LANDING_DIR/index.html.new" || { echo 'Unexpected landing page content' >&2; exit 1; }
install -m 644 "$LANDING_DIR/index.html.new" "$LANDING_DIR/index.html"
rm -f "$LANDING_DIR/index.html.new"
curl -fLsS --retry 3 --connect-timeout 20 "$REPO_RAW_BASE/landing/404.html" -o "$LANDING_DIR/404.html.new"
[[ -s "$LANDING_DIR/404.html.new" ]] || { echo 'Empty 404 page' >&2; exit 1; }
install -m 644 "$LANDING_DIR/404.html.new" "$LANDING_DIR/404.html"
rm -f "$LANDING_DIR/404.html.new"

# All public requests pass through local HTTPS Nginx, including access to the panel.
# The root path alone shows the landing page; the panel's secret base path is unchanged.
cat > /etc/nginx/sites-available/3x-ui-bootstrap.conf <<NGINX_BOOT_HTTP
# Pre-import: public nature landing at / and transparent panel proxy at its secret path.
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
server {
    listen 127.0.0.1:10446 ssl;
    server_name ${HOST};
    ssl_certificate ${CERT};
    ssl_certificate_key ${KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    error_page 404 /404.html;

    location = /404.html {
        internal;
        root /var/www/3x-ui-landing;
    }
    location = / {
        root /var/www/3x-ui-landing;
        try_files /index.html =404;
    }
    location = /index.html {
        root /var/www/3x-ui-landing;
        try_files /index.html =404;
    }
    # Keep every existing panel path intact, including API and WebSocket.
    location / {
        # Unknown public routes should show our 404, while known panel paths still proxy.
        proxy_intercept_errors on;
        proxy_pass https://127.0.0.1:${PANEL_PORT};
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINX_BOOT_HTTP
ln -sfn /etc/nginx/sites-available/3x-ui-bootstrap.conf /etc/nginx/sites-enabled/3x-ui-bootstrap.conf
cat > /etc/nginx/stream.conf.d/00-3x-ui-bootstrap.conf <<'NGINX_BOOT_STREAM'
# Pre-import TLS passthrough to local Nginx: panel + nature landing page.
stream {
    server {
        listen 443;
        listen [::]:443;
        proxy_pass 127.0.0.1:10446;
        proxy_connect_timeout 10s;
        proxy_timeout 1h;
    }
}
NGINX_BOOT_STREAM
printf 'Landing page installed at %s; bootstrap HTTPS listens on 127.0.0.1:10446.\n' "$LANDING_DIR/index.html"
