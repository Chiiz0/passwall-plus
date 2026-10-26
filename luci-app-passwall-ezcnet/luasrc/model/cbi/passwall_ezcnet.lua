local m = Map("passwall_ezcnet", "passwall-EzCNet 云控",
	"在云控网页中添加设备，将生成的设备 Key 填入下方。路由器主动通过 HTTPS 连接服务器，无需开放管理端口。")
local s = m:section(NamedSection, "main", "cloud", "连接设置")
s.addremove = false
local enabled = s:option(Flag, "enabled", "启用云控", "关闭后停止云端连接；已设置的本地订阅定时更新仍会运行。")
enabled.rmempty = false
local server = s:option(Value, "server", "服务端地址")
server.default = "https://passwall.ezcnet.com"
server.rmempty = false
function server.validate(self, value)
	if value:match("^https://[%w%.%-]+:?%d*$") then return value end
	return nil, "请输入 HTTPS 地址，不含路径、用户名或查询参数"
end
local key = s:option(Value, "key", "设备 Key", "每台路由器使用独立 Key；在平台轮换后需要重新填写。")
key.password = true
key.rmempty = false
function key.validate(self, value, section)
	if value == "" and enabled:formvalue(section) ~= "1" then return value end
	if value:match("^ezc_[%w_-]+$") and #value == 47 then return value end
	return nil, "请填写平台生成的完整设备 Key"
end
local status = s:option(DummyValue, "_status", "连接状态")
function status.cfgvalue()
	local fs = require "nixio.fs"
	local json = require "luci.jsonc"
	if m.uci:get("passwall_ezcnet", "main", "enabled") ~= "1" then return "未启用" end
	local state = json.parse(fs.readfile("/var/run/passwall-ezcnet-status.json") or "{}") or {}
	if state.time and os.time() - state.time < 90 then return state.message or "等待连接" end
	return "等待连接；可通过 logread -e passwall-ezcnet 查看日志"
end
function m.on_after_commit()
	require("nixio.fs").chmod("/etc/config/passwall_ezcnet", "600")
	require("luci.sys").call("/etc/init.d/passwall-ezcnet restart >/dev/null 2>&1 &")
end
return m
