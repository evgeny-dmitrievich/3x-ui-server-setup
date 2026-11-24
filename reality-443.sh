#!/usr/bin/env bash
# PROJECT_VERSION=2.5.0
# Migrate our named VPN VLESS Reality from apple.com/13133 to dl.google.com/443.
# Does not touch other inbounds, credentials, WireGuard, or the public TLS cert.
set -Eeuo pipefail
umask 077
export LANG=C.UTF-8 LC_ALL=C.UTF-8
DB=/etc/x-ui/x-ui.db
STREAM=/etc/nginx/stream.conf.d/3x-ui.conf
STATE=/etc/3x-ui-setup/bootstrap.env
LOCK=/run/3x-ui-stack-manager.lock
BACKUP=''
DIRTY=0
COMPLETE=0
XUI_STOPPED=0
log(){ printf '\n[REALITY 443] %s\n' "$*"; }
fail(){ printf '\n[Ошибка] %s\n' "$*" >&2; exit 1; }
restore(){
  local status=$?
  trap - EXIT
  if (( status && DIRTY && ! COMPLETE )); then
    printf '\n[Откат] Возвращаю SQLite и Nginx из %s\n' "$BACKUP" >&2
    systemctl stop x-ui >/dev/null 2>&1 || true
    cp -a "$BACKUP/live-before.db" "$DB" || true
    rm -f "${DB}-wal" "${DB}-shm"
    cp -a "$BACKUP/stream-before.conf" "$STREAM" || true
    if nginx -t >/dev/null 2>&1; then systemctl reload nginx >/dev/null 2>&1 || true; fi
    systemctl start x-ui >/dev/null 2>&1 || true
  elif (( status && XUI_STOPPED )); then
    systemctl start x-ui >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap restore EXIT
[[ $EUID -eq 0 ]] || fail 'Запусти через sudo.'
for tool in python3 nginx systemctl ufw flock ss; do command -v "$tool" >/dev/null || fail "Не найдена команда: $tool"; done
[[ -f "$DB" && -f "$STREAM" && -f "$STATE" ]] || fail 'Не найдена активная база, финальная маршрутизация Nginx или bootstrap.env. Сначала выполни after-import.'
exec 9>"$LOCK"
flock -n 9 || fail 'Другой помощник 3x-ui уже выполняется.'
# Root-owned state from the local installer, never from user input.
# shellcheck disable=SC1090
source "$STATE"
[[ -n ${SSL_HOST:-} ]] || fail 'В bootstrap.env отсутствует SSL_HOST.'
# Only the precise route is allowed to change; do not rewrite whole nginx files.
python3 - "$STREAM" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
p=r'(?m)^(\s*)apple\.com(\s+)127\.0\.0\.1:13133\s*;\s*$'
if len(re.findall(p,s))!=1: raise SystemExit('Ожидался ровно один маршрут apple.com -> 127.0.0.1:13133; проверь конфигурацию вручную')
if re.search(r'(?m)^\s*dl\.google\.com\s+',s):raise SystemExit('dl.google.com уже есть в Nginx; отказ во избежание дубликата')
PY
log "Будут изменены только: VLESS 'VPN', его Host и SNI-маршрут Nginx."
log "Публичный адрес подписки: $SSL_HOST; порт: 443/TCP. Внутренний порт 13133 останется только на 127.0.0.1."
read -r -p 'Подтвердить переключение (YES): ' ack
[[ "$ack" == YES ]] || { log 'Отменено.'; exit 0; }
BACKUP="/root/3x-ui-reality-443-$(date +%Y%m%d-%H%M%S)-$$"
install -d -m 700 "$BACKUP"
cp -a "$STREAM" "$BACKUP/stream-before.conf"
log "Резервная копия: $BACKUP"
systemctl stop x-ui
XUI_STOPPED=1
# Use SQLite backup API, not a raw file copy (may have WAL).
python3 - "$DB" "$BACKUP/live-before.db" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as src,sqlite3.connect(sys.argv[2]) as dst:
    src.backup(dst)
    assert dst.execute('pragma integrity_check').fetchone()[0]=='ok'
PY
chmod 600 "$BACKUP/live-before.db"
# Stage changes in a private backup copy, then atomically apply.
cp "$BACKUP/live-before.db" "$BACKUP/prepared.db"
python3 - "$BACKUP/prepared.db" "$SSL_HOST" <<'PY'
import json, secrets, sqlite3, sys, time
c=sqlite3.connect(sys.argv[1]);c.row_factory=sqlite3.Row
host=sys.argv[2]
try:
  with c:
    rs=c.execute("SELECT id,port,protocol,stream_settings FROM inbounds WHERE remark='VPN'").fetchall()
    if len(rs)!=1: raise ValueError('Ожидалось ровно одно подключение VPN')
    r=rs[0]; s=json.loads(r['stream_settings'] or '{}')
    if r['port']!=13133 or r['protocol']!='vless' or s.get('network')!='tcp' or s.get('security')!='reality':
      raise ValueError('VPN не соответствует ожидаемому VLESS TCP Reality :13133')
    if s.get('externalProxy'):raise ValueError('У VPN есть дополнительные externalProxy — ручная проверка обязательна')
    rt=s['realitySettings']
    if rt.get('serverNames')!=['apple.com'] or rt.get('target')!='apple.com:443':
      raise ValueError('Reality уже изменён или отличается от ожидаемого apple.com; отказ')
    if rt.get('settings',{}).get('serverName','') not in ('','apple.com'):
      raise ValueError('Неожиданный клиентский serverName')
    rt['target']='dl.google.com:443'
    rt['serverNames']=['dl.google.com']
    if isinstance(rt.get('settings'),dict):rt['settings']['serverName']='dl.google.com'
    c.execute('UPDATE inbounds SET stream_settings=?,listen=? WHERE id=?',
      (json.dumps(s,ensure_ascii=False,separators=(',',':')),'127.0.0.1',r['id']))
    hs=c.execute('SELECT id,address,port FROM hosts WHERE inbound_id=?',(r['id'],)).fetchall()
    if len(hs)>1:raise ValueError('У VPN несколько Hosts: автоматическое изменение запрещено')
    now=int(time.time()*1000)
    if hs:
      h=hs[0]
      if h['address'] not in (None,'',host) or h['port'] not in (0,443,13133):
        raise ValueError('Хост VPN имеет отдельный адрес или порт; ручная проверка обязательна')
      c.execute('''UPDATE hosts SET address=?,port=443,security='same',sni='dl.google.com',
        override_sni_from_address=0,keep_sni_blank=0,is_disabled=0,is_hidden=0,updated_at=? WHERE id=?''',
        (host,now,h['id']))
    else:
      c.execute('''INSERT INTO hosts (group_id,inbound_id,sort_order,remark,is_disabled,is_hidden,
      address,port,security,sni,override_sni_from_address,keep_sni_blank,created_at,updated_at)
      VALUES(?,?,0,'VLESS Reality 443',0,0,?,443,'same','dl.google.com',0,0,?,?)''',
      (secrets.token_hex(8),r['id'],host,now,now))
  assert c.execute('pragma integrity_check').fetchone()[0]=='ok'
finally:c.close()
PY
python3 - "$STREAM" "$BACKUP/stream-new.conf" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
p=r'(?m)^(\s*)apple\.com(\s+)127\.0\.0\.1:13133\s*;\s*$'
s,n=re.subn(p,lambda m:m.group(1)+'dl.google.com'+m.group(2)+'127.0.0.1:13133;',s)
assert n==1
pathlib.Path(sys.argv[2]).write_text(s)
PY
install -m 600 -o "$(stat -c %u "$DB")" -g "$(stat -c %g "$DB")" "$BACKUP/prepared.db" "$DB"
rm -f "${DB}-wal" "${DB}-shm"
DIRTY=1
install -m 644 "$BACKUP/stream-new.conf" "$STREAM"
nginx -t || fail 'Nginx не прошёл проверку — откатываю.'
systemctl start x-ui || fail '3x-ui не запустилась — откатываю.'
XUI_STOPPED=0
systemctl reload nginx || fail 'Nginx не перезагрузился — откатываю.'
# Confirm the backend port is LOCAL ONLY, and services are healthy.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  systemctl is-active --quiet x-ui && \
  ss -ltn | grep -Eq '127\.0\.0\.1:13133[[:space:]]' && break
  sleep 1
done
systemctl is-active --quiet x-ui || fail 'x-ui не активен — откатываю.'
ss -ltn | grep -Eq '127\.0\.0\.1:13133[[:space:]]' || fail 'Xray не слушает 127.0.0.1:13133 — откатываю.'
if ss -ltn | grep -Eq '(0\.0\.0\.0|\[::\]|\*):13133[[:space:]]'; then fail 'Порт 13133 всё ещё слушает публичный интерфейс — откатываю.'; fi
# Close the old external rule only after new config is active.
if ufw status | grep -Eq '(^|[[:space:]])13133/tcp'; then
  ufw --force delete allow 13133/tcp || fail 'Не удалось убрать правило UFW для 13133/tcp.'
fi
COMPLETE=1
log 'Готово. VLESS Reality: dl.google.com через TCP 443; внутренний Xray: 127.0.0.1:13133.'
log 'Правило UFW для 13133/TCP удалено; остальные маршруты, ключи и пользователи сохранены.'
log 'Проверь подключение в Shadowrocket после обновления подписки; живой VPN-трафик этот скрипт не тестирует.'
log "Резервные копии: $BACKUP"
