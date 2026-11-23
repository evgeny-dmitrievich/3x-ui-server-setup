#!/usr/bin/env bash
# Run only AFTER importing the private SQLite backup through 3x-ui's web UI.
# Applies domain/certificate/host adjustments to a BACKED-UP copy, then activates Nginx.
set -Eeuo pipefail
umask 077

PHASE='Проверки'
BACKUP_DIR=''
DATABASE_STOPPED=0
DATABASE_REPLACED=0
NGINX_CHANGED=0
NGINX_WAS_ACTIVE=0
SSL_STATE_FILE=/etc/3x-ui-setup/bootstrap.env
BOOTSTRAP_STREAM=/etc/nginx/stream.conf.d/00-3x-ui-bootstrap.conf
DOMAIN=''
EMAIL=''
CERT=''
KEY=''
DB_TOOL=/usr/local/lib/3x-ui-setup/db_tool.py
LIVE_DB=/etc/x-ui/x-ui.db

say() { printf '\n\033[1;36m[После импорта]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[Внимание]\033[0m %s\n' "$*" >&2; }
die() { printf '\n\033[1;31m[Ошибка]\033[0m (%s) %s\n' "$PHASE" "$*" >&2; exit 1; }
rollback() {
  local rc="$?"
  if (( rc != 0 )); then
    warn "Ошибка на этапе '${PHASE}'. Резервные копии: ${BACKUP_DIR:-не созданы}."
    if (( DATABASE_REPLACED )) && [[ -f "$BACKUP_DIR/live-before-finalize.db" ]]; then
      warn 'Восстанавливаю исходную SQLite-базу.'
      systemctl stop x-ui >/dev/null 2>&1 || true
      cp -a "$BACKUP_DIR/live-before-finalize.db" "$LIVE_DB"
      rm -f "${LIVE_DB}-wal" "${LIVE_DB}-shm"
    fi
    if (( NGINX_CHANGED )); then
      warn 'Убираю только конфигурации, созданные этим помощником.'
      rm -f /etc/nginx/sites-enabled/3x-ui.conf /etc/nginx/sites-available/3x-ui.conf /etc/nginx/stream.conf.d/3x-ui.conf
      if [[ -f "$BACKUP_DIR/00-3x-ui-bootstrap.conf.before" ]]; then
        cp -a "$BACKUP_DIR/00-3x-ui-bootstrap.conf.before" "$BOOTSTRAP_STREAM"
      fi
      if [[ -s "$BACKUP_DIR/nginx.conf.before" ]]; then cp -a "$BACKUP_DIR/nginx.conf.before" /etc/nginx/nginx.conf; fi
      if (( NGINX_WAS_ACTIVE )); then
        nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1 || warn 'Nginx не удалось автоматически восстановить: проверь конфигурацию.'
      else
        systemctl stop nginx >/dev/null 2>&1 || true
      fi
    fi
    if (( DATABASE_STOPPED )); then systemctl start x-ui >/dev/null 2>&1 || true; fi
  fi
}
trap rollback EXIT

usage() {
  cat <<'HELP'
После восстановления SQLite-базы через веб-интерфейс 3x-ui выполни:
  sudo 3x-ui-after-import

Адрес и сертификат считываются из настроек ПЕРВОГО этапа установки.
Если вначале не было домена, будут использованы публичный IPv4 и его
короткоживущий сертификат Let's Encrypt (с автоматическим продлением).

Совместимость с установщиками старого образца (без bootstrap.env):
  sudo 3x-ui-after-import --domain vpn.example.org --email you@example.org
  sudo 3x-ui-after-import --domain vpn.example.org --cert /path/fullchain.pem --key /path/privkey.pem
HELP
}
while (($#)); do
  case "$1" in
    --domain) [[ $# -ge 2 ]] || die 'Нет значения --domain'; DOMAIN="$2"; shift 2 ;;
    --email) [[ $# -ge 2 ]] || die 'Нет значения --email'; EMAIL="$2"; shift 2 ;;
    --cert) [[ $# -ge 2 ]] || die 'Нет значения --cert'; CERT="$2"; shift 2 ;;
    --key) [[ $# -ge 2 ]] || die 'Нет значения --key'; KEY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Неизвестный аргумент: $1" ;;
  esac
done
[[ $EUID -eq 0 ]] || die 'Нужно запустить через sudo.'
[[ -t 0 ]] || die 'Нужна интерактивная консоль.'
if [[ -r "$SSL_STATE_FILE" ]]; then
  # This root-only file was written by our own installer, values escaped with %q.
  # shellcheck source=/dev/null
  source "$SSL_STATE_FILE"
  if [[ -n "$DOMAIN" && "$DOMAIN" != "$SSL_HOST" ]]; then
    die 'Адрес задан при установке. Для смены домена сначала вручную перевыпусти SSL; повторный выпуск здесь запрещён.'
  fi
  DOMAIN="$SSL_HOST"
  [[ -z "$CERT" ]] && CERT="$SSL_CERT"
  [[ -z "$KEY" ]] && KEY="$SSL_KEY"
fi
DOMAIN=${DOMAIN,,}
python3 - "$DOMAIN" <<'PYADDRESS' || die 'Укажи корректный публичный IP или свой DNS-домен.'
import sys,ipaddress,re
s=sys.argv[1]
try:
    ip=ipaddress.ip_address(s)
    sys.exit(0 if ip.version==4 and ip.is_global else 1)
except ValueError:
    pass
sys.exit(0 if len(s)<=253 and re.fullmatch(r'([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}',s) else 1)
PYADDRESS
for blocked in apple.com www.amazon.com www.samsung.com; do
  [[ "$DOMAIN" != "$blocked" ]] || die 'Не используем чужой домен-маскировку как свой.'
done
if [[ -n "$CERT" || -n "$KEY" ]]; then
  [[ -r "$CERT" && -r "$KEY" ]] || die 'Нужны действующие файлы --cert и --key одновременно.'
else
  [[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Для выпуска сертификата требуется --email.'
  if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die 'Автоматический выпуск IP сертификата требует первый этап новой версии установщика.'
  fi
fi
[[ -x /usr/local/x-ui/x-ui && -f "$LIVE_DB" && -f "$DB_TOOL" ]] || die 'Панель/база/инструмент отсутствуют; сначала нужно установить панель и импортировать базу.'
[[ ! -e /etc/nginx/sites-enabled/3x-ui.conf && ! -e /etc/nginx/stream.conf.d/3x-ui.conf ]] || die 'Nginx уже настроен этим скриптом. Повторный запуск без ручной проверки запрещён.'
[[ -f /etc/nginx/nginx.conf ]] || die 'Nginx не установлен.'
PHASE='Проверка импортированной базы'
python3 "$DB_TOOL" inspect --db "$LIVE_DB" >/dev/null || die 'Схема/настройки базы не соответствуют проекту; изменений не внесено.'
if systemctl is-active --quiet nginx; then NGINX_WAS_ACTIVE=1; fi
cat <<WARNING
Сейчас серверная база будет сохранена в резервную копию.
Будут изменены только адреса/пути сертификатов, адреса хостов,
учётные данные ВЕБ-ПАНЕЛИ (VPN-клиенты остаются без изменений),
а Nginx начнёт обслуживать TCP 443.

Действующие подключения кратковременно перезапустятся. Не запускай это
на продакшен-сервере без резервной копии и веб-консоли провайдера.
WARNING
read -r -p 'Подтвердить настройку после импорта (YES): ' ACK
[[ "$ACK" == YES ]] || die 'Отменено.'

BACKUP_DIR="/root/3x-ui-after-import-$(date +%Y%m%d-%H%M%S)"
install -d -m 700 "$BACKUP_DIR"
cp -a /etc/nginx/nginx.conf "$BACKUP_DIR/nginx.conf.before"

PHASE='Сертификат'
say 'Проверяю HTTPS-сертификат.'
if [[ -z "$CERT" ]]; then
  systemctl stop nginx >/dev/null 2>&1 || true
  certbot certonly --standalone --non-interactive --agree-tos --preferred-challenges http \
    --email "$EMAIL" -d "$DOMAIN"
  CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
fi
openssl x509 -in "$CERT" -noout -checkend 86400 >/dev/null || die 'Нет действующего сертификата.'
[[ -s "$KEY" ]] || die 'Отсутствует ключ сертификата.'
if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  openssl x509 -in "$CERT" -noout -checkip "$DOMAIN" | grep -qi 'does match' || die 'Сертификат не соответствует IP.'
else
  openssl x509 -in "$CERT" -noout -checkhost "$DOMAIN" | grep -qi 'does match' || die 'Сертификат не соответствует домену.'
fi
PUB_CERT=$(openssl x509 -in "$CERT" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')
PUB_KEY=$(openssl pkey -in "$KEY" -pubout -outform DER | sha256sum | awk '{print $1}')
[[ "$PUB_CERT" == "$PUB_KEY" ]] || die 'Приватный ключ не соответствует сертификату.'

PHASE='Создание снимка импортированной базы'
say 'Останавливаю панель, создаю согласованную копию базы.'
systemctl stop x-ui
DATABASE_STOPPED=1
python3 - "$LIVE_DB" "$BACKUP_DIR/live-before-finalize.db" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as src,sqlite3.connect(sys.argv[2]) as dst:
    src.backup(dst)
    assert dst.execute('pragma integrity_check').fetchone()[0]=='ok'
PY
chmod 600 "$BACKUP_DIR/live-before-finalize.db"

PHASE='Подготовка новой базы и конфигурации Nginx'
python3 "$DB_TOOL" prepare --db "$BACKUP_DIR/live-before-finalize.db" --out "$BACKUP_DIR/prepared.db" --domain "$DOMAIN" --cert "$CERT" --key "$KEY"
python3 "$DB_TOOL" inspect --db "$BACKUP_DIR/prepared.db" >/dev/null
python3 "$DB_TOOL" nginx --db "$BACKUP_DIR/prepared.db" --domain "$DOMAIN" --cert "$CERT" --key "$KEY" \
  --http-out "$BACKUP_DIR/3x-ui-http.conf" --stream-out "$BACKUP_DIR/3x-ui-stream.conf"

PHASE='Применение Nginx и базы'
mkdir -p /etc/nginx/stream.conf.d
install -m 644 "$BACKUP_DIR/3x-ui-http.conf" /etc/nginx/sites-available/3x-ui.conf
install -m 644 "$BACKUP_DIR/3x-ui-stream.conf" /etc/nginx/stream.conf.d/3x-ui.conf
ln -s /etc/nginx/sites-available/3x-ui.conf /etc/nginx/sites-enabled/3x-ui.conf
NGINX_CHANGED=1
# Remove the bootstrap 443 listener before enabling the final SNI router.
if [[ -f "$BOOTSTRAP_STREAM" ]]; then
  cp -a "$BOOTSTRAP_STREAM" "$BACKUP_DIR/00-3x-ui-bootstrap.conf.before"
  rm -f "$BOOTSTRAP_STREAM"
fi
python3 - <<'PY'
from pathlib import Path
import re
p=Path('/etc/nginx/nginx.conf')
s=p.read_text()
t='include /etc/nginx/stream.conf.d/*.conf;'
if t not in s:
    m=re.search(r'(?m)^http\s*\{',s)
    if m is None: raise SystemExit('Ошибка nginx.conf: не найден блок http {}')
    s=s[:m.start()]+t+'\n\n'+s[m.start():]
    p.write_text(s)
PY
nginx -t || die 'Конфигурация Nginx не прошла проверку; будет выполнен откат.'
install -m 600 -o root -g root "$BACKUP_DIR/prepared.db" "$LIVE_DB"
rm -f "${LIVE_DB}-wal" "${LIVE_DB}-shm"
DATABASE_REPLACED=1
PANEL_USER="panel_$(openssl rand -hex 5)"
PANEL_PASS=$(openssl rand -hex 24)
/usr/local/x-ui/x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" >/dev/null || die 'Не удалось сменить учётные данные веб-панели.'
WEB_PATH=$(python3 "$DB_TOOL" inspect --db "$LIVE_DB" | python3 -c 'import json,sys;print(json.load(sys.stdin)["web_path"])')
cat > "$BACKUP_DIR/panel-access.txt" <<CREDS
Panel URL: https://${DOMAIN}${WEB_PATH}
username: ${PANEL_USER}
password: ${PANEL_PASS}
CREDS
chmod 600 "$BACKUP_DIR/panel-access.txt"
unset PANEL_PASS
systemctl enable --now nginx
# Nginx was already running the temporary bootstrap config on port 443;
# enable --now alone does NOT load the replacement SNI routes.
systemctl reload nginx || die 'Nginx не смог применить новые SNI-маршруты; будет выполнен откат.'
systemctl restart x-ui
systemctl is-active --quiet x-ui || die 'Служба x-ui не запустилась; откатываю изменения.'
ss -H -ltn 'sport = :443' | grep -q . || die 'Nginx не слушает TCP 443.'

if [[ "$CERT" == /etc/letsencrypt/live/* ]]; then
  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/90-3x-ui-reload.sh <<'RENEW'
#!/usr/bin/env bash
set -e
nginx -t
systemctl reload nginx
systemctl restart x-ui
RENEW
  chmod 700 /etc/letsencrypt/renewal-hooks/deploy/90-3x-ui-reload.sh
fi

# acme.sh is used by the official 3x-ui installer for BOTH domains and IPs.
# Its renewal hook must reload nginx because nginx now terminates HTTPS for
# the web routes, whereas initially only the panel was handling TLS.
if [[ -r "$SSL_STATE_FILE" && -x /root/.acme.sh/acme.sh ]]; then
  PHASE='Автоматическое продление SSL'
  /root/.acme.sh/acme.sh --installcert -d "$DOMAIN" \
    --key-file "$KEY" --fullchain-file "$CERT" \
    --reloadcmd 'systemctl reload nginx && systemctl restart x-ui' >/dev/null || \
    die 'Не удалось настроить обновление сертификата для Nginx.'
fi

DATABASE_STOPPED=0
DATABASE_REPLACED=0
NGINX_CHANGED=0
PHASE='Готово'
say 'Готово: маршруты Nginx и сертификаты настроены под импортированную базу.'
cat <<END

Параметры входа в веб-панель (доступны только root):
  sudo cat ${BACKUP_DIR}/panel-access.txt

Путь панели, пути подписок и протокольные параметры берутся из твоей базы.
База до изменений сохранена: ${BACKUP_DIR}/live-before-finalize.db

Проверки:
  sudo systemctl status x-ui nginx fail2ban --no-pager
  sudo ufw status
  sudo journalctl -u x-ui -n 70 --no-pager

Проверь фактическое подключение всех протоколов отдельно.
END
