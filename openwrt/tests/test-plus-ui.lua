-- Run from the repository root with Lua 5.1. No router or real credentials needed.
local profile = dofile('luci-app-passwall/luasrc/passwall/openvpn_profile.lua')
assert(profile.validate('\239\187\191client\r\nremote vpn.example.test 1194\r\n') == 'client\nremote vpn.example.test 1194')
assert(profile.validate('client\n<connection>\nremote 192.0.2.1 443 tcp\n</connection>'))
assert(not profile.validate('# remote fake 1194\n<key>\nremote hidden 1194\n</key>'))
assert(not profile.validate('client\nremote 2001:db8::1 1194'))
assert(not profile.validate('remote vpn.test\n\0'))
assert(not profile.validate('remote vpn.test\n' .. string.rep('a', 131072)))
local overview = dofile('luci-app-passwall/luasrc/passwall/overview.lua')
local global = {enabled='0', acl_enable='1', node='vpn', switch_guard='1'}
local sections = {
 nodes = {
  {['.name']='vpn', type='OpenVPN', remarks='<img src=x onerror=alert(1)>', config='PRIVATE_KEY', password='SECRET', username='SECRET_USER'},
  {['.name']='proxy', type='Xray', remarks='Proxy', address='private.example', password='SECRET'},
  {['.name']='../escape', type='OpenVPN'}
 },
 acl_rule = {
  {['.name']='device', enabled='1', mode='1', node='vpn', bind_enable='1', bind_ip='10.0.0.5', bind_mac='02:00:00:00:00:05'},
  {['.name']='draft', enabled='0', mode='1', node='proxy'},
  {['.name']='direct', enabled='1', mode='0'}
 }
}
local root = '/tmp/etc/passwall'
local files = {
 [root .. '/openvpn/nodes/vpn'] = '',
 [root .. '/openvpn/nodes/vpn/dev'] = 'pswov1\n',
 [root .. '/openvpn/nodes/vpn/table'] = '20001\n',
 [root .. '/openvpn/nodes/vpn/openvpn.pid'] = '123\n',
 ['/proc/123/cmdline'] = '/tmp/etc/passwall/bin/openvpn_vpn\0--config\0' .. root .. '/openvpn/nodes/vpn/client.conf\0',
 [root .. '/start_complete']='', [root .. '/firewall_ready']='',
 [root .. '/acl/device/source_list']='ip:10.0.0.5',
 ['/tmp/dhcp.leases']='2000 02:00:00:00:00:05 10.0.0.9 device *\n999 02:00:00:00:00:06 10.0.0.6 expired *\n0 02:00:00:00:00:07 10.0.0.7 permanent *\n',
 [root .. '/var']="ACL_GLOBAL_node='proxy'\n"
}
local routes = 'default dev pswov1 table 20001 metric 10\nunreachable default table 20002 metric 42760\n'
local env = {now=1000, openvpn_installed=true,
 uci={get_all=function() return global end, foreach=function(_, _, kind, fn) for _, s in ipairs(sections[kind]) do fn(s) end end},
 read=function(path) assert(not path:find('%.%./')); return files[path] or '' end,
 exists=function(path) return files[path] ~= nil end,
 exec=function(cmd) assert(cmd == 'timeout 2 ip -4 route show table all 2>/dev/null'); return routes end
}
local status = overview.collect(env)
assert(status.counts.nodes == 2 and status.counts.rules == 3 and status.counts.enabled == 2)
assert(status.counts.tunnels == 1 and status.vpns[1].status == 'tunnel_up')
assert(status.devices[1].state == 'loaded' and status.devices[2].state == 'disabled')
assert(status.devices[1].lease and not status.devices[1].lease_matches)
assert(#status.leases == 2 and status.global.runtime_node.id == 'proxy' and status.global.node.id == 'vpn')
assert(status.global.node ~= status.nodes[1] and status.devices[1].node ~= status.nodes[1])
assert(status.devices[1].lease ~= status.leases[1])
local function scan(t)
 for k,v in pairs(t) do
  assert(k ~= 'password' and k ~= 'config' and k ~= 'username' and k ~= 'address')
  if type(v) == 'table' then scan(v) elseif type(v) == 'string' then assert(not v:find('SECRET') and not v:find('PRIVATE_KEY')) end
 end
end
scan(status)
-- A process without its own default route is connecting, never connected.
routes = 'unreachable default table 20001 metric 42760\ndefault dev pswov1 table 20002\n'
assert(overview.collect(env).vpns[1].status == 'connecting')
-- Reused PIDs and stale runtime directories must not look connected.
files['/proc/123/cmdline'] = '/bin/sleep\0'
assert(overview.collect(env).vpns[1].status == 'not_running')
files['/tmp/passwall_switch_guard']='nft\n'
assert(overview.collect(env).devices[1].state == 'guard_pending')
files['/tmp/passwall_switch_guard']=nil
files[root .. '/firewall_error']=''
assert(overview.collect(env).devices[1].state == 'not_applied')
global.acl_enable='0'
assert(overview.collect(env).devices[1].state == 'acl_off')
print('Plus profile and read-only overview tests passed')
