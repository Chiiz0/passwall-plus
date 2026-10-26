-- This whitelist is deliberately independent from the server's validation.
local M = {}
M.defaults = {
	enabled = "0", node = "", tcp_proxy_mode = "proxy", udp_proxy_mode = "proxy",
	localhost_proxy = "1", client_proxy = "1", openvpn_global_allow_lan = "1", acl_enable = "0"
}

function M.config(cursor, section)
	local result = {}
	for key, default in pairs(M.defaults) do result[key] = cursor:get("passwall", section, key) or default end
	return result
end

function M.validate(command, cursor, revision, now)
	if type(command) ~= "table" or type(command.id) ~= "string" or not command.id:match("^[a-f0-9]+$") or #command.id ~= 32 then
		return nil, "invalid_command"
	end
	if command.kind ~= "config" and command.kind ~= "restart" then return nil, "unsupported_action" end
	if type(command.expires) ~= "number" or command.expires <= now then return nil, "expired" end
	if command.expected_revision ~= revision then return nil, "config_conflict" end
	if command.kind == "restart" then return true end
	if type(command.config) ~= "table" then return nil, "invalid_config" end
	for key, value in pairs(command.config) do
		if M.defaults[key] == nil or type(value) ~= "string" then return nil, "unsupported_field" end
	end
	for key in pairs(M.defaults) do
		local value = command.config[key]
		if key == "node" then
			if type(value) ~= "string" or #value > 64 or (value ~= "" and not value:match("^[%w_-]+$")) then return nil, "invalid_node" end
			if value ~= "" and cursor:get("passwall", value) ~= "nodes" then return nil, "node_missing" end
		elseif key == "tcp_proxy_mode" or key == "udp_proxy_mode" then
			if value ~= "disable" and value ~= "proxy" then return nil, "invalid_mode" end
		elseif value ~= "0" and value ~= "1" then return nil, "invalid_flag" end
	end
	if command.config.enabled == "1" and command.config.node == "" then return nil, "node_required" end
	return true
end

function M.apply(cursor, section, config)
	for key, value in pairs(config) do assert(cursor:set("passwall", section, key, value)) end
	-- Match the native PassWall node switch behavior for Xray/Sing-box shunts.
	if config.node ~= "" and cursor:get("passwall", config.node, "protocol") == "_shunt" then
		local dns_key = cursor:get("passwall", section, "dns_shunt") == "smartdns" and "smartdns_dns_mode" or "dns_mode"
		local mode = cursor:get("passwall", config.node, "type") == "Xray" and "xray" or "sing-box"
		assert(cursor:set("passwall", section, dns_key, mode))
		assert(cursor:set("passwall", section, "v2ray_dns_mode", "tcp"))
	end
	assert(cursor:commit("passwall"))
end

return M
