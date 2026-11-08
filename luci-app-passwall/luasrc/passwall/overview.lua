-- Read-only, allowlisted data for the Plus UI. Never return profiles, keys or passwords.
local M = {}
local function trim(v) return (v or ""):gsub("%s+$", "") end
local function safe_id(v) return type(v) == "string" and v:match("^[A-Za-z0-9_+%-]+$") end
local function words(v)
	if type(v) == "table" then return v end
	local result = {}
	for word in (v or ""):gmatch("%S+") do result[#result + 1] = word end
	return result
end
local function bounded_read(path)
	local file = io.open(path, "r")
	if not file then return "" end
	local value = file:read(524288) or ""
	file:close()
	return value
end

function M.collect(env)
	if not env then
		local api = require "luci.passwall.api"
		env = {uci = api.uci, read = bounded_read, exists = api.fs.access,
			exec = api.sys.exec, now = os.time(), openvpn_installed = api.is_finded("openvpn")}
	end
	local read, exists, cursor = env.read, env.exists, env.uci
	local root = "/tmp/etc/passwall"
	local global = cursor:get_all("passwall", "@global[0]") or {}
	local cache = {}
	for key, value in read(root .. "/var"):gmatch("([A-Za-z0-9_]+)=([^\n]*)") do
		cache[key] = value:gsub("^['\"]", ""):gsub("['\"]$", "")
	end
	local routes = env.exec("timeout 2 ip -4 route show table all 2>/dev/null") or ""
	local defaults = {}
	for line in routes:gmatch("[^\n]+") do
		if line:match("^default ") then
			local dev, route_table = line:match(" dev ([%w_.%-]+)"), line:match(" table (%d+)")
			if dev and route_table then defaults[dev .. ":" .. route_table] = true end
		end
	end
	local out = {
		generated_at = env.now, openvpn_installed = not not env.openvpn_installed,
		nodes = {}, vpns = {}, devices = {}, leases = {},
		global = {enabled = global.enabled == "1", acl_enabled = global.acl_enable == "1",
			client_proxy = global.client_proxy ~= "0", localhost_proxy = global.localhost_proxy ~= "0",
			reject_ipv6 = global.reject_ipv6 ~= "0", ipv6_zones = words(global.ipv6_reject_zones or "lan"),
			start_complete = not not exists(root .. "/start_complete"),
			firewall_ready = not not exists(root .. "/firewall_ready"),
			firewall_error = not not exists(root .. "/firewall_error")},
		guard = {enabled = global.switch_guard ~= "0", pending = read("/tmp/passwall_switch_guard") ~= "",
			result = trim(read("/tmp/passwall_switch/result")),
			phase = trim(read("/tmp/passwall_switch/phase")),
			attempts = tonumber(read("/tmp/passwall_switch/attempts")) or 0},
		counts = {rules = 0, enabled = 0, bindings = 0, tunnels = 0, nodes = 0}
	}
	local nodes = {}
	cursor:foreach("passwall", "nodes", function(node)
		local id = node[".name"]
		if not safe_id(id) then return end
		local item = {id = id, name = node.remarks or id, type = node.type or "", protocol = node.protocol or ""}
		nodes[id] = item
		out.nodes[#out.nodes + 1] = item
		out.counts.nodes = out.counts.nodes + 1
		if node.type ~= "OpenVPN" then return end
		local dir = root .. "/openvpn/nodes/" .. id
		local dev = trim(read(dir .. "/dev"))
		local route_table = trim(read(dir .. "/table"))
		local pid = trim(read(dir .. "/openvpn.pid"))
		local cmdline = pid:match("^%d+$") and read("/proc/" .. pid .. "/cmdline") or ""
		local running = cmdline:find("openvpn", 1, true) ~= nil and
			cmdline:find("--config\0" .. dir .. "/client.conf\0", 1, true) ~= nil
		local managed = dev:match("^pswov%d+$") and route_table:match("^%d+$")
		local routed = managed and defaults[dev .. ":" .. route_table] == true
		local status = "unused"
		if exists(dir) then
			status = running and (routed and "tunnel_up" or "connecting") or "not_running"
		end
		local vpn = {id = id, name = item.name, type = item.type, status = status,
			device = managed and dev or "", dns = node.vpn_dns or "1.1.1.1",
			preproxy_id = node.preproxy_node or "", global = global.node == id,
			runtime_global = exists(dir .. "/global") and true or false,
			assignments = 0, rx_bytes = 0, tx_bytes = 0}
		if managed then
			vpn.rx_bytes = tonumber(read("/sys/class/net/" .. dev .. "/statistics/rx_bytes")) or 0
			vpn.tx_bytes = tonumber(read("/sys/class/net/" .. dev .. "/statistics/tx_bytes")) or 0
		end
		if status == "tunnel_up" then out.counts.tunnels = out.counts.tunnels + 1 end
		out.vpns[#out.vpns + 1] = vpn
	end)
	local function node_ref(id)
		local node = nodes[id or ""]
		-- jsonc treats repeated table references as cycles and emits null.
		if node then return {id = node.id, name = node.name, type = node.type, protocol = node.protocol} end
		return {id = id or "", name = id or "", type = "", missing = true}
	end
	out.global.node = node_ref(global.node)
	-- Keep observed runtime selection distinct from the saved configuration.
	out.global.runtime_node = node_ref(cache.ACL_GLOBAL_node)
	out.global.runtime_openvpn = cache.GLOBAL_OPENVPN == "1"
	local vpn_by_id = {}
	for _, vpn in ipairs(out.vpns) do
		vpn.preproxy = node_ref(vpn.preproxy_id)
		vpn_by_id[vpn.id] = vpn
		if vpn.runtime_global then out.global.runtime_node = node_ref(vpn.id) end
	end
	local leases_by_mac = {}
	for line in read("/tmp/dhcp.leases"):gmatch("[^\n]+") do
		local expiry, mac, ip, name = line:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
		if mac and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") and ip:match("^%d+%.%d+%.%d+%.%d+$") and
			(tonumber(expiry) == 0 or tonumber(expiry) > env.now) then
			local lease = {mac = mac:upper(), ip = ip, name = name ~= "*" and name or "", expires = tonumber(expiry)}
			out.leases[#out.leases + 1] = lease
			leases_by_mac[lease.mac] = lease
		end
	end
	cursor:foreach("passwall", "acl_rule", function(rule)
		local id = rule[".name"]
		if not safe_id(id) then return end
		local inherited = rule.use_global_config == "1"
		local node = node_ref(inherited and global.node or rule.node)
		local mode = rule.mode == "1" and (inherited and "global" or "node") or "direct"
		local bound = rule.bind_enable == "1"
		local registered = exists(root .. "/acl/" .. id .. "/source_list")
		local state = "not_applied"
		if not out.global.acl_enabled then state = "acl_off"
		elseif rule.enabled ~= "1" then state = "disabled"
		elseif out.guard.pending then state = "guard_pending"
		elseif out.global.start_complete and out.global.firewall_ready and not out.global.firewall_error and registered then
			state = "loaded"
		end
		local vpn = mode ~= "direct" and vpn_by_id[node.id]
		if vpn and rule.enabled == "1" then vpn.assignments = vpn.assignments + 1 end
		local lease = bound and leases_by_mac[(rule.bind_mac or ""):upper()] or nil
		local item = {id = id, name = rule.remarks or rule.bind_hostname or id, enabled = rule.enabled == "1",
			mode = mode, node = node, bound = bound, mac = rule.bind_mac or "", ip = rule.bind_ip or "",
			hostname = rule.bind_hostname or "", sources = words(rule.sources), interface = rule.interface or "",
			allow_lan = rule.openvpn_allow_lan ~= "0", state = state,
			lease = lease and {mac = lease.mac, ip = lease.ip, name = lease.name, expires = lease.expires} or false,
			lease_matches = lease and lease.ip == rule.bind_ip or false,
			vpn_state = vpn and vpn.status or "", order = #out.devices + 1}
		out.devices[#out.devices + 1] = item
		out.counts.rules = out.counts.rules + 1
		if item.enabled then out.counts.enabled = out.counts.enabled + 1 end
		if bound then out.counts.bindings = out.counts.bindings + 1 end
	end)
	return out
end
return M
