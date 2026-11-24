#!/usr/bin/env bash
# Optional safe updater for import helpers only. No panel restart / DB modification.
set -Eeuo pipefail
umask 077
export LANG=C.UTF-8 LC_ALL=C.UTF-8
[[ $EUID -eq 0 ]] || { echo 'Требуется sudo/root.' >&2; exit 1; }
BASE='https://raw.githubusercontent.com/evgeny-dmitrievich/3x-ui-server-setup/main'
STAGE=$(mktemp -d /tmp/3x-ui-update.XXXXXXXX)
BACKUP="/root/3x-ui-import-tools-before-$(date +%Y%m%d-%H%M%S)-$$"
trap 'rm -rf -- "$STAGE"' EXIT
names=(db_tool.py stack-manager.sh prepare-import.sh)
paths=(/usr/local/lib/3x-ui-setup/db_tool.py /usr/local/sbin/3x-ui-stack-manager /usr/local/sbin/3x-ui-prepare-import)
for i in "${!names[@]}"; do
  curl --fail --location --silent --show-error --retry 2 --connect-timeout 8 --max-time 30 \
    "$BASE/${names[$i]}" -o "$STAGE/${names[$i]}"
  [[ -s "$STAGE/${names[$i]}" ]] || { echo "Пустой файл: ${names[$i]}" >&2; exit 1; }
  if [[ ${names[$i]} == *.sh ]]; then
    bash -n "$STAGE/${names[$i]}"
  else
    python3 - "$STAGE/${names[$i]}" <<'PY'
import ast,sys
ast.parse(open(sys.argv[1],encoding='utf-8').read())
PY
  fi
done
mkdir -p "$BACKUP"
for i in "${!paths[@]}"; do
  [[ -f "${paths[$i]}" ]] || { echo "Не найден установленный помощник: ${paths[$i]}" >&2; exit 1; }
  cp -a "${paths[$i]}" "$BACKUP/${names[$i]}"
done
# After checks and backup, install. Restore all helpers if an installation fails.
failed=0
for i in "${!names[@]}"; do
  if ! install -o root -g root -m 755 "$STAGE/${names[$i]}" "${paths[$i]}"; then
    failed=1
    break
  fi
done
if (( failed )); then
  for i in "${!names[@]}"; do
    cp -a "$BACKUP/${names[$i]}" "${paths[$i]}" || true
  done
  echo "Обновление не удалось; восстановлены прежние скрипты. Копии: $BACKUP" >&2
  exit 1
fi
printf '[3x-ui] Помощники импорта обновлены. Резервная копия: %s\n' "$BACKUP"
printf '[3x-ui] База, Nginx, версия панели, ключи и службы НЕ изменены.\n'
printf '[3x-ui] После восстановления базы отдельно запусти: sudo 3x-ui-after-import\n'
