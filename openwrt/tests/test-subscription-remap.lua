-- Run the subscription writer against a separate real UCI package in a disposable VM.
local api = require 'luci.passwall.api'
local name = 'qa_subscription_' .. api.gen_random_char()
local feed = '/tmp/' .. name
local config = '/etc/config/' .. name
api.c_config = name
assert(api.fs.writefile(config, "config global 'global'\nconfig subscribe_list 'feed'\n option remark 'QA'\n option url '" .. feed .. "'\n"))
local sys = require 'luci.sys'
local call = sys.call
sys.call = function(cmd)
	if cmd:match('^/etc/init.d/passwall restart') then return 0 end
	return call(cmd)
end
local function refresh(rows)
	local links = {}
	for _, row in ipairs(rows) do
		links[#links+1] = 'socks5://' .. row[2] .. ':1080#' .. row[1]
	end
	assert(api.fs.writefile(feed, table.concat(links, '\n') .. '\n'))
	arg = {'start', 'feed', 'manual'}
	assert(loadfile('/usr/share/passwall/subscribe.lua'))()
end
local function id(remarks)
	local found
	api.uci_foreach_c('nodes', function(node)
		if node.remarks == remarks then found = node['.name'] end
	end)
	return assert(found, 'missing ' .. remarks)
end
local function test()
	local address = '192.0.2.1'
	refresh({{'A', address}, {'B', address}})
	api.uci_set_c('global', 'node', id('A'))
	api.uci_set_c('global', 'backup_node', id('B'))
	api.uci_save_c(true)
	-- The standby's exact match comes first in the new subscription.
	refresh({{'B', address}, {'C', address}})
	assert(api.uci_get_c('global', 'node') == id('C'))
	assert(api.uci_get_c('global', 'backup_node') == id('B'))
	for _, backend in ipairs({{'ha1', '1180', 'C'}, {'ha2', '1180', 'B'}, {'ha3', '1181', 'C'}}) do
		api.uci:section(name, 'haproxy_config', backend[1], {haproxy_port=backend[2], lbss=id(backend[3])})
	end
	api.uci_save_c(true)
	-- Both nodes are renamed: two weak matches must still produce two live IDs.
	refresh({{'D', address}, {'E', address}})
	assert(api.uci_get_c('global', 'node') == id('D'))
	assert(api.uci_get_c('global', 'backup_node') == id('E'))
	local ha1, ha2 = api.uci_get_c('ha1', 'lbss'), api.uci_get_c('ha2', 'lbss')
	assert(ha1 and ha2 and ha1 ~= ha2 and api.uci_get_c(ha1) and api.uci_get_c(ha2))
	refresh({{'F', address}})
	assert(api.uci_get_c('global', 'node') == id('F'))
	assert(api.uci_get_c('ha1', 'lbss') == id('F') and not api.uci_get_c('ha2'))
	assert(api.uci_get_c('ha3', 'lbss') == id('F'))
	assert(not api.uci_get_c('global', 'backup_node'))
	-- No identity or endpoint match. Use a node from the refreshed inventory.
	refresh({{'G', '192.0.2.2'}})
	assert(api.uci_get_c('global', 'node') == id('G'))
	assert(not api.uci_get_c('global', 'backup_node'))
end
local ok, err = xpcall(test, debug.traceback)
api.uci:revert(name)
api.fs.remove(config)
api.fs.remove(feed)
assert(ok, err)
print('PASS subscription remapping preserves distinct primary/standby and HAProxy backend references')
