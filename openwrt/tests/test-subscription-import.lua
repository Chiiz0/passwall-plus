-- Run in a disposable OpenWrt VM against the installed subscription parser.
-- These synthetic credentials and reserved addresses never make connections.
local api = require "luci.passwall.api"
local original_config = api.fs.readfile("/etc/config/passwall")
local parser = assert(loadfile("/usr/share/passwall/subscribe.lua"))({library=true})
local count = 0
local function check(label, uri, expected, options)
	local nodes, errors = parser.parse(uri, "Import regression", options)
	assert(#errors == 0 and #nodes == 1, label .. ": import rejected")
	for key, value in pairs(expected) do
		if type(value) == 'table' then
			assert(api.jsonc.stringify(nodes[1][key]) == api.jsonc.stringify(value), label .. ": wrong " .. key)
		else assert(tostring(nodes[1][key]) == tostring(value), label .. ": wrong " .. key) end
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

for _, scheme in ipairs({'socks', 'socks5', 'socks5h'}) do
	check(scheme .. ' encoded userinfo', scheme .. '://user%3Aname:p%2B%252F@[2001:db8::1]#SOCKS',
		{protocol='socks', username='user:name', password='p+%2F', address='2001:db8::1', port=1080})
	check(scheme .. ' base64 userinfo', scheme .. '://' .. b64('user:p+%2F') .. '@example.net:1081#SOCKS',
		{username='user', password='p+%2F', address='example.net', port=1081})
	check(scheme .. ' legacy URI', scheme .. '://' .. b64('user:p+%2F@example.net:1082') .. '#SOCKS',
		{username='user', password='p+%2F', address='example.net', port=1082})
end
check('HTTP explicit port', 'http://user%3Aname:p%2B%252F@example.net:80#HTTP',
	{protocol='http', username='user:name', password='p+%2F', port=80, tls='0'})
check('HTTPS defaults and options', 'https://user:p%252F@[2001:db8::1]?sni=example.net&insecure=0&alpn=h2#HTTPS',
	{protocol='http', password='p%2F', port=443, tls='1', tls_serverName='example.net', tls_allowInsecure='0', alpn='h2'})
local key = api.base64Encode(string.rep('\251', 32))
for _, core in ipairs({'xray', 'sing-box'}) do
	check('WireGuard ' .. core, 'wireguard://' .. api.UrlEncode(key) .. '@[2001:db8::1]?publickey=' .. api.UrlEncode(key) ..
		'&presharedkey=' .. api.UrlEncode(key) .. '&address=10.0.0.2%2F32,fd00::2%2F128&reserved=1,2,3&mtu=1280&keepalive=25#WG',
		{protocol='wireguard', port=51820, address='2001:db8::1', wireguard_secret_key=key, wireguard_public_key=key,
		 wireguard_preSharedKey=key, wireguard_local_address={'10.0.0.2/32', 'fd00::2/128'}, wireguard_reserved='1,2,3',
		 wireguard_mtu='1280', wireguard_keepAlive='25'}, {other_type=core, filter_keyword_mode='0'})
end

-- Older firmware has Sing-box without WireGuard; both import surfaces must
-- select an available capable core instead of creating an unusable node.
local finded, tags = api.finded_com, api.get_singbox_tags
api.finded_com = function(name) return '/usr/bin/' .. name end
api.get_singbox_tags = function() return 'with_quic,with_utls' end
assert(api.get_wireguard_core('sing-box') == 'xray')
api.get_singbox_tags = function() return 'with_quic,with_wireguard' end
assert(api.get_wireguard_core('sing-box') == 'xray')
api.get_singbox_tags = function() return 'with_quic,with_wireguard,with_gvisor' end
assert(api.get_wireguard_core('sing-box') == 'sing-box')
assert(api.get_wireguard_core('xray') == 'xray')
api.finded_com = function(name) if name == 'sing-box' then return '/usr/bin/sing-box' end end
api.get_singbox_tags = function() return '' end
assert(api.get_wireguard_core('sing-box') == nil)
api.finded_com, api.get_singbox_tags = finded, tags

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
local function clash(dns)
	return dns .. [[
proxies:
  - { name: good, type: ss, server: example.net, port: 8388, cipher: aes-128-gcm, password: secret }
]]
end
local raw = clash('dns:\n  proxy-server-nameserver: [9.9.9.9]\n')
local links, issues, resolver = parseClashNode(raw)
assert(links ~= '' and #issues == 0 and resolver == nil, 'DNS extraction must be opt-in')
links, issues, resolver = parseClashNode(raw, 'DNS regression', true)
assert(#issues == 0 and resolver.domain_resolver == 'udp' and resolver.domain_resolver_dns == '9.9.9.9:53')
raw = clash('dns:\n  enable: true\n  listen: 0.0.0.0:1053\n  proxy-server-nameserver: [127.0.0.1:1053]\n  nameserver: [https://dns.example/dns-query]\n')
links, issues, resolver = parseClashNode(raw, 'DNS regression', true)
assert(resolver.domain_resolver == 'https' and resolver.domain_resolver_dns_https == 'https://dns.example/dns-query')
for _, dns in ipairs({
	'dns:\n  proxy-server-nameserver: [127.0.0.1]\n',
	'dns:\n  proxy-server-nameserver: [https://dns.example/dns-query?unsupported=1]\n',
	'dns:\n  proxy-server-nameserver: [9.9.9.9]\n  proxy-server-nameserver-policy: { example.net: 1.1.1.1 }\n',
	'dns:\n  enable: true\n  listen: 0.0.0.0:1053\n  proxy-server-nameserver: [127.0.0.1:1053]\n  nameserver: [127.0.0.1:1053]\n'
}) do
	links, issues, resolver = parseClashNode(clash(dns), 'DNS regression', true)
	assert(links ~= '' and #issues == 0 and resolver == nil, 'unsupported DNS policy must not be flattened')
end
assert(api.fs.readfile("/etc/config/passwall") == original_config, "Read-only import changed UCI")
print("PASS: " .. count .. " subscription URI cases, WireGuard core selection, opt-in DNS, Clash errors and read-only import")
