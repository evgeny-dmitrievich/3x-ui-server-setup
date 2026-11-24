#!/usr/bin/env bash
# PROJECT_VERSION=2.5.0
# Restart ONLY the known pre-panel Fail2ban interruption from 3x-ui-server-setup.
# Never reset the current SSH user or UFW. Do not use on a live 3x-ui server.
set -Eeuo pipefail
umask 077
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a UCF_FORCE_CONFFOLD=1

readonly PROJECT_VERSION='2.5.0'
readonly SSH_PORT=1335
readonly PANEL_PORT=13350
readonly VERIFY_MARKER=/run/3xui-ssh-verified
readonly OFFICIAL_INSTALL_URL=https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh
readonly REPO_RAW_BASE=${SETUP_REPO_RAW_BASE:-https://raw.githubusercontent.com/evgeny-dmitrievich/3x-ui-server-setup/main}
readonly SSL_STATE_FILE=/etc/3x-ui-setup/bootstrap.env
PHASE='Проверка возможности продолжения'
SSL_MODE='ip'
SSL_DOMAIN=''
SSL_EMAIL=''
SSL_HOST=''
SSL_CERT=''
SSL_KEY=''
PUBLIC_IPV4=''
SSH_USER=''
SSH_DROPIN=/etc/ssh/sshd_config.d/00-3xui-bootstrap.conf
SSH_SOCKET_ACTIVE=0
BACKUP_DIR=''
say() { printf '\n\033[1;36m[3x-ui]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[Внимание]\033[0m %s\n' "$*" >&2; }
die() { printf '\n\033[1;31m[Ошибка]\033[0m (%s) %s\n' "$PHASE" "$*" >&2; exit 1; }
trap 'warn "Сбой на этапе: ${PHASE}, строка ${LINENO}. Резервные копии: ${BACKUP_DIR:-ещё не найдены}."' ERR
if [[ "${1:-}" == '--help' ]]; then
  printf '%s\n' 'Продолжает установку только после сбоя Fail2ban в старом установщике.'
  printf '%s\n' 'Запуск: sudo bash resume-after-fail2ban.sh'
  exit 0
fi
(($#==0)) || die 'Этот скрипт не принимает аргументы.'
[[ $EUID -eq 0 && -t 0 ]] || die 'Запускай от root в интерактивной консоли VPS.'
# Strong preconditions: interruption happened between initial SSH/UFW and panel install.
[[ -s /etc/fail2ban/jail.d/99-3xui-sshd.local ]] || die 'Нет конфигурации Fail2ban от нашего установщика.'
[[ -f "$SSH_DROPIN" ]] || die 'Нет временной SSH-конфигурации установщика.'
grep -qx 'Port 22' "$SSH_DROPIN" || die 'Порт 22 уже закрыт в конфигурации; режим восстановления недопустим.'
grep -qx 'Port 1335' "$SSH_DROPIN" || die 'Порт 1335 не подготовлен.'
[[ -f /usr/local/sbin/3x-ui-after-import && -f /usr/local/sbin/3x-ui-change-domain && -f /usr/local/sbin/3x-ui-stack-manager && -f /usr/local/lib/3x-ui-setup/db_tool.py ]] || die 'Помощник не установлен, установка завершилась до Fail2ban.'
[[ ! -f "$SSL_STATE_FILE" && ! -f /etc/nginx/stream.conf.d/00-3x-ui-bootstrap.conf ]] || die 'Сертификат или Nginx уже настроены; продолжение запрещено.'
[[ ! -e /usr/local/x-ui/x-ui && ! -e /etc/x-ui/x-ui.db ]] || die 'Панель уже установлена; этот сценарий восстановления не подходит.'
[[ -f /etc/nginx/nginx.conf ]] || die 'Nginx не установлен.'
if ! grep -Fqx "# PROJECT_VERSION=${PROJECT_VERSION}" /usr/local/sbin/3x-ui-stack-manager; then
  warn 'Версия уже установленного помощника отличается от версии продолжения. Проверь совместимость файлов.'
fi
[[ $(ufw status 2>/dev/null | head -1) == 'Status: active' ]] || die 'UFW не активен.'
for port in 22 1335; do
  ss -H -ltn "sport = :${port}" | grep -q . || die "SSH не слушает порт ${port}."
done
EFFECTIVE_PORTS=$(/usr/sbin/sshd -T | awk '$1=="port"{print $2}' | sort -n | paste -sd, -)
[[ "$EFFECTIVE_PORTS" == '22,1335' ]] || die "Неожиданные SSH-порты: $EFFECTIVE_PORTS"
if [[ -f /etc/systemd/system/ssh.socket.d/00-3xui-bootstrap.conf ]]; then SSH_SOCKET_ACTIVE=1; fi
BACKUP_DIR=$(find /root -maxdepth 1 -type d -name '3x-ui-setup-backup-*' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)
[[ -n "$BACKUP_DIR" && -f "$BACKUP_DIR/sshd_config.bak" ]] || die 'Не найдена оригинальная резервная копия SSH.'

# Verify the rescue script and its dependencies are a single published release.
# Do this BEFORE modifying Fail2ban, installing the panel, or changing firewall.
PHASE='Проверка совместимости файлов продолжения'
SOURCE_STAGE=$(mktemp -d /tmp/3x-ui-resume-source.XXXXXXXX)
trap 'rm -rf -- "${SOURCE_STAGE:-/nonexistent}"' EXIT
for src in resume-after-fail2ban.sh landing/install.sh landing/index.html landing/404.html wireguard/setup.sh wireguard/manage.sh; do
  mkdir -p "${SOURCE_STAGE}/$(dirname "$src")"
  curl --fail --location --silent --show-error --retry 2 --connect-timeout 10 --max-time 35 \
    "${REPO_RAW_BASE}/${src}" -o "${SOURCE_STAGE}/${src}" \
    || die "Не удалось загрузить ${src} из GitHub."
  [[ -s "${SOURCE_STAGE}/${src}" ]] || die "Пустой файл ${src}."
  grep -Fq "PROJECT_VERSION=${PROJECT_VERSION}" "${SOURCE_STAGE}/${src}" \
    || die "Неполная публикация ${PROJECT_VERSION} в GitHub: ${src}."
  case "$src" in *.sh) bash -n "${SOURCE_STAGE}/${src}" || die "Ошибка Bash в ${src}." ;; esac
done
[[ -f "$0" ]] && cmp -s -- "$0" "${SOURCE_STAGE}/resume-after-fail2ban.sh" \
  || die 'Версия запускаемого resume-after-fail2ban.sh отличается от GitHub. Скачай заново.'
grep -Fqx "# PROJECT_VERSION=${PROJECT_VERSION}" /usr/local/sbin/3x-ui-stack-manager \
  || die 'Установленный помощник другого выпуска; безопасное продолжение невозможно.'

cat <<'INTRO'
Предыдущая установка остановилась на Fail2ban. Это продолжение сохранит
существующего SSH-пользователя и настройки UFW, затем установит 3x-ui.
Порт 22 останется открыт до проверки входа по ключу на 1335.
Адрес SSL и email нужно указать повторно: прежний запуск не сохранил их.
INTRO
read -r -p 'Продолжить с точки Fail2ban (YES): ' ACK
[[ "$ACK" == 'YES' ]] || die 'Отменено.'
read -r -p 'Есть собственный домен, указывающий прямо на сервер? (y/N): ' HAS_DOMAIN
case "${HAS_DOMAIN,,}" in
  y|yes|д|да)
    SSL_MODE=domain
    read -r -p 'Введи домен (например, vpn.example.org): ' SSL_DOMAIN
    SSL_DOMAIN=${SSL_DOMAIN,,}
    [[ "$SSL_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ && ${#SSL_DOMAIN} -le 253 ]] || die 'Некорректный домен.'
    for blocked in dl.google.com apple.com www.amazon.com www.samsung.com; do
      [[ "$SSL_DOMAIN" != "$blocked" ]] || die 'Нельзя использовать домен маскировки в качестве своего.'
    done
    ;;
  n|no|н|нет|'') SSL_MODE=ip ;;
  *) die 'Ответь y или N.' ;;
esac
read -r -p "Email для сертификатов Let's Encrypt: " SSL_EMAIL
[[ "$SSL_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Укажи действительный email.'
read -r -p 'Логин уже созданного SSH-пользователя: ' SSH_USER
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$SSH_USER" != root ]] || die 'Некорректный SSH-логин.'
getent passwd "$SSH_USER" >/dev/null || die 'Такого пользователя нет.'
id -nG "$SSH_USER" | tr ' ' '\n' | grep -qx sudo || die 'Пользователь не входит в группу sudo.'
HOME_DIR=$(getent passwd "$SSH_USER" | cut -d: -f6)
[[ -s "$HOME_DIR/.ssh/authorized_keys" ]] || die 'У пользователя отсутствует SSH-ключ.'

PHASE='Подготовка помощника WireGuard'
for spec in 'wireguard/setup.sh /usr/local/sbin/3x-ui-wg-setup' \
            'wireguard/manage.sh /usr/local/sbin/3x-ui-wg'; do
  read -r src dest <<< "$spec"
  cp -a "${SOURCE_STAGE}/${src}" "${dest}.tmp"
  bash -n "${dest}.tmp" || die "Ошибка синтаксиса ${src}."
  install -m 755 -o root -g root "${dest}.tmp" "$dest"
  rm -f "${dest}.tmp"
done

PHASE='Проверка публичного IP и DNS'
PUBLIC_IPV4=$(curl -4fsS --retry 2 --connect-timeout 8 --max-time 12 https://api.ipify.org | tr -d '[:space:]') || die 'Не удалось узнать публичный IP.'
python3 - "$PUBLIC_IPV4" <<'PYIP' || die 'IPv4 не является публичным.'
import ipaddress,sys
try:
    a=ipaddress.ip_address(sys.argv[1]); assert a.version==4 and a.is_global
except (ValueError,AssertionError): sys.exit(1)
PYIP
if [[ "$SSL_MODE" == domain ]]; then
  python3 - "$SSL_DOMAIN" "$PUBLIC_IPV4" <<'PYDNS' || die 'DNS домена не указывает на IP этого сервера.'
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

PHASE='Восстановление Fail2ban'
say 'Проверяю Fail2ban; при необходимости доустановлю поддержку systemd-journal.'
apt-get install -y --no-install-recommends python3-systemd
if ! fail2ban-client -t; then
  journalctl -u fail2ban -n 35 --no-pager || true
  die 'Ошибка в конфигурации Fail2ban.'
fi
systemctl enable fail2ban
if ! systemctl restart fail2ban; then
  journalctl -u fail2ban -n 35 --no-pager || true
  die 'Не удалось перезапустить Fail2ban.'
fi
FAIL2BAN_READY=0
for ((attempt=0; attempt<12; attempt++)); do
  if systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
    FAIL2BAN_READY=1; break
  fi
  if systemctl is-failed --quiet fail2ban; then break; fi
  if (( attempt < 11 )); then sleep 1; fi
done
if (( ! FAIL2BAN_READY )); then
  systemctl status fail2ban --no-pager -l || true
  journalctl -u fail2ban -n 35 --no-pager || true
  die 'Fail2ban не запущен либо sshd-jail не готов.'
fi
say 'Fail2ban работает. Продолжаю установку с места остановки.'
ufw allow 51820/udp comment 'Standalone WireGuard wg0'

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

2) В панели вручную восстанови свою SQLite-базу через Backup/Restore.
   После импорта адрес/порт панели могут измениться и доступ временно
   пропадёт: это нормально, следующий этап восстановит правильный маршрут.

3) После импорта выполни НА СЕРВЕРЕ:
   sudo 3x-ui-after-import
   Он использует уже выданный сертификат для ${SSL_HOST},
   маршрутизирует VPN через TCP 443 и обновит адреса подписок.

4) Рекомендуется проверить выпуск и продление сертификата:
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
