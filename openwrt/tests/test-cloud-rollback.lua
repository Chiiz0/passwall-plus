-- Disposable guest only: exercise cloud rollback with real libuci and locks.
local C=dofile('/usr/share/passwall-ezcnet/common.lua')
local T=require'luci.passwall.config_transaction'
local fs=require'nixio.fs'
local originals={}
for _,path in ipairs({C.config,C.persist..'/rollback',C.persist..'/pending.json'}) do originals[path]=fs.readfile(path) or false end
local function restore()
 for path,data in pairs(originals) do if data==false then fs.remove(path) else assert(fs.writefile(path,data)) end end
end
local ok,err=pcall(function()
 local old=C.read(C.config)
 local cursor=require('uci').cursor()
 cursor:set('passwall','@global[0]','cloud_transaction_test','candidate');cursor:set('passwall','@global[0]','flush_set','1');assert(cursor:commit('passwall'))
 local journal={id=string.rep('b',32)}
 C.write(C.persist..'/rollback',old);journal.old_revision=C.hash(C.persist..'/rollback')
 journal.new_revision=C.hash(C.config);journal.new_digest=C.config_digest(C.config)
 -- A restart can normalize formatting and add the DNS runtime marker.
 assert(T.run(function()
  local c=require('uci').cursor();c:set('passwall','@global[0]','dnsmasq_dns_redirect','1');c:delete('passwall','@global[0]','flush_set');T.commit(c,'passwall')
 end))
 assert(C.hash(C.config)~=journal.new_revision)
 assert(C.config_digest(C.config)==journal.new_digest)
 local restarted=false;C.restart=function() restarted=true;return true end
 C.rollback(journal)
 assert(restarted and C.read(C.config)==old)
 assert(C.load(C.persist..'/pending.json').result.status=='rolled_back')
 -- A real local change must still prevent cloud rollback.
 cursor=require('uci').cursor();cursor:set('passwall','@global[0]','cloud_transaction_test','local-newer');assert(cursor:commit('passwall'))
 local newer=C.read(C.config);restarted=false
 C.rollback(journal)
 assert(not restarted and C.read(C.config)==newer)
 assert(C.load(C.persist..'/pending.json').result.message=='local_config_changed_rollback_skipped')
end)
restore()
if not ok then error(err) end
print('PASS cloud rollback after runtime normalization; later local changes preserved')
