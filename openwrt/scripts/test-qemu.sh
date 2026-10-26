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
trap 'status=$?; if [ "$status" -ne 0 ]; then tail -n 100 /tmp/log/passwall.log 2>/dev/null || true; fi; exit "$status"' EXIT

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
apk info -e luci-app-passwall-ezcnet
test "$(uci -q get passwall_ezcnet.main.enabled)" = '0'
test "$(uci -q get passwall_ezcnet.main.server)" = 'https://passwall.ezcnet.com'
test -z "$(uci -q get passwall_ezcnet.main.key)"
test -x /etc/init.d/passwall-ezcnet
test -f /usr/share/passwall-ezcnet/agent.lua
apk info -e openvpn-openssl
apk info -e xray-core
apk info -e sing-box
test -x /usr/sbin/openvpn
test -x /usr/bin/xray
test -x /usr/bin/sing-box
pgrep -f uhttpd >/dev/null

# Finish the delayed first-boot startup before changing any test configuration.
for _ in $(seq 1 120); do
	[ -f /var/lock/passwall_ready.lock ] && break
	sleep 1
done
test -f /var/lock/passwall_ready.lock

# Compile every installed Lua source with the firmware's native Lua compiler.
# lua is installed by LuCI; standalone luac is not part of the firmware.
lua <<'LUA'
local command = "find /usr/lib/lua/luci/passwall /usr/lib/lua/luci/model/cbi/passwall /usr/lib/lua/luci/controller/passwall.lua /usr/share/passwall /usr/share/passwall-ezcnet /usr/lib/lua/luci/controller/passwall_ezcnet.lua /usr/lib/lua/luci/model/cbi/passwall_ezcnet.lua -name '*.lua'"
local files = assert(io.popen(command))
local count = 0
for path in files:lines() do
	assert(loadfile(path))
	count = count + 1
end
files:close()
assert(count > 0, "No PassWall Lua files found")
print("Native Lua syntax checks passed: " .. count .. " files")
LUA

# All synthetic profiles and settings exist only on this disposable QEMU disk.
cp /etc/config/passwall /tmp/passwall-qemu-original
uci set passwall.qemu_vpn=nodes
uci set passwall.qemu_vpn.type=OpenVPN
uci set passwall.qemu_vpn.remarks='QEMU unreachable test'
uci set passwall.qemu_vpn.username=test
uci set passwall.qemu_vpn.password=test
uci set passwall.qemu_vpn.vpn_dns=1.1.1.1
uci set passwall.qemu_vpn.config="$(printf 'client\ndev tun\nproto udp\nremote 192.0.2.1 1194\nnobind\nca /etc/ssl/certs/ca-certificates.crt\nremote-cert-tls server\nauth-nocache\n')"
uci set passwall.qemu_device=acl_rule
uci set passwall.qemu_device.enabled=0
uci set passwall.qemu_device.remarks='QEMU device'
uci set passwall.qemu_device.bind_enable=1
uci set passwall.qemu_device.bind_mac=52:54:00:aa:bb:cc
uci set passwall.qemu_device.bind_ip=10.0.0.250
uci set passwall.qemu_device.bind_hostname=qemu-device
uci set passwall.qemu_device.mode=1
uci set passwall.qemu_device.node=qemu_vpn
uci set passwall.qemu_device.openvpn_allow_lan=1
uci set passwall.@global[0].node=qemu_vpn
uci set passwall.@global[0].enabled=1
uci set passwall.@global[0].acl_enable=0
uci set passwall.@global[0].client_proxy=1
uci set passwall.@global[0].localhost_proxy=1
uci set passwall.@global[0].openvpn_global_allow_lan=1
uci set passwall.@global[0].log_node=1
uci set passwall.@global_delay[0].start_delay=0
uci set passwall.@global_delay[0].start_daemon=1
uci commit passwall

# Render real authenticated LuCI pages, including their Lua models/templates.
# Set the same session token field as LuCI's login handler, without logging it.
set +x
session=$(ubus call session login '{"username":"root","password":""}' | jsonfilter -e '@.ubus_rpc_session')
test -n "$session"
ubus call session set "{\"ubus_rpc_session\":\"$session\",\"values\":{\"token\":\"qemu-test-only\"}}" >/dev/null
for page in settings node_config/qemu_vpn acl_config/qemu_device; do
	case "$page" in
		settings) control=openvpn_global_allow_lan ;;
		node_config/*) control=openvpn_config ;;
		acl_config/*) control=bind_enable ;;
	esac
	status=$(curl --max-time 45 --silent --show-error --location \
		--output /tmp/passwall-qemu-form.html --write-out '%{http_code}' \
		--cookie "sysauth_http=$session" \
		"http://127.0.0.1/cgi-bin/luci/admin/services/passwall/$page")
	test "$status" = 200
	grep -q "$control" /tmp/passwall-qemu-form.html
	printf 'LuCI form passed: %s\n' "$page"
done
status=$(curl --max-time 45 --silent --show-error --location \
	--output /tmp/passwall-ezcnet-qemu-form.html --write-out '%{http_code}' \
	--cookie "sysauth_http=$session" \
	'http://127.0.0.1/cgi-bin/luci/admin/services/passwall_ezcnet')
test "$status" = 200
grep -q 'cbid.passwall_ezcnet.main.key' /tmp/passwall-ezcnet-qemu-form.html
printf 'LuCI form passed: passwall-EzCNet\n'
ubus call session destroy "{\"ubus_rpc_session\":\"$session\"}" >/dev/null
unset session
set -x

# A global tunnel must stay supervised when ordinary proxy ACLs are disabled.
/etc/init.d/passwall restart
. /usr/share/passwall/utils.sh
test "$(get_cache_var GLOBAL_OPENVPN)" = 1
test "$(get_cache_var ENABLED_DEFAULT_ACL)" = 0
test "$(get_cache_var ENABLED_ACLS)" = 0
sleep 2
pgrep -f '^/bin/sh /usr/share/passwall/monitor.sh$' >/dev/null
pgrep -f '^/tmp/etc/passwall/bin/openvpn_qemu_vpn ' >/dev/null
ip -4 route show table 20000 | grep -q '^unreachable default.*metric 42760'
nft list chain inet passwall PSW_OPENVPN_FWD | grep -q 'reject.*PSW_OPENVPN_GLOBAL_KILLSWITCH_default'
nft list chain inet passwall PSW_OPENVPN_OUTPUT | grep -q 'reject.*PSW_OPENVPN_GLOBAL_OUTPUT_KILLSWITCH'
if ip -4 route get 198.51.100.1 from 10.0.0.250 iif br-lan >/tmp/passwall-qemu-route 2>&1; then
	echo 'error: disconnected global OpenVPN permitted a WAN route' >&2
	cat /tmp/passwall-qemu-route >&2
	exit 1
fi

# A bound direct device must get a permanent lease and both anti-spoof guards.
uci set passwall.@global[0].enabled=0
uci set passwall.@global[0].acl_enable=1
uci set passwall.qemu_device.enabled=1
uci set passwall.qemu_device.mode=0
uci commit passwall
/etc/init.d/passwall restart
test "$(uci -q get dhcp.passwall_qemu_device.passwall_managed)" = 1
test "$(uci -q get dhcp.passwall_qemu_device.passwall_acl)" = qemu_device
test "$(uci -q get dhcp.passwall_qemu_device.mac)" = 52:54:00:AA:BB:CC
test "$(uci -q get dhcp.passwall_qemu_device.ip)" = 10.0.0.250
test "$(uci -q get dhcp.passwall_qemu_device.leasetime)" = infinite
nft list chain inet passwall PSW_DEVICE_GUARD > /tmp/passwall-qemu-guard
grep -q 'ether saddr 52:54:00:aa:bb:cc ip saddr != 10.0.0.250.*drop' /tmp/passwall-qemu-guard
grep -q 'ip saddr 10.0.0.250 ether saddr != 52:54:00:aa:bb:cc.*drop' /tmp/passwall-qemu-guard

# Removing the device must also remove its managed lease and firewall guards.
cp /tmp/passwall-qemu-original /etc/config/passwall
/etc/init.d/passwall restart
if uci -q get dhcp.passwall_qemu_device >/dev/null; then
	echo 'error: stale managed DHCP lease after deleting the device' >&2
	exit 1
fi
if nft list chain inet passwall PSW_DEVICE_GUARD | grep -q qemu_device; then
	echo 'error: stale device firewall rules after deleting the device' >&2
	exit 1
fi
ip -4 route get 198.51.100.1 from 10.0.0.250 iif br-lan >/dev/null

echo 'PassWall Plus LuCI, OpenVPN fail-closed, and device binding checks passed'

fw4 check
fw4 reload
if dmesg | grep -Eiq 'segfault|nft.*(fault|crash)'; then
	echo 'nftables crash signature found in dmesg' >&2
	exit 1
fi

echo 'PassWall Plus QEMU firmware checks passed'
EOF

# Reference migration tests use an isolated UCI directory in the disposable VM.
ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 lua < "${OPENWRT_DIR}/tests/test-ezcnet-catalog.lua"
