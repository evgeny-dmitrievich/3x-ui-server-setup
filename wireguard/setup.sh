#!/usr/bin/env bash
# PROJECT_VERSION=2.6.0
# Install standalone, kernel WireGuard. This is intentionally separate from 3x-ui/Xray.
set -Eeuo pipefail
umask 077
export LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive
PORT=51820
WG_DIR=/etc/wireguard
PEERS_DIR=$WG_DIR/clients
IFACE=wg0
VPN_CIDR=10.73.20.0/24

err() { printf '[WireGuard] ОШИБКА: %s\n' "$*" >&2; exit 1; }
say() { printf '[WireGuard] %s\n' "$*"; }
if [[ "${1:-}" == '--help' ]]; then
  echo 'Usage: sudo bash wireguard/setup.sh PUBLIC_IPV4 [SSH_USERNAME]'
  exit 0
fi
[[ $EUID -eq 0 && $# -ge 1 && $# -le 2 ]] || err 'Нужны root и публичный IPv4.'
SERVER_IP=$1
python3 - "$SERVER_IP" <<'PY' || err 'Неверный публичный IPv4'
import ipaddress,sys
try:
    assert ipaddress.ip_address(sys.argv[1]).is_global and ipaddress.ip_address(sys.argv[1]).version == 4
except (ValueError,AssertionError): sys.exit(1)
PY
# Fail closed: never overwrite somebody else's wg0 or its private keys.
[[ ! -e "$WG_DIR/wg0.conf" && ! -d "$PEERS_DIR" ]] || err 'WireGuard wg0 уже настроен. Повторная установка без перезаписи запрещена.'
if ip link show dev "$IFACE" >/dev/null 2>&1; then err 'Интерфейс wg0 уже существует. Отказываюсь перезаписывать его.'; fi
if ss -H -lun "sport = :${PORT}" | grep -q .; then err 'UDP 51820 уже занят.'; fi
if ip -4 route show "$VPN_CIDR" | grep -q .; then err 'Подсеть 10.73.20.0/24 уже занята в маршрутизации.'; fi
WAN_DEV=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
[[ "$WAN_DEV" =~ ^[a-zA-Z0-9_.:-]+$ ]] || err 'Не удалось определить внешний сетевой интерфейс.'

say 'Устанавливаю WireGuard, iptables и необходимые инструменты.'
apt-get install -y --no-install-recommends wireguard-tools wireguard iptables
install -d -m 700 "$WG_DIR" "$PEERS_DIR"
# Default profiles are generated with distinct, cryptographically random keys.
SERVER_PRIVATE=$(wg genkey)
SERVER_PUBLIC=$(printf '%s' "$SERVER_PRIVATE" | wg pubkey)
create_peer() {
  local title=$1 addr=$2 filename=$3 priv pub psk
  priv=$(wg genkey)
  pub=$(printf '%s' "$priv" | wg pubkey)
  psk=$(wg genpsk)
  cat >> "$WG_DIR/wg0.conf" <<PEER_SERVER

[Peer]
# ${title}
PublicKey = ${pub}
PresharedKey = ${psk}
AllowedIPs = ${addr}/32
PEER_SERVER
  cat > "$PEERS_DIR/${filename}.conf" <<PEER_CLIENT
# ${title}
[Interface]
PrivateKey = ${priv}
Address = ${addr}/32
DNS = 1.1.1.1, 9.9.9.9

[Peer]
PublicKey = ${SERVER_PUBLIC}
PresharedKey = ${psk}
Endpoint = ${SERVER_IP}:${PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
PEER_CLIENT
  chmod 600 "$PEERS_DIR/${filename}.conf"
}
cat > "$WG_DIR/wg0.conf" <<SERVER_CONF
# Standalone WireGuard for 3x-ui-server-setup. NOT managed by 3x-ui.
[Interface]
Address = 10.73.20.1/24
ListenPort = ${PORT}
PrivateKey = ${SERVER_PRIVATE}
SaveConfig = false
PostUp = iptables -t nat -C POSTROUTING -s ${VPN_CIDR} -o ${WAN_DEV} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${VPN_CIDR} -o ${WAN_DEV} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${VPN_CIDR} -o ${WAN_DEV} -j MASQUERADE 2>/dev/null || true
SERVER_CONF
chmod 600 "$WG_DIR/wg0.conf"
create_peer 'Роутер' '10.73.20.2' 'Роутер'
create_peer 'Роутер (Катя)' '10.73.20.3' 'Роутер (Катя)'
cat > /etc/sysctl.d/90-3x-ui-wireguard.conf <<'SYSCTL'
# IPv4 routing for the standalone WireGuard gateway.
net.ipv4.ip_forward = 1
SYSCTL
sysctl -w net.ipv4.ip_forward=1 >/dev/null
# Minimal firewall changes: WireGuard uses its own UDP port, not ports of AWG.
ufw allow "${PORT}/udp" comment 'WireGuard wg0'
ufw route allow in on wg0 out on "$WAN_DEV" comment 'WireGuard VPN forwarding'

say 'Запускаю wg-quick@wg0.'
if ! systemctl enable --now wg-quick@wg0; then
  systemctl status wg-quick@wg0 --no-pager -l || true
  journalctl -u wg-quick@wg0 -n 25 --no-pager || true
  err 'WireGuard не запустился. Конфигурации оставлены на диске для диагностики.'
fi
wg show wg0 >/dev/null || err 'Интерфейс wg0 не поднялся.'
[[ $(wg show wg0 peers | wc -l) -eq 2 ]] || err 'WireGuard запущен, но ожидались два peer.'
say 'Готово: UDP 51820; созданы профили «Роутер» и «Роутер (Катя)».'
say 'Для безопасного экспорта от своего SSH-пользователя: sudo 3x-ui-wg export all'
