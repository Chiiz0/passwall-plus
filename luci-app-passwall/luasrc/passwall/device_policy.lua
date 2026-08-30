module("luci.passwall.device_policy", package.seeall)

local api = require "luci.passwall.api"
local jsonc = require "luci.jsonc"

local DHCP_MARKER = "passwall_managed"
local DHCP_ACL = "passwall_acl"

local function trim(value)
	return api.trim(value or "")
end

local function list_values(value)
	if type(value) == "table" then
		return value
	elseif type(value) == "string" and value ~= "" then
		local values = {}
		for item in value:gmatch("%S+") do
			values[#values + 1] = item
		end
		return values
	end
	return {}
end

function normalize_mac(value)
	value = trim(value):upper():gsub("-", ":")
	if not api.datatypes.macaddr(value) or not value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
		return nil
	end
	local first_octet = tonumber(value:sub(1, 2), 16)
	if value == "00:00:00:00:00:00" or first_octet % 2 == 1 then return nil end
	return value
end

local function ipv4_number(value)
	local a, b, c, d = trim(value):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return nil end
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
	return ((a * 256 + b) * 256 + c) * 256 + d, string.format("%d.%d.%d.%d", a, b, c, d)
end

function normalize_ipv4(value)
	local _, normalized = ipv4_number(value)
	return normalized
end

function valid_ipv4(value)
	return normalize_ipv4(value) ~= nil
end

local function subnet_contains(address, mask, candidate)
	local address_number = ipv4_number(address)
	local candidate_number = ipv4_number(candidate)
	local bits = tonumber(mask)
	if not bits then
		local mask_number = ipv4_number(mask)
		if not mask_number then return false end
		bits = 0
		local seen_zero = false
		for bit = 31, 0, -1 do
			local value = math.floor(mask_number / (2 ^ bit)) % 2
			if value == 1 and not seen_zero then
				bits = bits + 1
			elseif value == 0 then
				seen_zero = true
			else
				return false
			end
		end
	end
	if not address_number or not candidate_number or bits < 0 or bits > 32 then
		return false
	end
	local size = 2 ^ (32 - bits)
	local network = math.floor(address_number / size) * size
	if math.floor(candidate_number / size) * size ~= network then return false end
	if size > 2 and (candidate_number == network or candidate_number == network + size - 1) then
		return false
	end
	return true
end

local function configured_lan_networks(cursor)
	local networks = {}
	local zones = api.uci_get_c("@global[0]", "ipv6_reject_zones") or { "lan" }
	local wanted = {}
	for _, zone in ipairs(list_values(zones)) do
		wanted[zone] = true
	end
	cursor:foreach("firewall", "zone", function(section)
		if wanted[section.name] then
			for _, network in ipairs(list_values(section.network)) do
				networks[network] = true
			end
		end
	end)
	if not next(networks) then networks.lan = true end
	return networks
end

function get_lan_subnets(cursor)
	cursor = cursor or api.uci
	local networks = configured_lan_networks(cursor)
	local subnets = {}
	local status = jsonc.parse(api.sys.exec("ubus call network.interface dump 2>/dev/null") or "") or {}
	for _, interface in ipairs(status.interface or {}) do
		if networks[interface.interface] then
			for _, address in ipairs(interface["ipv4-address"] or {}) do
				if address.address and address.mask then
					subnets[#subnets + 1] = { address = address.address, mask = address.mask }
				end
		end
		end
	end
	if #subnets == 0 then
		for network in pairs(networks) do
			local address = cursor:get("network", network, "ipaddr")
			local mask = cursor:get("network", network, "netmask") or "255.255.255.0"
			if type(address) == "string" then
				local ip, bits = address:match("^([^/]+)/(%d+)$")
				subnets[#subnets + 1] = { address = ip or address, mask = bits or mask }
			end
		end
	end
	return subnets
end

function ip_in_lan(value, cursor)
	if not valid_ipv4(value) then return false end
	local subnets = get_lan_subnets(cursor)
	if #subnets == 0 then return true end
	local candidate = ipv4_number(value)
	for _, subnet in ipairs(subnets) do
		if ipv4_number(subnet.address) == candidate then return false end
	end
	for _, subnet in ipairs(subnets) do
		if subnet_contains(subnet.address, subnet.mask, value) then return true end
	end
	return false
end

function get_bindings(cursor, include_disabled)
	cursor = cursor or api.uci
	local bindings, errors = {}, {}
	local macs, ips = {}, {}
	cursor:foreach(api.c_config, "acl_rule", function(section)
		if section.bind_enable == "1" and (include_disabled or section.enabled == "1") then
			local id = section[".name"]
			local mac = normalize_mac(section.bind_mac)
			local ip = normalize_ipv4(section.bind_ip)
			if not mac then
				errors[#errors + 1] = string.format("%s: invalid MAC address", id)
			elseif not ip then
				errors[#errors + 1] = string.format("%s: invalid IPv4 address", id)
			elseif not ip_in_lan(ip, cursor) then
				errors[#errors + 1] = string.format("%s: IPv4 address is not usable in the selected LAN firewall zones", id)
			elseif macs[mac] and macs[mac] ~= id then
				errors[#errors + 1] = string.format("%s: MAC address is already bound by %s", id, macs[mac])
			elseif ips[ip] and ips[ip] ~= id then
				errors[#errors + 1] = string.format("%s: IPv4 address is already bound by %s", id, ips[ip])
			else
				macs[mac], ips[ip] = id, id
				bindings[#bindings + 1] = {
					id = id,
					mac = mac,
					ip = ip,
					hostname = trim(section.bind_hostname or section.remarks or id),
					interface = trim(section.interface)
				}
			end
		end
	end)
	return bindings, errors
end

function find_dhcp_conflict(mac, ip, cursor)
	cursor = cursor or api.uci
	mac = normalize_mac(mac)
	ip = normalize_ipv4(ip)
	if not mac or not ip then return nil end
	local conflict
	cursor:foreach("dhcp", "host", function(section)
		if not conflict and section[DHCP_MARKER] ~= "1" then
			local host_ip = normalize_ipv4(section.ip)
			for _, mac_value in ipairs(list_values(section.mac)) do
				local host_mac = normalize_mac(mac_value)
				if host_mac and (host_mac == mac or host_ip == ip) and not (host_mac == mac and host_ip == ip) then
					conflict = section.name or section[".name"]
					break
				end
			end
		end
	end)
	return conflict
end

local function safe_hostname(value, fallback)
	value = trim(value):gsub("[^A-Za-z0-9_.-]", "-"):gsub("%-+", "-")
	value = value:gsub("^[.-]+", ""):gsub("[.-]+$", "")
	return value ~= "" and value:sub(1, 63) or fallback
end

local function set_if_changed(cursor, config, section, option, value)
	if cursor:get(config, section, option) ~= value then
		cursor:set(config, section, option, value)
		return true
	end
	return false
end

local function managed_section(cursor, acl_id)
	local found
	cursor:foreach("dhcp", "host", function(section)
		if not found and section[DHCP_MARKER] == "1" and section[DHCP_ACL] == acl_id then
			found = section[".name"]
		end
	end)
	if found then return found end

	local base = "passwall_" .. acl_id:gsub("[^A-Za-z0-9_]", "_")
	local section, suffix = base, 0
	while cursor:get("dhcp", section) do
		suffix = suffix + 1
		section = base .. "_" .. suffix
	end
	return section
end

function sync_dhcp()
	local cursor = require "luci.model.uci".cursor()
	local bindings, errors = get_bindings(cursor, false)
	local changed_passwall, changed_dhcp = false, false
	local desired, user_hosts = {}, {}

	cursor:foreach("dhcp", "host", function(section)
		if section[DHCP_MARKER] ~= "1" then
			local ip = normalize_ipv4(section.ip)
			for _, mac_value in ipairs(list_values(section.mac)) do
				local mac = normalize_mac(mac_value)
				if mac then user_hosts[#user_hosts + 1] = { mac = mac, ip = ip } end
			end
		end
	end)

	for _, binding in ipairs(bindings) do
		local conflict, existing = false, false
		for _, host in ipairs(user_hosts) do
			if host.mac == binding.mac or host.ip == binding.ip then
				if host.mac == binding.mac and host.ip == binding.ip then
					existing = true
				else
					conflict = true
					errors[#errors + 1] = string.format("%s: DHCP reservation conflicts with an existing host", binding.id)
				end
			end
		end

		if cursor:get(api.c_config, binding.id, "bind_mac") ~= binding.mac then
			cursor:set(api.c_config, binding.id, "bind_mac", binding.mac)
			changed_passwall = true
		end
		if cursor:get(api.c_config, binding.id, "bind_ip") ~= binding.ip then
			cursor:set(api.c_config, binding.id, "bind_ip", binding.ip)
			changed_passwall = true
		end
		local sources = binding.mac .. " " .. binding.ip
		if cursor:get(api.c_config, binding.id, "sources") ~= sources then
			cursor:set(api.c_config, binding.id, "sources", sources)
			changed_passwall = true
		end

		if not conflict and not existing then
			local section = managed_section(cursor, binding.id)
			desired[section] = true
			if cursor:get("dhcp", section) ~= "host" then
				cursor:set("dhcp", section, "host")
				changed_dhcp = true
			end
			changed_dhcp = set_if_changed(cursor, "dhcp", section, "name", safe_hostname(binding.hostname, binding.id)) or changed_dhcp
			changed_dhcp = set_if_changed(cursor, "dhcp", section, "mac", binding.mac) or changed_dhcp
			changed_dhcp = set_if_changed(cursor, "dhcp", section, "ip", binding.ip) or changed_dhcp
			changed_dhcp = set_if_changed(cursor, "dhcp", section, "leasetime", "infinite") or changed_dhcp
			changed_dhcp = set_if_changed(cursor, "dhcp", section, DHCP_MARKER, "1") or changed_dhcp
			changed_dhcp = set_if_changed(cursor, "dhcp", section, DHCP_ACL, binding.id) or changed_dhcp
		end
	end

	local stale = {}
	cursor:foreach("dhcp", "host", function(section)
		local id = section[".name"]
		if section[DHCP_MARKER] == "1" and not desired[id] then
			stale[#stale + 1] = id
		end
	end)
	for _, id in ipairs(stale) do
		cursor:delete("dhcp", id)
		changed_dhcp = true
	end

	if changed_passwall then
		cursor:save(api.c_config)
		cursor:commit(api.c_config)
	end
	if changed_dhcp then
		cursor:save("dhcp")
		cursor:commit("dhcp")
		api.sys.call("/etc/init.d/dnsmasq reload >/dev/null 2>&1")
	end
	for _, message in ipairs(errors) do api.log("Device policy:", message) end
	return #errors == 0, errors
end
