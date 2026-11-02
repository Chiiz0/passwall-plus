#!/usr/bin/env python3
"""Real packet tests against the disposable QEMU router, without host root.

The third NIC uses QEMU's UDP Ethernet transport. We inject LAN frames and
inspect the WAN capture; no test traffic is sent outside the emulated network.
"""
import socket
import select
import struct
import subprocess
import sys
import threading
import time

ssh_port, probe_port = map(int, sys.argv[1:])
ssh = ["ssh", "-p", str(ssh_port), "-o", "BatchMode=yes", "-o",
       "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
       "-o", "LogLevel=ERROR", "root@127.0.0.1"]


def guest(script, check=True):
    return subprocess.run(ssh + ["/bin/sh"], input="set -eu\n" + script,
                          text=True, capture_output=True, check=check, timeout=180)


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    value = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while value >> 16:
        value = (value & 0xffff) + (value >> 16)
    return (~value) & 0xffff


sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", probe_port + 1))
echo_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
echo_socket.bind(("127.0.0.1", 0))
echo_port = echo_socket.getsockname()[1]
source = socket.inet_aton("10.0.0.250")
dest = socket.inet_aton("10.77.0.2")
client_mac = bytes.fromhex("525400000030")
finished = threading.Event()


def respond():
    while not finished.is_set():
        for endpoint in select.select([sock, echo_socket], [], [], 0.1)[0]:
            data, peer = endpoint.recvfrom(65536)
            if endpoint is echo_socket:
                endpoint.sendto(data, peer)
            elif len(data) >= 42 and data[12:14] == b"\x08\x06" and data[20:22] == b"\0\1" and data[38:42] == source:
                # ARP reply enables return traffic, establishing an offloaded UDP flow.
                sender_mac, sender_ip = data[22:28], data[28:32]
                arp = struct.pack("!HHBBH", 1, 0x800, 6, 4, 2)
                packet = sender_mac + client_mac + b"\x08\x06" + arp + client_mac + source + sender_mac + sender_ip
                sock.sendto(packet, ("127.0.0.1", probe_port))


responder = threading.Thread(target=respond, daemon=True)
responder.start()


def frame(protocol, port):
    if protocol == 17:
        payload = struct.pack("!HHHH", 19991, port, 20, 0) + b"guard-probe!"
    elif protocol == 6:
        payload = struct.pack("!HHIIBBHHH", 19992, port, 1, 0, 80, 2, 4096, 0, 0)
        pseudo = source + dest + struct.pack("!BBH", 0, 6, len(payload))
        payload = payload[:16] + struct.pack("!H", checksum(pseudo + payload)) + payload[18:]
    else:
        payload = struct.pack("!BBHHH", 8, 0, 0, 1, 1) + b"guard-probe!"
        payload = payload[:2] + struct.pack("!H", checksum(payload)) + payload[4:]
    ip = struct.pack("!BBHHHBBH4s4s", 69, 0, 20 + len(payload), 123, 0,
                     64, protocol, 0, source, dest)
    ip = ip[:10] + struct.pack("!H", checksum(ip)) + ip[12:]
    return router_mac + client_mac + b"\x08\x00" + ip + payload


def probe(blocked):
    guest(f"tcpdump -U -ni eth1 -w /tmp/guard-probe.pcap 'dst host 10.77.0.2 and (udp dst port {echo_port} or udp dst port 53 or tcp dst port 19994 or icmp)' >/tmp/guard-capture.log 2>&1 &\necho $! >/tmp/guard-capture.pid\n")
    time.sleep(0.4)
    for _ in range(12):
        for protocol, port in [(17, echo_port), (17, 53), (6, 19994), (1, 0)]:
            sock.sendto(frame(protocol, port), ("127.0.0.1", probe_port))
        time.sleep(0.025)
    time.sleep(0.4)
    guest("kill -INT $(cat /tmp/guard-capture.pid)\nsleep 1\n")
    packets = guest("tcpdump -nn -r /tmp/guard-probe.pcap 2>/dev/null\n").stdout.strip()
    if blocked:
        assert not packets, "LAN traffic escaped during guard: " + packets
        guest("nft list chain inet passwall_switch prerouting | grep -Eq 'counter packets [1-9]'\n")
    else:
        assert str(echo_port) in packets and "19994" in packets and "ICMP" in packets, packets


try:
    guest("cp /etc/config/passwall /tmp/guard-original\nip link set eth2 master br-lan\nip link set eth2 up\n")
    router_mac = bytes.fromhex(guest("cat /sys/class/net/br-lan/address\n").stdout.strip().replace(":", ""))
    # Established flows must also be flushed before tearing down the old rules.
    guest("uci set firewall.@defaults[0].flow_offloading=1\nuci commit firewall\nfw4 reload\n")
    probe(False)
    guest(f"grep 'sport=19991 dport={echo_port} ' /proc/net/nf_conntrack | grep -q OFFLOAD\n")
    # An already offloaded flow must stop, even before the old core/rules are removed.
    guest("uci set passwall.@global[0].enabled=1\nuci commit passwall\n. /usr/share/passwall/utils.sh\n. /usr/share/passwall/switch_guard.sh\nswitch_guard_begin\n")
    probe(True)
    guest("""
uci set passwall.guard_node=nodes
uci set passwall.guard_node.type=Xray
uci set passwall.guard_node.protocol=socks
uci set passwall.guard_node.address=192.0.2.1
uci set passwall.guard_node.port=1080
uci set passwall.@global[0].enabled=1
uci set passwall.@global[0].node=guard_node
uci set passwall.@global[0].switch_guard=1
uci set passwall.@global[0].use_gfw_list=0
uci set passwall.@global[0].use_proxy_list=0
uci set passwall.@global[0].use_direct_list=0
uci set passwall.@global[0].use_block_list=0
uci set passwall.@global[0].chn_list=0
uci set passwall.@global[0].dns_shunt=chinadns-ng
uci set passwall.@global[0].dns_mode=xray
uci set passwall.@global[0].v2ray_dns_mode=tcp
uci set passwall.@global[0].remote_dns=1.1.1.1
uci commit passwall
/etc/init.d/passwall restart
test ! -e /tmp/passwall_switch_guard
pgrep -f '/tmp/etc/passwall/bin/xray ' >/dev/null
mkdir -p /tmp/guard-fault
cat > /tmp/guard-fault/nft <<'SH'
#!/bin/sh
[ "$1" != -f ] || exit 1
exec /usr/sbin/nft "$@"
SH
chmod +x /tmp/guard-fault/nft
pgrep -f '^/tmp/etc/passwall/bin/xray ' > /tmp/guard-old-pids
if PATH=/tmp/guard-fault:$PATH /etc/init.d/passwall restart; then exit 1; fi
while read -r pid; do kill -0 "$pid"; done < /tmp/guard-old-pids
/etc/init.d/passwall stop_for_update
test -s /tmp/passwall_switch_guard
! nft list table inet passwall | grep -q 'redirect to'
""")
    probe(True)
    # The guard is independent of fw4 and of PassWall's ordinary chain cleanup.
    guest("fw4 reload\nnft list table inet passwall_switch >/dev/null\n")
    probe(True)
    # Router-originated DNS/UDP/ICMP cannot use a private-address WAN either.
    guest("! ping -c 1 -W 1 10.77.0.2\nnft list chain inet passwall_switch output | grep -Eq 'counter packets [1-9]'\n")
    guest("/etc/init.d/passwall start\ntest ! -e /tmp/passwall_switch_guard\n")
    # Invalid global node used to silently finish startup with no proxy rules.
    guest("uci set passwall.@global[0].node=missing_node\nuci commit passwall\n! /etc/init.d/passwall restart\ntest -s /tmp/passwall_switch_guard\n")
    probe(True)
    guest("uci set passwall.@global[0].node=guard_node\nuci commit passwall\n/etc/init.d/passwall restart\ntest ! -e /tmp/passwall_switch_guard\n")
    # Invalid core config: process launch succeeds, then Xray immediately exits.
    guest("uci set passwall.guard_node.protocol=vmess\nuci set passwall.guard_node.uuid=00000000-0000-0000-0000-00000000000Z\nuci commit passwall\n! /etc/init.d/passwall restart\ntest -s /tmp/passwall_switch_guard\n")
    probe(True)
    # A live core must not lift protection when redirect rule installation fails.
    guest('''
uci set passwall.guard_node.protocol=socks
uci commit passwall
cat > /tmp/guard-fault/nft <<'SH'
#!/bin/sh
case "$*" in
  "add rule inet passwall dstnat "*"jump PSW_NAT"*) exit 1 ;;
esac
exec /usr/sbin/nft "$@"
SH
chmod +x /tmp/guard-fault/nft
if PATH=/tmp/guard-fault:$PATH /etc/init.d/passwall restart; then exit 1; fi
test -s /tmp/passwall_switch_guard
test -s /tmp/etc/passwall/firewall_error
''')
    probe(True)
    guest("/etc/init.d/passwall stop\ntest ! -e /tmp/passwall_switch_guard\n")
    probe(False)
    print("Switch guard packet checks passed: TCP/UDP/DNS/ICMP, established offloaded flow, fw4 reload, protected update, guard/rule installation failures, invalid node/core, recovery and explicit stop")
except subprocess.CalledProcessError as error:
    print(error.stdout, error.stderr, file=sys.stderr)
    print(guest("tail -n 100 /tmp/log/passwall.log\n", check=False).stdout, file=sys.stderr)
    raise
finally:
    guest("cp /tmp/guard-original /etc/config/passwall\nuci delete firewall.@defaults[0].flow_offloading\nuci commit firewall\n/etc/init.d/passwall stop\n/etc/init.d/passwall start\nfw4 reload\n", check=False)
    finished.set()
    responder.join(timeout=1)
    sock.close()
    echo_socket.close()
