-- Run in a disposable guest. Generate and validate configs without connecting.
arg = {}
local api = require 'luci.passwall.api'
local xray = require 'luci.passwall.util_xray'
local singbox = require 'luci.passwall.util_sing-box'
local saved_get = api.uci_get_c
local fixture
api.uci_get_c = function(section, option)
	if section == 'member' or section == 'member_long' then
		return {['.type']='nodes', ['.name']=section, type=fixture.type, remarks=section, protocol='socks',
			address='127.0.0.1', port=section == 'member' and '11080' or '11081'}
	end
	if section == 'qa_upstream' then
		local copy = api.jsonc.parse(api.jsonc.stringify(fixture))
		return option and copy[option] or copy
	end
	return saved_get(section, option)
end
local function generate(core, node, verify)
	fixture = node
	fixture['.name'], fixture['.type'] = 'qa_upstream', 'nodes'
	fixture.type = core == xray and 'Xray' or 'sing-box'
	local raw = core.gen_config({flag='qa-upstream', node='qa_upstream', local_socks_address='127.0.0.1', local_socks_port='18990', no_run=true})
	local data = assert(api.jsonc.parse(raw))
	if verify then
		local path = '/tmp/qa-upstream-config.json'
		assert(api.fs.writefile(path, raw))
		local binary = core == xray and 'xray run -test -config ' or 'sing-box check -c '
		local status, output = api.exec_call(binary .. path)
		api.fs.remove(path)
		assert(status == 0, output)
	end
	return data
end
local uuid = '11111111-2222-4333-8444-555555555555'
local ws = generate(singbox, {protocol='vless', address='192.0.2.1', port='443', uuid=uuid, transport='ws',
	ws_path='/socket?foo=a%3Db&ed=2048&eh=X-ED&bar=x%2Fy'}, true)
local outbound = ws.outbounds[1]
assert(outbound.transport.path == '/socket?foo=a%3Db&bar=x%2Fy')
assert(outbound.transport.max_early_data == 2048 and outbound.transport.early_data_header_name == 'X-ED')

for _, interval in ipairs({'1', '4-8', 'invalid'}) do
	local config = generate(xray, {protocol='hysteria', transport='hysteria', address='192.0.2.1', port='443',
		tls='1', tls_serverName='example.net', hysteria2_auth_password='synthetic', hysteria2_hop='2000:2010', hysteria2_hop_interval=interval}, true)
	local stream = config.outbounds[1].streamSettings
	local hop = stream.finalmask.udp[1]
	assert(hop.type == 'udphop' and hop.settings.remotePorts == '2000-2010')
		assert(tostring(hop.settings.interval) == ({['1']='30', ['4-8']='5-8', invalid='30'})[interval])
	assert(not stream.hysteriaSettings.udpHop)
end

local raw = generate(xray, {protocol='vless', address='192.0.2.1', port='443', uuid=uuid,
	tls='1', tls_serverName='up.example', transport='raw', tcp_guise='http', tcp_guise_http_host='single.example', tcp_guise_http_path='/old'}, true)
local request = raw.outbounds[1].streamSettings.rawSettings.header.request
assert(request.path[1] == '/old' and request.headers.Host[1] == 'single.example')
for _, options in ipairs({{}, {domainStrategy='UseIPv6', mark=42}}) do
	local extra = {downloadSettings={address='down.example', port=443, network='xhttp', sockopt=options}}
	local config = generate(xray, {protocol='vless', address='UP.example', port='443', uuid=uuid,
		tls='1', tls_serverName='up.example', transport='xhttp', xhttp_mode='stream-up', download_address='DOWN.example',
		domain_resolver='udp', domain_resolver_dns='192.0.2.53', domain_strategy='UseIPv4',
		xhttp_extra=api.base64Encode(api.jsonc.stringify(extra))}, true)
	local sockopt = config.outbounds[1].streamSettings.xhttpSettings.extra.downloadSettings.sockopt
	assert(sockopt.domainStrategy == (options.domainStrategy or 'UseIPv4') and sockopt.mark == (options.mark or 255))
	local found = {}
	for _, server in ipairs(config.dns.servers) do
		if type(server) == 'table' and server.address == '192.0.2.53' then
			for _, domain in ipairs(server.domains) do found[domain] = true end
		end
	end
	assert(found['full:up.example'] and found['full:down.example'])
end

for _, core in ipairs({xray, singbox}) do
	local group = core == xray and {protocol='_balancing'} or {protocol='_urltest'}
	local field = core == xray and 'balancing_node' or 'urltest_node'
	group[field] = {'member_long', 'member', 'member_long'}
	local config = generate(core, group, true)
	local members
	if core == xray then
		members = config.routing.balancers[1].selector
	else
		for _, outbound in ipairs(config.outbounds) do
			if outbound.type == 'urltest' then members = outbound.outbounds end
		end
	end
	assert(members and #members == 2 and members[1] ~= members[2], 'group members with overlapping IDs must stay distinct')
end

local key = api.base64Encode(string.rep('a', 32))
for _, core in ipairs({xray, singbox}) do
	local config = generate(core, {protocol='wireguard', address='2001:db8::1', port='51820',
		wireguard_secret_key=key, wireguard_public_key=key, wireguard_local_address={'10.200.0.2/32'},
		wireguard_reserved='1,2,3', wireguard_keepAlive='25', wireguard_mtu='1280'},
		true)
	if core == xray then
		assert(config.outbounds[1].settings.peers[1].endpoint == '[2001:db8::1]:51820')
	else
		assert(config.endpoints[1].type == 'wireguard')
		assert(config.endpoints[1].peers[1].persistent_keepalive_interval == 25)
		assert(config.endpoints[1].peers[1].address == '2001:db8::1')
	end
end
api.uci_get_c = saved_get
print('PASS generated core configs: WebSocket query preservation, Hysteria2 hopping, IPv6 WireGuard, RAW HTTP and XHTTP download DNS')
