#!/usr/bin/env bash
# PROJECT_VERSION=2.6.0
# CLI for root-only WireGuard profiles, exporting via authenticated SSH account.
set -Eeuo pipefail
umask 077
export LANG=C.UTF-8 LC_ALL=C.UTF-8
DIR=/etc/wireguard/clients
SERVER=/etc/wireguard/wg0.conf
PORT=51820
VPN_PREFIX='10.73.20'
err() { printf '[WireGuard] ОШИБКА: %s\n' "$*" >&2; exit 1; }
help_text() {
  cat <<'HELP'
WireGuard — профили без веб-панели (UDP 51820)

  sudo 3x-ui-wg list                Показать профили
  sudo 3x-ui-wg status              Проверить сервер и peer
  sudo 3x-ui-wg export all          Экспортировать оба/все профили в ~/wireguard-profiles
  sudo 3x-ui-wg export 'Роутер'     Экспорт одного профиля
  sudo 3x-ui-wg add 'Название'      Создать дополнительный профиль

Файлы выдаются только через sudo и SSH (1335), НЕ через публичный веб-сайт.
Из пользовательского терминала можно скачать их командой scp -P 1335.
HELP
}
mode=${1:-help}
if [[ "$mode" == help || "$mode" == -h || "$mode" == --help ]]; then help_text; exit 0; fi
[[ $EUID -eq 0 ]] || err 'Запускай с sudo.'
[[ -f "$SERVER" && -d "$DIR" ]] || err 'WireGuard ещё не установлен.' 
case "$mode" in
  help|-h|--help) help_text ;;
  list)
    find "$DIR" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' | sort ;;
  status)
    systemctl --no-pager --full status wg-quick@wg0 || true
    wg show wg0 2>/dev/null || err 'Не удалось получить статус интерфейса wg0.' ;;
  export)
    [[ $# == 2 ]] || err 'Используй export all или export "Название".'
    user=${SUDO_USER:-}
    [[ -n "$user" && "$user" != root ]] || err 'Выполни команду как sudo из своей SSH-сессии, а не напрямую от root.'
    home=$(getent passwd "$user" | cut -d: -f6)
    [[ -n "$home" && -d "$home" ]] || err 'Не найден домашний каталог пользователя.'
    group=$(id -gn "$user")
    out="$home/wireguard-profiles"
    install -d -m 700 -o "$user" -g "$group" "$out"
    target=$2
    count=0
    for src in "$DIR"/*.conf; do
      [[ -f "$src" ]] || continue
      name=${src##*/}; name=${name%.conf}
      if [[ "$target" != all && "$target" != "$name" ]]; then continue; fi
      install -m 600 -o "$user" -g "$group" "$src" "$out/${name}.conf"
      printf 'Готово: %s\n' "$out/${name}.conf"
      (( count+=1 ))
    done
    (( count > 0 )) || err 'Профиль с таким названием не найден.'
    printf 'Скачай по SSH/SFTP на порт 1335; не размещай приватные .conf на сайте.\n' ;;
  add)
    [[ $# == 2 ]] || err 'Нужно указать название профиля.'
    name=$2
    [[ ${#name} -le 60 && "$name" =~ ^[[:alnum:]А-Яа-яЁё_\ \(\)\.-]+$ ]] || err 'Недопустимое имя (разрешены буквы, цифры, пробелы, скобки, _ и -).'
    [[ ! -e "$DIR/${name}.conf" ]] || err 'Профиль с таким названием уже существует.'
    command -v wg >/dev/null || err 'wireguard-tools не установлен.'
    # Allocate a unique IPv4 from .4 through .254, without changing existing peers.
    next=''
    for n in $(seq 4 254); do
      if ! grep -Fq "AllowedIPs = ${VPN_PREFIX}.${n}/32" "$SERVER"; then next=$n; break; fi
    done
    [[ -n "$next" ]] || err 'Нет свободных IPv4 в VPN-подсети.'
    endpoint=$(sed -nE 's/^Endpoint = ([^:]+):51820$/\1/p' "$DIR"/*.conf | head -1)
    [[ -n "$endpoint" ]] || err 'Не найден существующий Endpoint.'
    server_private=$(sed -n 's/^PrivateKey = //p' "$SERVER" | head -1)
    server_pub=$(printf '%s' "$server_private" | wg pubkey)
    priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey); psk=$(wg genpsk)
    backup=$(mktemp /etc/wireguard/wg0.conf.backup.XXXXXXXX)
    cp -a "$SERVER" "$backup"
    cat >> "$SERVER" <<EOP

[Peer]
# ${name}
PublicKey = ${pub}
PresharedKey = ${psk}
AllowedIPs = ${VPN_PREFIX}.${next}/32
EOP
    cat > "$DIR/${name}.conf" <<EOP
# ${name}
[Interface]
PrivateKey = ${priv}
Address = ${VPN_PREFIX}.${next}/32
DNS = 1.1.1.1, 9.9.9.9

[Peer]
PublicKey = ${server_pub}
PresharedKey = ${psk}
Endpoint = ${endpoint}:${PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOP
    chmod 600 "$SERVER" "$DIR/${name}.conf"
    if ! wg syncconf wg0 <(wg-quick strip wg0); then
      cp -a "$backup" "$SERVER"
      rm -f "$DIR/${name}.conf" "$backup"
      err 'Не удалось добавить peer без остановки WireGuard; конфигурация возвращена.'
    fi
    rm -f "$backup"
    echo "Создан профиль ${name} (${VPN_PREFIX}.${next}); для скачивания: sudo 3x-ui-wg export '${name}'" ;;
  *) help_text; err 'Неизвестная команда.' ;;
esac
