if not api.is_finded("openvpn") then
	return
end

local m, s1 = ...
local type_name = "OpenVPN"

s1.fields["type"]:value(type_name, type_name)

if s1.val["type"] ~= type_name then
	return
end

local s = NamedSection(m, arg[1], "tmp_" .. s1.sectiontype)
s.parent = s1
s.type_name = type_name
s.option_prefix = "openvpn_"
api.set_type_cbi(s)

o = s:option(TextValue, "config", translate("OpenVPN client profile"), translate("Paste the complete .ovpn client profile. PassWall removes profile directives that can execute commands or change system routing."))
o.rows = 16
o.wrap = "off"
o.rmempty = false
o.validate = function(self, value)
	value = api.trim(value or "")
	if value == "" then
		return nil, translate("OpenVPN client profile is required.")
	end
	if #value > 131072 then
		return nil, translate("OpenVPN client profile must not exceed 128 KiB.")
	end
	if value:find("%z") then
		return nil, translate("OpenVPN client profile contains invalid data.")
	end
	local lower = "\n" .. value:lower()
	if not lower:match("\n%s*remote%s+") and not lower:match("\n%s*%-%-remote%s+") then
		return nil, translate("OpenVPN client profile must contain a remote directive.")
	end
	return value
end

o = s:option(Value, "username", translate("Username"), translate("Leave both username and password empty for certificate-only authentication."))
o.validate = function(self, value, section)
	local password = s.fields["password"]:formvalue(section) or m:get(section, "password") or ""
	if (value == "") ~= (password == "") then
		return nil, translate("OpenVPN username and password must be configured together.")
	end
	return value
end

o = s:option(Value, "password", translate("Password"))
o.password = true
o.validate = function(self, value, section)
	local username = s.fields["username"]:formvalue(section) or m:get(section, "username") or ""
	if (value == "") ~= (username == "") then
		return nil, translate("OpenVPN username and password must be configured together.")
	end
	return value
end

o = s:option(Value, "vpn_dns", translate("OpenVPN DNS server"), translate("All TCP and UDP port 53 traffic from devices assigned to this node is forced to this IPv4 DNS server through the tunnel."))
o.datatype = "ip4addr"
o.default = "1.1.1.1"
o.rmempty = false

o = s:option(ListValue, "preproxy_node", translate("Pre-proxy node"), translate("Optionally connect OpenVPN through a local SOCKS endpoint backed by an Xray or Sing-box node. The OpenVPN server endpoint must support TCP."))
o:value("", translate("Direct Connection"))
for _, node in ipairs(api.get_valid_nodes()) do
	if node.node_type == "normal" and (node.type == "Xray" or node.type == "sing-box") then
		o:value(node.id, node.remark)
	end
end
o.validate = function(self, value)
	if value == "" then return value end
	for _, node in ipairs(api.get_valid_nodes()) do
		if node.id == value and node.node_type == "normal" and (node.type == "Xray" or node.type == "sing-box") then
			return value
		end
	end
	return nil, translate("The OpenVPN pre-proxy must be a normal Xray or Sing-box node.")
end

api.type_cbi_section(s1, s)
