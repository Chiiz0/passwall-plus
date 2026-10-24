local api = require "luci.passwall.api"

api.set_default_cbi()

m = Map()

s = m:section(NamedSection, "@global[0]", "global", translate("ACLs"), "<font color='red'>" .. translate("ACLs is a tools which used to designate specific IP proxy mode.") .. "</font>")

o = s:option(Flag, "acl_enable", translate("Main switch"))
o.rmempty = false
o.default = false

o = s:option(Flag, "reject_ipv6", translate("Reject IPv6"), translate("Reject all IPv6 traffic originating from the selected LAN firewall zones."))
o.rmempty = false
o.default = "1"

o = s:option(DynamicList, "ipv6_reject_zones", translate("IPv6 reject source zones"))
o:value("lan", "lan")
api.uci:foreach("firewall", "zone", function(zone)
	if zone.name and zone.name ~= "lan" then o:value(zone.name, zone.name) end
end)
o.default = { "lan" }
o:depends("reject_ipv6", "1")
o.validate = function(self, value)
	local values = type(value) == "table" and value or { value }
	for _, zone in ipairs(values) do
		if not zone:match("^[A-Za-z0-9][A-Za-z0-9_.-]*$") then
			return nil, translate("Invalid firewall zone name")
		end
	end
	return value
end

-- [[ ACLs Settings ]]--
s = m:section(TypedSection, "acl_rule")
s.template = "cbi/tblsection"
s.sortable = true
s.anonymous = true
s.addremove = true
s.extedit = api.url("acl_config", "%s")
function s.create(e, t)
	local uid = "acl_" .. api.gen_random_char(5)
	TypedSection.create(e, uid)
	luci.http.redirect(e.extedit:format(uid))
end
function s.remove(e, t)
	api.remove(api.CACHE_PATH .. "/dnsmasq_" .. t .. "*")
	TypedSection.remove(e, t)
end

---- Enable
o = s:option(Flag, "enabled", translate("Enable"))
o.default = 1
o.rmempty = false

---- Remarks
o = s:option(Value, "remarks", translate("Remarks"))
o.rmempty = true

local mac_t = {}
api.sys.net.mac_hints(function(e, t)
	mac_t[e] = {
		ip = t,
		mac = e
	}
end)

local node_remarks = {}
for _, node in ipairs(api.get_valid_nodes()) do
	node_remarks[node.id] = node.remark
end

i = s:option(DummyValue, "interface", translate("Source Interface"))
i.cfgvalue = function(t, n)
	local v = Value.cfgvalue(t, n) or ''
	if v == "" then
		return translate("All")
	end
	return v
end

o = s:option(DummyValue, "sources", translate("Source"))
o.rawhtml = true
o.cfgvalue = function(t, n)
	local e = ''
	local v = Value.cfgvalue(t, n) or '-'
	string.gsub(v, '[^' .. " " .. ']+', function(w)
		local a = w
		if mac_t[w] then
			a = a .. ' (' .. mac_t[w].ip .. ')'
		end
		if #e > 0 then
			e = e .. "<br />"
		end
		e = e .. a
	end)
	return e
end

o = s:option(DummyValue, "binding", translate("IP/MAC Binding"))
o.rawhtml = true
o.cfgvalue = function(t, n)
	if m:get(n, "bind_enable") ~= "1" then
		return "-"
	end
	local mac = m:get(n, "bind_mac") or "-"
	local ip = m:get(n, "bind_ip") or "-"
	local hostname = m:get(n, "bind_hostname")
	local value = api.util.pcdata(mac) .. "<br />" .. api.util.pcdata(ip)
	if hostname and hostname ~= "" then
		value = api.util.pcdata(hostname) .. "<br />" .. value
	end
	return value
end

i = s:option(DummyValue, "mode", translate("Mode"))
i.cfgvalue = function(t, n)
	local v = Value.cfgvalue(t, n) or '0'
	if v == "1" then
		if m:get(n, "use_global_config") == "1" then
			return translate("Use global config")
		end
		local node = m:get(n, "node")
		return node_remarks[node] or translate("Proxy")
	end
	return translate("No Proxy")
end

m:appendTemplate("/cbi/sortable", {sectiontype = s.sectiontype})

return api.return_map(m)
