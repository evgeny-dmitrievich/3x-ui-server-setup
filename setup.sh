#!/usr/bin/env bash
# 3x-ui server bootstrap. NO database is needed or imported at this stage.
# Intended for a NEW Ubuntu VPS. Source files must be published in the same GitHub repository.
set -Eeuo pipefail
umask 077

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
Nginx (443 -> HTTPS-панель), SSH 1335, UFW и Fail2ban.
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
    for blocked in apple.com www.amazon.com www.samsung.com; do
      [[ "$SSL_DOMAIN" != "$blocked" ]] || die 'Нельзя использовать чужой домен маскировки как свой.'
    done
    ;;
  n|no|н|нет|'') SSL_MODE=ip ;;
  *) die 'Ответь y или N.' ;;
esac
read -r -p 'Email для сертификатов Let's Encrypt: ' SSL_EMAIL
[[ "$SSL_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Укажи действительный email для Let's Encrypt.'
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

BACKUP_DIR="/root/3x-ui-setup-backup-$(date +%Y%m%d-%H%M%S)"
install -d -m 700 "$BACKUP_DIR"

PHASE='Системные пакеты и инструменты'
say 'Устанавливаю пакеты, firewall, Fail2ban, Nginx и stream-модуль.'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl openssh-server sudo ufw fail2ban python3 \
  nginx libnginx-mod-stream certbot openssl iproute2 sqlite3

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
say 'Загружаю инструмент, который понадобится ПОСЛЕ восстановления базы.'
install -d -m 755 /usr/local/lib/3x-ui-setup
for spec in 'configure-after-import.sh /usr/local/sbin/3x-ui-after-import' 'db_tool.py /usr/local/lib/3x-ui-setup/db_tool.py'; do
  read -r src dest <<< "$spec"
  curl -fLsS --retry 3 --connect-timeout 20 "${REPO_RAW_BASE}/${src}" -o "${dest}.tmp" || die "Не удалось скачать ${src} из репозитория. Проверь публикацию всех файлов."
  if [[ "$src" == *.sh ]]; then bash -n "${dest}.tmp" || die 'Ошибка синтаксиса помощника'; else python3 - "${dest}.tmp" <<'PY' || die 'Ошибка Python-синтаксиса помощника'
import ast,sys
ast.parse(open(sys.argv[1],encoding='utf-8').read())
PY
  fi
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
ufw allow 13133/tcp comment 'VLESS Reality direct'
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
systemctl enable --now fail2ban
systemctl restart fail2ban
fail2ban-client status sshd >/dev/null || die 'Fail2ban не запустился.'

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
  printf 'PUBLIC_IPV4=%q\n' "$PUBLIC_IPV4"
} > "$SSL_STATE_FILE"
chmod 600 "$SSL_STATE_FILE"

# An initial 443/TCP stream forwards TLS unmodified to 3x-ui HTTPS:13350.
# The after-import tool replaces it with the complete VPN SNI router.
PHASE='Первичный HTTPS через Nginx'
install -d -m 755 /etc/nginx/stream.conf.d
cat > /etc/nginx/stream.conf.d/00-3x-ui-bootstrap.conf <<'STREAM_BOOT'
# Pre-import only: HTTPS on TCP 443 -> built-in panel TLS on 13350.
stream {
    server {
        listen 443;
        listen [::]:443;
        proxy_pass 127.0.0.1:13350;
        proxy_connect_timeout 10s;
        proxy_timeout 1h;
    }
}
STREAM_BOOT
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

1) Панель открывается по HTTPS через TCP 443:
   https://${SSL_HOST}/ПУТЬ_ИЗ_ФАЙЛА/

   Посмотреть случайный путь и логин/пароль панели:
   sudo cat /etc/x-ui/install-result.env

2) В панели вручную восстанови свою SQLite-базу через Backup/Restore.
   После импорта адрес/порт панели могут измениться и доступ временно
   пропадёт: это нормально, следующий этап восстановит правильный маршрут.

3) После импорта выполни НА СЕРВЕРЕ:
   sudo 3x-ui-after-import
   Он использует уже выданный сертификат для ${SSL_HOST},
   маршрутизирует VPN через TCP 443 и обновит адреса подписок.

4) Рекомендуется проверить выпуск и продление сертификата:
   sudo /root/.acme.sh/acme.sh --list

Резервные копии: ${BACKUP_DIR}
Также открой TCP 80/443 и нужные UDP-порты в firewall VPS-провайдера.
END
