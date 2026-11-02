#!/usr/bin/env python3
"""Exercise the production init lifecycle with fake services, never host firewall."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "luci-app-passwall/root/etc/init.d/passwall").read_text()
functions = source[source.index("start() {"):source.index("reload() {")]

with tempfile.TemporaryDirectory() as tmp:
    directory = Path(tmp)
    app = directory / "app"
    app.write_text('''#!/bin/sh
echo "$1" >> "$EVENTS"
case "$1" in
  start) exit "${START_RESULT:-0}" ;;
  stop) exit "${STOP_RESULT:-0}" ;;
esac
''')
    app.chmod(0o755)
    prelude = '''
set_lock() { echo lock >> "$EVENTS"; }
set_lock_wait() { echo lock >> "$EVENTS"; }
unset_lock() { echo unlock >> "$EVENTS"; }
echolog() { :; }
switch_guard_begin() { echo arm >> "$EVENTS"; return "${ARM_RESULT:-0}"; }
switch_guard_end() { echo clear >> "$EVENTS"; }
lua() { return 0; }
seq() { echo 1; }
'''
    cases = [
        ("restart", {}, 0, ["lock", "arm", "stop", "start", "unlock"]),
        ("restart", {"ARM_RESULT": "1"}, 1, ["lock", "arm", "unlock"]),
        ("restart", {"STOP_RESULT": "1"}, 1, ["lock", "arm", "stop", "unlock"]),
        ("restart", {"START_RESULT": "1"}, 1, ["lock", "arm", "stop", "start", "unlock"]),
        ("start", {"START_RESULT": "1"}, 1, ["lock", "start", "unlock"]),
        ("stop_for_update", {}, 0, ["lock", "arm", "stop", "unlock"]),
        ("stop_for_update", {"ARM_RESULT": "1"}, 1, ["lock", "arm", "unlock"]),
        ("stop", {}, 0, ["lock", "stop", "clear", "unlock"]),
    ]
    for action, overrides, expected_code, expected_events in cases:
        events = directory / "events"
        events.write_text("")
        env = dict(os.environ, APP_FILE=str(app), EVENTS=str(events), **overrides)
        result = subprocess.run(["/bin/sh"], input=prelude + functions + action,
                                text=True, env=env)
        assert result.returncode == expected_code, (action, overrides, result.returncode)
        assert events.read_text().splitlines() == expected_events, (action, overrides, events.read_text())
print("Switch lifecycle checks passed: guard-before-stop, abort on protection failure, error propagation, protected update and explicit stop")
