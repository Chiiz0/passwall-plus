-- Compare effective configuration, including the normalization performed by
-- device_policy.sync_dhcp(), without changing the live UCI configuration.
local cursor = require("uci").cursor(arg[1], arg[1])
local policy = require "luci.passwall.device_policy"
assert(cursor:load("passwall"), "invalid configuration snapshot")
local function value(item)
	if type(item) == "table" then
		io.write("list:", #item, ":")
		for _, part in ipairs(item) do value(part) end
	else
		item = tostring(item)
		io.write(#item, ":", item)
	end
end
assert(cursor:foreach("passwall", nil, function(section)
	io.write("section:")
	value(section[".type"])
	value(section[".anonymous"] and "" or section[".name"])
	if section[".type"] == "global" then section.dnsmasq_dns_redirect = nil end
	if section[".type"] == "acl_rule" and section.enabled == "1" and section.bind_enable == "1" then
		local mac, ip = policy.normalize_mac(section.bind_mac), policy.normalize_ipv4(section.bind_ip)
		if mac and ip then
			section.bind_mac, section.bind_ip = mac, ip
			section.sources = mac .. " " .. ip
		end
	end
	local keys = {}
	for key in pairs(section) do
		if key:sub(1, 1) ~= "." then keys[#keys + 1] = key end
	end
	table.sort(keys)
	for _, key in ipairs(keys) do value(key); value(section[key]) end
	io.write("\n")
end))
