#!/usr/bin/env python3
"""Race two production probes against delayed, local-only proxy stand-ins."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='url-probe-') as tmp:
    directory = Path(tmp)
    def executable(name, content):
        path = directory / name
        path.write_text('#!/bin/sh\n' + content)
        path.chmod(0o755)
        return path
    utils = directory / 'utils.sh'
    utils.write_text('''CONFIG=passwall
LOCK_PATH="$PROBE_TEST_DIR"
TMP_PATH="$PROBE_TEST_DIR"
config_n_get() {
 case "$2" in type) echo Xray;; url_test_url) echo https://example.test/204;; esac
}
get_new_port() {
 for port in 48900 48901; do
  [ -d "$PROBE_TEST_DIR/port-$port" ] || { echo "$port"; return; }
 done
 return 1
}
check_port_exists() { [ -d "$PROBE_TEST_DIR/port-$1" ] && echo 1 || echo 0; }
''')
    app = executable('app', '''for argument do
 case "$argument" in socks_port=*) port=${argument#socks_port=};; esac
done
# Listener setup is deliberately delayed to expose the original allocation race.
sleep 0.2
mkdir "$PROBE_TEST_DIR/port-$port" || exit 1
echo "$port" >> "$PROBE_TEST_DIR/ports"
# A spawned core must not inherit the startup lock descriptor.
if [ -e /proc/$$/fd/8 ]; then echo inherited >> "$PROBE_TEST_DIR/lock-errors"; fi
''')
    executable('curl', '''printf 'call\\n' >> "$PROBE_TEST_DIR/curl-calls"
for argument do [ "$argument" != '-w' ] || printf '204:0.010:0.030'; done
exit 0
''')
    executable('busybox', 'exit 0\n')
    source = (ROOT / 'luci-app-passwall/root/usr/share/passwall/test.sh').read_text()
    source = source.replace('. /usr/share/passwall/utils.sh', '. ' + shlex.quote(str(utils)))
    source = source.replace('/usr/share/${CONFIG}/app.sh', shlex.quote(str(app)))
    probe = directory / 'probe.sh'; probe.write_text(source)
    env = dict(os.environ, PROBE_TEST_DIR=tmp, PATH=tmp + ':' + os.environ['PATH'])
    workers = [subprocess.Popen(['sh', str(probe), 'url_test_node', node], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for node in ('first', 'second')]
    try:
        for worker in workers:
            out, err = worker.communicate(timeout=15)
            assert worker.returncode == 0 and out == '204:0.010:0.030', (out, err)
        assert sorted((directory / 'ports').read_text().splitlines()) == ['48900', '48901']
        assert len((directory / 'curl-calls').read_text().splitlines()) == 4
        assert not (directory / 'lock-errors').exists()
        # The shell-local lock must be released on completion.
        subprocess.run(['flock', '-n', str(directory / 'passwall_socks_auto_switch_test.lock'), 'true'], check=True)
    finally:
        for worker in workers:
            if worker.poll() is None: worker.kill(); worker.wait()
print('PASS concurrent URL probes: exclusive startup, distinct ports, warm-up and lock release')
