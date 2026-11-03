#!/usr/bin/env python3
"""Establish a real TLS OpenVPN tunnel between two isolated QEMU routers."""
import gzip
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from switch_fixture import Upstream

client_port, image = int(sys.argv[1]), Path(sys.argv[2])
server_port = client_port + 10
vpn_port = client_port + 20


def guest(port, script, check=True):
    return subprocess.run(['ssh', '-p', str(port), '-o', 'BatchMode=yes', '-o',
                           'ConnectTimeout=2', '-o', 'StrictHostKeyChecking=no', '-o',
                           'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR',
                           'root@127.0.0.1', '/bin/sh'], input='set -e\n' + script,
                          text=True, capture_output=True, check=check, timeout=240)


def install(port, destination, content):
    guest(port, 'cat > ' + shlex.quote(destination) + " <<'TEST_FILE'\n" + content + '\nTEST_FILE\n')


def openssl(*arguments):
    subprocess.run(['openssl', *map(str, arguments)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


upstream = Upstream()
vm = None
backed_up = False
try:
    with tempfile.TemporaryDirectory(prefix='passwall-vpn-test-') as temporary:
        directory = Path(temporary)
        disk = directory / 'server.img'
        with gzip.open(image, 'rb') as source, disk.open('wb') as target:
            shutil.copyfileobj(source, target)
        serial = (directory / 'serial.log').open('wb')
        vm = subprocess.Popen(['qemu-system-x86_64', '-machine', 'pc,accel=tcg', '-cpu', 'max',
                               '-smp', '2', '-m', '512', '-drive', f'file={disk},format=raw,if=ide',
                               '-netdev', f'user,id=lan,net=10.0.0.0/24,hostfwd=tcp:127.0.0.1:{server_port}-10.0.0.1:22',
                               '-device', 'e1000,netdev=lan,mac=52:54:00:01:00:10',
                               '-netdev', f'user,id=wan,net=10.78.0.0/24,dhcpstart=10.78.0.15,hostfwd=udp:127.0.0.1:{vpn_port}-10.78.0.15:1194',
                               '-device', 'e1000,netdev=wan,mac=52:54:00:01:00:20',
                               '-display', 'none', '-monitor', 'none', '-serial', 'stdio'],
                              stdout=serial, stderr=subprocess.STDOUT)
        for _ in range(90):
            if guest(server_port, 'true\n', check=False).returncode == 0:
                break
            time.sleep(1)
        guest(server_port, 'true\n')
        openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', directory / 'ca.key',
                '-out', directory / 'ca.crt', '-days', '2', '-subj', '/CN=Disposable OpenVPN Test CA')
        for role in ('server', 'client'):
            openssl('req', '-newkey', 'rsa:2048', '-nodes', '-keyout', directory / f'{role}.key',
                    '-out', directory / f'{role}.csr', '-subj', f'/CN={role}')
            extension = directory / f'{role}.ext'
            extension.write_text(f'extendedKeyUsage={role}Auth\nkeyUsage=digitalSignature,keyEncipherment\n')
            openssl('x509', '-req', '-in', directory / f'{role}.csr', '-CA', directory / 'ca.crt',
                    '-CAkey', directory / 'ca.key', '-CAcreateserial', '-days', '2',
                    '-extfile', extension, '-out', directory / f'{role}.crt')
        for name in ('ca.crt', 'server.crt', 'server.key'):
            install(server_port, '/tmp/' + name, (directory / name).read_text())
        install(server_port, '/tmp/vpn-server.conf', '''
port 1194
proto udp4
dev tun0
topology subnet
server 10.8.0.0 255.255.255.0
duplicate-cn
ca /tmp/ca.crt
cert /tmp/server.crt
key /tmp/server.key
dh none
data-ciphers AES-128-GCM
keepalive 2 10
verb 3
''')
        guest(server_port, '''
for pid in $(pgrep -f '^/bin/sh /etc/rc.common /etc/rc.d/S99passwall boot$'); do
 kill "$pid" 2>/dev/null || true
done
/etc/init.d/passwall disable
/etc/init.d/passwall stop
if [ -x /etc/init.d/passwall-guard ]; then
 /etc/init.d/passwall-guard stop
 /etc/init.d/passwall-guard disable
fi
nft insert rule inet fw4 input_wan udp dport 1194 accept
nft insert rule inet fw4 forward iifname tun0 accept
openvpn --config /tmp/vpn-server.conf --log /tmp/vpn-server.log --daemon
''')
        guest(client_port, 'cp /etc/config/passwall /tmp/vpn-test-original\n'
              'cp /etc/ssl/certs/ca-certificates.crt /tmp/vpn-test-ca\n/etc/init.d/passwall stop\n'
              'rm -rf /etc/passwall/.switch\n')
        backed_up = True
        install(client_port, '/tmp/vpn-test-ca.crt', (directory / 'ca.crt').read_text())
        profile = f'client\ndev tun\nproto udp4\nremote 10.77.0.2 {vpn_port}\nnobind\nremote-cert-tls server\ndata-ciphers AES-128-GCM\n'
        for tag, name in (('ca', 'ca.crt'), ('cert', 'client.crt'), ('key', 'client.key')):
            profile += f'<{tag}>\n' + (directory / name).read_text() + f'</{tag}>\n'
        install(client_port, '/tmp/vpn-client.ovpn', profile)
        install(client_port, '/tmp/vpn-health-ca', upstream.cert.read_text())
        guest(client_port, f'''
cat /tmp/vpn-health-ca >> /etc/ssl/certs/ca-certificates.crt
uci set passwall.real_vpn=nodes
uci set passwall.real_vpn.type=OpenVPN
uci set passwall.real_vpn.config="$(cat /tmp/vpn-client.ovpn)"
uci set passwall.@global[0].enabled=1
uci set passwall.@global[0].acl_enable=0
uci set passwall.@global[0].node=real_vpn
uci set passwall.@global[0].switch_guard=1
uci set passwall.@global[0].switch_guard_probe_url=https://10.78.0.2:{upstream.tls_port}/generate_204
uci set passwall.@global[0].openvpn_global_allow_lan=1
uci commit passwall
/etc/init.d/passwall restart
test "$(cat /tmp/passwall_switch/result)" = ready
test ! -e /tmp/passwall_switch_guard
ip -4 route show table 20000 | grep -q '^default dev pswov0 .*metric 10'
curl --silent --show-error --fail --interface pswov0 --max-time 5 --head https://10.78.0.2:{upstream.tls_port}/generate_204
''')
        print('PASS: real OpenVPN TLS handshake, tunnel-bound HTTPS health, automatic guard removal', flush=True)
        guest(client_port, '''
uci set passwall.device_vpn=nodes
uci set passwall.device_vpn.type=OpenVPN
uci set passwall.device_vpn.config="$(cat /tmp/vpn-client.ovpn)"
uci set passwall.health_acl=acl_rule
uci set passwall.health_acl.enabled=1
uci set passwall.health_acl.bind_enable=1
uci set passwall.health_acl.bind_mac=52:54:00:aa:bb:cc
uci set passwall.health_acl.bind_ip=10.0.0.250
uci set passwall.health_acl.sources=10.0.0.250
uci set passwall.health_acl.mode=1
uci set passwall.health_acl.node=device_vpn
uci set passwall.@global[0].acl_enable=1
uci commit passwall
/bin/sh -x /etc/rc.common /etc/init.d/passwall restart >/tmp/vpn-switch-trace 2>&1
test "$(cat /tmp/passwall_switch/result)" = ready
test ! -e /tmp/passwall_switch_guard
ip -4 route show table 20001 | grep -q '^default dev pswov1 .*metric 10'
uci set passwall.@global[0].enabled=0
uci commit passwall
/etc/init.d/passwall restart
test "$(cat /tmp/passwall_switch/result)" = ready
test ! -e /tmp/passwall_switch_guard
ip -4 rule show | grep -q 'oif pswov1 lookup 20001'
''')
        print('PASS: simultaneous global/device VPNs and ACL-only tunnel health', flush=True)
except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
    print("Guest failure:", getattr(error, "returncode", "timeout"), error.stdout, error.stderr, file=sys.stderr)
    print(guest(client_port, 'tail -n 160 /tmp/vpn-switch-trace 2>/dev/null || true\n', check=False).stdout, file=sys.stderr)
    print(guest(client_port, 'cat /tmp/passwall_switch/phase /tmp/passwall_switch/result /tmp/passwall_switch/request\n', check=False).stdout, file=sys.stderr)
    print(guest(client_port, 'tail -n 80 /tmp/log/passwall.log\ncat /tmp/etc/passwall/openvpn/nodes/*/log 2>/dev/null || true\n', check=False).stdout, file=sys.stderr)
    print(guest(server_port, 'cat /tmp/vpn-server.log\n', check=False).stdout, file=sys.stderr)
    raise
finally:
    if backed_up:
        guest(client_port, 'cp /tmp/vpn-test-original /etc/config/passwall\n'
              'cp /tmp/vpn-test-ca /etc/ssl/certs/ca-certificates.crt\n/etc/init.d/passwall stop\n'
              'rm -rf /etc/passwall/.switch\n/etc/init.d/passwall start\n', check=False)
    if vm:
        vm.terminate()
        vm.wait(timeout=10)
    upstream.close()
