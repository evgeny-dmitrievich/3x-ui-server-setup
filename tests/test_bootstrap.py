#!/usr/bin/env python3
"""Offline static regressions for first install and safe management actions."""
from pathlib import Path
import subprocess

root=Path(__file__).resolve().parents[1]
for script in ('setup.sh','configure-after-import.sh','change-domain.sh','stack-manager.sh'):
    subprocess.run(['bash','-n',str(root/script)],check=True)
subprocess.run(['bash',str(root/'setup.sh'),'--help'],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['bash',str(root/'stack-manager.sh'),'--help'],check=True,stdout=subprocess.DEVNULL)
setup=(root/'setup.sh').read_text()
manager=(root/'stack-manager.sh').read_text()
helper=(root/'db_tool.py').read_text()
assert setup.index("PHASE='Preparing console font'") < setup.index("cat <<'INTRO'")
assert 'export LANG=C.UTF-8 LC_ALL=C.UTF-8' in setup
assert 'CODESET="Uni2"' in setup and 'FONTFACE="Terminus"' in setup
assert 'setupcon --force' in setup
assert 'XUI_SSL_MODE="$SSL_MODE"' in setup
assert 'SSL_EMAIL=%q' in setup
assert "for ((attempt=0; attempt<12; attempt++))" in setup
assert 'for ((attempt=0; attempt<12; attempt++))' in setup
assert 'ufw allow 1335/tcp' in setup
assert "ss -H -ltn \"sport = :${SSH_PORT}\"" in setup
assert 'ssh -o PreferredAuthentications=publickey' in setup
assert 'sudo 3x-ui-change-domain' in setup
for name in ('configure-after-import.sh','change-domain.sh','stack-manager.sh','db_tool.py'):
    assert name in setup, f'{name} not installed by bootstrap'
assert '3x-ui-stack-manager after-import' in (root/'configure-after-import.sh').read_text()
assert '3x-ui-stack-manager change-domain' in (root/'change-domain.sh').read_text()
assert 'proxy_ssl_verify off;' in helper and 'proxy_ssl_verify on;' not in helper
assert 'read -r -p' in manager and 'Подтвердить изменения' in manager
assert 'snapshot_configs' in manager and 'restore_configs' in manager
assert 'live-before.db' in manager and 'healthcheck' in manager
assert 'systemctl reload nginx' in manager
assert '3x-ui-after-import' in manager and '3x-ui-change-domain' in manager
assert 'landing/install.sh' in setup
assert '3x-ui-wg-setup' in setup
assert 'ufw allow 51820/udp' in setup
assert 'wireguard/setup.sh' in setup and 'wireguard/manage.sh' in setup
assert '3x-ui-bootstrap.conf' in manager and 'rm -f "$STREAM_BOOT" "$HTTP_BOOT_LINK"' in manager
assert 'Стартовая страница ответила HTTP' in setup
assert 'Сайт-заглушка ответил' in manager
assert "--noproxy '*'" in manager
assert 'SECONDS - start < 12' in manager
assert 'Локальная панель не ответила' in manager
assert 'Не удалось соединиться с панелью через Nginx/TCP 443' in manager
landing_html=(root/'landing/index.html').read_text()
assert '<!doctype html>' in landing_html.lower() and '<title>Тихие маршруты' in landing_html
assert '<svg' in landing_html and '<script' not in landing_html.lower()
assert all(bad not in landing_html for bad in ('http://', 'https://', '3x-ui', 'VPN', 'Xray'))
assert (root/'landing/install.sh').is_file()
assert (root/'landing/404.html').is_file()
page404=(root/'landing/404.html').read_text()
assert 'href="/"' in page404 and '<title>Тропа не найдена' in page404
assert 'error_page 404 /404.html;' in (root/'landing/install.sh').read_text()
assert 'error_page 404 /404.html;' in helper
for name in ('wireguard/setup.sh','wireguard/manage.sh'):
    subprocess.run(['bash','-n',str(root/name)],check=True)
installer=(root/'wireguard/setup.sh').read_text()
manager_wg=(root/'wireguard/manage.sh').read_text()
assert 'wg genkey' in installer and 'wg genpsk' in installer
assert "Роутер" in installer and "Роутер (Катя)" in installer
assert 'ListenPort = ${PORT}' in installer and 'PORT=51820' in installer
assert 'wg-quick@wg0' in installer and 'ufw route allow in on wg0' in installer
assert '0.0.0.0/0' in installer and 'net.ipv4.ip_forward = 1' in installer
assert 'sudo 3x-ui-wg export' in (root/'README.md').read_text()
assert 'install -m 600' in manager_wg
subprocess.run(['bash','-n',str(root/'landing/install.sh')],check=True)
assert 'x-ui setting -username' not in manager
assert 'PANEL_USER=' not in manager and 'PANEL_PASS=' not in manager
assert 'AuthenticationMethods publickey' in setup
assert (root/'.gitignore').is_file()
print('PASS: installation, SSH/Fail2ban, no credential resets, SSL and safe rollback.')
