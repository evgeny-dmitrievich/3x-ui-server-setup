#!/usr/bin/env bash
# PROJECT_VERSION=2.8.0
# Stage a copy of a foreign 3x-ui SQLite backup BEFORE panel restore.
# Never change /etc/x-ui/x-ui.db, active nginx, WireGuard, or SSH.
set -Eeuo pipefail
umask 077
export LANG=C.UTF-8 LC_ALL=C.UTF-8

STATE=/etc/3x-ui-setup/bootstrap.env
TOOL=/usr/local/lib/3x-ui-setup/db_tool.py
LIVE=/etc/x-ui/x-ui.db

usage() {
  cat <<'USAGE'
Применение:
  sudo 3x-ui-prepare-import /home/evgen/source.db
  sudo 3x-ui-prepare-import --disable-tuic /home/evgen/source.db

Создаёт НОВЫЙ приватный SQLite-файл рядом с исходным, не импортируя
его в панель. Второй вариант ВРЕМЕННО отключает все TUIC,
сохраняя пользователей и ключи. Используй только если обычный импорт
после исправления сертификатов по-прежнему не проходит из-за TUIC.
USAGE
}
[[ $EUID -eq 0 ]] || { echo 'Запусти через sudo.' >&2; exit 1; }
if [[ ${1:-} == -h || ${1:-} == --help ]]; then usage; exit 0; fi
DISABLE_TUIC=0
if [[ ${1:-} == --disable-tuic ]]; then DISABLE_TUIC=1; shift; fi
[[ $# == 1 ]] || { usage; exit 2; }
[[ -r "$STATE" && -f "$TOOL" ]] || { echo 'Файлы установки не найдены.' >&2; exit 1; }
python3 -m py_compile "$TOOL" || { echo 'db_tool.py содержит синтаксическую ошибку.' >&2; exit 1; }
# shellcheck disable=SC1090
source "$STATE"
[[ -f "$SSL_CERT" && -f "$SSL_KEY" ]] || { echo 'Нет выданных для этого сервера сертификата/ключа.' >&2; exit 1; }
[[ -n "$SSL_HOST" ]] || { echo 'SSL_HOST не указан.' >&2; exit 1; }
SRC=$(realpath -e -- "$1")
[[ -f "$SRC" && "$SRC" != "$LIVE" ]] || { echo 'Нужен отдельный исходный файл, не живая база.' >&2; exit 1; }
python3 "$TOOL" inspect --db "$SRC" >/dev/null || {
  echo 'В исходной базе не найдены необходимые настройки панели. Файл не менялся.' >&2; exit 1;
}
DEST="${SRC%.*}-prepared-$(date +%Y%m%d-%H%M%S).db"
[[ ! -e "$DEST" ]] || { echo 'Выходной файл уже существует.' >&2; exit 1; }
args=(prepare --db "$SRC" --out "$DEST" --domain "$SSL_HOST" --cert "$SSL_CERT" --key "$SSL_KEY")
if (( DISABLE_TUIC )); then args+=(--disable-tuic); fi
python3 "$TOOL" "${args[@]}" || { rm -f -- "$DEST"; exit 1; }
chmod 600 "$DEST"
# Make the generated file downloadable over SFTP by the user who ran sudo,
# but only when the source file is already owned by that user.
if [[ -n ${SUDO_USER:-} && ${SUDO_USER:-} != root ]]; then
  owner=$(stat -c %U -- "$SRC")
  if [[ "$owner" == "$SUDO_USER" ]]; then
    chown --reference="$SRC" "$DEST"
  fi
fi
python3 "$TOOL" inspect --db "$DEST" >/dev/null
printf '\n[3x-ui] Готов файл для импорта: %s\n' "$DEST"
printf '[3x-ui] Исходная база не изменена. Работающая панель не затронута.\n'
if (( DISABLE_TUIC )); then
  printf '[3x-ui] TUIC 8444 временно выключен; позже можно включить в панели.\n'
fi
printf '[3x-ui] Импортируй подготовленный файл в веб-панели через Backup/Restore, затем запусти sudo 3x-ui-after-import.\n'
