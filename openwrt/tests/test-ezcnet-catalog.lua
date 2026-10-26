-- Run inside a disposable OpenWrt VM with the real plugin installed.
local C=dofile('/usr/share/passwall-ezcnet/common.lua')
local M=dofile('/usr/share/passwall-ezcnet/catalog.lua')
local dir='/tmp/ezcnet-catalog-unit';C.fs.mkdir(dir,'700');C.fs.mkdir(dir..'/delta','700')
C.write(dir..'/passwall',[[
config global 'global'
 option node 'a'
config nodes 'a'
 option type 'Xray'
 option protocol 'vless'
 option remarks 'A'
config nodes 'b'
 option type 'Xray'
 option protocol 'vless'
 option remarks 'B'
config nodes 'c'
 option type 'OpenVPN'
 option preproxy_node 'a'
config nodes 'shunt'
 option protocol '_shunt'
 option type 'Xray'
 option rule1 'a'
 option default_node 'a'
config shunt_rules 'rule1'
config nodes 'balancer'
 option protocol '_balancing'
 list balancing_node 'a'
 list balancing_node 'b'
 option fallback_node 'a'
config nodes 'urltest'
 option protocol '_urltest'
 list urltest_node 'a'
config socks 'socks1'
 option node 'a'
 list autoswitch_backup_node 'a'
config haproxy_config 'haproxy'
 option lbss 'a'
config acl_rule 'acl'
 option node 'a'
]])
local function cursor() C.fs.remove(dir..'/delta/passwall');return C.uci.cursor(dir,dir..'/delta') end
local c=cursor();assert(#M.references(c).a==11)
local ok,err=pcall(M.prepare,c,{action='nodes.delete',ids={'a'}},function() end);assert(not ok and err=='node_in_use')
c=cursor();M.prepare(c,{action='nodes.delete',ids={'a'},replacement='b'},function() end)
c=cursor();assert(c:get('passwall','global','node')=='b');assert(c:get('passwall','c','preproxy_node')=='b');assert(c:get('passwall','shunt','rule1')=='b');assert(#c:get('passwall','balancer','balancing_node')==1);assert(c:get('passwall','a')==nil)
c:set('passwall','b','to_node','c');c:commit('passwall')
ok,err=pcall(M.prepare,c,{action='nodes.edit',id='b',name='B changed',group='test'},function() end);assert(not ok and err=='reference_cycle')
print('PASS all reference fields, list de-duplication, OpenVPN preproxy and cycle protection')
