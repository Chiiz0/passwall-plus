#!/usr/bin/lua
-- Outbound HTTPS only. No remote shell, arbitrary UCI, or credential upload.
local fs = require "nixio.fs"
local nixio = require "nixio"
local json = require "luci.jsonc"
local uci = require "uci"
local common = dofile('/usr/share/passwall-ezcnet/common.lua')
local catalog = dofile('/usr/share/passwall-ezcnet/catalog.lua')
local protocol = dofile("/usr/share/passwall-ezcnet/protocol.lua")
local persist = "/etc/passwall_ezcnet"
local runtime = "/var/run/passwall-ezcnet"
local config_path = "/etc/config/passwall"
fs.mkdir(persist, "700")
fs.mkdir(runtime, "700")
fs.chmod(persist, "700")
fs.chmod(runtime, "700")

local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function read(path) return fs.readfile(path) or "" end
local function bounded(value, length)
	-- Keep UTF-8 node names valid when enforcing byte limits on OpenWrt Lua 5.1.
	local value = tostring(value or "")
	if #value <= length then return value end
	local finish = length
	while finish > 0 and value:byte(finish) >= 128 and value:byte(finish) < 192 do finish = finish - 1 end
	local lead = value:byte(finish) or 0
	local width = lead >= 240 and 4 or lead >= 224 and 3 or lead >= 192 and 2 or 1
	if finish + width - 1 > length then length = finish - 1 end
	return value:sub(1, length)
end
local function write(path, data) common.write(path, data) end
local function hash(path)
	local file = assert(io.popen("sha256sum " .. quote(path) .. " 2>/dev/null"))
	local value = file:read("*l") or ""
	file:close()
	return value:match("^([a-f0-9]+)") or ""
end
local function log(message)
	-- Only fixed messages, never the URL, Key, response body or UCI contents.
	os.execute("logger -t passwall-ezcnet " .. quote(message))
	write("/var/run/passwall-ezcnet-status.json", json.stringify({time = os.time(), message = message}))
end
local function cursor()
	-- Private delta directory: never commit another LuCI session's staged edits.
	fs.mkdir(runtime .. "/delta", "700")
	return uci.cursor("/etc/config", runtime .. "/delta")
end
local function section(c)
	local name
	c:foreach("passwall", "global", function(s) if not name then name = s[".name"] end end)
	return name
end
local function restart()
	return os.execute("/usr/bin/timeout -k 5 60 /etc/init.d/passwall restart >/dev/null 2>&1") == 0
end

local installation_id = read(persist .. "/installation_id"):match("^([a-f0-9-]+)")
if not installation_id then
	installation_id = assert(read("/proc/sys/kernel/random/uuid"):match("^([a-f0-9-]+)"))
	write(persist .. "/installation_id", installation_id)
end
local journal_path = persist .. "/pending.json"
local journal = json.parse(read(journal_path))
local function save_journal() write(journal_path, json.stringify(journal)) end
local function result(status, message)
	journal.phase = "done"
	journal.result = {id = journal.id, status = status, message = message}
	save_journal()
end
local function rollback() common.rollback(journal);journal = common.load(journal_path) end
local function worker_idle()
 local lock = common.lock('/var/lock/passwall_ezcnet_worker.lock')
 if lock then lock:close();return true end
 return false
end
local function reconcile()
 if not worker_idle() then journal = common.load(journal_path);return end
 journal = common.load(journal_path)
 if journal and (journal.phase == 'executing' or journal.phase == 'preparing') then rollback() end
 if journal and journal.phase == 'awaiting_ack' and os.time() >= journal.deadline then rollback() end
 if journal and journal.local_job and journal.phase == 'done' then
  local events = common.load(persist .. '/events.json') or {}
  events[#events+1] = {time=os.time(),source=journal.local_job,status=journal.result.status,message=journal.result.message}
  while #events>20 do table.remove(events,1) end
  common.save(persist .. '/events.json',events)
  fs.remove(journal_path);fs.remove(persist .. '/rollback');journal=nil
 end
end
reconcile()

local function report()
	-- Capture the revision before opening UCI: concurrent local writes must cause
	-- a later conflict, never pair stale UI values with a newer revision.
	local report_revision = hash(config_path)
	local c = cursor()
	local global = assert(section(c), "PassWall global section missing")
	local nodes, subscriptions = catalog.inventory(c)
	local running = false
	for pid in fs.dir("/proc") do
		if pid:match("^%d+$") then
			local cmd = read("/proc/" .. pid .. "/cmdline")
			if cmd:find("/tmp/etc/passwall/", 1, true) and (cmd:find("xray", 1, true) or cmd:find("sing%-box") or cmd:find("openvpn", 1, true) or cmd:find("ss%-redir") or cmd:find("ssr%-redir") or cmd:find("ipt2socks", 1, true) or cmd:find("hysteria", 1, true)) then running = true; break end
		end
	end
	local memory = read("/proc/meminfo")
	local board = json.parse(read("/etc/board.json")) or {}
	local release = read("/etc/openwrt_release")
	return {
		hostname = bounded(read("/proc/sys/kernel/hostname"):gsub("%s+$", ""),128),
		model = bounded((board.model or {}).name or "OpenWrt",128),
		firmware = bounded(release:match("DISTRIB_DESCRIPTION='([^']+)'") or "OpenWrt",128),
		agent_version = "0.2.0", uptime = math.floor(tonumber(read("/proc/uptime"):match("^[%d%.]+")) or 0),
		memory_total = (tonumber(memory:match("MemTotal:%s+(%d+)")) or 0) * 1024,
		memory_available = (tonumber(memory:match("MemAvailable:%s+(%d+)")) or 0) * 1024,
		load = tonumber(read("/proc/loadavg"):match("^[%d%.]+")) or 0,
		core_running = running, config_revision = report_revision, config = protocol.config(c, global), nodes = nodes, subscriptions = subscriptions, capabilities = {"catalog_v2"}, local_events = common.load(persist .. "/events.json") or {}
	}
end

local function execute(command)
 if not worker_idle() or journal then return end
 if type(command.id)~='string' or #command.id~=32 or not command.id:match('^[a-f0-9]+$') then return end
 -- Persist receipt before spawning; a crash before the worker starts reports failure,
 -- never silently executes the same command again after a reboot.
 journal={id=command.id,kind=command.kind,old_revision=hash(config_path),phase='preparing',local_job=command.local_job}
 common.save(journal_path,journal)
 common.save(runtime..'/job.json',command)
 os.execute('/usr/bin/timeout -k 5 900 /usr/bin/lua /usr/share/passwall-ezcnet/worker.lua >/dev/null 2>&1 &')
end
local last_schedule=0
local function schedule()
 if journal or not worker_idle() or os.time()-last_schedule<60 then return end
 last_schedule=os.time()
 local attempts=common.load(persist..'/schedule.json') or {}
 local selected
 cursor():foreach('passwall','subscribe_list',function(s)
  local hours=tonumber(s.ezcnet_interval) or 0
  local last=math.max(tonumber(s.ezcnet_updated) or 0,tonumber(attempts[s['.name']]) or 0)
  if not selected and s.ezcnet_managed=='1' and hours>0 and os.time()-last>=hours*3600 then selected=s['.name'] end
 end)
 if selected then
  attempts[selected]=os.time();common.save(persist..'/schedule.json',attempts)
  execute({id=common.id(),kind='catalog',expected_revision=hash(config_path),expires=os.time()+900,local_job=selected,operation={action='subscription.update',ids={selected}}})
 end
end

local function heartbeat()
	reconcile()
	schedule()
	local settings = cursor():get_all("passwall_ezcnet", "main") or {}
	if settings.enabled ~= "1" then return true, nil, 30 end
	local server, key = settings.server or "", settings.key or ""
	if not server:match("^https://[%w%.%-]+:?%d*$") or not key:match("^ezc_[%w_-]+$") or #key ~= 47 then
		return nil, "服务端地址或设备 Key 格式错误"
	end
	local body = {installation_id = installation_id, report = report(), result = journal and not journal.local_job and journal.result or nil, progress = journal and not journal.local_job and common.load(runtime .. "/progress.json") or nil}
	local encoded = common.encode(body)
	write(runtime .. "/request.json", encoded)
	write(runtime .. "/curl.conf", 'header = "Authorization: Bearer ' .. key .. '"\n')
	local cmd = "curl --silent --show-error --fail --noproxy '*' --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 20 --max-filesize 2097152 " ..
		"--config " .. quote(runtime .. "/curl.conf") .. " --header 'Content-Type: application/json' --data-binary @" .. quote(runtime .. "/request.json") ..
		" --output " .. quote(runtime .. "/response.json") .. " " .. quote(server .. "/api/agent/heartbeat") .. " 2>/dev/null"
	local success = os.execute(cmd) == 0
	fs.remove(runtime .. "/curl.conf")
	fs.remove(runtime .. "/request.json")
	if not success then return nil, "云端连接失败，请检查网络、时间、证书或设备 Key" end
	local response = json.parse(read(runtime .. "/response.json"))
	fs.remove(runtime .. "/response.json")
	if type(response) ~= "table" or type(response.server_time) ~= "number" or type(response.acknowledged) ~= "table" then return nil, "云端响应无效" end
	if journal then
		for _, id in ipairs(response.acknowledged) do
			if journal and id == journal.id then
				fs.remove(journal_path)
				fs.remove(persist .. "/rollback")
				journal = nil
			end
		end
	end
	log("已连接云端")
	if not journal and worker_idle() and type(response.command) == "table" then
		execute(response.command)
		return true, nil, 3 -- keep heartbeats independent from long-running workers
	end
	return true, nil, 15
end

math.randomseed(os.time())
local failures = 0
while true do
	local ok, connected, message, delay = pcall(heartbeat)
	if not ok then
		-- A failed local write/apply is resolved using the durable journal.
		journal = json.parse(read(journal_path))
		if worker_idle() and journal and journal.phase == "executing" then pcall(rollback) end
		connected, message = nil, "本地操作失败，请检查 PassWall 配置与存储空间"
	end
	if connected then failures = 0 else failures = failures + 1; log(message) end
	if arg[1] == "--once" then break end
	nixio.nanosleep(connected and delay or math.min(5 * 2 ^ math.min(failures, 4), 30) + math.random(0, 3))
end
