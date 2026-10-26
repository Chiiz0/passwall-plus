local M = {fs=require'nixio.fs', nixio=require'nixio', json=require'luci.jsonc', uci=require'uci'}
M.runtime='/var/run/passwall-ezcnet'
M.persist='/etc/passwall_ezcnet'
M.config='/etc/config/passwall'
for _,p in ipairs({M.runtime,M.persist}) do M.fs.mkdir(p,'700'); M.fs.chmod(p,'700') end
function M.quote(s) return "'"..tostring(s):gsub("'", "'\\''").."'" end
function M.read(p) return M.fs.readfile(p) or '' end
function M.write(p,s)
 local f=assert(M.nixio.open(p..'.new',M.nixio.open_flags('wronly','creat','trunc'),'600'))
 assert(M.fs.chmod(p..'.new','600'))
 local offset=0;while offset<#s do local count=assert(f:write(s,offset));assert(count>0);offset=offset+count end
 assert(f:sync());f:close()
 assert(M.fs.rename(p..'.new',p))
 local dir=M.nixio.open(p:match('^(.*)/[^/]+$'),'r');if dir then dir:sync();dir:close() end
end
function M.encode(v)
 local s=M.json.stringify(v)
 for _,key in ipairs({'nodes','references','subscriptions','local_events','capabilities','discard','keep','issues','probes'}) do s=s:gsub('"'..key..'":%s*{}','"'..key..'":[]') end
 return s
end
function M.save(p,v) M.write(p,M.encode(v)) end
function M.load(p) return M.json.parse(M.read(p)) end
function M.hash(p)
 local f=assert(io.popen('sha256sum '..M.quote(p)..' 2>/dev/null')); local s=f:read('*l') or ''; f:close(); return s:match('^([a-f0-9]+)') or ''
end
function M.id() return M.read('/proc/sys/kernel/random/uuid'):gsub('[^a-f0-9]','') end
function M.cursor(dir)
 dir=dir or '/etc/config'; M.fs.mkdir(M.runtime..'/delta','700')
 return M.uci.cursor(dir,M.runtime..'/delta')
end
function M.global(c) local id; c:foreach('passwall','global',function(s) id=id or s['.name'] end); return assert(id,'global_missing') end
function M.bounded(v,n)
 v=tostring(v or ''); if #v<=n then return v end
 local i=n; while i>0 and v:byte(i)>=128 and v:byte(i)<192 do i=i-1 end
 local b=v:byte(i) or 0; local w=b>=240 and 4 or b>=224 and 3 or b>=192 and 2 or 1
 return v:sub(1,i+w-1>n and i-1 or n)
end
function M.lock(path)
 local f=M.nixio.open(path,M.nixio.open_flags('rdwr','creat'), '600')
 if not f then return nil end
 if not f:lock('tlock') then f:close(); return nil end
 return f
end
function M.restart() return os.execute('/usr/bin/timeout -k 5 60 /etc/init.d/passwall restart >/dev/null 2>&1')==0 end
function M.check(ok,code) if not ok then error(code,0) end end
function M.valid_id(id) return type(id)=='string' and #id<=64 and id:match('^[%w_-]+$') end
function M.stage()
 local p=M.runtime..'/stage'; M.fs.mkdir(p,'700'); M.fs.mkdir(p..'/delta','700'); M.fs.remove(p..'/delta/passwall')
 M.write(p..'/passwall',M.read(M.config)); return M.uci.cursor(p,p..'/delta'),p..'/passwall'
end
function M.finish(j,status,message,data)
 j.phase='done'; j.result={id=j.id,status=status,message=message,data=data}; M.save(M.persist..'/pending.json',j)
end
function M.rollback(j)
 local lock=M.lock('/var/lock/passwall_sub_rule.lock'); if not lock then return end
 local revision=M.hash(M.config)
 if j.new_revision and revision==j.new_revision and M.hash(M.persist..'/rollback')==j.old_revision then
  M.write(M.config,M.read(M.persist..'/rollback')); lock:close();lock=nil;local ok=M.restart()
  M.finish(j,'rolled_back',ok and 'cloud_confirmation_failed_config_restored' or 'config_restored_restart_failed')
 else M.finish(j,'failed',revision==j.old_revision and 'operation_interrupted_before_apply' or 'local_config_changed_rollback_skipped') end
 if lock then lock:close() end
end
return M
