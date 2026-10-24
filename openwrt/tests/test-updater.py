#!/usr/bin/env python3
"""Test production updater functions without an OpenWrt installation.

Requires Python 3 and lua5.1 (the same Lua version as the firmware). Run from any
working directory with: python3 openwrt/tests/test-updater.py
Only system/network calls are stubbed; updater and version comparison functions
are extracted directly from api.lua, and com.lua is loaded unchanged.
"""

from pathlib import Path
import json
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
API = ROOT / "luci-app-passwall/luasrc/passwall/api.lua"
COM = ROOT / "luci-app-passwall/luasrc/passwall/com.lua"
api = API.read_text()
LUA = os.environ.get("LUA") or shutil.which("lua5.1")
if LUA is None:
    sys.exit("lua5.1 is required; install the lua5.1 package before running this test.")


def run(code):
    subprocess.run([LUA, "-"], input=code, text=True, check=True, cwd=ROOT)


def block(start, stop):
    return api[api.index(start):api.index(stop, api.index(start))]
code = 'com = dofile(' + json.dumps(str(COM), ensure_ascii=False) + ')\n' + '''
util = {split = function(s)
 local t={}; for part in s:gmatch("[^%.%-]+") do t[#t+1]=part end; return t
end}
appname = "passwall"

i18n = {translate = function(s) return s end}
local release, apk, installed, cached, cached_version, written_version
CACHE_PATH = "/tmp/passwall-updater-test"
fs = {
 access = function() return cached_version ~= nil end,
 readfile = function() return cached_version end,
 writefile = function(path, value) written_version = value end
}
sys = {
 call = function(cmd)
  if cmd:find("command -v apk", 1, true) then return apk and 0 or 1 end
  return 0
 end,
 exec = function(cmd)
  if cmd:find("uname", 1, true) then return "6.12.94" end
  if cmd:find("opkg", 1, true) and apk then return "" end
  return installed
 end
}
function trim(s) return s:match("^%s*(.-)%s*$") end
function get_api_json(url)
 assert(url == "https://api.github.com/repos/Chiiz0/passwall-plus/releases/latest")
 return release
end
function cache_update_digests(name, assets) cached = assets end
'''
code += block('function compare_versions(', 'local function auto_get_arch(')
code += block('local function is_self_release_asset(', 'local function cache_update_digests(')
code += block('function get_version()', 'function to_install_self(')
code += block('function to_download(', 'function to_download_progress(')
code += '''
local own = "https://github.com/Chiiz0/passwall-plus/releases/download/firmware-v25.12.5-r4/"
local vanilla = "https://github.com/Openwrt-Passwall/openwrt-passwall/releases/download/26.10.22-2/"
local function asset(name, prefix)
 return {name=name, browser_download_url=(prefix or own)..name, digest="sha256:test"}
end
local function fixture(names)
 release = {tag_name="firmware-v25.12.5-r4", assets={}, html_url="https://github.com/Chiiz0/passwall-plus/releases/tag/firmware-v25.12.5-r4"}
 for _, name in ipairs(names) do table.insert(release.assets, asset(name)) end
 apk=true; installed="26.8.26-r6"; cached=nil; cached_version=nil
end
apk=true; installed=" 26.10.22-r3 "
assert(get_version() == "26.10.22-3", "APK revision should normalize after opkg fallback")
assert(written_version == "26.10.22-r3", "Cache should retain the package manager's version")
apk=false; installed="26.10.22-3"
assert(get_version() == "26.10.22-3", "IPK revision should be preserved")
cached_version=" 26.10.22-r4 "
assert(get_version() == "26.10.22-4", "Cached APK revisions should normalize too")
fixture({"luci-app-passwall-26.10.22-r3.apk", "luci-i18n-passwall-zh-cn-26.10.22.apk"})
local result = to_check_self()
assert(result.code == 0 and result.has_update and result.remote_version == "26.10.22-3")
assert(#cached == 2)
installed="26.10.22-3"
assert(to_check_self().has_update == false)
installed="26.10.22-4"
assert(to_check_self().has_update == false)
fixture({"25.12+_luci-app-passwall-26.10.22-r3.apk", "25.12+_luci-i18n-passwall-zh-cn-26.10.22.apk"})
assert(to_check_self().has_update)
fixture({"23.05-24.10_luci-app-passwall_26.10.22-3_all.ipk", "23.05-24.10_luci-i18n-passwall-zh-cn_26.10.22_all.ipk"})
apk=false
assert(to_check_self().remote_version == "26.10.22-3")
fixture({"luci-app-passwall_26.10.22-3_all.ipk", "luci-i18n-passwall-zh-cn_26.10.22_all.ipk"})
apk=false
assert(to_check_self().has_update)
fixture({"luci-app-passwall-26.10.22-r3.apk"})
assert(to_check_self().code == 1)
fixture({"luci-app-passwall-26.10.22-r3.apk", "luci-i18n-passwall-zh-cn-26.10.22.apk"})
release.assets[1].browser_download_url = vanilla..release.assets[1].name
assert(to_check_self().code == 1)
assert(to_download(appname, vanilla.."luci-app-passwall.apk").code == 1)
assert(to_download(appname, nil).code == 1)
fixture({"openwrt-x86-64-generic-ext4-combined.img.gz"})
assert(to_check_self().code == 1)
print("Updater regression checks passed: native/prefixed APK and IPK, firmware/package version separation, equal/newer versions, missing packages, foreign download rejection.")
'''
run('assert(loadfile(' + json.dumps(str(API), ensure_ascii=False) + '))\n' + code)
print('api.lua and com.lua Lua 5.1 checks passed.')
