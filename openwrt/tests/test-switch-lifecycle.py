#!/usr/bin/env python3
"""Fault-inject production transition/cleanup functions without host networking."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
lifecycle = (root / 'luci-app-passwall/root/usr/share/passwall/switch_lifecycle.sh').read_text()
guard = (root / 'luci-app-passwall/root/usr/share/passwall/switch_guard.sh').read_text()
with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    env = dict(os.environ, TEST_DIR=temporary, APP_FILE='/fake/app')
    setup = lifecycle + '''
SWITCH_DIR="$TEST_DIR/state"
SWITCH_SAVE="$TEST_DIR/save"
mkdir -p "$SWITCH_DIR" "$SWITCH_SAVE"
SWITCH_REQUEST='original restart'
switch_write request "$SWITCH_REQUEST"
switch_write running digest
printf 'good\n' > "$SWITCH_SAVE/last-good"
switch_export() { echo candidate; }
switch_digest_file() { echo digest; }
switch_digest() { echo digest; }
config_n_get() { echo "${3:-}"; }
echolog() { :; }
switch_guard_needed() { return 0; }
switch_supervisor() { return 0; }
switch_guard_ready() { return 0; }
switch_guard_begin() { echo arm; return "${ARM_FAIL:-0}"; }
switch_guard_end() { echo clear; return "${CLEAR_FAIL:-0}"; }
switch_checkpoint() { echo checkpoint; }
switch_core_commit() { echo commit; }
switch_core_restore() { echo core_restore; }
switch_restore_config() { echo rollback; return "${ROLLBACK_FAIL:-0}"; }
switch_exec() {
 case "$2" in
 /fake/app)
   echo "$3"
   if [ "$3" = start ]; then
     [ "${SUPERSEDE:-0}" = 0 ] || switch_write request 'new stop'
     if [ "${START_FAIL_ONCE:-0}" = 1 ] && [ ! -f "$TEST_DIR/failed" ]; then
       touch "$TEST_DIR/failed"; return 1
     fi
   fi
   [ "$3" != stop ] || return "${STOP_FAIL:-0}"
   ;;
 *) echo check; return "${CHECK_FAIL:-0}" ;;
 esac
 return 0
}
'''
    cases = [
        ({}, ['check', 'arm', 'stop', 'start', 'check', 'clear', 'checkpoint', 'commit', 'finish'], 0, 'ready'),
        ({'ARM_FAIL': '1'}, ['check', 'arm', 'rollback', 'clear'], 1, 'cancelled'),
        ({'ARM_FAIL': '1', 'ROLLBACK_FAIL': '1'}, ['check', 'arm', 'rollback'], 1, 'blocked'),
        ({'START_FAIL_ONCE': '1'}, ['check', 'arm', 'stop', 'start', 'core_restore', 'rollback', 'arm', 'stop', 'start', 'check', 'clear', 'checkpoint', 'commit', 'finish'], 1, 'rolled_back'),
        ({'STOP_FAIL': '1', 'ROLLBACK_FAIL': '1'}, ['check', 'arm', 'stop', 'core_restore', 'rollback'], 1, 'blocked'),
        ({'SUPERSEDE': '1'}, ['check', 'arm', 'stop', 'start'], 1, 'switching'),
        ({'CLEAR_FAIL': '1', 'ROLLBACK_FAIL': '1'}, ['check', 'arm', 'stop', 'start', 'check', 'clear', 'core_restore', 'rollback'], 1, 'blocked'),
    ]
    for overrides, expected, code, result in cases:
        subprocess.run(['rm', '-rf', str(directory / 'state'), str(directory / 'save'), str(directory / 'failed')], check=True)
        process = subprocess.run(['/bin/sh'], input=setup + '\nswitch_run\n', text=True,
                                 capture_output=True, env=dict(env, **overrides))
        assert process.returncode == code, (overrides, process.returncode, process.stderr)
        assert process.stdout.splitlines() == expected, (overrides, process.stdout, process.stderr)
        result_file = directory / 'state/result'
        if result:
            assert result_file.read_text().strip() == result
        else:
            assert not result_file.exists(), 'Superseded work wrote a terminal status'

    process = subprocess.run(['/bin/sh'], input=setup + '''
TMP_PATH="$TEST_DIR/runtime"
mkdir -p "$TMP_PATH"
switch_now() { echo 100; }
get_cache_var() { [ "$1" != FAILOVER_ROLE ] || echo "$role_under_test"; }
wait_updates() { return "${writer_busy:-0}"; }
switch_exec() {
 case "$3" in active) return "$active_status" ;; primary) return "$primary_status" ;; esac
 return 1
}
switch_run() { printf '%s %s\n' "$2" "$3" >> "$TEST_DIR/decisions"; }
sample() {
 echo 100 > "$TMP_PATH/failover_next"
 switch_failover_tick || exit 1
}
echo '0 0' > "$TMP_PATH/failover_counts"
rm -f "$TEST_DIR/decisions"
role_under_test=primary
active_status=1; sample; sample
active_status=0; sample
[ "$(cat "$TMP_PATH/failover_counts")" = '0 0' ] || exit 1
active_status=1; sample; sample
[ ! -f "$TEST_DIR/decisions" ] || exit 1
writer_busy=1; sample
[ ! -f "$TEST_DIR/decisions" ] || exit 1
writer_busy=0; sample
[ "$(cat "$TEST_DIR/decisions")" = 'backup digest' ] || exit 1
role_under_test=backup; active_status=0; primary_status=0
sample; sample; primary_status=1; sample
[ "$(cat "$TMP_PATH/failover_counts")" = '0 0' ] || exit 1
primary_status=0; sample; sample
[ "$(wc -l < "$TEST_DIR/decisions")" -eq 1 ] || exit 1
sample
[ "$(tail -n 1 "$TEST_DIR/decisions")" = 'primary digest' ] || exit 1
rm -f "$TMP_PATH/failover_next"
! switch_failover_due
''', text=True, capture_output=True, env=env)
    assert process.returncode == 0, (process.stdout, process.stderr)

    process = subprocess.run(['/bin/sh'], input=setup + '''
config_n_get() { case "$2" in enabled) echo 1 ;; node) echo main ;; esac; }
global_backup_node() { echo standby; }
switch_exec() {
 if [ "$2" = /fake/app ] && [ "$3" = start ]; then echo "try $4"; return 1; fi
 return 0
}
switch_restore_config() { return 1; }
switch_run && exit 1
[ "$(switch_read result)" = blocked ] && [ "$(switch_read phase)" = failed ] || exit 1
switch_write desired current
! switch_capture stale && [ "$(switch_read desired)" = current ]
''', text=True, capture_output=True, env=env)
    assert process.returncode == 0, (process.stdout, process.stderr)
    assert [line for line in process.stdout.splitlines() if line.startswith('try ')] == ['try primary', 'try backup']
    assert 'clear' not in process.stdout.splitlines(), 'Both exits failed but the guard was removed'

    process = subprocess.run(['/bin/sh'], input=setup + '''
get_process_start_time() { [ "$1" = "$$" ] && echo 123; }
SWITCH_REQUEST="uuid $$ 123 restart"
switch_request_alive || exit 1
SWITCH_REQUEST="uuid $$ 122 restart"
! switch_request_alive || exit 1
SWITCH_REQUEST='legacy restart'
! switch_request_alive
''', text=True, env=env)
    assert process.returncode == 0, 'Request ownership must distinguish live callers and PID reuse'

    # Production cleanup must distinguish command failure from absence, retain
    # ownership when deletion fails, and remove a table with a missing marker.
    nft = directory / 'nft'
    nft.write_text('''#!/bin/sh
case "$*" in
 'list tables')
  [ "${QUERY_FAIL:-0}" = 0 ] || exit 1
  [ ! -f "$TEST_DIR/table" ] || echo 'table inet passwall_switch'
  ;;
 'delete table inet passwall_switch')
  [ "${DELETE_FAIL:-0}" = 0 ] || exit 1
  rm "$TEST_DIR/table"
  ;;
 *) exit 99 ;;
esac
''')
    nft.chmod(0o755)
    fw4 = directory / 'fw4'
    fw4.write_text('#!/bin/sh\nexit 99\n')
    fw4.chmod(0o755)
    for overrides in ({'QUERY_FAIL':'1'}, {'DELETE_FAIL':'1'}, {}):
        marker = directory / 'marker'
        marker.write_text('nft\n')
        (directory / 'table').touch()
        process = subprocess.run(['/bin/sh'], input=guard + '\nSWITCH_GUARD_STATE="$TEST_DIR/marker"\necholog() { :; }\nswitch_guard_end\n',
                                 text=True, env=dict(env, PATH=temporary + ':' + os.environ['PATH'], **overrides))
        assert bool(process.returncode) == bool(overrides)
        assert marker.exists() == bool(overrides)
        assert (directory / 'table').exists() == bool(overrides)
    (directory / 'table').touch()
    process = subprocess.run(['/bin/sh'], input=guard + '\nSWITCH_GUARD_STATE="$TEST_DIR/marker"\necholog() { :; }\nswitch_guard_end\n',
                             text=True, env=dict(env, PATH=temporary + ':' + os.environ['PATH']))
    assert process.returncode == 0 and not (directory / 'table').exists()

    # The legacy backend must preserve DHCP even when conntrack cannot pair
    # the reply with the broadcast/zero-address request. Capture its actual
    # restore transaction; the firmware packet regression exercises nftables.
    iptables = directory / 'test-iptables'
    iptables.write_text('#!/bin/sh\nexit 1\n')
    iptables.chmod(0o755)
    restore = directory / 'test-iptables-restore'
    restore.write_text('#!/bin/sh\ncat > "$TEST_DIR/restore"\n')
    restore.chmod(0o755)
    for family, client, server in [(4, 68, 67), (6, 546, 547)]:
        process = subprocess.run(['/bin/sh'], input=guard + f'\nDIRECT_GID=453\nswitch_guard_ipt_family "$TEST_DIR/test-iptables" {family}\n',
                                 text=True, capture_output=True, env=env)
        assert process.returncode == 0, process.stderr
        rules = (directory / 'restore').read_text().splitlines()
        for chain in ('PW_SWITCH_PRE', 'PW_SWITCH_OUT'):
            for source, target in [(client, server), (server, client)]:
                rule = f'-A {chain} -p udp --sport {source} --dport {target} -j RETURN'
                assert rule in rules, f'DHCP direction missing: {rule}'
                if chain == 'PW_SWITCH_OUT':
                    assert rules.index(rule) < rules.index('-A PW_SWITCH_OUT -j DROP')
        assert '-A PW_SWITCH_FWD -j DROP' in rules
        assert '-A PW_SWITCH_PRE ! -i lo -p udp --dport 53 -j DROP' in rules
        if family == 6:
            assert '-A PW_SWITCH_OUT -p ipv6-icmp --icmpv6-type 134 -j RETURN' in rules
print('PASS: rollback, partial arm failure, superseded requests, stop/start/cleanup errors, orphan cleanup')
print('PASS: iptables IPv4/IPv6 DHCP directions and router advertisements; transit/DNS remain blocked')
