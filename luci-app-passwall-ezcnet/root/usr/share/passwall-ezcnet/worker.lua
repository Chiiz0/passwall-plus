#!/usr/bin/lua
local C=dofile('/usr/share/passwall-ezcnet/common.lua')
local catalog=dofile('/usr/share/passwall-ezcnet/catalog.lua')
local workerlock=C.lock('/var/lock/passwall_ezcnet_worker.lock')
if not workerlock then os.exit(0) end
local command=C.load(C.runtime..'/job.json')
C.fs.remove(C.runtime..'/job.json')
if not command then os.exit(0) end
local check=C.check
local journal={id=command.id,kind=command.kind,phase='preparing',old_revision=C.hash(C.config),local_job=command.local_job}
local function progress(stage,current,total) C.save(C.runtime..'/progress.json',{id=command.id,stage=stage,current=current or 0,total=total or 0}) end
local function finish(status,message,data) C.finish(journal,status,message,data) end
local native_lock
local function unlock() if native_lock then native_lock:close();native_lock=nil end end
local ok,err=pcall(function()
 check(type(command.id)=='string' and #command.id==32 and command.id:match('^[a-f0-9]+$'),'invalid_command')
 check(type(command.expires)=='number' and command.expires>os.time(),'expired')
 check(journal.old_revision==command.expected_revision,'config_conflict')
 native_lock=C.lock('/var/lock/passwall_sub_rule.lock');check(native_lock~=nil,'native_update_busy')
 check(C.read('/tmp/.uci/passwall')=='','local_uncommitted_changes')
 progress('starting');C.save(C.persist..'/pending.json',journal)
 local c,stage=C.stage();local out
 local p=dofile('/usr/share/passwall-ezcnet/protocol.lua')
 if command.kind=='catalog' then
  local op=command.operation;check(type(op)=='table','invalid_operation')
  if op.action=='nodes.test' then return finish('applied','node_tests_complete',catalog.test(c,op,progress)) end
  if op.action=='preview.apply' then catalog.consume(op.token,journal.old_revision,stage)
  else
   out=catalog.prepare(c,op,progress)
   if op.action=='subscription.preview' or op.action=='nodes.preview' or op.action=='openvpn.preview' or (op.action=='subscription.update' and not command.local_job) then
    check(C.hash(C.config)==journal.old_revision,'config_conflict')
    return finish('ready','preview_ready',catalog.preview(stage,journal.old_revision,out))
   end
  end
 else
  local valid,reason=p.validate(command,c,journal.old_revision,os.time());check(valid,reason)
  if command.kind=='restart' then unlock();progress('restarting');local restarted=C.restart();return finish(restarted and 'applied' or 'failed',restarted and 'service_restarted' or 'service_restart_failed') end
  p.apply(c,C.global(c),command.config)
 end
 progress('applying');check(C.hash(C.config)==journal.old_revision,'config_conflict');check(C.read('/tmp/.uci/passwall')=='','local_uncommitted_changes')
 journal.new_revision=C.hash(stage);journal.phase='executing'
 C.write(C.persist..'/rollback',C.read(C.config));C.save(C.persist..'/pending.json',journal)
 C.write(C.config,C.read(stage));unlock();progress('restarting')
 if not C.restart() then return C.rollback(journal) end
 if command.local_job then return finish('applied','scheduled_update_applied',out) end
 journal.phase='awaiting_ack';journal.deadline=os.time()+90
 journal.result={id=journal.id,status='applied',message='config_applied_service_restarted',data=out}
 C.save(C.persist..'/pending.json',journal)
end)
if not ok then
 unlock()
 if journal.phase=='executing' then C.rollback(journal)
 else
  -- Exception details can include provider content; expose only our fixed error codes.
  local message=tostring(err);if not message:match('^[a-z_]+$') then message='operation_failed' end
  finish('failed',message)
 end
end
for _,file in ipairs({'progress.json','stage/passwall','stage/delta/passwall','download.conf','download','download.headers','openvpn.input','openvpn.clean'}) do C.fs.remove(C.runtime..'/'..file) end
if native_lock then native_lock:close() end
workerlock:close()
