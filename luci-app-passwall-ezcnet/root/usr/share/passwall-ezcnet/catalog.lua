local C=dofile('/usr/share/passwall-ezcnet/common.lua')
local M={}
local check=C.check
local function canonical(v)
 if type(v)~='table' then return tostring(v) end
 local keys={}; for k in pairs(v) do keys[#keys+1]=k end; table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
 local out={}; for _,k in ipairs(keys) do out[#out+1]=#tostring(k)..':'..k..'='..canonical(v[k]) end
 return table.concat(out,'\0')
end
local function clean(node)
 local t={}; for k,v in pairs(node) do if k:sub(1,1)~='.' and not k:match('^ezcnet_') and k~='group' and k~='add_mode' and k~='remarks' and v~='' and not (type(v)=='table' and next(v)==nil) then t[k]=v end end; return t
end
local function fingerprint(n) return canonical(clean(n)) end
local function identity(n) return table.concat({n.type or '',n.protocol or '',n.address or '',n.port or '',n.ezcnet_origin_remarks or n.remarks or ''},'\0') end
local function setnode(c,id,node)
 c:delete('passwall',id); assert(c:set('passwall',id,'nodes'))
 for k,v in pairs(node) do if k:sub(1,1)~='.' and v~=nil then assert(c:set('passwall',id,k,type(v)=='table' and v or tostring(v))) end end
end
local function list(v) if type(v)=='table' then return v elseif v and v~='' then return {v} else return {} end end
-- Reference schema mirrors native subscribe.lua, including dynamic shunt rules.
function M.references(c)
 local refs,rules={},{}
 c:foreach('passwall','shunt_rules',function(s) rules[#rules+1]=s['.name'];rules[#rules+1]=s['.name']..'_proxy_tag' end)
 c:foreach('passwall',nil,function(s)
  local fields={}
  if s['.type']=='global' or s['.type']=='acl_rule' or s['.type']=='socks' then fields={'node','autoswitch_backup_node'}
  elseif s['.type']=='haproxy_config' then fields={'lbss'}
  elseif s['.type']=='nodes' then
   fields={'preproxy_node','to_node','balancing_node','urltest_node','fallback_node'}
   if s.protocol=='_shunt' then fields[#fields+1]='default_node';fields[#fields+1]='default_proxy_tag'; for _,r in ipairs(rules) do fields[#fields+1]=r end end
  end
  for _,field in ipairs(fields) do for _,id in ipairs(list(s[field])) do
   if c:get('passwall',id)=='nodes' then
    refs[id]=refs[id] or {}; refs[id][#refs[id]+1]={section=s['.name'],field=field,label=s['.name']..'.'..field}
   end
  end end
 end)
 return refs
end
-- Validate dependency cycles and the constrained OpenVPN pre-proxy type before
-- committing replacements; existing unrelated cycles do not get introduced here.
local function validate_references(c)
 local graph={}
 for target,refs in pairs(M.references(c)) do
  for _,r in ipairs(refs) do
   if c:get('passwall',r.section)=='nodes' then
    graph[r.section]=graph[r.section] or {};table.insert(graph[r.section],target)
    if c:get('passwall',r.section,'type')=='OpenVPN' and r.field=='preproxy_node' then
     local n=c:get_all('passwall',target)
     check((n.type=='Xray' or n.type=='sing-box') and not (n.protocol or ''):match('^_'),'invalid_preproxy')
    end
   end
  end
 end
 local visiting,done={},{}
 local function visit(id)
  check(not visiting[id],'reference_cycle');if done[id] then return end
  visiting[id]=true;for _,nextid in ipairs(graph[id] or {}) do visit(nextid) end
  visiting[id]=nil;done[id]=true
 end
 for id in pairs(graph) do visit(id) end
end
function M.inventory(c)
 local nodes,subs,refs={}, {},M.references(c)
 local groups={};c:foreach('passwall','subscribe_list',function(s) if s.remark then if groups[s.remark]~=nil then groups[s.remark]=false else groups[s.remark]=s['.name'] end end end)
 c:foreach('passwall','nodes',function(n)
  local used={}; for _,r in ipairs(refs[n['.name']] or {}) do if #used<100 then used[#used+1]=r.label end end
  nodes[#nodes+1]={id=n['.name'],remarks=C.bounded(n.remarks or n['.name'],128),type=C.bounded(n.type,32),protocol=C.bounded(n.protocol,32),group=C.bounded(n.group,128),source=n.ezcnet_source or (n.add_mode=='2' and groups[n.group]) or '',orphan=n.ezcnet_orphan=='1',references=used}
 end)
 c:foreach('passwall','subscribe_list',function(s)
  local count=0; for _,n in ipairs(nodes) do if n.source==s['.name'] or (n.source=='' and n.group==s.remark) then count=count+1 end end
  subs[#subs+1]={id=s['.name'],name=C.bounded(s.remark,128),managed=s.ezcnet_managed=='1',interval_hours=tonumber(s.ezcnet_interval) or 0,access_mode=s.access_mode or 'auto',user_agent=C.bounded(s.user_agent,256),filter_mode=s.filter_keyword_mode or '0',discard=list(s.filter_discard_list),keep=list(s.filter_keep_list),last_node=s.ezcnet_last_node or '',updated=tonumber(s.ezcnet_updated) or 0,count=count,remaining=C.bounded(s.rem_traffic,64),expiry=C.bounded(s.expired_date,64)}
 end)
 return nodes,subs
end
local function summary()
 return {added=0,updated=0,removed=0,kept=0,duplicates=0,nodes={},issues={},probes={}}
end
local function item(out,id,node,change)
 local key=change=='duplicate' and 'duplicates' or change;out[key]=out[key]+1
 if #out.nodes<2000 then out.nodes[#out.nodes+1]={id=id,remarks=C.bounded(node.remarks or id,128),type=C.bounded(node.type,32),change=change} end
end
local function merge(c,nodes,source,group,out)
 local old,all,byidentity,byprint={}, {},{},{}
 c:foreach('passwall','nodes',function(n)
  all[fingerprint(n)]=n['.name']
  if source and (n.ezcnet_source==source or (not n.ezcnet_source and n.add_mode=='2' and n.group==group)) then
   old[n['.name']]=n; local key=identity(n); byidentity[key]=byidentity[key] or {}; table.insert(byidentity[key],n['.name'])
   byprint[fingerprint(n)]=n['.name']
  end
 end)
 local seen,retained={},{}
 for _,n in ipairs(nodes) do
  local fp=fingerprint(n)
  if seen[fp] or (not source and all[fp]) then item(out,seen[fp] or all[fp],n,'duplicate')
  else
   local id=byprint[fp]
   if retained[id] then id=nil end
   if not id then for _,candidate in ipairs(byidentity[identity(n)] or {}) do if not retained[candidate] then id=candidate;break end end end
   local exists=id~=nil; id=id or ('ezn_'..C.id():sub(1,20)); retained[id]=true; seen[fp]=id
   n.group=group;n.add_mode=source and '2' or '1';n.ezcnet_source=source;n.ezcnet_origin_remarks=source and n.remarks or nil
   -- Retain explicit chaining configured locally when updating credentials.
   if old[id] then for _,k in ipairs({'preproxy_node','to_node'}) do n[k]=n[k] or old[id][k] end end
   setnode(c,id,n);item(out,id,n,exists and 'updated' or 'added')
  end
 end
 local refs=M.references(c)
 for id,n in pairs(old) do if not retained[id] then
  if refs[id] and #refs[id]>0 then c:set('passwall',id,'ezcnet_orphan','1');item(out,id,n,'kept')
  else c:delete('passwall',id);item(out,id,n,'removed') end
 end end
end
local function parse(raw,group,settings,out)
 local parser=assert(loadfile('/usr/share/passwall/subscribe.lua'))({library=true})
 check(type(parser)=='table' and type(parser.parse)=='function','parser_upgrade_required')
 local nodes,issues=parser.parse(raw,group,settings)
 for _,v in ipairs(issues or {}) do if #out.issues<2000 then out.issues[#out.issues+1]=v end end
 check(#nodes>0,'no_valid_nodes');return nodes
end
local function curlsetting(k,v) return k..' = "'..v:gsub('\\','\\\\'):gsub('"','\\"')..'"\n' end
local function download(s)
 local url=s.url or '';check(#url<=4096 and url:match('^https://[^/%s]+') and not url:find('[%z\1-\32]') and not url:match('^https://[^/]*@'),'invalid_subscription_url')
 local ua=s.user_agent or 'PassWall-EzCNet/0.2';check(#ua<=256 and not ua:find('[%z\1-\31\127]'),'invalid_user_agent')
 local path=C.runtime..'/download';local conf=curlsetting('url',url)..curlsetting('user-agent',ua)
 C.write(path..'.conf',conf)
 local api=require'luci.passwall.api'
 local base="curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 3 --connect-timeout 10 --max-time 60 --max-filesize 262144 --config "..C.quote(path..'.conf')..' --dump-header '..C.quote(path..'.headers')..' -o '..C.quote(path)..' 2>/dev/null'
 local function direct()
  if api.get_cache_var('ENABLED_DEFAULT_ACL')=='1' or api.get_cache_var('ENABLED_ACLS')=='1' then
   -- Same bypass GID as native curl_direct; secrets stay in the private config.
   local rc=api.exec_call_as_gid(base.." --noproxy '*'",api.DIRECT_GID or 453);return rc==0
  end
  return os.execute(base.." --noproxy '*'")==0
 end
 local proxy=api.get_cache_var('GLOBAL_SOCKS_server')
 local function proxied() return proxy and proxy:match('^[%w%.:%[%]_-]+$') and os.execute(base..' --proxy '..C.quote('socks5h://'..proxy))==0 end
 local mode=s.access_mode or 'auto';local ok
 if mode=='direct' then ok=direct() elseif mode=='proxy' then ok=proxied() else ok=proxied() or direct() end
 C.fs.remove(path..'.conf'); local raw,headers=C.read(path),C.read(path..'.headers');C.fs.remove(path);C.fs.remove(path..'.headers')
 check(ok and #raw>0 and #raw<=262144,'subscription_download_failed');return raw,headers
end
local function validname(name) return type(name)=='string' and #name>0 and #name<=512 and not name:find('[%z\1-\31]') end
local function subscription(c,id,settings)
 local s=id and c:get_all('passwall',id)
 if id then
  check(s and s['.type']=='subscribe_list','subscription_missing')
  if s.ezcnet_managed~='1' then
   local collision=0;c:foreach('passwall','subscribe_list',function(other) if other.remark==s.remark then collision=collision+1 end end)
   check(collision==1,'ambiguous_subscription_group')
   c:foreach('passwall','nodes',function(n) if not n.ezcnet_source and n.add_mode=='2' and n.group==s.remark then c:set('passwall',n['.name'],'ezcnet_source',id) end end)
  end
 else
  local count=0;c:foreach('passwall','subscribe_list',function() count=count+1 end);check(count<50,'too_many_subscriptions')
  id='ezs_'..C.id():sub(1,20);s={};c:set('passwall',id,'subscribe_list')
 end
 if settings then
  check(validname(settings.name),'invalid_name')
  check(type(settings.interval_hours)=='number' and settings.interval_hours>=0 and settings.interval_hours<=720,'invalid_schedule')
  check(settings.access_mode=='direct' or settings.access_mode=='proxy' or settings.access_mode=='auto','invalid_access_mode')
  check(tostring(settings.filter_mode):match('^[0-4]$'),'invalid_filter')
  local map={remark=settings.name,url=settings.url or s.url,ezcnet_interval=tostring(settings.interval_hours),access_mode=settings.access_mode,user_agent=settings.user_agent,filter_keyword_mode=settings.filter_mode,filter_discard_list=settings.discard,filter_keep_list=settings.keep}
  for k,v in pairs(map) do if type(v)=='table' and #v==0 then c:delete('passwall',id,k) else c:set('passwall',id,k,v) end end
 end
 c:set('passwall',id,'ezcnet_managed','1');c:set('passwall',id,'auto_update','0');c:set('passwall',id,'allowInsecure','0')
 return id,c:get_all('passwall',id)
end
local function update_sub(c,id,settings,out,progress)
 local source,s=subscription(c,id,settings)
 progress('downloading');local raw,headers=download(s);progress('parsing')
 local nodes=parse(raw,s.remark,s,out);merge(c,nodes,source,s.remark,out)
 c:set('passwall',source,'ezcnet_updated',tostring(os.time()))
 -- Parser loads the native converter; only the numeric traffic header is consumed.
 local info=parse_clash_sub_info(headers)
 if info then c:set('passwall',source,'rem_traffic',info.rem_traffic);c:set('passwall',source,'expired_date',info.expired_date) end
 return source
end
local function remove_nodes(c,ids,replacement,out)
 local deleting={};for _,id in ipairs(ids) do check(C.valid_id(id) and c:get('passwall',id)=='nodes','node_missing');deleting[id]=true end
 if replacement then check(C.valid_id(replacement) and not deleting[replacement] and c:get('passwall',replacement)=='nodes','invalid_replacement') end
 local refs=M.references(c)
 for _,id in ipairs(ids) do
  for _,r in ipairs(refs[id] or {}) do if not deleting[r.section] then
   check(replacement~=nil,'node_in_use');check(r.section~=replacement,'reference_cycle')
   local value=c:get('passwall',r.section,r.field)
   if type(value)=='table' then local mapped,seen={},{};for _,v in ipairs(value) do v=v==id and replacement or v;if not seen[v] then mapped[#mapped+1]=v;seen[v]=true end end; c:set('passwall',r.section,r.field,mapped)
   else c:set('passwall',r.section,r.field,replacement) end
  end end
  item(out,id,c:get_all('passwall',id),'removed');c:delete('passwall',id)
  c:foreach('passwall','subscribe_list',function(s) if s.ezcnet_last_node==id then if replacement then c:set('passwall',s['.name'],'ezcnet_last_node',replacement) else c:delete('passwall',s['.name'],'ezcnet_last_node') end end end)
 end
end
local function openvpn(c,op,out)
 check(validname(op.name) and type(op.content)=='string' and #op.content<=131072 and not op.content:find('%z'),'invalid_openvpn')
 check((op.username=='')==(op.password==''),'invalid_credentials')
 for _,v in ipairs({op.username,op.password}) do check(type(v)=='string' and #v<=256 and not v:find('[\r\n%z]'),'invalid_credentials') end
 local api=require'luci.passwall.api';check(api.is_finded('openvpn'),'openvpn_missing');check(api.datatypes.ip4addr(op.dns),'invalid_dns')
 if op.preproxy then local n=c:get_all('passwall',op.preproxy);check(n and (n.type=='Xray' or n.type=='sing-box') and not (n.protocol or ''):match('^_') and op.preproxy~=op.id,'invalid_preproxy') end
 local path=C.runtime..'/openvpn';C.write(path..'.input',op.content)
 local ok=os.execute('/usr/share/passwall/openvpn.sh sanitize-profile '..(op.preproxy and '1' or '0')..' < '..C.quote(path..'.input')..' > '..C.quote(path..'.clean')..' 2>/dev/null')==0
 local profile=C.read(path..'.clean');C.fs.remove(path..'.input');C.fs.remove(path..'.clean')
 check(ok and ('\n'..profile):match('\n%s*remote%s+'),'invalid_openvpn_remote')
 local node={type='OpenVPN',remarks=op.name,config=profile,username=op.username,password=op.password,preproxy_node=op.preproxy,vpn_dns=op.dns,group='OpenVPN',add_mode='1'}
 if op.id then check(C.valid_id(op.id) and c:get('passwall',op.id,'type')=='OpenVPN','node_missing');setnode(c,op.id,node);item(out,op.id,node,'updated')
 else merge(c,{node},nil,'OpenVPN',out) end
end
function M.prepare(c,op,progress)
 check(type(op)=='table' and type(op.action)=='string','invalid_operation');local out=summary()
 local action=op.action
 if action=='subscription.preview' then update_sub(c,op.id,op.settings,out,progress)
 elseif action=='subscription.update' then
  check(type(op.ids)=='table' and #op.ids>0 and #op.ids<=50,'invalid_subscriptions')
  for i,id in ipairs(op.ids) do check(C.valid_id(id),'invalid_id');progress('downloading',i,#op.ids);update_sub(c,id,nil,out,progress) end
 elseif action=='nodes.preview' then
  check(validname(op.group),'invalid_group');progress('parsing');merge(c,parse(op.content,op.group,nil,out),nil,op.group,out)
 elseif action=='openvpn.preview' then openvpn(c,op,out)
 elseif action=='nodes.edit' then
  check(C.valid_id(op.id) and c:get('passwall',op.id)=='nodes','node_missing');check(validname(op.name) and validname(op.group),'invalid_name')
  c:set('passwall',op.id,'remarks',op.name);c:set('passwall',op.id,'group',op.group);item(out,op.id,c:get_all('passwall',op.id),'updated')
 elseif action=='nodes.delete' then check(type(op.ids)=='table' and #op.ids>0 and #op.ids<=2000,'invalid_nodes');remove_nodes(c,op.ids,op.replacement,out)
 elseif action=='subscription.delete' then
  check(C.valid_id(op.id) and c:get('passwall',op.id)=='subscribe_list','subscription_missing')
  local ids={};local group=c:get('passwall',op.id,'remark')
  if c:get('passwall',op.id,'ezcnet_managed')~='1' then local count=0;c:foreach('passwall','subscribe_list',function(s) if s.remark==group then count=count+1 end end);check(count==1,'ambiguous_subscription_group') end
  c:foreach('passwall','nodes',function(n) if n.ezcnet_source==op.id or (not n.ezcnet_source and n.add_mode=='2' and n.group==group) then ids[#ids+1]=n['.name'] end end)
  if op.delete_nodes then remove_nodes(c,ids,op.replacement,out) else for _,id in ipairs(ids) do c:delete('passwall',id,'ezcnet_source');c:set('passwall',id,'add_mode','1') end end
  c:delete('passwall',op.id)
 elseif action=='nodes.switch' then
  check(C.valid_id(op.id) and c:get('passwall',op.id)=='nodes','node_missing');local p=dofile('/usr/share/passwall-ezcnet/protocol.lua');local g=C.global(c);local cfg=p.config(c,g)
  cfg.node=op.id;cfg.enabled=op.enable and '1' or cfg.enabled;p.apply(c,g,cfg)
  local source=c:get('passwall',op.id,'ezcnet_source');if source and c:get('passwall',source)=='subscribe_list' then c:set('passwall',source,'ezcnet_last_node',op.id) end
 else error('unsupported_action',0) end
 local count=0;c:foreach('passwall','nodes',function() count=count+1 end);check(count<=2000,'too_many_nodes')
 validate_references(c);assert(c:commit('passwall'));return out
end
function M.test(c,op,progress)
 check(type(op.ids)=='table' and #op.ids>0 and #op.ids<=20,'invalid_nodes');local out=summary()
 for i,id in ipairs(op.ids) do
  check(C.valid_id(id) and c:get('passwall',id)=='nodes','node_missing');check(c:get('passwall',id,'type')~='OpenVPN','openvpn_probe_unsupported')
  progress('testing',i,#op.ids)
  local f=assert(io.popen('/usr/bin/timeout -k 5 30 /usr/share/passwall/test.sh url_test_node '..C.quote(id)..' 2>/dev/null'));local value=f:read('*a') or '';f:close()
  local code,pre,start=value:match('(%d+):([%d%.]+):([%d%.]+)%s*$');code,pre,start=tonumber(code) or 0,tonumber(pre),tonumber(start)
  local latency=code>=200 and code<600 and start and pre and start>0 and start>=pre and (start-pre)*1000 or nil
  out.probes[#out.probes+1]={id=id,http_code=code,latency=latency}
 end;return out
end
function M.preview(stage,revision,out)
 local dir=C.runtime..'/previews';C.fs.mkdir(dir,'700')
 for name in C.fs.dir(dir) do if name:match('^[a-f0-9]+%.json$') then local p=dir..'/'..name;local old=C.load(p);if not old or old.expires<=os.time() then C.fs.remove(p) end end end
 local token=C.id();local expiry=os.time()+600
 C.save(dir..'/'..token..'.json',{revision=revision,expires=expiry,config=C.read(stage),digest=C.hash(stage)})
 out.token=token;out.expires=expiry;return out
end
function M.consume(token,revision,stage)
 check(type(token)=='string' and #token==32 and token:match('^[a-f0-9]+$'),'invalid_preview')
 local path=C.runtime..'/previews/'..token..'.json';local p=C.load(path)
 check(p and p.expires>os.time(),'preview_expired');check(p.revision==revision,'config_conflict')
 C.write(stage,p.config);check(C.hash(stage)==p.digest,'preview_invalid');C.fs.remove(path)
end
return M
