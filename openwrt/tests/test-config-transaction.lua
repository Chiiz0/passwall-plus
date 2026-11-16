-- Run only in the disposable OpenWrt QEMU guest, with the real libuci/nixio.
local T=require'luci.passwall.config_transaction'
local R=require'luci.passwall.backup_runtime'
local B=require'luci.passwall.backup'
local fs=require'nixio.fs'
local nixio=require'nixio'
local originals={}
for _,name in ipairs(B.files) do originals['/'..name]=fs.readfile('/'..name) or false end
local function restore()
 for path,data in pairs(originals) do if data==false then fs.remove(path) else assert(fs.writefile(path,data)) end end
end
local function check_error(fn,code)
 local ok,err=pcall(fn);assert(not ok and tostring(err)==code,tostring(err)..' expected '..code)
end
local function stage(name)
 local p='/tmp/passwall-transaction-test-'..name
 os.execute('rm -rf '..p);assert(fs.mkdir(p,'700'));return p
end
local ok,err=pcall(function()
 assert(T.acquire());assert(T.acquire());T.release();assert(T.active());T.release();assert(not T.active())
 local revision=T.revision('passwall');assert(T.check(revision,'passwall'));assert(not T.check(string.rep('0',64),'passwall'))
 local failed=T.run(function() error('expected',0) end);assert(not failed and not T.active())
 -- A separate process uses the exact POSIX lock used by cloud/subscription workers.
 os.execute([[lua -e 'local n=require"nixio";local f=assert(n.open("/var/lock/passwall_sub_rule.lock","a"));assert(f:lock("tlock"));local r=io.open("/tmp/passwall-lock-ready","w");r:close();n.nanosleep(2)' >/dev/null 2>&1 &]])
 for i=1,50 do if fs.access('/tmp/passwall-lock-ready') then break end;nixio.nanosleep(0,100000000) end
 local lock,busy=T.acquire();assert(not lock and busy=='config_busy');nixio.nanosleep(2);fs.remove('/tmp/passwall-lock-ready')
 assert(T.run(function() end))
 -- Preserve list order, quotes, backslashes, multiline profiles and section IDs.
 local cursor=require('uci').cursor()
 local special="quote's \\ path\nsecond line"
 assert(T.run(function()
  cursor:set('passwall','@global[0]','transaction_test',special)
  cursor:set('passwall','@global[0]','transaction_list',{'first',special,'last'})
  T.commit(cursor,'passwall')
 end))
 cursor=require('uci').cursor()
 assert(cursor:get('passwall','@global[0]','transaction_test')==special)
 local list=cursor:get('passwall','@global[0]','transaction_list');assert(#list==3 and list[2]==special)
 restore()
 local session=string.rep('a',32)
 local archive
 assert(T.run(function() archive=R.create(session,'26.11.3-2') end))
 local args={index=0,count=1,kind='all',chunk=nixio.bin.b64encode(archive)}
 local response
 local success,message=T.run(function() response=R.upload(session,args,'26.11.3-2') end)
 assert(success,message);assert(response.restored)
 for path,data in pairs(originals) do assert((fs.readfile(path) or false)==data,path) end
 assert(T.run(function() R.reset(session,'client'); R.reset(session,'server') end))
 assert(fs.readfile('/etc/config/passwall')==fs.readfile('/usr/share/passwall/0_default_config'))
 assert(fs.readfile('/etc/config/passwall_server')=="config global 'global'\n")
 restore()
 local form_revision=T.form_revision('passwall')
 assert(fs.writefile('/etc/passwall/rules/direct_host','new-rule.test\n'))
 assert(T.form_revision('passwall')~=form_revision)
 restore()
 local dir=stage('invalid')
 check_error(function() R.install({['etc/config/passwall']='not a uci config!'},dir) end,'invalid_backup_config')
 assert(T.revision('passwall')==revision)
 dir=stage('failure')
 local rename=fs.rename;local injected=false
 fs.rename=function(from,to)
  if to=='/etc/passwall/rules/direct_host' and not injected then injected=true;return nil end
  return rename(from,to)
 end
 check_error(function() R.install({['etc/config/passwall']="config global 'global'\n option marker 'candidate'\n",['etc/passwall/rules/direct_host']='candidate.test\n'},dir) end,'restore_write_failed_rolled_back')
 fs.rename=rename;assert(injected)
 assert(T.revision('passwall')==revision);assert(not fs.access('/etc/passwall/.restore-journal.json'))
 -- Simulate power loss after the first file replacement; next writer recovers.
 dir=stage('crash')
 local script=assert(io.open(dir..'/crash.lua','w'))
 script:write([[local fs=require'nixio.fs';local rename=fs.rename
 fs.rename=function(a,b) if b=='/etc/passwall/rules/direct_host' then os.exit(23) end;return rename(a,b) end
 require'luci.passwall.backup_runtime'.install({['etc/config/passwall']="config global 'global'\n option marker 'crash'\n",['etc/passwall/rules/direct_host']='crash.test\n'},']]..dir..[[')
 ]]);script:close()
 assert(os.execute('lua '..dir..'/crash.lua')~=0)
 assert(fs.access('/etc/passwall/.restore-journal.json'))
 assert(T.run(function() end));assert(T.revision('passwall')==revision)
 -- Out-of-order chunks cannot complete or modify live configuration.
 local half=math.floor(#archive/2)
 assert(T.run(function() response=R.upload(session,{index=0,count=2,kind='client',chunk=nixio.bin.b64encode(archive:sub(1,half))},'26.11.3-2') end))
 check_error(function() R.upload(session,{index=1,count=2,kind='client',id='wrong',chunk=nixio.bin.b64encode(archive:sub(half+1))},'26.11.3-2') end,'invalid_upload_session')
 assert(T.revision('passwall')==revision)
 -- A cloud/local change while uploading makes the restore stale.
 assert(fs.writefile('/etc/config/passwall',originals['/etc/config/passwall']..'\n# newer\n'))
 check_error(function() R.upload(session,{index=1,count=2,kind='client',id=response.upload_id,chunk=nixio.bin.b64encode(archive:sub(half+1))},'26.11.3-2') end,'config_conflict')
end)
restore()
if not ok then error(err) end
print('PASS real configuration locks, backup roundtrip, default reset, rule conflicts, UCI rejection, partial-write rollback, crash recovery, chunk ordering and revision conflicts')
