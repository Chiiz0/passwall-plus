-- Run with Lua 5.1 from the repository root.
local protocol = dofile("luci-app-passwall-ezcnet/root/usr/share/passwall-ezcnet/protocol.lua")
local data = {global = {dns_shunt = "chinadns-ng", private_field = "preserve"}, node1 = {type = "Xray", protocol = "_shunt"}}
local committed = false
local cursor = {}
function cursor:get(package, section, key)
	assert(package == "passwall")
	if not key then return data[section] and (section == "global" and "global" or "nodes") end
	return data[section] and data[section][key]
end
function cursor:set(package, section, key, value)
	assert(package == "passwall")
	data[section][key] = value
	return true
end
function cursor:commit(package) assert(package == "passwall"); committed = true; return true end
local function command()
	local config = protocol.config(cursor, "global")
	config.node = "node1"
	return {id = string.rep("a", 32), kind = "config", expires = 200, expected_revision = "revision", config = config}
end
assert(protocol.validate(command(), cursor, "revision", 100))
local invalid = command(); invalid.config.password = "inject"
assert(not protocol.validate(invalid, cursor, "revision", 100))
invalid = command(); invalid.config.node = "$(reboot)"
assert(not protocol.validate(invalid, cursor, "revision", 100))
invalid = command(); invalid.config.node = "missing"
assert(not protocol.validate(invalid, cursor, "revision", 100))
invalid = command(); invalid.config.enabled = "1"; invalid.config.node = ""
assert(not protocol.validate(invalid, cursor, "revision", 100))
invalid = command(); invalid.config.client_proxy = true
assert(not protocol.validate(invalid, cursor, "revision", 100))
invalid = command(); invalid.config.udp_proxy_mode = "global"
assert(not protocol.validate(invalid, cursor, "revision", 100))
invalid = command(); invalid.kind = "shell"
assert(not protocol.validate(invalid, cursor, "revision", 100))
invalid = command(); invalid.id = "bad/id"
assert(not protocol.validate(invalid, cursor, "revision", 100))
assert(not protocol.validate(command(), cursor, "local_edit", 100))
assert(not protocol.validate(command(), cursor, "revision", 201))
protocol.apply(cursor, "global", command().config)
assert(committed and data.global.node == "node1")
assert(data.global.dns_mode == "xray" and data.global.v2ray_dns_mode == "tcp")
assert(data.global.private_field == "preserve")
data.global.dns_shunt = "smartdns"; data.node1.type = "Sing-Box"
protocol.apply(cursor, "global", command().config)
assert(data.global.smartdns_dns_mode == "sing-box")
print("EzCNet protocol validation and shunt switching passed")
