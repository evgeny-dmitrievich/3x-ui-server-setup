#!/usr/bin/env bash
# PROJECT_VERSION=2.8.0
# 3x-ui server bootstrap. NO database is needed or imported at this stage.
# Intended for a NEW Ubuntu VPS. Source files must be published in the same GitHub repository.
set -Eeuo pipefail
umask 077

# Use UTF-8 within this process without changing the system-wide locale.
# The Linux virtual console (tty1 etc.) also needs a font with Cyrillic glyphs.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a UCF_FORCE_CONFFOLD=1

readonly PROJECT_VERSION='2.8.0'
readonly SSH_PORT=1335
readonly PANEL_PORT=13350
readonly VERIFY_MARKER=/run/3xui-ssh-verified
readonly OFFICIAL_INSTALL_URL=https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh
readonly REPO_RAW_BASE=${SETUP_REPO_RAW_BASE:-https://raw.githubusercontent.com/evgeny-dmitrievich/3x-ui-server-setup/main}
PHASE='Проверки'
SSL_MODE='ip'
SSL_DOMAIN=''
SSL_EMAIL=''
SSL_HOST=''
SSL_CERT=''
SSL_KEY=''
PUBLIC_IPV4=''
readonly SSL_STATE_FILE=/etc/3x-ui-setup/bootstrap.env
BACKUP_DIR=''
SSH_USER=''
SSH_SOCKET_ACTIVE=0

say() { printf '\n\033[1;36m[3x-ui]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[Внимание]\033[0m %s\n' "$*" >&2; }
die() { printf '\n\033[1;31m[Ошибка]\033[0m (%s) %s\n' "$PHASE" "$*" >&2; exit 1; }
trap 'warn "Сбой на этапе: ${PHASE}, строка ${LINENO}. Резервные копии: ${BACKUP_DIR:-ещё не созданы}."' ERR

usage() {
  cat <<'HELP'
3x-ui Server Setup — установка одной командой, БЕЗ импорта базы.

  curl -fsSL https://raw.githubusercontent.com/evgeny-dmitrievich/3x-ui-server-setup/main/setup.sh \
    -o /tmp/3x-ui-setup.sh && sudo bash /tmp/3x-ui-setup.sh

Устанавливаются: официальная 3x-ui, SSL для своего домена ИЛИ публичного IP,
Nginx (443 -> HTTPS-панель + сайт о природе), SSH 1335, UFW и Fail2ban.
После импорта базы выполняется простая команда:
  sudo 3x-ui-after-import
Она применяет уже выданный сертификат и настраивает VPN-маршруты.
Порт 80 должен быть доступен снаружи для выдачи и продления сертификата.

Важное: только ЧИСТЫЙ Ubuntu 22.04 или 24.04 VPS, c веб-консолью провайдера.
Репозиторий 3x-ui-server-setup сначала нужно создать и загрузить в GitHub.
HELP
}

if (($#)); then
  case "$1" in -h|--help) usage; exit 0 ;; *) usage; die "Неизвестный аргумент: $1" ;; esac
fi
[[ $EUID -eq 0 ]] || die 'Запускай с правами root (sudo bash).'
[[ -t 0 ]] || die 'Нужна интерактивная консоль. Используй curl -o /tmp/setup.sh && sudo bash /tmp/setup.sh.'
[[ -r /etc/os-release ]] || die 'Не удалось определить ОС.'
# shellcheck source=/dev/null
source /etc/os-release
[[ "$ID" == ubuntu && ("$VERSION_ID" == 22.04 || "$VERSION_ID" == 24.04) ]] || die 'Поддерживается только Ubuntu 22.04/24.04.'
[[ ! -e /usr/local/x-ui/x-ui && ! -e /usr/bin/x-ui && ! -e /etc/x-ui/x-ui.db ]] || die '3x-ui или её база уже установлена. На действующем сервере запуск запрещён.'
[[ ! -e /etc/nginx/nginx.conf && ! -e /etc/nginx/stream.conf.d ]] || die 'Nginx уже установлен или настроен. Автоматическая перезапись запрещена.'
# Never alter firewall/SSH on a machine whose current login path is not the standard port 22.
if [[ -x /usr/sbin/sshd ]]; then
  ACTIVE_SSH_PORTS=$(/usr/sbin/sshd -T | awk '$1=="port"{print $2}' | sort -u)
  [[ "$ACTIVE_SSH_PORTS" == 22 ]] || die 'Текущая конфигурация SSH использует не только порт 22. Требуется ручная настройка.'
fi
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  die 'UFW уже активен. Скрипт не перезаписывает действующий firewall.'
fi
for p in 80 443 "$PANEL_PORT" "$SSH_PORT"; do
  if command -v ss >/dev/null && ss -H -ltn "sport = :${p}" | grep -q .; then
    die "TCP-порт ${p} уже занят. Требуется чистый VPS."
  fi
done
if [[ -r /etc/ssh/sshd_config ]]; then
  if grep -E '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config | grep -qvE '^[[:space:]]*Port[[:space:]]+22([[:space:]]|$)'; then
    die 'Есть нестандартные SSH-порты. Не меняем их автоматически.'
  fi
fi

# Freeze all source components BEFORE changing system services. This prevents
# mixing an old setup.sh with newer stack-manager.sh/db_tool.py from GitHub.
# If a multi-file GitHub upload is incomplete, abort while SSH/UFW remain intact.
PHASE='Проверка комплекта исходных файлов'
SOURCE_STAGE=$(mktemp -d /tmp/3x-ui-source.XXXXXXXX)
trap 'rm -rf -- "${SOURCE_STAGE:-/nonexistent}"' EXIT
printf '[3x-ui] Checking downloaded installation files...\n'
SOURCE_ITEMS=(
  setup.sh configure-after-import.sh change-domain.sh stack-manager.sh db_tool.py prepare-import.sh
  landing/install.sh landing/index.html landing/404.html
  wireguard/setup.sh wireguard/manage.sh
)
for src in "${SOURCE_ITEMS[@]}"; do
  mkdir -p "${SOURCE_STAGE}/$(dirname "$src")"
  curl --fail --location --silent --show-error --retry 2 --connect-timeout 10 --max-time 35 \
    "${REPO_RAW_BASE}/${src}" -o "${SOURCE_STAGE}/${src}" \
    || die "Не удалось загрузить ${src}; проверь GitHub."
  [[ -s "${SOURCE_STAGE}/${src}" ]] || die "Пустой файл ${src}."
  case "$src" in
    *.sh) bash -n "${SOURCE_STAGE}/${src}" || die "Ошибка Bash в ${src}." ;;
    *.py) python3 - "${SOURCE_STAGE}/${src}" <<'CHECKPY' || die "Ошибка Python в ${src}."
import ast,sys
with open(sys.argv[1],encoding='utf-8') as f: ast.parse(f.read())
CHECKPY
      ;;
  esac
done
[[ -f "${0}" ]] && cmp -s -- "$0" "${SOURCE_STAGE}/setup.sh" \
  || die 'Скачанный setup.sh отличается от опубликованной версии. Загрузи весь новый проект в GitHub и скачай setup.sh заново.'
printf '[3x-ui] All required installation files checked.\n'

# Configure a Cyrillic-capable console font BEFORE the first Russian prompts.
# Same safe approach as our 3ax-server-setup: do not change OS-wide language.
PHASE='Preparing console font'
BACKUP_DIR="/root/3x-ui-setup-backup-$(date +%Y%m%d-%H%M%S)"
install -d -m 700 "$BACKUP_DIR"
printf '[3x-ui] Preparing UTF-8 / Cyrillic Linux console font...\n'
apt-get -y -o 'Dpkg::Options::=--force-confold' update
apt-get -y -o 'Dpkg::Options::=--force-confold' install \
  console-setup console-setup-linux kbd openssh-client
if [[ -f /etc/default/console-setup ]]; then
  cp -a /etc/default/console-setup "$BACKUP_DIR/console-setup.orig"
  for entry in 'CHARMAP="UTF-8"' 'CODESET="Uni2"' 'FONTFACE="Terminus"' 'FONTSIZE="8x16"'; do
    key=${entry%%=*}
    if grep -q "^${key}=" /etc/default/console-setup; then
      sed -i "s/^${key}=.*/${entry}/" /etc/default/console-setup
    else
      printf '%s\n' "$entry" >> /etc/default/console-setup
    fi
  done
  CONSOLE_TTY=$(tty 2>/dev/null || true)
  if [[ -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ]] &&
     [[ "${TERM:-}" == linux || "$CONSOLE_TTY" =~ ^/dev/tty[0-9]+$ ]]; then
    if ! setupcon --force >/dev/null 2>&1; then
      printf '[3x-ui] Warning: console font could not be applied; try SSH terminal.\n' >&2
    fi
  fi
else
  printf '[3x-ui] Warning: console-setup configuration is missing.\n' >&2
fi
PHASE='Проверки и исходные параметры'

cat <<'INTRO'
Установщик НЕ читает и НЕ восстанавливает SQLite-базу.
Ты загрузишь её позже в панели 3x-ui через HTTPS.

SSL: свой домен (если есть), иначе настоящий Let's Encrypt сертификат
для публичного IPv4. IP-сертификаты действуют около 6 дней, обновляются
автоматически. Нужен входящий TCP 80 от интернета для проверки ACME.

Будут изменены SSH и UFW. Нужен публичный SSH-ключ, доступ к веб-консоли
хостинга (на случай ошибки) и snapshot нового VPS.
Порт 22 закрывается ТОЛЬКО после проверки SSH-доступа на 1335.
INTRO
read -r -p 'Подтвердить установку на новом VPS (YES): ' ACK
[[ "$ACK" == YES ]] || die 'Отменено.'
read -r -p 'Есть собственный домен, указывающий прямо на этот сервер? (y/N): ' HAS_DOMAIN
case "${HAS_DOMAIN,,}" in
  y|yes|д|да)
    SSL_MODE=domain
    read -r -p 'Введи домен (например, vpn.example.org): ' SSL_DOMAIN
    SSL_DOMAIN=${SSL_DOMAIN,,}
    [[ "$SSL_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ && ${#SSL_DOMAIN} -le 253 ]] || die 'Некорректный домен.'
    for blocked in dl.google.com apple.com www.amazon.com www.samsung.com; do
      [[ "$SSL_DOMAIN" != "$blocked" ]] || die 'Нельзя использовать чужой домен маскировки как свой.'
    done
    ;;
  n|no|н|нет|'') SSL_MODE=ip ;;
  *) die 'Ответь y или N.' ;;
esac
read -r -p "Email для сертификатов Let's Encrypt: " SSL_EMAIL
[[ "$SSL_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Укажи действительный email для Let's Encrypt."
read -r -p 'Новый SSH-логин (латиница): ' SSH_USER
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$SSH_USER" != root ]] || die 'Некорректный SSH-логин.'
! getent passwd "$SSH_USER" >/dev/null || die 'Такой пользователь уже существует.'
read -r -s -p 'Пароль для sudo (минимум 12 символов): ' SUDO_PASS; echo
read -r -s -p 'Повтори пароль: ' SUDO_PASS2; echo
[[ ${#SUDO_PASS} -ge 12 && "$SUDO_PASS" == "$SUDO_PASS2" ]] || die 'Пароли не совпадают или слишком короткие.'
unset SUDO_PASS2
printf '%s\n' 'Вставь публичный SSH-ключ одной строкой (ssh-ed25519 AAAA...):'
IFS= read -r PUBLIC_KEY
[[ "$PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256)[[:space:]]+[A-Za-z0-9+/]+={0,2}([[:space:]].*)?$ ]] || die 'Нужен ПУБЛИЧНЫЙ SSH-ключ.'
KEYTMP=$(mktemp)
printf '%s\n' "$PUBLIC_KEY" > "$KEYTMP"
ssh-keygen -lf "$KEYTMP" >/dev/null 2>&1 || { rm -f "$KEYTMP"; die 'Недопустимый публичный ключ.'; }
rm -f "$KEYTMP"

PHASE='Системные пакеты и инструменты'
say 'Устанавливаю пакеты, firewall, Fail2ban, Nginx и stream-модуль.'
apt-get install -y --no-install-recommends ca-certificates curl openssh-server sudo ufw fail2ban python3 \
  nginx libnginx-mod-stream certbot openssl iproute2 sqlite3 python3-systemd

# ACME can only issue for a reachable PUBLIC IP. Domain must resolve directly
# to this address, not a reverse-proxy CDN or somebody else's server.
PHASE='Проверка публичного IP и DNS'
PUBLIC_IPV4=$(curl -4fsS --retry 2 --connect-timeout 8 --max-time 12 https://api.ipify.org | tr -d '[:space:]') || die 'Не удалось узнать публичный IPv4. Проверь сеть.'
python3 - "$PUBLIC_IPV4" <<'PYIP' || die 'Нет действительного публичного IPv4.'
import ipaddress,sys
try:
    addr=ipaddress.ip_address(sys.argv[1]); assert addr.version==4 and addr.is_global
except (ValueError,AssertionError): sys.exit(1)
PYIP
if [[ "$SSL_MODE" == domain ]]; then
  python3 - "$SSL_DOMAIN" "$PUBLIC_IPV4" <<'PYDNS' || die 'DNS A-запись домена не указывает напрямую на IP сервера; SSL пока нельзя выпустить.'
import socket,sys
try:
    ips={x[4][0] for x in socket.getaddrinfo(sys.argv[1],None,family=socket.AF_INET)}
    if sys.argv[2] not in ips: sys.exit(1)
except (socket.gaierror,OSError): sys.exit(1)
PYDNS
  SSL_HOST="$SSL_DOMAIN"
  SSL_CERT="/root/cert/${SSL_DOMAIN}/fullchain.pem"
  SSL_KEY="/root/cert/${SSL_DOMAIN}/privkey.pem"
else
  SSL_HOST="$PUBLIC_IPV4"
  SSL_CERT='/root/cert/ip/fullchain.pem'
  SSL_KEY='/root/cert/ip/privkey.pem'
fi
say "SSL: ${SSL_MODE}, адрес: ${SSL_HOST}." 
# Keep nginx stopped for ACME standalone on port 80; enable TLS on 443 later.
systemctl stop nginx || true
systemctl disable nginx >/dev/null 2>&1 || true
rm -f /etc/nginx/sites-enabled/default

PHASE='Установка помощника для шага после импорта'
say 'Загружаю инструменты после импорта и смены домена/IP.'
install -d -m 755 /usr/local/lib/3x-ui-setup
for spec in \
  'configure-after-import.sh /usr/local/sbin/3x-ui-after-import' \
  'change-domain.sh /usr/local/sbin/3x-ui-change-domain' \
  'stack-manager.sh /usr/local/sbin/3x-ui-stack-manager' \
  'prepare-import.sh /usr/local/sbin/3x-ui-prepare-import' \
  'db_tool.py /usr/local/lib/3x-ui-setup/db_tool.py'; do
  read -r src dest <<< "$spec"
  cp -a "${SOURCE_STAGE}/${src}" "${dest}.tmp"
  if [[ "$src" == *.sh ]]; then bash -n "${dest}.tmp" || die 'Ошибка синтаксиса помощника'; else python3 - "${dest}.tmp" <<'PY' || die 'Ошибка Python-синтаксиса помощника'
import ast,sys
ast.parse(open(sys.argv[1],encoding='utf-8').read())
PY
  fi
  install -m 755 -o root -g root "${dest}.tmp" "$dest"
  rm -f "${dest}.tmp"
done

PHASE='Подготовка помощника WireGuard'
for spec in 'wireguard/setup.sh /usr/local/sbin/3x-ui-wg-setup' \
            'wireguard/manage.sh /usr/local/sbin/3x-ui-wg'; do
  read -r src dest <<< "$spec"
  cp -a "${SOURCE_STAGE}/${src}" "${dest}.tmp"
  bash -n "${dest}.tmp" || die "Ошибка синтаксиса ${src}."
  install -m 755 -o root -g root "${dest}.tmp" "$dest"
  rm -f "${dest}.tmp"
done

PHASE='Настройка SSH-пользователя'
say 'Создаю нового пользователя. Порт 22 пока остаётся открытым.'
useradd -m -s /bin/bash "$SSH_USER"
printf '%s:%s\n' "$SSH_USER" "$SUDO_PASS" | chpasswd
unset SUDO_PASS
usermod -aG sudo "$SSH_USER"
HOME_DIR=$(getent passwd "$SSH_USER" | cut -d: -f6)
install -d -o "$SSH_USER" -g "$SSH_USER" -m 700 "$HOME_DIR/.ssh"
printf '%s\n' "$PUBLIC_KEY" > "$HOME_DIR/.ssh/authorized_keys"
chown "$SSH_USER:$SSH_USER" "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
unset PUBLIC_KEY
cp -a /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.bak"
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config; then
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi
install -d -m 755 /etc/ssh/sshd_config.d
SSH_DROPIN=/etc/ssh/sshd_config.d/00-3xui-bootstrap.conf
cat > "$SSH_DROPIN" <<'SSHTEMP'
# Port 22 is temporary; it will be removed ONLY after verification.
Port 22
Port 1335
PubkeyAuthentication yes
SSHTEMP
if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
  SSH_SOCKET_ACTIVE=1
  install -d -m 755 /etc/systemd/system/ssh.socket.d
  cat > /etc/systemd/system/ssh.socket.d/00-3xui-bootstrap.conf <<'SOCK'
[Socket]
ListenStream=
ListenStream=22
ListenStream=1335
SOCK
  systemctl daemon-reload
  systemctl restart ssh.socket
fi
/usr/sbin/sshd -t
systemctl restart ssh.service
ss -H -ltn "sport = :${SSH_PORT}" | grep -q . || die 'SSH не слушает порт 1335.'

PHASE='UFW и Fail2ban'
say 'Открываю нужные TCP/UDP-порты и настраиваю защиту SSH.'
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'TEMPORARY SSH access'
ufw allow 1335/tcp comment 'Admin SSH'
ufw allow 80/tcp comment 'Certificate ACME HTTP-01'
ufw allow 443/tcp comment 'Nginx stream TLS'
ufw allow 51820/udp comment 'Standalone WireGuard wg0'
for p in 443 8444 51821 51822; do ufw allow "$p/udp" comment '3x-ui UDP inbound'; done
ufw --force enable
ufw status | grep -q '^Status: active' || die 'UFW не активировался.'
install -d -m 755 /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/99-3xui-sshd.local <<'JAIL'
[sshd]
enabled = true
port = 1335
filter = sshd
backend = systemd
maxretry = 3
findtime = 10m
bantime = 12h
JAIL
# Ubuntu can return from 'systemctl restart' before the Unix socket is ready.
# Verify config and wait for the jail; on a real failure print the actual service logs.
if ! fail2ban-client -t; then
  systemctl status fail2ban --no-pager -l || true
  journalctl -u fail2ban -n 35 --no-pager || true
  die 'Ошибка конфигурации Fail2ban; смотри сообщения выше.'
fi
systemctl enable fail2ban
if ! systemctl restart fail2ban; then
  systemctl status fail2ban --no-pager -l || true
  journalctl -u fail2ban -n 35 --no-pager || true
  die 'Fail2ban не смог перезапуститься; смотри журнал выше.'
fi
FAIL2BAN_READY=0
for ((attempt=0; attempt<12; attempt++)); do
  if systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
    FAIL2BAN_READY=1
    break
  fi
  if systemctl is-failed --quiet fail2ban; then break; fi
  if (( attempt < 11 )); then sleep 1; fi
done
if (( ! FAIL2BAN_READY )); then
  systemctl status fail2ban --no-pager -l || true
  journalctl -u fail2ban -n 35 --no-pager || true
  die 'Fail2ban не готов или sshd-jail не запущен.'
fi
say 'Fail2ban готов, защита sshd включена.'

PHASE='Официальная панель 3x-ui'
say 'Устанавливаю свежую стабильную версию официальной 3x-ui (БЕЗ базы).'
OFFICIAL_FILE="$BACKUP_DIR/mhsanaei-install.sh"
curl -fLsS --retry 3 --connect-timeout 20 "$OFFICIAL_INSTALL_URL" -o "$OFFICIAL_FILE"
bash -n "$OFFICIAL_FILE" || die 'Ошибка синтаксиса официального установщика.'
sha256sum "$OFFICIAL_FILE" > "$BACKUP_DIR/mhsanaei-install.sha256"
XUI_NONINTERACTIVE=1 XUI_SSL_MODE="$SSL_MODE" XUI_DOMAIN="$SSL_DOMAIN" \
  XUI_ACME_EMAIL="$SSL_EMAIL" XUI_ACME_HTTP_PORT=80 XUI_SERVER_IP="$PUBLIC_IPV4" \
  XUI_DB_TYPE=sqlite XUI_PANEL_PORT="$PANEL_PORT" bash "$OFFICIAL_FILE"
[[ -x /usr/local/x-ui/x-ui ]] || die '3x-ui не установлена.'
systemctl is-active --quiet x-ui || die 'Служба x-ui не активна.'
[[ -s /etc/x-ui/install-result.env ]] || die 'Не найден файл учётных данных официальной установки.'
chmod 600 /etc/x-ui/install-result.env

PHASE='Проверка сертификата и HTTPS панели'
[[ -s "$SSL_CERT" && -s "$SSL_KEY" ]] || die "Официальная установка не выпустила SSL для ${SSL_HOST}. Не открываю HTTPS без сертификата."
openssl x509 -in "$SSL_CERT" -noout -checkend 86400 >/dev/null || die 'SSL-сертификат недействителен или скоро истекает.'
if [[ "$SSL_MODE" == ip ]]; then
  openssl x509 -in "$SSL_CERT" -noout -checkip "$SSL_HOST" | grep -qi 'does match' || die 'IP не присутствует в SAN сертификата.'
else
  openssl x509 -in "$SSL_CERT" -noout -checkhost "$SSL_HOST" | grep -qi 'does match' || die 'Домен не присутствует в SAN сертификата.'
fi
CERT_PUB=$(openssl x509 -in "$SSL_CERT" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')
KEY_PUB=$(openssl pkey -in "$SSL_KEY" -pubout -outform DER | sha256sum | awk '{print $1}')
[[ "$CERT_PUB" == "$KEY_PUB" ]] || die 'Сертификат и приватный ключ не совпадают.'

# Root-only state is read after manual database restoration, without re-prompting.
install -d -m 700 /etc/3x-ui-setup
{
  printf 'SSL_MODE=%q\n' "$SSL_MODE"
  printf 'SSL_HOST=%q\n' "$SSL_HOST"
  printf 'SSL_CERT=%q\n' "$SSL_CERT"
  printf 'SSL_KEY=%q\n' "$SSL_KEY"
  printf 'SSL_EMAIL=%q\n' "$SSL_EMAIL"
  printf 'PUBLIC_IPV4=%q\n' "$PUBLIC_IPV4"
} > "$SSL_STATE_FILE"
chmod 600 "$SSL_STATE_FILE"

# Before import, TCP 443 forwards to a local Nginx TLS terminator,
# serving the public nature landing and proxying all other paths to the panel.
# After import, the manager replaces both Nginx routes while retaining the landing.
PHASE='Первичный HTTPS через Nginx'
say 'Устанавливаю природную страницу-заглушку и локальный HTTPS-прокси панели.'
LANDING_INSTALL="$BACKUP_DIR/landing-install.sh"
cp -a "${SOURCE_STAGE}/landing/install.sh" "$LANDING_INSTALL"
bash -n "$LANDING_INSTALL" || die 'Ошибка синтаксиса установщика сайта-заглушки.'
bash "$LANDING_INSTALL" "$SSL_HOST" "$SSL_CERT" "$SSL_KEY" "$PANEL_PORT" "file://${SOURCE_STAGE}" || die 'Не удалось установить сайт-заглушку.'
python3 - <<'PYNGINX'
from pathlib import Path
import re
p=Path('/etc/nginx/nginx.conf'); s=p.read_text()
t='include /etc/nginx/stream.conf.d/*.conf;'
if t not in s:
    m=re.search(r'(?m)^http\s*\{',s)
    if not m: raise SystemExit('nginx.conf: http block not found')
    p.write_text(s[:m.start()]+t+'\n\n'+s[m.start():])
PYNGINX
nginx -t || die 'Nginx не принял стартовую HTTPS-конфигурацию.'
systemctl enable --now nginx
ss -H -ltn 'sport = :443' | grep -q . || die 'Nginx не слушает TCP 443.'
# Fail early if the ordinary public landing page is not reachable via real TLS/SNI.
BOOT_HTTP_STATUS=$(curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 \
  --resolve "${SSL_HOST}:443:127.0.0.1" "https://${SSL_HOST}/") || die 'Стартовая страница не открывается через Nginx.'
[[ "$BOOT_HTTP_STATUS" == 200 ]] || die "Стартовая страница ответила HTTP ${BOOT_HTTP_STATUS}, ожидался 200."
BOOT_404_STATUS=$(curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 \
  --resolve "${SSL_HOST}:443:127.0.0.1" "https://${SSL_HOST}/__missing_nature_page_3xui__") || die 'Страница 404 не открывается через Nginx.'
[[ "$BOOT_404_STATUS" == 404 ]] || die "Несуществующая страница ответила HTTP ${BOOT_404_STATUS}, ожидался 404."


PHASE='Самостоятельный WireGuard с двумя профилями'
say 'Настраиваю WireGuard (UDP 51820) и создаю профили «Роутер» и «Роутер (Катя)».'
bash /usr/local/sbin/3x-ui-wg-setup "$PUBLIC_IPV4" "$SSH_USER" || die 'WireGuard не установился. SSH 22 остаётся доступен, пока установка не завершена.'

PHASE='Подтверждение SSH на 1335'
cat <<SSHVERIFY

====================================================================
ПРОВЕРКА SSH — открой ВТОРОЙ терминал, не закрывая этот.

  ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no \\
      -o KbdInteractiveAuthentication=no -p 1335 ${SSH_USER}@SERVER_IP

В новой сессии выполни:
  sudo touch ${VERIFY_MARKER}

Вернись сюда и нажми Enter. Пока метки нет, порт 22 НЕ закрывается.
Нажатие Ctrl+C оставит старый порт 22 открытым.
====================================================================
SSHVERIFY
rm -f "$VERIFY_MARKER"
while :; do
  read -r -p 'Проверка завершена? Нажми Enter (Ctrl+C отмена): ' _
  if [[ -f "$VERIFY_MARKER" && $(stat -c %u "$VERIFY_MARKER") == 0 ]]; then break; fi
  warn 'Нужна проверочная метка, созданная через новую SSH-сессию с sudo.'
done

PHASE='Завершение защиты SSH'
cat > "$SSH_DROPIN" <<'SSHFINAL'
Port 1335
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PermitEmptyPasswords no
SSHFINAL
if (( SSH_SOCKET_ACTIVE )); then
  cat > /etc/systemd/system/ssh.socket.d/00-3xui-bootstrap.conf <<'SOCK'
[Socket]
ListenStream=
ListenStream=1335
SOCK
  systemctl daemon-reload
  systemctl restart ssh.socket
fi
/usr/sbin/sshd -t || die 'Ошибочная финальная SSH-конфигурация. Порт 22 пока открыт в UFW.'
SSH_EFF=$(/usr/sbin/sshd -T -C "user=${SSH_USER},host=localhost,addr=127.0.0.1")
ROOT_EFF=$(/usr/sbin/sshd -T -C 'user=root,host=localhost,addr=127.0.0.1')
PORTS=$(printf '%s\n' "$SSH_EFF" | awk '$1=="port"{print $2}' | sort -u)
[[ "$PORTS" == 1335 ]] || die 'Эффективный порт SSH не равен 1335.'
for must in 'pubkeyauthentication yes' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'authenticationmethods publickey'; do
  printf '%s\n' "$SSH_EFF" | grep -qx "$must" || die "SSH не применил $must"
done
printf '%s\n' "$ROOT_EFF" | grep -qx 'permitrootlogin no' || die 'Доступ root по SSH ещё не отключён.'
systemctl restart ssh.service
ss -H -ltn "sport = :${SSH_PORT}" | grep -q . || die 'SSH перестал слушать 1335.'
ufw --force delete allow 22/tcp || true
ufw --force delete allow OpenSSH >/dev/null 2>&1 || true
rm -f "$VERIFY_MARKER"

PHASE='Готово'
say "3x-ui установлена, HTTPS включён для ${SSL_HOST}. База ещё НЕ ИМПОРТИРОВАНА."
cat <<END

1) На https://${SSL_HOST}/ показывается публичная страница о природе.
   Панель открывается по HTTPS на её прежнем секретном пути через TCP 443:
   https://${SSL_HOST}/ПУТЬ_ИЗ_ФАЙЛА/

   Посмотреть случайный путь и логин/пароль панели:
   sudo cat /etc/x-ui/install-result.env

2) Сначала подготовь исходный SQLite-файл без изменения активной базы:
   sudo 3x-ui-prepare-import /home/USER/source.db
   Затем импортируй полученный *-prepared-*.db через Backup/Restore.
   Если TUIC мешает старту Xray, после проверки журналов попробуй:
   sudo 3x-ui-prepare-import --disable-tuic /home/USER/source.db
   Этот вариант отключает только TUIC, не удаляет его клиентов.

3) Только ПОСЛЕ успешного импорта выполни НА СЕРВЕРЕ:
   sudo 3x-ui-after-import
   Он использует уже выданный сертификат для ${SSL_HOST},
   маршрутизирует VPN через TCP 443 и обновит адреса подписок.

4) В любой момент можно изменить домен или вернуться на IP:
   sudo 3x-ui-change-domain

5) Рекомендуется проверить выпуск и продление сертификата:
   sudo /root/.acme.sh/acme.sh --list

WireGuard: создан отдельный сервер UDP 51820 и два профиля:
   «Роутер» и «Роутер (Катя)».
   Безопасно выгрузить их в домашнюю папку SSH-пользователя:
   sudo 3x-ui-wg export all
   Посмотреть статус или создать следующий профиль:
   sudo 3x-ui-wg status
   sudo 3x-ui-wg add 'Название'
   Затем скачай *.conf через SFTP/SSH (порт 1335).

Резервные копии: ${BACKUP_DIR}
Также открой TCP 80/443 и нужные UDP-порты в firewall VPS-провайдера.
END
