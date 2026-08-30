#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OPENWRT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
REPO_ROOT=$(cd -- "${OPENWRT_DIR}/.." && pwd)

# shellcheck source=../versions.env
source "${OPENWRT_DIR}/versions.env"

DIST_DIR=${FIRMWARE_OUTPUT_DIR:-"${REPO_ROOT}/dist/openwrt/${OPENWRT_VERSION}"}
SSH_PORT=${QEMU_SSH_PORT:-2222}
TEST_DIR=$(mktemp -d -t passwall-plus-qemu.XXXXXX)
PID_FILE="${TEST_DIR}/qemu.pid"
SERIAL_LOG="${TEST_DIR}/serial.log"
RAW_IMAGE="${TEST_DIR}/firmware.img"

cleanup() {
	local status=$?
	trap - EXIT INT TERM
	if [ "${status}" -ne 0 ] && [ -f "${SERIAL_LOG}" ]; then
		echo '--- QEMU serial log (last 100 lines) ---' >&2
		tail -n 100 "${SERIAL_LOG}" >&2
	fi
	if [ -f "${PID_FILE}" ]; then
		kill "$(cat "${PID_FILE}")" >/dev/null 2>&1 || true
	fi
	rm -rf -- "${TEST_DIR}"
	exit "${status}"
}
trap cleanup EXIT INT TERM

for command_name in find gzip qemu-system-x86_64 seq ssh tail; do
	command -v "${command_name}" >/dev/null 2>&1 || {
		echo "error: required command not found: ${command_name}" >&2
		exit 1
	}
done

COMPRESSED_IMAGE=$(find "${DIST_DIR}" -maxdepth 1 -type f \
	-name '*-generic-ext4-combined.img.gz' -print | sort | head -n 1)
[ -n "${COMPRESSED_IMAGE}" ] || {
	echo "error: BIOS ext4 combined image not found in ${DIST_DIR}" >&2
	exit 1
}

gzip --decompress --stdout "${COMPRESSED_IMAGE}" > "${RAW_IMAGE}"
qemu-system-x86_64 \
	-machine pc,accel=tcg \
	-cpu max \
	-smp 2 \
	-m 768 \
	-drive "file=${RAW_IMAGE},format=raw,if=ide" \
	-netdev "user,id=lan,net=10.0.0.0/24,hostfwd=tcp:127.0.0.1:${SSH_PORT}-10.0.0.1:22" \
	-device e1000,netdev=lan,mac=52:54:00:00:00:10 \
	-netdev 'user,id=wan,net=10.77.0.0/24,dhcpstart=10.77.0.15' \
	-device e1000,netdev=wan,mac=52:54:00:00:00:20 \
	-display none \
	-monitor none \
	-serial "file:${SERIAL_LOG}" \
	-daemonize \
	-pidfile "${PID_FILE}"

SSH_OPTIONS=(
	-p "${SSH_PORT}"
	-o BatchMode=yes
	-o ConnectTimeout=2
	-o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR
)

for _ in $(seq 1 90); do
	if ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 true >/dev/null 2>&1; then
		break
	fi
	sleep 2
done

if ! ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 true >/dev/null 2>&1; then
	echo 'error: firmware did not become reachable over its LAN interface' >&2
	tail -n 100 "${SERIAL_LOG}" >&2
	exit 1
fi

ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 /bin/sh <<'EOF'
set -eux

test "$(uci -q get system.@system[0].hostname)" = 'PassWall-Plus'
test "$(uci -q get network.lan.device)" = 'br-lan'
test "$(uci -q get network.br_lan.ports)" = 'eth0'
test "$(uci -q get network.lan.ipaddr)" = '10.0.0.1'
test "$(uci -q get network.wan.device)" = 'eth1'
test "$(uci -q get network.wan.proto)" = 'dhcp'
test "$(uci -q get dhcp.lan.ra)" = 'disabled'
test "$(uci -q get dhcp.lan.dhcpv6)" = 'disabled'
test "$(uci -q get dhcp.lan.ndp)" = 'disabled'
test "$(uci -q get firewall.passwall_plus_reject_ipv6.target)" = 'REJECT'
test "$(uci -q get passwall.@global[0].reject_ipv6)" = '1'
test "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" = '1'
test "$(sysctl -n net.ipv6.conf.default.disable_ipv6)" = '1'
! ip -6 address show scope global | grep -q inet6

ip link show eth0 >/dev/null
ip link show eth1 >/dev/null
test -r /lib/functions/network.sh
for _ in $(seq 1 30); do
	if ubus call network.interface.wan status | grep -q '"up": true'; then
		break
	fi
	sleep 1
done
ubus call network.interface.wan status | grep -q '"up": true'

apk info -e luci-app-passwall
apk info -e openvpn-openssl
apk info -e xray-core
apk info -e sing-box
test -x /usr/sbin/openvpn
test -x /usr/bin/xray
test -x /usr/bin/sing-box
pgrep -f uhttpd >/dev/null

fw4 check
fw4 reload
if dmesg | grep -Eiq 'segfault|nft.*(fault|crash)'; then
	echo 'nftables crash signature found in dmesg' >&2
	exit 1
fi

echo 'PassWall Plus QEMU firmware checks passed'
EOF
