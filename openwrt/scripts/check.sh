#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
for test in updater switch-lifecycle package-copy release url-probe; do
    python3 "openwrt/tests/test-${test}.py"
done
for test in plus-ui ezcnet backup; do
    lua5.1 "openwrt/tests/test-${test}.lua"
done
node openwrt/tests/test-plus-profile.js
node openwrt/tests/test-request.js
while IFS= read -r -d '' path; do luac5.1 -p "$path"; done < <(find luci-app-passwall luci-app-passwall-ezcnet -name '*.lua' -print0)
luac5.1 -p luci-app-passwall/root/usr/libexec/passwall-config-marker
git diff --check
