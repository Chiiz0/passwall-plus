#!/usr/bin/env python3
"""Exercise real DHCP and LuCI from a separate LAN client during fail-closed recovery.

The router must expose eth2 via QEMU UDP Ethernet (as test-qemu.sh does).
All changes and traffic are confined to disposable test VMs.
"""
import gzip
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from switch_fixture import Upstream

router_port, probe_port = map(int, sys.argv[1:3])
image = Path(sys.argv[3])
client_port = router_port + 30


def guest(port, script, check=True, timeout=90):
    result = subprocess.run(['ssh', '-p', str(port), '-o', 'BatchMode=yes', '-o',
                           'ConnectTimeout=2', '-o', 'StrictHostKeyChecking=no', '-o',
                           'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR',
                           'root@127.0.0.1', '/bin/sh'], input='set -e\n' + script,
                          text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise AssertionError(f'Guest {port} failed: {result.stdout}\n{result.stderr}')
    return result


def router(script, **kwargs):
    return guest(router_port, script, **kwargs)


def client(script, **kwargs):
    return guest(client_port + 1, script, **kwargs)


def wait_for(port, script, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if guest(port, script, check=False, timeout=10).returncode == 0:
                return
        except subprocess.TimeoutExpired:
            pass
        time.sleep(0.5)
    raise AssertionError('Guest condition timed out: ' + script)


def access(label, broadcast=False):
    result = client('''
ip -4 addr flush dev eth0
udhcpc %s -i eth0 -n -q -t 5 -T 2 -s /tmp/management-lease >/tmp/dhcp-check.log 2>&1
cat /tmp/management-ip
status=$(curl --noproxy '*' -sS --connect-timeout 3 --max-time 6 -o /tmp/management-page -w '%%{http_code}' http://10.0.0.1/cgi-bin/luci/)
# LuCI's login form intentionally returns 403 without a session.
test "$status" = 200 || test "$status" = 403
grep -q 'name="luci_username"' /tmp/management-page
''' % ('-B' if broadcast else ''), check=False)
    if result.returncode:
        print(client('cat /tmp/dhcp-check.log; ip -4 addr show dev eth0', check=False).stdout, flush=True)
        print(router('logread -e dnsmasq-dhcp | tail -n 15\nnft list table inet passwall_switch', check=False).stdout, flush=True)
        raise AssertionError(label + ': DHCP / management failed: ' + result.stderr)
    print('PASS: ' + label + ': DHCP lease ' + result.stdout.strip() + ', LuCI reachable', flush=True)


vm = None
backed_up = False
upstream = Upstream()
try:
    router('''
test -e /sys/class/net/br-lan/brif/eth2
cp /etc/config/passwall /tmp/management-original-passwall
cp /etc/config/dhcp /tmp/management-original-dhcp
cp /etc/ssl/certs/ca-certificates.crt /tmp/management-original-ca
/etc/init.d/passwall stop
/etc/init.d/passwall-guard stop
rm -rf /etc/passwall/.switch
# QEMU's SSH management and spare LAN NICs have built-in DHCP servers.
# Block all forwarded DHCP replies so only the router's locally generated
# replies can reach the test client and satisfy this regression.
nft add table bridge management_test
nft 'add chain bridge management_test forward { type filter hook forward priority -300; policy accept; }'
nft add rule bridge management_test forward ether type ip ip protocol udp udp sport 67 udp dport 68 drop
uci set dhcp.lan.force=1
uci commit dhcp
/etc/init.d/dnsmasq restart
''')
    backed_up = True
    with tempfile.TemporaryDirectory(prefix='passwall-management-test-') as temporary:
        directory = Path(temporary)
        disk = directory / 'client.img'
        with gzip.open(image, 'rb') as source, disk.open('wb') as target:
            shutil.copyfileobj(source, target)
        with (directory / 'serial.log').open('wb') as serial:
            vm = subprocess.Popen([
                'qemu-system-x86_64', '-machine', 'pc,accel=tcg', '-cpu', 'max', '-smp', '2', '-m', '512',
                '-drive', f'file={disk},format=raw,if=ide',
                '-netdev', f'socket,id=wan,udp=127.0.0.1:{probe_port},localaddr=127.0.0.1:{probe_port + 1}',
                '-device', 'e1000,netdev=wan,mac=52:54:00:06:00:20',
                '-netdev', f'user,id=lan,net=10.99.0.0/24,hostfwd=tcp:127.0.0.1:{client_port}-10.0.0.1:22,hostfwd=tcp:127.0.0.1:{client_port + 1}-10.99.0.1:22',
                '-device', 'e1000,netdev=lan,mac=52:54:00:06:00:10',
                '-display', 'none', '-monitor', 'none', '-serial', 'stdio'], stdin=subprocess.PIPE, stdout=serial, stderr=subprocess.STDOUT)
        # The client's factory LAN address equals the router under test. Move
        # only its separate management interface over the serial console first.
        deadline = time.monotonic() + 90
        while b'Please press Enter' not in (directory / 'serial.log').read_bytes():
            assert time.monotonic() < deadline, 'Client console did not start'
            time.sleep(0.5)
        vm.stdin.write(b'\n')
        vm.stdin.flush()
        time.sleep(1)
        vm.stdin.write(b'''
while ! ubus call network.interface.lan status >/dev/null 2>&1; do sleep 1; done
/etc/init.d/passwall disable
/etc/init.d/passwall stop
/etc/init.d/passwall-guard stop
/etc/init.d/passwall-guard disable
uci set network.wan.proto=none
uci set network.lan.ipaddr=10.99.0.1
uci commit network
/etc/init.d/network restart
''')
        vm.stdin.flush()
        wait_for(client_port + 1, 'test -e /sys/class/net/eth0')
        client('''
cat > /tmp/management-lease <<'SH'
#!/bin/sh
case "$1" in
 bound|renew)
  ip -4 addr flush dev "$interface"
  ip addr add "$ip/24" dev "$interface"
  ip route replace default via 10.0.0.1 dev "$interface"
  echo "$ip" > /tmp/management-ip
  echo "$1 $ip" >> /tmp/management-events
  ;;
esac
SH
chmod +x /tmp/management-lease
ip link set eth0 up
''')
        access('normal networking')
        endpoint = f'https://10.77.0.2:{upstream.tls_port}/generate_204'
        client(f"curl --noproxy '*' -kIfsS --connect-timeout 3 --max-time 5 {endpoint}")
        router('''
uci set passwall.@global[0].enabled=1
uci set passwall.@global[0].switch_guard=1
uci commit passwall
. /usr/share/passwall/utils.sh
. /usr/share/passwall/switch_guard.sh
switch_guard_begin
''')
        access('switch guard active')
        access('broadcast DHCP with guard active', broadcast=True)
        client('''
rm -f /tmp/management-events
nohup udhcpc -f -i eth0 -p /tmp/management-udhcpc.pid -t 3 -T 2 -s /tmp/management-lease >/tmp/management-renew.log 2>&1 </dev/null &
''')
        wait_for(client_port + 1, 'grep -q "^bound " /tmp/management-events')
        client('kill -USR1 "$(cat /tmp/management-udhcpc.pid)"')
        wait_for(client_port + 1, 'grep -q "^renew " /tmp/management-events')
        client('kill "$(cat /tmp/management-udhcpc.pid)"')
        print('PASS: existing DHCP lease renews while guard is active', flush=True)

        router(upstream.setup() + '''
uci set passwall.@global[0].node=bad_b
uci set passwall.@global[0].acl_enable=1
uci set passwall.management_device=acl_rule
uci set passwall.management_device.enabled=1
uci set passwall.management_device.bind_enable=1
uci set passwall.management_device.bind_mac=52:54:00:06:00:20
uci set passwall.management_device.bind_ip=10.0.0.250
uci set passwall.management_device.mode=0
uci commit passwall
nohup /etc/init.d/passwall restart >/tmp/management-recovery.log 2>&1 </dev/null &
''')
        wait_for(router_port, 'test -f /tmp/etc/passwall/start_complete\ntest -s /tmp/passwall_switch_guard')
        access('unreachable node, bound device during health check')
        assert client('cat /tmp/management-ip').stdout.strip() == '10.0.0.250'
        wait_for(router_port, 'test "$(cat /tmp/passwall_switch/result)" = blocked', timeout=100)
        access('node failed, sustained protected recovery')
        # Preserve the fail-closed guarantee: DHCP exceptions must never allow
        # ordinary LAN traffic to fall back to the direct upstream.
        client(f"! curl --noproxy '*' -kIfsS --connect-timeout 2 --max-time 3 {endpoint}")
        router('''
uci set passwall.@global[0].node=good_a
uci commit passwall
nohup /etc/init.d/passwall restart >/tmp/management-restored.log 2>&1 </dev/null &
''')
        wait_for(router_port, 'test "$(cat /tmp/passwall_switch/result)" = ready\ntest ! -e /tmp/passwall_switch_guard', timeout=100)
        access('verified node restored')
finally:
    try:
        if backed_up:
            router('''
/etc/init.d/passwall stop
nft delete table bridge management_test
cp /tmp/management-original-passwall /etc/config/passwall
cp /tmp/management-original-dhcp /etc/config/dhcp
cp /tmp/management-original-ca /etc/ssl/certs/ca-certificates.crt
/etc/init.d/dnsmasq restart
/etc/init.d/passwall-guard start
''', check=False)
    finally:
        if vm is not None:
            vm.terminate()
            vm.wait(timeout=15)
        upstream.close()
