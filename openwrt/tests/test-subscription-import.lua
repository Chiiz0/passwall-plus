-- Run in a disposable OpenWrt VM against the installed subscription parser.
-- These synthetic credentials and reserved addresses never make connections.
local api = require "luci.passwall.api"
local original_config = api.fs.readfile("/etc/config/passwall")
local parser = assert(loadfile("/usr/share/passwall/subscribe.lua"))({library=true})
local count = 0
local function check(label, uri, expected)
	local nodes, errors = parser.parse(uri, "Import regression")
	assert(#errors == 0 and #nodes == 1, label .. ": import rejected")
	for key, value in pairs(expected) do
		assert(tostring(nodes[1][key]) == tostring(value), label .. ": wrong " .. key)
	end
	count = count + 1
	return nodes[1]
end
local function b64(value)
	return api.base64Encode(value):gsub("%+", "-"):gsub("/", "_"):gsub("=+$", "")
end

check("SS SIP002 literal percent password",
	"ss://" .. b64("aes-128-gcm:secret%2F%25") .. "@example.net:80#SS",
	{address="example.net", port=80, password="secret%2F%25"})
check("SS legacy literal percent password",
	"ss://" .. b64("aes-128-gcm:secret%2F%25@example.net:443") .. "#SS",
	{address="example.net", port=443, password="secret%2F%25"})
check("SS URI-encoded plaintext password",
	"ss://aes-128-gcm:secret%252F%2525@example.net:443#SS",
	{address="example.net", port=443, password="secret%2F%25"})
check("SS bracketed IPv6 and trailing slash",
	"ss://" .. b64("aes-128-gcm:secret") .. "@[2001:db8::1]:8388/#SS",
	{address="2001:db8::1", port=8388, password="secret"})

for _, scheme in ipairs({"naive+https", "naive+quic"}) do
	check(scheme .. " separate encoded userinfo",
		scheme .. "://user%3Aname:secret%3Avalue%252F@example.net:80/#Naive",
		{protocol="naive", username="user:name", password="secret:value%2F", address="example.net", port=80})
	check(scheme .. " password-only encoded colon",
		scheme .. "://secret%3Avalue@example.net#Naive",
		{protocol="naive", username="", password="secret:value", address="example.net", port=443})
	check(scheme .. " IPv6 without explicit port",
		scheme .. "://user:secret@[2001:db8::1]/#Naive",
		{address="2001:db8::1", port=443})
end

local uuid = "11111111-2222-4333-8444-555555555555"
for _, scheme in ipairs({"vless", "trojan", "hysteria2", "tuic"}) do
	local auth = scheme == "tuic" and uuid .. ":secret" or (scheme == "vless" and uuid or "secret")
	check(scheme .. " default TLS port", scheme .. "://" .. auth .. "@[2001:db8::1]/#Node",
		{address="2001:db8::1", port=443})
	check(scheme .. " explicit port 80", scheme .. "://" .. auth .. "@example.net:80/#Node",
		{address="example.net", port=80})
end

local nodes, errors = parser.parse("ss://" .. b64("aes-128-gcm:secret") .. "@example.net#MissingPort")
assert(#nodes == 0 and #errors == 1, "SS must still require an explicit port")
nodes, errors = parser.parse([[
dns:
  proxy-server-nameserver: [9.9.9.9]
proxies:
  - { name: good, type: ss, server: example.net, port: 8388, cipher: aes-128-gcm, password: 'secret%2F' }
  - { name: unsupported, type: unsupported, server: example.net, port: 443 }
]])
assert(#nodes == 1 and nodes[1].password == "secret%2F", "Clash password conversion changed")
assert(#errors == 1 and errors[1].index == 2 and errors[1].code == "invalid_or_unsupported",
	"Clash error reporting contract changed")
assert(not nodes[1].domain_resolver, "Clash import silently changed node DNS")
assert(api.fs.readfile("/etc/config/passwall") == original_config, "Read-only import changed UCI")
print("PASS: " .. count .. " subscription URI cases, Clash conversion errors, unchanged DNS and read-only import")
