#!/usr/bin/env bash
# 3x-ui setup v2: preserve panel credentials, paths, and all VPN identities.
# Maintains the Nginx SNI routes and HTTPS certificates for the imported database.
set -Eeuo pipefail
umask 077
export LANG=C.UTF-8 LC_ALL=C.UTF-8

STATE=/etc/3x-ui-setup/bootstrap.env
LIVE_DB=/etc/x-ui/x-ui.db
DB_TOOL=/usr/local/lib/3x-ui-setup/db_tool.py
STREAM_BOOT=/etc/nginx/stream.conf.d/00-3x-ui-bootstrap.conf
STREAM_FINAL=/etc/nginx/stream.conf.d/3x-ui.conf
HTTP_CONF=/etc/nginx/sites-available/3x-ui.conf
HTTP_BOOT=/etc/nginx/sites-available/3x-ui-bootstrap.conf
HTTP_BOOT_LINK=/etc/nginx/sites-enabled/3x-ui-bootstrap.conf
HTTP_LINK=/etc/nginx/sites-enabled/3x-ui.conf
NGINX_MAIN=/etc/nginx/nginx.conf
ACME=/root/.acme.sh/acme.sh
BACKUP_DIR=''
CURRENT_STEP='Проверка'
OLD_HOST=''
TARGET_HOST=''
TARGET_MODE=''
TARGET_CERT=''
TARGET_KEY=''
SSL_EMAIL=''
PUBLIC_IPV4=''
BACKUP_READY=0
SERVICE_STOPPED=0
DB_REPLACED=0
NGINX_CHANGED=0
COMMITTED=0

say() { printf '\n[3x-ui] %s\n' "$*"; }
warn() { printf '\n[Внимание] %s\n' "$*" >&2; }
die() { printf '\n[Ошибка] (%s) %s\n' "$CURRENT_STEP" "$*" >&2; exit 1; }

# Snapshot ONLY the files we may touch, preserving symlinks, ownership and mode.
TARGETS=("$NGINX_MAIN" "$STREAM_BOOT" "$STREAM_FINAL" "$HTTP_CONF" "$HTTP_LINK" "$HTTP_BOOT" "$HTTP_BOOT_LINK" "$STATE")
snapshot_configs() {
  mkdir -p "$BACKUP_DIR/original"
  local path
  for path in "${TARGETS[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a --parents "$path" "$BACKUP_DIR/original/"
    fi
  done
}
restore_configs() {
  local path
  for path in "${TARGETS[@]}"; do
    rm -f -- "$path"
    if [[ -e "$BACKUP_DIR/original$path" || -L "$BACKUP_DIR/original$path" ]]; then
      mkdir -p "$(dirname "$path")"
      cp -a -- "$BACKUP_DIR/original$path" "$path"
    fi
  done
}
rollback() {
  local status=$?
  trap - EXIT
  if (( status != 0 && BACKUP_READY && ! COMMITTED )); then
    warn "Откат после ошибки на этапе '${CURRENT_STEP}'. Копии: $BACKUP_DIR"
    if (( DB_REPLACED )); then
      systemctl stop x-ui >/dev/null 2>&1 || true
      cp -a "$BACKUP_DIR/live-before.db" "$LIVE_DB" || true
      rm -f "${LIVE_DB}-wal" "${LIVE_DB}-shm"
    fi
    if (( NGINX_CHANGED )); then
      restore_configs || warn 'Не удалось вернуть некоторые файлы Nginx/состояния.'
      if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
      else
        warn 'Возвращённая конфигурация Nginx требует ручной проверки.'
      fi
    fi
    if (( SERVICE_STOPPED )); then systemctl start x-ui >/dev/null 2>&1 || warn 'x-ui не запустилась после отката'; fi
  elif (( status != 0 )); then
    warn "Остановлено на этапе '${CURRENT_STEP}'. База и Nginx не изменены."
  fi
  exit "$status"
}
trap rollback EXIT
usage() {
  cat <<'HELP'
Команды (от root):
  3x-ui-after-import                 После восстановления базы через панель.
  3x-ui-change-domain                Меню: домен, IP, сертификат, проверка.

Никакие логины/пароли, пути панели и UUID не меняются.
После смены публичного адреса старые ссылки подписок потребуется заменить.
HELP
}

if [[ ${1:-} == '--help' || ${1:-} == '-h' ]]; then usage; exit 0; fi
[[ $EUID -eq 0 ]] || die 'Нужны права root (sudo).'
[[ -r "$STATE" && -f "$DB_TOOL" && -f "$NGINX_MAIN" && -f "$LIVE_DB" ]] || die 'Нет состояния установки, панели или базы.'
[[ -x "$ACME" ]] || die 'Не установлен acme.sh (официальная установка 3x-ui должна его создать).'
command -v flock >/dev/null || die 'Нет команды flock.'
exec 9>/run/3x-ui-stack-manager.lock
flock -n 9 || die 'Другая операция настройки уже выполняется.'
# Root-owned state is written by our installer with Bash %q escaping.
# shellcheck disable=SC1090
source "$STATE"
OLD_HOST=${SSL_HOST:-}
SSL_EMAIL=${SSL_EMAIL:-}
PUBLIC_IPV4=${PUBLIC_IPV4:-}
[[ -n "$OLD_HOST" && -n "$SSL_CERT" && -n "$SSL_KEY" ]] || die 'Не заполнены сведения SSL в bootstrap.env.'

is_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
validate_host() {
  python3 - "$1" <<'PY'
import ipaddress,re,sys
name=sys.argv[1].lower()
try:
    ip=ipaddress.ip_address(name)
    ok=ip.version==4 and ip.is_global
except ValueError:
    ok=bool(len(name)<=253 and re.fullmatch(r'([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}',name))
sys.exit(0 if ok else 1)
PY
}
get_ip() {
  local current
  current=$(curl -4fsS --retry 2 --connect-timeout 5 --max-time 10 https://api.ipify.org | tr -d '[:space:]') || return 1
  is_ip "$current" && validate_host "$current" || return 1
  printf '%s\n' "$current"
}
check_dns() {
  python3 - "$1" "$2" <<'PY'
import socket,sys
try:
    records={x[4][0] for x in socket.getaddrinfo(sys.argv[1],None,family=socket.AF_INET)}
    sys.exit(0 if sys.argv[2] in records else 1)
except OSError: sys.exit(1)
PY
}
validate_cert() {
  local host=$1 cert=$2 key=$3
  [[ -s "$cert" && -s "$key" ]] || return 1
  openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1 || return 1
  if is_ip "$host"; then
    openssl x509 -in "$cert" -noout -checkip "$host" 2>/dev/null | grep -q 'does match' || return 1
  else
    openssl x509 -in "$cert" -noout -checkhost "$host" 2>/dev/null | grep -q 'does match' || return 1
  fi
  local certpub keypub
  certpub=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1) || return 1
  keypub=$(openssl pkey -in "$key" -pubout -outform DER | sha256sum | cut -d' ' -f1) || return 1
  [[ "$certpub" == "$keypub" ]]
}
# Keep certificate issuance separate from the live DB and Nginx configuration.
# acme.sh's renewal task retains the installed paths and reload command.
ensure_cert() {
  CURRENT_STEP='Проверка/выпуск TLS-сертификата'
  local host=$1 mode=$2 email=$3
  if [[ "$mode" == ip ]]; then
    TARGET_CERT=/root/cert/ip/fullchain.pem
    TARGET_KEY=/root/cert/ip/privkey.pem
  else
    TARGET_CERT="/root/cert/$host/fullchain.pem"
    TARGET_KEY="/root/cert/$host/privkey.pem"
  fi
  if validate_cert "$host" "$TARGET_CERT" "$TARGET_KEY"; then
    say "Уже имеется подходящий действительный сертификат для $host."
    return 0
  fi
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Нужен email для выпуска сертификата.'
  command -v ss >/dev/null || die 'Не найден ss.'
  # For this stack nginx listens on 443 and local 10446; 80 must be free for ACME.
  if ss -H -ltn '( sport = :80 )' | grep -q .; then die 'TCP 80 занят, автоматический выпуск сертификата остановлен.'; fi
  if [[ "$mode" == domain ]]; then
    local ip
    ip=$(get_ip) || die 'Не удалось определить публичный IPv4.'
    check_dns "$host" "$ip" || die "DNS домена $host не указывает на IP $ip."
  fi
  install -d -m 700 "$(dirname "$TARGET_CERT")"
  say "Запрашиваю сертификат Let's Encrypt для $host; порт 80 должен быть доступен из интернета."
  "$ACME" --set-default-ca --server letsencrypt >/dev/null
  "$ACME" --register-account --server letsencrypt -m "$email" >/dev/null 2>&1 || true
  local args=(--issue -d "$host" --standalone --server letsencrypt --httpport 80)
  if [[ "$mode" == ip ]]; then args+=(--certificate-profile shortlived --days 6); fi
  "$ACME" "${args[@]}" || die 'Не удалось получить сертификат. Проверь DNS/IP и внешний TCP 80.'
  # acme.sh sometimes reports failure if its reload hook fails, even when
  # the cert was written. Verify the actual output rather than only exit code.
  "$ACME" --installcert -d "$host" \
    --key-file "$TARGET_KEY" --fullchain-file "$TARGET_CERT" \
    --reloadcmd 'systemctl reload nginx && systemctl restart x-ui' || warn 'acme.sh сообщил ошибку при установке/перезагрузке — проверяю файлы сертификата.'
  validate_cert "$host" "$TARGET_CERT" "$TARGET_KEY" || die 'Полученный сертификат не соответствует адресу или ключу.'
}

# Verify real HTTP responses; allow the panel to finish starting after systemd
# reports active. acme.sh --installcert may restart x-ui immediately beforehand.
# Keep probes on loopback, bypass inherited HTTP(S)_PROXY settings and never
# print private panel/subscription URLs or credentials in diagnostics.
healthcheck() {
  CURRENT_STEP='Проверка веб-панели'
  local db=$1 host=$2 port base code status start ready=0 attempt=0
  port=$(python3 "$DB_TOOL" inspect --db "$db" | python3 -c 'import json,sys; print(json.load(sys.stdin)["web_port"])') || return 1
  base=$(python3 "$DB_TOOL" inspect --db "$db" | python3 -c 'import json,sys; print(json.load(sys.stdin)["web_path"])') || return 1

  # The web server often binds 1-3 seconds after systemctl start/restart.
  # The certificate hook above can restart it once more. Limit this wait to
  # approximately 12 seconds (individual curl calls have a 2-second cap).
  start=$SECONDS
  code='соединение не установлено'
  while :; do
    attempt=$((attempt+1))
    if status=$(curl --noproxy '*' -ksS -o /dev/null -w '%{http_code}' \
        --connect-timeout 1 --max-time 2 "https://127.0.0.1:${port}${base}" 2>/dev/null); then
      code=$status
      if [[ "$code" =~ ^(2[0-9][0-9]|3[0-9][0-9]|401|403)$ ]]; then
        ready=1
        break
      fi
    else
      code='нет HTTPS-соединения'
    fi
    (( SECONDS - start < 12 )) || break
    sleep 1
  done
  if (( ! ready )); then
    warn "Локальная панель не ответила ожидаемым HTTP-кодом на порту ${port} (последний результат: ${code}; попыток: ${attempt})."
    warn 'Проверь, совпадает ли порт в восстановленной SQLite-базе с фактическим портом процесса x-ui.'
    return 1
  fi

  # Validate the full path through the Nginx TCP/SNI router to this panel.
  # --noproxy is important if the server has HTTPS_PROXY set in its environment.
  if ! code=$(curl --noproxy '*' -ksS -o /dev/null -w '%{http_code}' \
      --connect-timeout 2 --max-time 5 --resolve "${host}:443:127.0.0.1" \
      "https://${host}${base}" 2>/dev/null); then
    warn 'Не удалось соединиться с панелью через Nginx/TCP 443.'
    return 1
  fi
  [[ "$code" =~ ^(2[0-9][0-9]|3[0-9][0-9]|401|403)$ ]] || { warn "Через Nginx панель ответила HTTP ${code}."; return 1; }

  if ! code=$(curl --noproxy '*' -ksS -o /dev/null -w '%{http_code}' \
      --connect-timeout 2 --max-time 5 --resolve "${host}:443:127.0.0.1" \
      "https://${host}/" 2>/dev/null); then
    warn 'Не удалось открыть главную страницу через Nginx.'
    return 1
  fi
  [[ "$code" == 200 ]] || { warn "Сайт-заглушка ответил HTTP ${code} вместо 200."; return 1; }

  if ! code=$(curl --noproxy '*' -ksS -o /dev/null -w '%{http_code}' \
      --connect-timeout 2 --max-time 5 --resolve "${host}:443:127.0.0.1" \
      "https://${host}/__missing_nature_page_3xui__" 2>/dev/null); then
    warn 'Не удалось проверить страницу 404 через Nginx.'
    return 1
  fi
  [[ "$code" == 404 ]] || { warn "Несуществующая страница ответила HTTP ${code} вместо 404."; return 1; }
  say 'Панель отвечает через Nginx; сайт-заглушка HTTP 200 и страница 404 проверены.'
}

apply_stack() {
  local phase=$1 new_host=$2 new_mode=$3 email=$4
  CURRENT_STEP='Проверка базы и Nginx'
  [[ -t 0 ]] || die 'Требуется интерактивный терминал.'
  validate_host "$new_host" || die 'Некорректный домен или IPv4.'
  [[ "$new_host" != apple.com && "$new_host" != www.amazon.com && "$new_host" != www.samsung.com ]] || die 'Нельзя использовать домен-маскировку как публичный адрес.'
  python3 "$DB_TOOL" inspect --db "$LIVE_DB" > /dev/null || die 'База не соответствует ожидаемой схеме.'
  [[ -s /var/www/3x-ui-landing/index.html ]] || die 'Не найдена страница-заглушка. Проверь файлы установки.' 
  [[ -s /var/www/3x-ui-landing/404.html ]] || die 'Не найдена страница 404. Проверь файлы установки.' 
  if [[ "$phase" == after-import ]]; then
    [[ ! -e "$STREAM_FINAL" && ! -e "$HTTP_CONF" ]] || die 'Настройка после импорта уже выполнялась. Для смены адреса используй 3x-ui-change-domain.'
    [[ -f "$STREAM_BOOT" && -L "$HTTP_BOOT_LINK" ]] || die 'Нет временной конфигурации Nginx; отказ от изменения других Nginx-схем.'
  else
    [[ -f "$STREAM_FINAL" && -f "$HTTP_CONF" ]] || die 'Сначала выполни sudo 3x-ui-after-import.'
  fi
  if [[ "$phase" == change && "$new_host" == "$OLD_HOST" && "$new_mode" == "${SSL_MODE:-}" ]]; then
    say 'Этот адрес уже используется. Никаких изменений не требуется.'
    return 0
  fi
  TARGET_HOST=$new_host
  TARGET_MODE=$new_mode
  # Check cert before we stop the live panel or touch its database.
  ensure_cert "$TARGET_HOST" "$TARGET_MODE" "$email"
  [[ "$TARGET_HOST" != "$OLD_HOST" ]] && say "Адрес изменится: $OLD_HOST -> $TARGET_HOST"
  if [[ "$phase" == after-import ]]; then
    warn 'Сейчас будут настроены адреса подписок, хосты и Nginx. Логин, пароль и пути панели сохранятся.'
  else
    warn 'Сейчас будут обновлены адреса в подписках/хостах, SSL и Nginx. Существующие VPN-ключи не меняются.'
  fi
  read -r -p 'Подтвердить изменения (YES): ' ack
  [[ "$ack" == YES ]] || { say 'Отменено.'; return 0; }

  BACKUP_DIR="/root/3x-ui-stack-backup-$(date +%Y%m%d-%H%M%S)-$$"
  install -d -m 700 "$BACKUP_DIR"
  snapshot_configs
  BACKUP_READY=1
  CURRENT_STEP='Согласованная копия SQLite'
  systemctl stop x-ui
  SERVICE_STOPPED=1
  python3 - "$LIVE_DB" "$BACKUP_DIR/live-before.db" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as src,sqlite3.connect(sys.argv[2]) as dst:
    src.backup(dst)
    assert dst.execute('pragma integrity_check').fetchone()[0]=='ok'
PY
  chmod 600 "$BACKUP_DIR/live-before.db"
  CURRENT_STEP='Подготовка копии базы'
  local prep_args=(prepare --db "$BACKUP_DIR/live-before.db" --out "$BACKUP_DIR/prepared.db" \
    --domain "$TARGET_HOST" --cert "$TARGET_CERT" --key "$TARGET_KEY")
  if [[ "$phase" == change ]]; then prep_args+=(--old-host "$OLD_HOST"); fi
  python3 "$DB_TOOL" "${prep_args[@]}"
  python3 "$DB_TOOL" inspect --db "$BACKUP_DIR/prepared.db" >/dev/null
  python3 "$DB_TOOL" nginx --db "$BACKUP_DIR/prepared.db" --domain "$TARGET_HOST" \
    --cert "$TARGET_CERT" --key "$TARGET_KEY" \
    --http-out "$BACKUP_DIR/http.conf" --stream-out "$BACKUP_DIR/stream.conf"
  # Defend against accidentally regressing to the original 502 failure.
  if grep -q 'proxy_ssl_verify on;' "$BACKUP_DIR/http.conf"; then die 'Отказ: конфиг Nginx содержит прежнюю ошибочную проверку локального SSL.'; fi

  CURRENT_STEP='Применение конфигурации'
  install -d -m 755 /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/stream.conf.d
  NGINX_CHANGED=1
  install -m 644 "$BACKUP_DIR/http.conf" "$HTTP_CONF"
  install -m 644 "$BACKUP_DIR/stream.conf" "$STREAM_FINAL"
  ln -sfn "$HTTP_CONF" "$HTTP_LINK"
  rm -f "$STREAM_BOOT" "$HTTP_BOOT_LINK"
  # setup.sh already includes the top-level stream.conf.d directive.
  grep -Fq 'include /etc/nginx/stream.conf.d/*.conf;' "$NGINX_MAIN" || die 'Nginx не подключает stream.conf.d.'
  nginx -t || die 'Ошибка синтаксиса Nginx.'
  install -m 600 -o root -g root "$BACKUP_DIR/prepared.db" "$LIVE_DB"
  rm -f "${LIVE_DB}-wal" "${LIVE_DB}-shm"
  DB_REPLACED=1
  systemctl start x-ui || die 'Не удалось запустить x-ui.'
  systemctl reload nginx || die 'Не удалось перечитать Nginx.'
  # Refresh acme.sh reload hook, including for certificates originally issued
  # by the official 3x-ui installer. Do not fail a working panel on hook errors.
  if ! "$ACME" --installcert -d "$TARGET_HOST" \
      --key-file "$TARGET_KEY" --fullchain-file "$TARGET_CERT" \
      --reloadcmd 'systemctl reload nginx && systemctl restart x-ui' >/dev/null 2>&1; then
    warn 'Не удалось обновить команду автопродления сертификата в acme.sh. Проверь вручную.'
  fi
  healthcheck "$LIVE_DB" "$TARGET_HOST" || die 'Панель недоступна после изменений; выполняю откат.'

  CURRENT_STEP='Сохранение SSL-состояния'
  {
    printf 'SSL_MODE=%q\n' "$TARGET_MODE"
    printf 'SSL_HOST=%q\n' "$TARGET_HOST"
    printf 'SSL_CERT=%q\n' "$TARGET_CERT"
    printf 'SSL_KEY=%q\n' "$TARGET_KEY"
    printf 'SSL_EMAIL=%q\n' "$email"
    printf 'PUBLIC_IPV4=%q\n' "$PUBLIC_IPV4"
  } > "${STATE}.new"
  chmod 600 "${STATE}.new"
  mv -f "${STATE}.new" "$STATE"
  # Everything including healthcheck is OK. No credential changes, ever.
  COMMITTED=1
  say "Готово! https://${TARGET_HOST}/ (сохранён прежний путь веб-панели)."
  say "Резервная копия базы: $BACKUP_DIR/live-before.db"
  say 'При изменении адреса обнови подписки в клиентских приложениях.'
}

cmd=${1:-}
case "$cmd" in
  after-import)
    (($#==1)) || die 'Лишние аргументы.'
    apply_stack after-import "$OLD_HOST" "${SSL_MODE:-ip}" "$SSL_EMAIL"
    ;;
  change-domain)
    (($#==1)) || die 'Лишние аргументы.'
    [[ -t 0 ]] || die 'Нужен интерактивный терминал.'
    printf '\n3x-ui — Управление адресом\nТекущий адрес: %s\n\n' "$OLD_HOST"
    cat <<'MENU'
1. Добавить или изменить домен
2. Удалить домен и вернуться на SSL по IP
3. Перевыпустить SSL-сертификат текущего адреса
4. Проверить доступность панели
0. Выход
MENU
    read -r -p 'Выбор: ' choice
    case "$choice" in
      0) exit 0 ;;
      1)
        read -r -p 'Новый домен (A-запись на этот VPS): ' target
        target=${target,,}
        if [[ -z "$SSL_EMAIL" ]]; then read -r -p 'Email для сертификата: ' SSL_EMAIL; fi
        apply_stack change "$target" domain "$SSL_EMAIL" ;;
      2)
        target=$(get_ip) || die 'Не удалось определить публичный IP.'
        if [[ -z "$SSL_EMAIL" ]]; then read -r -p 'Email для сертификата: ' SSL_EMAIL; fi
        apply_stack change "$target" ip "$SSL_EMAIL" ;;
      3)
        CURRENT_STEP='Принудительное продление сертификата'
        validate_host "$OLD_HOST" || die 'Неверный текущий адрес.'
        read -r -p 'Принудительно перевыпустить действующий сертификат? (YES): ' ack
        [[ "$ack" == YES ]] || { say 'Отменено.'; exit 0; }
        [[ -s "$SSL_CERT" && -s "$SSL_KEY" ]] || die 'Не найдены текущие сертификат и ключ.'
        BACKUP_DIR="/root/3x-ui-cert-backup-$(date +%Y%m%d-%H%M%S)-$$"
        install -d -m 700 "$BACKUP_DIR"
        cp -a "$SSL_CERT" "$BACKUP_DIR/fullchain.pem"
        cp -a "$SSL_KEY" "$BACKUP_DIR/privkey.pem"
        if ! "$ACME" --renew -d "$OLD_HOST" --force; then
          warn 'Сертификат не перевыпущен. Проверяю прежний рабочий комплект.'
        fi
        if ! validate_cert "$OLD_HOST" "$SSL_CERT" "$SSL_KEY" || ! healthcheck "$LIVE_DB" "$OLD_HOST"; then
          cp -a "$BACKUP_DIR/fullchain.pem" "$SSL_CERT"
          cp -a "$BACKUP_DIR/privkey.pem" "$SSL_KEY"
          systemctl reload nginx || true
          systemctl restart x-ui || true
          die "Сертификат или доступ к панели не прошли проверку. Восстановлена копия: $BACKUP_DIR"
        fi
        say 'Сертификат и доступность панели проверены.' ;;
      4)
        healthcheck "$LIVE_DB" "$OLD_HOST" || die 'Панель не прошла проверку.' ;;
      *) die 'Неизвестный пункт меню.' ;;
    esac
    ;;
  *) usage; die 'Неизвестная команда.' ;;
esac
