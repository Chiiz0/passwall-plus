"""Drop and restore real upstream traffic while both local proxy listeners stay up."""
import subprocess
import sys
import time

from switch_fixture import Upstream


def guest(script):
    result = subprocess.run([
        'ssh', '-p', sys.argv[1], '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR', 'root@127.0.0.1', '/bin/sh',
    ], input='set -e\n' + script, text=True, capture_output=True, timeout=300)
    if result.returncode:
        raise AssertionError((script, result.stdout, result.stderr))
    return result.stdout.strip()


def wait_for_node(node, role):
    # Advance only the probe timer. The production watcher performs every probe,
    # counts consecutive results and owns the protected transaction.
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        state = guest("""
if [ -f /tmp/etc/passwall/failover_next ]; then echo 0 > /tmp/etc/passwall/failover_next; fi
if [ "$(cat /tmp/passwall_switch/phase)" = idle ] && [ ! -e /tmp/passwall_switch_guard ]; then
    . /usr/share/passwall/utils.sh
    echo "$(get_cache_var ACL_GLOBAL_node) $(get_cache_var FAILOVER_ROLE)"
fi
""")
        if state == node + ' ' + role:
            assert guest('uci get passwall.@global[0].node') == 'good_a'
            return
        time.sleep(1)
    raise AssertionError(guest('tail -n 80 /tmp/log/passwall.log'))


upstream = Upstream()
try:
    guest('cp /etc/config/passwall /tmp/failover-original\n'
          'cp /etc/ssl/certs/ca-certificates.crt /tmp/failover-ca\n/etc/init.d/passwall stop')
    guest(upstream.setup() + """
uci set passwall.@global[0].backup_node=good_c
uci commit passwall
/etc/init.d/passwall restart
""")
    wait_for_node('good_a', 'primary')
    upstream.nodes['good_a'].enabled = False
    wait_for_node('good_c', 'backup')
    assert upstream.nodes['good_c'].requests > 0
    guest("""
for i in $(seq 1 45); do
    set -- /tmp/etc/passwall/failover/workers/*
    if [ -s "$1" ]; then
        read -r pid < "$1"
        kill "$pid"
        exit
    fi
    sleep 1
done
exit 1
""")
    upstream.nodes['good_a'].enabled = True
    wait_for_node('good_a', 'primary')
    print('PASS: global proxy failover and verified failback with the saved primary preserved', flush=True)
finally:
    try:
        guest('/etc/init.d/passwall stop\ncp /tmp/failover-original /etc/config/passwall\n'
              'cp /tmp/failover-ca /etc/ssl/certs/ca-certificates.crt\n'
              'rm -rf /etc/passwall/.switch\n/etc/init.d/passwall start')
    finally:
        upstream.close()
