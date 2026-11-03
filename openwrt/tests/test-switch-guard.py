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
from switch_fixture import Upstream

ssh_port, probe_port = map(int, sys.argv[1:])
ssh = ["ssh", "-p", str(ssh_port), "-o", "BatchMode=yes", "-o",
       "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
       "-o", "LogLevel=ERROR", "root@127.0.0.1"]


def guest(script, check=True):
    return subprocess.run(ssh + ["/bin/sh"], input="set -e\n" + script,
                          text=True, capture_output=True, check=check, timeout=300)


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


def wait_for(script, timeout=100):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if guest(script, check=False).returncode == 0:
            return
        time.sleep(0.5)
    raise AssertionError("Guest condition timed out: " + script)


def launch():
    return guest("rm -f /tmp/etc/passwall/start_complete\n"
                 "nohup /etc/init.d/passwall restart >/tmp/transition.log 2>&1 </dev/null &\n"
                 "echo $!\n").stdout.strip()


def ready(node="good_a", result="ready"):
    wait_for(f"test \"$(cat /tmp/passwall_switch/result)\" = {result}\n"
             f"test \"$(uci get passwall.@global[0].node)\" = {node}\n"
             "test ! -e /tmp/passwall_switch_guard\n"
             "test \"$(cat /tmp/passwall_switch/phase)\" = idle\n")


upstream = Upstream()
try:
    guest("cp /etc/config/passwall /tmp/guard-original\n"
          "cp /etc/ssl/certs/ca-certificates.crt /tmp/guard-original-ca\n"
          "ip link set eth2 master br-lan\nip link set eth2 up\n"
          "/etc/init.d/passwall stop\nrm -rf /etc/passwall/.switch\n")
    router_mac = bytes.fromhex(guest("cat /sys/class/net/br-lan/address\n").stdout.strip().replace(":", ""))
    guest('''
. /usr/share/passwall/utils.sh
. /usr/share/passwall/switch_lifecycle.sh
SWITCH_REQUEST=$(switch_read request)
mkdir -p "$SWITCH_SAVE"
switch_export > "$SWITCH_SAVE/last-good"
uci set passwall.@global[0].probe_lock_case=candidate
uci commit passwall
switch_capture
lua -e '
 local n=require "nixio"
 local f=assert(n.open("/var/lock/passwall_sub_rule.lock","a"))
 assert(f:lock("tlock"))
 local ready=assert(io.open("/tmp/native-lock-ready","w")); ready:close()
 n.nanosleep(30)
' &
holder=$!
for i in $(seq 1 30); do [ ! -e /tmp/native-lock-ready ] || break; sleep 0.1; done
test -e /tmp/native-lock-ready
! switch_restore_config
test "$(uci get passwall.@global[0].probe_lock_case)" = candidate
kill "$holder"
wait "$holder" 2>/dev/null || true
uci set passwall.@global[0].probe_lock_case=edited
uci commit passwall
! switch_restore_config
test "$(uci get passwall.@global[0].probe_lock_case)" = edited
switch_capture
switch_restore_config
! uci -q get passwall.@global[0].probe_lock_case
rm -rf "$SWITCH_SAVE"
rm /tmp/native-lock-ready
''')
    print("PASS: native subscription lock and changed configuration prevent stale rollback", flush=True)
    guest("uci set firewall.@defaults[0].flow_offloading=1\nuci commit firewall\nfw4 reload\n")
    probe(False)
    guest(f"grep 'sport=19991 dport={echo_port} ' /proc/net/nf_conntrack | grep -q OFFLOAD\n")
    guest("uci set passwall.@global[0].enabled=1\nuci commit passwall\n"
          ". /usr/share/passwall/utils.sh\n. /usr/share/passwall/switch_guard.sh\nswitch_guard_begin\n")
    probe(True)
    print("PASS: guard blocks TCP/UDP/DNS/ICMP and established offloaded flow", flush=True)
    guest(upstream.setup() + "\n/etc/init.d/passwall restart\n")
    ready()
    assert upstream.nodes["good_a"].requests > 0
    guest("ls -l /etc/passwall/.switch/last-good | grep -q '^-rw-------'\n")
    print("PASS: real SOCKS/TLS connectivity gates removal; private checkpoint", flush=True)

    # Failure after installation must preserve the previous live proxy and undo
    # the temporary barrier. Fault is scoped to this caller, not the watchdog.
    guest('''
mkdir -p /tmp/guard-fault
cat > /tmp/guard-fault/fw4 <<'SH'
#!/bin/sh
[ "$1" != reload ] || exit 1
exec /sbin/fw4 "$@"
SH
chmod +x /tmp/guard-fault/fw4
pgrep -f '^/tmp/etc/passwall/bin/xray ' > /tmp/guard-old-pids
! PATH=/tmp/guard-fault:$PATH /etc/init.d/passwall restart
while read -r pid; do kill -0 "$pid"; done < /tmp/guard-old-pids
test ! -e /tmp/passwall_switch_guard
test "$(cat /tmp/passwall_switch/result)" = cancelled
rm /tmp/guard-fault/fw4
''')
    print("PASS: partial arm failure cancels without tearing down healthy proxy", flush=True)

    guest("uci set passwall.@global[0].node=bad_b\nuci commit passwall\n")
    pid = launch()
    wait_for("test -f /tmp/etc/passwall/start_complete\ntest -s /tmp/passwall_switch_guard\n")
    probe(True)
    ready(result="rolled_back")
    print("PASS: unreachable node stays protected then rolls back automatically", flush=True)

    # Delayed core launch must eventually recover, even though the config test
    # completes immediately. Never gate Xray's synchronous `run -test` command.
    guest('''
cat > /tmp/delayed-xray <<'SH'
#!/bin/sh
if [ "$1" = run ] && [ "$2" != -test ]; then
 while [ ! -f /tmp/release-xray ]; do sleep 1; done
fi
exec /usr/bin/xray "$@"
SH
chmod +x /tmp/delayed-xray
uci set passwall.@global_app[0].xray_file=/tmp/delayed-xray
uci commit passwall
rm -f /tmp/release-xray
''')
    pid = launch()
    wait_for("test -f /tmp/etc/passwall/start_complete\ntest -s /tmp/passwall_switch_guard\n")
    probe(True)
    guest("touch /tmp/release-xray\n")
    ready()
    print("PASS: delayed listeners recover without a manual restart", flush=True)

    # Controller death must leave no inherited service lock. A separate procd
    # service resumes the transition while old stage children are cancelled.
    guest("rm /tmp/release-xray\n")
    pid = launch()
    wait_for("test -f /tmp/etc/passwall/start_complete\ntest -s /tmp/passwall_switch_guard\n")
    guest(f"kill -KILL {pid}\ntouch /tmp/release-xray\n")
    ready()
    print("PASS: killed controller recovers through independent supervisor", flush=True)

    guest("rm /tmp/release-xray\n")
    launch()
    wait_for("test -f /tmp/etc/passwall/start_complete\ntest -s /tmp/passwall_switch_guard\n")
    guest("/etc/init.d/passwall stop\ntouch /tmp/release-xray\nsleep 5\n"
          "test \"$(cat /tmp/passwall_switch/result)\" = stopped\n"
          "test ! -e /tmp/passwall_switch_guard\n"
          "! pgrep -f '^/tmp/etc/passwall/bin/xray '\n"
          "uci delete passwall.@global_app[0].xray_file\nuci commit passwall\n")
    probe(False)
    print("PASS: explicit stop cancels delayed startup and prevents resurrection", flush=True)

    guest("/etc/init.d/passwall restart\nuci set passwall.@global[0].node=bad_b\nuci commit passwall\n")
    launch()
    wait_for("test -f /tmp/etc/passwall/start_complete\ntest -s /tmp/passwall_switch_guard\n")
    guest("uci set passwall.@global[0].node=good_c\nuci commit passwall\n/etc/init.d/passwall restart\n")
    ready(node="good_c")
    print("PASS: newest switch cancels previous work without stale rollback", flush=True)

    guest('''
sha256sum /usr/bin/xray > /tmp/original-core.sha
printf '#!/bin/sh\nexit 1\n' > /tmp/bad-core
! /etc/init.d/passwall update_core /tmp/bad-core /usr/bin/xray
sha256sum -c /tmp/original-core.sha
test ! -e /etc/passwall/.switch/core-update
test ! -e /usr/bin/xray.passwall-previous
''')
    ready(node="good_c", result="rolled_back")
    print("PASS: failed core replacement restores binary and verified service", flush=True)

    guest("kill -KILL $(pgrep -f '^/tmp/etc/passwall/bin/xray ')\n")
    wait_for("test -s /tmp/passwall_switch_guard\n", timeout=15)
    probe(True)
    ready(node="good_c")
    print("PASS: runtime core death promptly triggers protected recovery", flush=True)

    # A failed table query must not lose ownership of a real drop table.
    guest('''
. /usr/share/passwall/utils.sh
. /usr/share/passwall/switch_guard.sh
switch_guard_begin
cat > /tmp/guard-fault/nft <<'SH'
#!/bin/sh
[ "$*" != 'list tables' ] || exit 1
exec /usr/sbin/nft "$@"
SH
chmod +x /tmp/guard-fault/nft
! PATH=/tmp/guard-fault:$PATH switch_guard_end
test -s /tmp/passwall_switch_guard
nft list table inet passwall_switch >/dev/null
! PATH=/tmp/guard-fault:$PATH /etc/init.d/passwall stop
''')
    wait_for("test ! -e /tmp/passwall_switch_guard\ntest \"$(cat /tmp/passwall_switch/result)\" = stopped\n")
    guest('''
rm /tmp/guard-fault/nft
. /usr/share/passwall/utils.sh
. /usr/share/passwall/switch_guard.sh
switch_guard_begin
rm /tmp/passwall_switch_guard
/etc/init.d/passwall stop
! nft list tables | grep -q 'table inet passwall_switch'
''')
    probe(False)
    print("PASS: query failure retains ownership; stop clears orphaned barrier", flush=True)

    guest("rm -rf /etc/passwall/.switch\nuci set passwall.@global[0].node=bad_b\nuci commit passwall\n"
          "! /etc/init.d/passwall restart\ntest -s /tmp/passwall_switch_guard\n")
    probe(True)
    guest("fw4 reload\nnft list table inet passwall_switch >/dev/null\n! ping -c 1 -W 1 10.77.0.2\n")
    probe(True)
    upstream.nodes["bad_b"].enabled = True
    ready(node="bad_b")
    print("PASS: no usable fallback stays protected across fw4 reload, then auto-recovers", flush=True)

    guest("pgrep -f '^/bin/sh /usr/libexec/passwall-guard-watch$' > /tmp/old-watch\nkill -KILL $(cat /tmp/old-watch)\n")
    wait_for("pid=$(pgrep -f '^/bin/sh /usr/libexec/passwall-guard-watch$')\ntest -n \"$pid\"\ntest \"$pid\" != \"$(cat /tmp/old-watch)\"\n", timeout=20)
    print("PASS: procd respawns recovery supervisor", flush=True)
except (subprocess.CalledProcessError, AssertionError):
    print(guest("cat /tmp/transition.log\ntail -n 100 /tmp/log/passwall.log\n", check=False).stdout, file=sys.stderr)
    raise
finally:
    guest("cp /tmp/guard-original /etc/config/passwall\n"
          "cp /tmp/guard-original-ca /etc/ssl/certs/ca-certificates.crt\n"
          "uci -q delete firewall.@defaults[0].flow_offloading || true\nuci commit firewall\n"
          "/etc/init.d/passwall stop\nrm -rf /etc/passwall/.switch\n"
          "/etc/init.d/passwall start\nfw4 reload\n", check=False)
    upstream.close()
    finished.set()
    responder.join(timeout=1)
    sock.close()
    echo_socket.close()
