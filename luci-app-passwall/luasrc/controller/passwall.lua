-- Copyright (C) 2018-2020 L-WRT Team
-- Copyright (C) 2021-2025 xiaorouji
-- Copyright (C) 2026 Openwrt-Passwall Organization

module("luci.controller.passwall", package.seeall)
local api = require "luci.passwall.api"
local appname = api.appname		-- not available
local c_config = api.c_config	-- not available
local uci, uci_get, uci_set, uci_del, uci_foreach, uci_save = api.uci, api.uci_get_c, api.uci_set_c, api.uci_del_c, api.uci_foreach_c, api.uci_save_c
local fs = api.fs
local http = require "luci.http"
local util = require "luci.util"
local i18n = require "luci.i18n"
local jsonStringify = luci.jsonc.stringify
local jsonParse = luci.jsonc.parse

local function identifier(value)
	if type(value) == "string" and #value <= 128 and value:match("^[%w_%-]+$") then return value end
	http.status(400, "Invalid identifier")
	return nil
end

function index()
	if not nixio.fs.access("/etc/config/passwall") then
		if nixio.fs.access("/usr/share/passwall/0_default_config") then
			luci.sys.call('cp -f /usr/share/passwall/0_default_config /etc/config/passwall')
		else return end
	end
	luci.sys.call("mkdir -p /etc/passwall/rules")
	local api = require "luci.passwall.api"
	local appname = api.appname		-- global definitions not available
	local fs = api.fs
	entry({"admin", "services", appname}).dependent = true
	entry({"admin", "services", appname, "show"}, call("menu_action", "show_menu")).leaf = true
	entry({"admin", "services", appname, "hide"}, call("menu_action", "hide_menu")).leaf = true
	local e
	if api.uci_get_c("@global[0]", "hide_from_luci") ~= "1" then
		e = entry({"admin", "services", appname}, alias("admin", "services", appname, "overview"), "PassWall Plus", -1)
	else
		e = entry({"admin", "services", appname}, alias("admin", "services", appname, "overview"), nil, -1)
	end
	e.dependent = true
	e.acl_depends = { "luci-app-passwall" }
	--[[ Client ]]
	entry({"admin", "services", appname, "overview"}, template(appname .. "/plus/overview"), _("Plus Overview"), 0).leaf = true
	entry({"admin", "services", appname, "openvpn"}, template(appname .. "/plus/openvpn"), "OpenVPN", 2).leaf = true
	entry({"admin", "services", appname, "settings"}, cbi(appname .. "/client/global"), _("Global egress"), 3).dependent = true
	entry({"admin", "services", appname, "node_list"}, cbi(appname .. "/client/node_list"), _("Node List"), 4).dependent = true
	entry({"admin", "services", appname, "node_subscribe"}, cbi(appname .. "/client/node_subscribe"), _("Node Subscribe"), 5).dependent = true
	entry({"admin", "services", appname, "other"}, cbi(appname .. "/client/other"), _("Other Settings"), 92).leaf = true
	if api.is_finded("haproxy") then
		entry({"admin", "services", appname, "haproxy"}, cbi(appname .. "/client/haproxy"), _("Load Balancing"), 93).leaf = true
	end
	entry({"admin", "services", appname, "app_update"}, cbi(appname .. "/client/app_update"), _("App Update"), 95).leaf = true
	entry({"admin", "services", appname, "rule"}, cbi(appname .. "/client/rule"), _("Rule Manage"), 96).leaf = true
	entry({"admin", "services", appname, "rule_list"}, cbi(appname .. "/client/rule_list", {autoapply = true}), _("Rule List"), 97).leaf = true
	entry({"admin", "services", appname, "node_subscribe_config"}, cbi(appname .. "/client/node_subscribe_config")).leaf = true
	entry({"admin", "services", appname, "node_config"}, cbi(appname .. "/client/node_config")).leaf = true
	entry({"admin", "services", appname, "shunt_rules"}, cbi(appname .. "/client/shunt_rules")).leaf = true
	entry({"admin", "services", appname, "socks_config"}, cbi(appname .. "/client/socks_config")).leaf = true
	entry({"admin", "services", appname, "acl"}, cbi(appname .. "/client/acl"), _("Device egress"), 1).leaf = true
	entry({"admin", "services", appname, "acl_config"}, cbi(appname .. "/client/acl_config")).leaf = true
	entry({"admin", "services", appname, "log"}, template(appname .. "/log/log"), _("Runtime Logs"), 999).leaf = true

	--[[ Server ]]
	entry({"admin", "services", appname, "server"}, cbi(appname .. "/server/index"), _("Server-Side"), 99).leaf = true
	entry({"admin", "services", appname, "server_config"}, cbi(appname .. "/server/server_config")).leaf = true
	entry({"admin", "services", appname, "server_user_config"}, cbi(appname .. "/server/user_config")).leaf = true

	--[[ API ]]
	entry({"admin", "services", appname, "plus_status"}, call("plus_status")).leaf = true
	entry({"admin", "services", appname, "plus_create"}, post("config_action", "plus_create")).leaf = true
	entry({"admin", "services", appname, "server_update_config"}, post("config_action", "server_update_config")).leaf = true
	entry({"admin", "services", appname, "server_status"}, call("server_status")).leaf = true
	entry({"admin", "services", appname, "server_log"}, call("server_log")).leaf = true
	entry({"admin", "services", appname, "server_get_log"}, call("server_get_log")).leaf = true
	entry({"admin", "services", appname, "server_clear_log"}, post("write_action", "server_clear_log")).leaf = true
	entry({"admin", "services", appname, "link_add_node"}, post("config_action", "link_add_node")).leaf = true
	entry({"admin", "services", appname, "socks_autoswitch_add_node"}, post("config_action", "socks_autoswitch_add_node")).leaf = true
	entry({"admin", "services", appname, "socks_autoswitch_remove_node"}, post("config_action", "socks_autoswitch_remove_node")).leaf = true
	entry({"admin", "services", appname, "gen_client_config"}, call("gen_client_config")).leaf = true
	entry({"admin", "services", appname, "get_now_use_node"}, call("get_now_use_node")).leaf = true
	entry({"admin", "services", appname, "get_redir_log"}, call("get_redir_log")).leaf = true
	entry({"admin", "services", appname, "get_socks_log"}, call("get_socks_log")).leaf = true
	entry({"admin", "services", appname, "get_chinadns_log"}, call("get_chinadns_log")).leaf = true
	entry({"admin", "services", appname, "get_smartdns_log"}, call("get_smartdns_log")).leaf = true
	entry({"admin", "services", appname, "get_log"}, call("get_log")).leaf = true
	entry({"admin", "services", appname, "clear_log"}, post("write_action", "clear_log")).leaf = true
	entry({"admin", "services", appname, "index_status"}, call("index_status")).leaf = true
	entry({"admin", "services", appname, "haproxy_status"}, call("haproxy_status")).leaf = true
	entry({"admin", "services", appname, "socks_status"}, call("socks_status")).leaf = true
	entry({"admin", "services", appname, "connect_status"}, call("connect_status")).leaf = true
	entry({"admin", "services", appname, "ping_node"}, call("ping_node")).leaf = true
	entry({"admin", "services", appname, "urltest_node"}, call("urltest_node")).leaf = true
	entry({"admin", "services", appname, "update_config"}, post("config_action", "update_config")).leaf = true
	entry({"admin", "services", appname, "add_node"}, post("config_action", "add_node")).leaf = true
	entry({"admin", "services", appname, "set_node"}, post("config_action", "set_node")).leaf = true
	entry({"admin", "services", appname, "copy_node"}, post("config_action", "copy_node")).leaf = true
	entry({"admin", "services", appname, "clear_all_nodes"}, post("config_action", "clear_all_nodes")).leaf = true
	entry({"admin", "services", appname, "delete_select_nodes"}, post("config_action", "delete_select_nodes")).leaf = true
	entry({"admin", "services", appname, "reassign_group"}, post("config_action", "reassign_group")).leaf = true
	entry({"admin", "services", appname, "get_node"}, call("get_node")).leaf = true
	entry({"admin", "services", appname, "save_node_list_opt"}, post("config_action", "save_node_list_opt")).leaf = true
	entry({"admin", "services", appname, "update_rules"}, post("write_action", "update_rules")).leaf = true
	entry({"admin", "services", appname, "rollback_rules"}, post("config_action", "rollback_rules")).leaf = true
	entry({"admin", "services", appname, "subscribe_del_node"}, post("write_action", "subscribe_del_node")).leaf = true
	entry({"admin", "services", appname, "subscribe_del_all"}, post("write_action", "subscribe_del_all")).leaf = true
	entry({"admin", "services", appname, "subscribe_manual"}, post("config_action", "subscribe_manual")).leaf = true
	entry({"admin", "services", appname, "subscribe_manual_all"}, post("config_action", "subscribe_manual_all")).leaf = true
	entry({"admin", "services", appname, "flush_set"}, post("config_action", "flush_set")).leaf = true
	entry({"admin", "services", appname, "get_shunt_rules"}, call("get_shunt_rules")).leaf = true
	entry({"admin", "services", appname, "add_shunt_rule"}, post("config_action", "add_shunt_rule")).leaf = true
	entry({"admin", "services", appname, "delete_select_shunt_rules"}, post("config_action", "delete_select_shunt_rules")).leaf = true

	--[[rule_list]]
	entry({"admin", "services", appname, "read_rulelist"}, call("read_rulelist")).leaf = true

	--[[Components update]]
	entry({"admin", "services", appname, "check_" .. appname}, call("app_check")).leaf = true
	entry({"admin", "services", appname, "update_" .. appname}, call("component_action", "app_update")).leaf = true
	local coms = require "luci.passwall.com"
	local com
	for _, com in ipairs(coms.order) do
		entry({"admin", "services", appname, "check_" .. com}, call("com_check", com)).leaf = true
		entry({"admin", "services", appname, "update_" .. com}, call("component_action", "com_update", com)).leaf = true
		entry({"admin", "services", appname, "version_" .. com}, call("com_version", com)).leaf = true
	end

	--[[Backup]]
	entry({"admin", "services", appname, "create_backup"}, post("config_action", "create_backup")).leaf = true
	entry({"admin", "services", appname, "restore_backup"}, post("config_action", "restore_backup")).leaf = true
	entry({"admin", "services", appname, "reset_config"}, post("config_action", "reset_config")).leaf = true

	--[[geoview]]
	entry({"admin", "services", appname, "geo_view"}, call("geo_view")).leaf = true

	entry({"admin", "services", appname, "fetch_certsha256"}, call("fetch_certsha256")).leaf = true
	entry({"admin", "services", appname, "gen_wireguard_key"}, call("gen_wireguard_key")).leaf = true
end

local function http_write_json(content)
	http.prepare_content("application/json")
	http.write(jsonStringify(content or {code = 1}))
end

local function http_write_json_ok(data)
	http.prepare_content("application/json")
	http.write(jsonStringify({code = 1, data = data}))
end

local function http_write_json_error(data)
	http.prepare_content("application/json")
	http.write(jsonStringify({code = 0, data = data}))
end

function show_menu()
	uci_del("@global[0]", "hide_from_luci"); uci_save(true)
	api.remove("/tmp/luci-*")
	require("luci.passwall.config_transaction").after(function()
		luci.sys.call("(sleep 1; /etc/init.d/rpcd restart) >/dev/null 2>&1 &")
	end)
	http.redirect(api.url())
end

function hide_menu()
	uci_set("@global[0]", "hide_from_luci", "1"); uci_save(true)
	api.remove("/tmp/luci-*")
	require("luci.passwall.config_transaction").after(function()
		luci.sys.call("(sleep 1; /etc/init.d/rpcd restart) >/dev/null 2>&1 &")
	end)
	http.redirect(luci.dispatcher.build_url("admin", "status", "overview"))
end

function link_add_node()
	local result = require("luci.passwall.link_import").upload(luci.dispatcher.context.authsession, {
		index=http.formvalue("chunk_index"), count=http.formvalue("total_chunks"),
		chunk=http.formvalue("chunk"), group=http.formvalue("group") or "default", id=http.formvalue("upload_id")
	})
	http_write_json(result)
end

function socks_autoswitch_add_node()
	local id = http.formvalue("id")
	local key = http.formvalue("key")
	if id and id ~= "" and key and key ~= "" then
		uci_set(id, "enable_autoswitch", "1")
		local new_list = uci_get(id, "autoswitch_backup_node") or {}
		for i = #new_list, 1, -1 do
			if (uci_get(new_list[i], "remarks") or ""):find(key, 1, true) then
				table.remove(new_list, i)
			end
		end
		for k, e in ipairs(api.get_valid_nodes()) do
			if e.node_type == "normal" and e["remark"]:find(key, 1, true) then
				table.insert(new_list, e.id)
			end
		end
		uci_set(id, "autoswitch_backup_node", new_list)
		uci_save()
	end
	http.redirect(api.url("socks_config", id))
end

function socks_autoswitch_remove_node()
	local id = http.formvalue("id")
	local key = http.formvalue("key")
	if id and id ~= "" and key and key ~= "" then
		uci_set(id, "enable_autoswitch", "1")
		local new_list = uci_get(id, "autoswitch_backup_node") or {}
		for i = #new_list, 1, -1 do
			if (uci_get(new_list[i], "remarks") or ""):find(key, 1, true) then
				table.remove(new_list, i)
			end
		end
		uci_set(id, "autoswitch_backup_node", new_list)
		uci_save()
	end
	http.redirect(api.url("socks_config", id))
end


function gen_client_config()
	local id = identifier(http.formvalue("id")); if not id then return end
	if uci:get(c_config, id) ~= "nodes" then http.status(404, "Node not found"); return end
	local config_file = api.TMP_PATH .. "/config_" .. id .. "_" .. api.gen_random_char()
	luci.sys.call(string.format("/usr/share/passwall/app.sh run_socks flag=config_%s node=%s bind=127.0.0.1 socks_port=1080 config_file=%s no_run=1", id, id, util.shellquote(config_file)))
	if nixio.fs.access(config_file) then
		http.prepare_content("application/json")
		http.write(fs.readfile(config_file))
		fs.remove(config_file)
	else
		http.redirect(api.url("node_list"))
	end
end

function get_now_use_node()
	local path = api.TMP_PATH .. "/acl/default"
	local e = {}
	local node = api.get_cache_var("ACL_GLOBAL_node")
	if node then
		e["global"] = node
	end
	http_write_json(e)
end

function get_redir_log()
	local id = identifier(http.formvalue("id")); if not id then return end
	local path = api.TMP_PATH .. "/acl/" .. id

	local function alert(msg)
		http.prepare_content("text/html; charset=utf-8")
		http.write(string.format("<script>alert('%s');window.close();</script>", i18n.translate(msg)))
	end

	local name = "global"
	if id and id ~= "default" then
		local global_node = uci_get("@global[0]", "node") or "nil"
		local acl_node = uci_get(id, "node") or "nil"
		local use_global_config = uci_get(id, "use_global_config") == "1"
		local global_enabled = uci_get("@global[0]", "enabled") == "1"
		if (use_global_config or acl_node == global_node) and global_enabled then
			path = api.TMP_PATH .. "/acl/default"
			if uci_get("@global[0]", "log_node") ~= "1" then
				alert("The access control node is the same as the global node. Please enable global logging.")
				return
			end
		else
			name = "node"
		end
	end

	path = path .. "/" .. name .. ".log"
	if fs.access(path) then
		http.prepare_content("text/plain; charset=utf-8")
		http.write(luci.sys.exec("tail -n 5000 " .. util.shellquote(path)))
	else
		alert("Not enabled log")
	end
end

function get_socks_log()
	local name = identifier(http.formvalue("name")); if not name then return end
	local path = api.TMP_PATH .. "/" .. name .. ".log"
	if fs.access(path) then
		http.prepare_content("text/plain; charset=utf-8")
		http.write(luci.sys.exec("tail -n 5000 " .. util.shellquote(path)))
	else
		http.prepare_content("text/html; charset=utf-8")
		http.write(string.format("<script>alert('%s');window.close();</script>", i18n.translate("Not enabled log")))
	end
end

function get_chinadns_log()
	local flag = identifier(http.formvalue("flag")); if not flag then return end
	local path = api.TMP_PATH .. "/acl/" .. flag .. "/chinadns_ng.log"
	if flag ~= "default" then
		local global_node = uci_get("@global[0]", "node") or "nil"
		local acl_node = uci_get(flag, "node") or "nil"
		local use_global_config = uci_get(flag, "use_global_config") == "1"
		if (use_global_config or acl_node == global_node) and uci_get("@global[0]", "enabled") == "1" then
			path = api.TMP_PATH .. "/acl/default/chinadns_ng.log"
			if uci_get("@global[0]", "log_chinadns_ng") ~= "1" then
				http.prepare_content("text/html; charset=utf-8")
				http.write(string.format("<script>alert('%s');window.close();</script>", i18n.translate("The access control node is the same as the global node. Please enable global logging.")))
				return
			end
		end
	end
	if fs.access(path) then
		http.prepare_content("text/plain; charset=utf-8")
		http.write(luci.sys.exec("tail -n 5000 " .. util.shellquote(path)))
	else
		http.prepare_content("text/html; charset=utf-8")
		http.write(string.format("<script>alert('%s');window.close();</script>", i18n.translate("Not enabled log")))
	end
end

function get_smartdns_log()
	local path = api.TMP_PATH .. "/acl/default/smartdns.log"
	if fs.access(path) then
		http.prepare_content("text/plain; charset=utf-8")
		http.write(luci.sys.exec("tail -n 5000 " .. util.shellquote(path)))
	else
		http.prepare_content("text/html; charset=utf-8")
		http.write(string.format("<script>alert('%s');window.close();</script>", i18n.translate("Not enabled log")))
	end
end

function get_log()
	-- luci.sys.exec("[ -f /tmp/log/passwall.log ] && sed '1!G;h;$!d' /tmp/log/passwall.log > /tmp/log/passwall_show.log")
	http.write(luci.sys.exec("[ -f '/tmp/log/passwall.log' ] && cat /tmp/log/passwall.log"))
end

function clear_log()
	luci.sys.call("echo '' > /tmp/log/passwall.log")
end

function plus_status()
	http.header("Cache-Control", "no-store")
	http_write_json(require("luci.passwall.overview").collect())
end

function plus_create()
	local access = util.ubus("session", "access", {
		ubus_rpc_session = luci.dispatcher.context.authsession,
		scope = "uci", object = c_config, ["function"] = "write"
	})
	if not access or not access.access then
		http.status(403, "Forbidden")
		return
	end
	local kind = http.formvalue("kind")
	if kind ~= "openvpn" and kind ~= "device" then
		http.status(400, "Invalid configuration kind")
		return
	end
	if kind == "openvpn" and not api.is_finded("openvpn") then
		http.status(409, "OpenVPN is not installed")
		return
	end
	local selected = http.formvalue("node")
	if selected and (kind ~= "device" or not selected:match("^[A-Za-z0-9_+%-]+$") or uci_get(selected, "type") ~= "OpenVPN") then
		http.status(400, "Invalid OpenVPN node")
		return
	end
	local id = (kind == "device" and "acl_" or "vpn_") .. api.gen_random_char(8)
	if kind == "openvpn" then
		uci:section(c_config, "nodes", id, {type = "OpenVPN", remarks = "OpenVPN", vpn_dns = "1.1.1.1"})
	else
		-- A draft never changes forwarding until the user enables and applies it.
		uci:section(c_config, "acl_rule", id, {enabled = "0", bind_enable = "1", mode = "1", use_global_config = "0"})
		if selected then uci_set(id, "node", selected) end
	end
	uci_save()
	http.redirect(api.url(kind == "openvpn" and "node_config" or "acl_config", id))
end

function index_status()
	local e = {}
	local dns_shunt = uci_get("@global[0]", "dns_shunt") or "dnsmasq"
	if dns_shunt == "smartdns" then
		local config_file = api.TMP_PATH .. "/acl/default/smartdns.conf"
		e.dns_mode_status = luci.sys.call("/bin/busybox top -bn1 | grep -v 'grep' | grep -F %s | grep 'smartdns' >/dev/null" % util.shellquote(config_file)) == 0
	elseif dns_shunt == "chinadns-ng" then
		e.dns_mode_status = luci.sys.call("/bin/busybox top -bn1 | grep -v 'grep' | grep '%s/bin/' | grep 'default' | grep 'chinadns_ng' >/dev/null" % api.TMP_PATH) == 0
	else
		e.dns_mode_status = luci.sys.call("netstat -apn | grep ':15353 ' >/dev/null") == 0
	end

	e.haproxy_status = "-1"
	if api.is_finded("haproxy") then
		e.haproxy_status = (luci.sys.call("/bin/busybox top -bn1 | grep -v 'grep' | grep '%s/bin/' | grep haproxy >/dev/null" % appname) == 0) and "0" or "1"
	end

	if api.get_cache_var("ENABLED_DEFAULT_ACL") == "1" then
		local has_tproxy = api.get_cache_var("HAS_TPROXY")
		if not has_tproxy then
			local handle = io.popen("lsmod")
			local mods = handle and handle:read("*a") or ""
			if handle then handle:close() end
			has_tproxy = (mods:find("TPROXY") or mods:find("nft_tproxy")) and "1" or "0"
			api.set_cache_var("HAS_TPROXY", has_tproxy)
		end
		e["tcp_status"] = luci.sys.call("/bin/busybox top -bn1 | grep -v 'grep' | grep '%s/bin/' | grep 'default' | grep 'global' >/dev/null" % api.TMP_PATH) == 0
		if has_tproxy == "1" then
			e["udp_status"] = luci.sys.call("/bin/busybox top -bn1 | grep -v -E 'grep|naive' | grep '%s/bin/' | grep 'default' | grep 'global' >/dev/null" % api.TMP_PATH) == 0
		end
	end
	http_write_json(e)
end

function haproxy_status()
	local e = {}
	e["status"] = luci.sys.call("/bin/busybox top -bn1 | grep -v 'grep' | grep '%s/bin/' | grep haproxy >/dev/null" % appname) == 0
	http_write_json(e)
end

function socks_status()
	if not identifier(http.formvalue("id")) then return end
	local e = {}
	local index = http.formvalue("index")
	local id = http.formvalue("id")
	e.index = index
	e.socks_status = luci.sys.call(string.format("/bin/busybox top -bn1 | grep -v -E 'grep|acl/|acl_' | grep '%s/bin/' | grep '/%s' > /dev/null", appname, id)) == 0
	local use_http = uci_get(id, "http_port") or 0
	e.use_http = 0
	if tonumber(use_http) > 0 then
		e.use_http = 1
		e.http_status = luci.sys.call(string.format("/bin/busybox top -bn1 | grep -v -E 'grep|acl/|acl_' | grep '%s/bin/' | grep '/%s' | grep -E '\\+http|_http' > /dev/null", appname, id)) == 0
	end
	http_write_json(e)
end

function connect_status()
	local e = {}
	e.use_time = ""
	local url = http.formvalue("url")
	if type(url) ~= "string" or not url:match("^https?://") or url:find("%z") then
		http_write_json(e)
		return
	end
	local aliyun = string.find(url, "aliyun")
	local chn_list = uci_get("@global[0]", "chn_list") or "direct"
	local gfw_list = uci_get("@global[0]", "use_gfw_list") or "1"
	local proxy_mode = uci_get("@global[0]", "tcp_proxy_mode") or "proxy"
	local localhost_proxy = uci_get("@global[0]", "localhost_proxy") or "1"
	local socks_server = (localhost_proxy == "0") and api.get_cache_var("GLOBAL_SOCKS_server") or ""
	local curl_args = "-w '%{http_code}:%{time_pretransfer}:%{time_starttransfer}' --url " .. util.shellquote(url)
	if socks_server and socks_server ~= "" then
		if (chn_list == "proxy" and gfw_list == "0" and proxy_mode ~= "proxy" and aliyun ~= nil) or (chn_list == "0" and gfw_list == "0" and proxy_mode == "proxy") then
		-- 中国列表+阿里 or 全局
			curl_args = "-x " .. util.shellquote("socks5h://" .. socks_server) .. " " .. curl_args
		elseif aliyun == nil then
		-- 其他代理模式+阿里以外网站
			curl_args = "-x " .. util.shellquote("socks5h://" .. socks_server) .. " " .. curl_args
		end
	end
	local result = luci.sys.exec('curl_result=$(/usr/bin/curl --connect-timeout 3 --max-time 5 -o /dev/null -I -sk ' .. curl_args .. '); [ $? -eq 0 ] && printf "%s" "$curl_result"')
	local code, pretransfer, starttransfer = result:match("^%s*(%d+):([%d%.]+):([%d%.]+)%s*$")
	code, pretransfer, starttransfer = tonumber(code), tonumber(pretransfer), tonumber(starttransfer)
	if code and code > 0 then e.http_code = code end
	-- A completed HTTP response, including 4xx/5xx, confirms homepage connectivity.
	if code and code >= 200 and code < 600 and pretransfer and pretransfer >= 0 and starttransfer and starttransfer > 0 and starttransfer >= pretransfer then
		-- HTTP request latency excludes connection and TLS handshakes.
		e.use_time = string.format("%.2f", (starttransfer - pretransfer) * 1000)
		e.handshake_time = string.format("%.2f", pretransfer * 1000)
		e.ping_type = "curl"
	end
	http_write_json(e)
end

function ping_node()
	local index = http.formvalue("index")
	local address = http.formvalue("address")
	local port = http.formvalue("port")
	local type = http.formvalue("type") or "icmp"
	if not address or #address > 253 or (not api.is_ip(address) and not api.datatypes.hostname(address)) then http.status(400, "Invalid host"); return end
	port = tonumber(port)
	if type == "tcping" and (not port or port % 1 ~= 0 or port < 1 or port > 65535) then http.status(400, "Invalid port"); return end
	local e = {}
	e.index = index
	if type == "tcping" and luci.sys.exec("echo -n $(command -v tcping)") ~= "" then
		if api.is_ipv6(address) then
			address = api.get_ipv6_only(address)
		end
		e.ping = luci.sys.exec(string.format("echo -n $(tcping -q -c 1 -i 1 -t 2 -p %s %s 2>&1 | grep -o 'time=[0-9]*' | awk -F '=' '{print $2}') 2>/dev/null", port, util.shellquote(address)))
	else
		e.ping = luci.sys.exec("echo -n $(ping -c 1 -W 1 %s 2>&1 | grep -o 'time=[0-9]*' | awk -F '=' '{print $2}') 2>/dev/null" % util.shellquote(address))
	end
	http_write_json(e)
end

function urltest_node()
	local index = http.formvalue("index")
	local id = http.formvalue("id")
	local e = {}
	e.index = index
	local result = luci.sys.exec("/usr/share/passwall/test.sh url_test_node " .. util.shellquote(id or ""))
	local code, pretransfer, starttransfer = result:match("^%s*(%d+):([%d%.]+):([%d%.]+)%s*$")
	code, pretransfer, starttransfer = tonumber(code), tonumber(pretransfer), tonumber(starttransfer)
	if code and code > 0 then e.http_code = code end
	if code and code >= 200 and code < 600 and pretransfer and pretransfer >= 0 and starttransfer and starttransfer > 0 and starttransfer >= pretransfer then
		-- Keep node test parsing independent from the homepage test.
		e.use_time = string.format("%.2f", (starttransfer - pretransfer) * 1000)
		e.handshake_time = string.format("%.2f", pretransfer * 1000)
	end
	http_write_json(e)
end

function update_config()
	local id = http.formvalue("id") -- Node id
	local data = http.formvalue("data") -- json new Data
	if id and data then
		local data_t = jsonParse(data) or {}
		if next(data_t) then
			for k, v in pairs(data_t) do
				uci_set(id, k, v)
			end
			uci_save()
			http_write_json_ok()
			return
		end
	end
	http_write_json_error()
end

function add_node()
	local redirect = http.formvalue("redirect")

	local uid = api.gen_random_char()
	uci:section(c_config, "nodes", uid)

	local group = http.formvalue("group")
	if group and group ~= "default" then
		uci_set(uid, "group", group)
	end

	if api.is_finded("ipt2socks") then
		uci_set(uid, "type", "Socks")
	elseif api.finded_com("sing-box") then
		uci_set(uid, "type", "sing-box")
	elseif api.finded_com("xray") then
		uci_set(uid, "type", "Xray")
	elseif api.is_finded("sslocal") then
		uci_set(uid, "type", "SS-Rust")
	elseif api.is_finded("ssr-local") then
		uci_set(uid, "type", "SSR")
	elseif api.finded_com("hysteria") then
		uci_set(uid, "type", "Hysteria2")
	elseif api.is_finded("naive") then
		uci_set(uid, "type", "Naiveproxy")
	end

	if redirect == "1" then
		uci_save()
		http.redirect(api.url("node_config", uid))
	else
		uci_save(true, true)
		http_write_json({result = uid})
	end
end

function set_node()
	local type = http.formvalue("type")
	local config = http.formvalue("config")
	local section = http.formvalue("section")
	if type == "@global[0]" then
		local node_protocol = uci_get(section, "protocol")
		if node_protocol == "_shunt" then
			local node_type = uci_get(section, "type")
			local dns_shunt = uci_get(type, "dns_shunt")
			local dns_key = (dns_shunt == "smartdns") and "smartdns_dns_mode" or "dns_mode"
			local dns_mode = uci_get(type, dns_key)
			local new_dns_mode = (node_type == "Xray") and "xray" or "sing-box"
			if dns_mode ~= new_dns_mode then
				uci_set(type, dns_key, new_dns_mode)
				uci_set(type, "v2ray_dns_mode", "tcp")
			end
		end
	end
	uci_set(type, config, section)
	uci_save(true, true)
	http.redirect(api.url("log"))
end

function copy_node()
	local section = http.formvalue("section")
	local uid = api.gen_random_char()
	uci:section(c_config, "nodes", uid)
	for k, v in pairs(uci_get(section)) do
		if not k:match("^%.") and k ~= "group" then
			if k == "remarks" then v = (v or "") .. "(1)" end
			uci_set(uid, k, v)
		end
	end
	uci_set(uid, "add_mode", 1)
	uci_save()
	http.redirect(api.url("node_config", uid))
end

function clear_all_nodes()
	uci_set('@global[0]', "enabled", "0")
	uci_set('@global[0]', "socks_enabled", "0")
	uci_set('@global_haproxy[0]', "balancing_enable", "0")
	uci_del('@global[0]', "node")
	uci_foreach("socks", function(t)
		uci_del(t[".name"])
		uci_set(t[".name"], "autoswitch_backup_node", {})
	end)
	uci_foreach("haproxy_config", function(t)
		uci_del(t[".name"])
	end)
	uci_foreach("acl_rule", function(t)
		uci_del(t[".name"], "node")
	end)
	uci_foreach("nodes", function(node)
		uci_del(node['.name'])
	end)
	uci_foreach("subscribe_list", function(t)
		uci_del(t[".name"], "md5")
		uci_del(t[".name"], "chain_proxy")
		uci_del(t[".name"], "preproxy_node")
		uci_del(t[".name"], "to_node")
	end)

	uci_save(true, true)
end

function delete_select_nodes()
	local ids = http.formvalue("ids")
	local redirect = http.formvalue("redirect")
	local ids_t = {}
	string.gsub(ids, '[^' .. "," .. ']+', function(w)
		ids_t[#ids_t + 1] = w
		if (uci_get("@global[0]", "node") or "") == w then
			uci_del('@global[0]', "node")
		end
		uci_foreach("socks", function(t)
			local changed = false
			local auto_switch_node_list = uci_get(t[".name"], "autoswitch_backup_node") or {}
			for i = #auto_switch_node_list, 1, -1 do
				if w == auto_switch_node_list[i] then
					table.remove(auto_switch_node_list, i)
					changed = true
				end
			end
			if changed then
				uci_set(t[".name"], "autoswitch_backup_node", auto_switch_node_list)
			end
			if t["node"] == w then
				local new_node = api.get_random_normal_node(ids_t)
				if new_node then
					uci_set(t[".name"], "node", new_node[".name"])
				else
					uci_set(t[".name"], "enabled", "0")
				end
			end
		end)
		uci_foreach("haproxy_config", function(t)
			if t["lbss"] == w then
				uci_del(t[".name"])
			end
		end)
		uci_foreach("acl_rule", function(t)
			if t["node"] == w then
				uci_del(t[".name"], "node")
			end
		end)
		uci_foreach("nodes", function(t)
			if t["preproxy_node"] == w then
				uci_del(t[".name"], "preproxy_node")
				uci_del(t[".name"], "chain_proxy")
			end
			if t["to_node"] == w then
				uci_del(t[".name"], "to_node")
				uci_del(t[".name"], "chain_proxy")
			end
			local list_name = t["urltest_node"] and "urltest_node" or (t["balancing_node"] and "balancing_node")
			if list_name then
				local nodes = uci:get_list(c_config, t[".name"], list_name)
				if nodes then
					local changed = false
					local new_nodes = {}
					for _, node in ipairs(nodes) do
						if node ~= w and node ~= socks then
							table.insert(new_nodes, node)
						else
							changed = true
						end
					end
					if changed then
						uci_set(t[".name"], list_name, new_nodes)
					end
				end
			end
			if t["fallback_node"] == w then
				uci_del(t[".name"], "fallback_node")
			end
		end)
		uci_foreach("subscribe_list", function(t)
			if t["preproxy_node"] == w then
				uci_del(t[".name"], "preproxy_node")
				uci_del(t[".name"], "chain_proxy")
			end
			if t["to_node"] == w then
				uci_del(t[".name"], "to_node")
				uci_del(t[".name"], "chain_proxy")
			end
		end)
		if (uci_get(w, "add_mode") or "0") == "2" then
			local group = uci_get(w, "group") or ""
			if group ~= "" then
				uci_foreach("subscribe_list", function(t)
					if t["remark"] == group then
						uci_del(t[".name"], "md5")
					end
				end)
			end
		end
		uci_del(w)
	end)
	if redirect == "1" then
		uci_save()
		http.redirect(api.url("node_list"))
	else
		uci_save(true, true)
	end
end

function get_node()
	local id = http.formvalue("id")
	local result = {}
	local show_node_info = uci_get("@global_other[0]", "show_node_info") or "0"

	local function add_is_ipv6_key(o)
		if o and o.address and show_node_info == "1" then
			local f = api.get_ipv6_full(o.address)
			if f ~= "" then
				o.ipv6 = true
				o.full_address = f
			end
		end
	end

	if id then
		result = uci_get(id)
		add_is_ipv6_key(result)
	else
		local default_nodes = {}
		local other_nodes = {}
		uci_foreach("nodes", function(t)
			add_is_ipv6_key(t)
			if not t.group or t.group == "" then
				default_nodes[#default_nodes + 1] = t
			else
				other_nodes[#other_nodes + 1] = t
			end
		end)
		for i = 1, #default_nodes do result[#result + 1] = default_nodes[i] end
		for i = 1, #other_nodes do result[#result + 1] = other_nodes[i] end
	end
	http_write_json(result)
end

function reassign_group()
	local ids = http.formvalue("ids") or ""
	local group = http.formvalue("group") or "default"
	if #group > 256 or group:find("%z") then http.status(400, "Invalid group"); return end
	local nodes = {}
	for id in ids:gmatch("([^,]+)") do
		if not identifier(id) then return end
		if uci:get(c_config, id) ~= "nodes" then http.status(400, "Invalid node"); return end
		nodes[#nodes + 1] = id
	end
	if #nodes == 0 then http.status(400, "Missing nodes"); return end
	for _, id in ipairs(nodes) do
		if group ~= "" and group ~= "default" then uci_set(id, "group", group)
		else uci_del(id, "group") end
	end
	uci_save(true)
	http_write_json({ status = "ok" })
end

function save_node_list_opt()
	local option = identifier(http.formvalue("option")); if not option then return end
	local value = http.formvalue("value") or ""
	if #value > 8192 or value:find("%z") then http.status(400, "Invalid option value"); return end
	uci_set("@global_other[0]", option, value); uci_save(true)
	http_write_json({ status = "ok" })
end

function update_rules()
	local update = http.formvalue("update") or ""
	if update == "" then
		http_write_json_error({ message = "missing update target" })
		return
	end
	luci.sys.call("lua /usr/share/passwall/rule_update.lua log " .. util.shellquote(update) .. " >/dev/null 2>&1 &")
	http_write_json()
end

function rollback_rules()
	local arg_type = http.formvalue("type")
	local rules = http.formvalue("rules") or ""
	if arg_type ~= "geoip" and arg_type ~= "geosite" then
		http_write_json_error()
		return
	end
	local bak_dir = "/tmp/bak_v2ray/"
	local geo_dir = (uci_get("@global_rules[0]", "v2ray_location_asset") or "/usr/share/v2ray/")
	local geo2rule = uci_get("@global_rules[0]", "geo2rule") or "0"
	fs.move(bak_dir .. arg_type .. ".dat", geo_dir .. arg_type .. ".dat")
	fs.rmdir(bak_dir)
	if geo2rule == "1" and rules ~= "" then
		require("luci.passwall.config_transaction").after(function()
			luci.sys.call("lua /usr/share/passwall/rule_update.lua log " .. util.shellquote(rules) .. " rollback >/dev/null 2>&1 &")
		end)
	end
	uci_set("@global[0]", "flush_set", "1")
	uci_save(true)
	http_write_json_ok()
end

function server_update_config()
	local id = http.formvalue("id") -- Node id
	local data = http.formvalue("data") -- json new Data
	if id and data then
		local data_t = jsonParse(data) or {}
		if next(data_t) then
			for k, v in pairs(data_t) do
				api.uci_set_s(id, k, v)
			end
			api.uci_save_s()
			http_write_json_ok()
			return
		end
	end
	http_write_json_error()
end

function server_status()
	if not identifier(http.formvalue("id")) then return end
	local e = {}
	e.index = http.formvalue("index")
	e.status = luci.sys.call(string.format("/bin/busybox top -bn1 | grep -v 'grep' | grep '%s/bin/' | grep -i '%s' >/dev/null", appname .. "_server", http.formvalue("id"))) == 0
	http_write_json(e)
end

function server_log()
	local id = identifier(http.formvalue("id")); if not id then return end
	local f_file = api.S_TMP_PATH .. "/" .. id .. ".log"
	if nixio.fs.access(f_file) then
		http.prepare_content("text/plain; charset=utf-8")
		local content = fs.readfile(f_file) or ""
		http.write(content)
	else
		http.write(string.format("<script>alert('%s');window.close();</script>", i18n.translate("Not enabled log")))
	end
end

function server_get_log()
	http.write(luci.sys.exec("[ -f '/tmp/log/passwall_server.log' ] && cat /tmp/log/passwall_server.log"))
end

function server_clear_log()
	luci.sys.call("echo '' > /tmp/log/passwall_server.log")
end

function app_check()
	local json = api.to_check_self()
	http_write_json(json)
end

function app_update()
	local id = http.formvalue("id")
	if not id or not id:match("^[%w_-]+$") then http_write_json({code = 1}); return end
	local task = http.formvalue("task")
	local result
	if task == "progress" then
		result = api.to_download_progress(appname, id, http.formvalue("total_size"))
	elseif task == "install" then
		if not luci.dispatcher.test_post_security() then return end
		result = api.to_install_self(id, http.formvalue("force"))
	else
		local part = http.formvalue("part") == "2" and "2" or "1"
		result = api.to_download(appname, http.formvalue("url"), http.formvalue("size"), id .. part, part == "2")
	end
	http_write_json(result)
end

function com_check(comname)
	local json = api.to_check("",comname)
	http_write_json(json)
end

function com_update(comname)
	local json = nil
	local task = http.formvalue("task")
	if task == "progress" then
		json = api.to_download_progress(comname, http.formvalue("id"), http.formvalue("total_size"))
	elseif task == "extract" then
		json = api.to_extract(comname, http.formvalue("file"), http.formvalue("subfix"))
	elseif task == "move" then
		json = api.to_move(comname, http.formvalue("file"))
	else
		json = api.to_download(comname, http.formvalue("url"), http.formvalue("size"), http.formvalue("id"))
	end

	http_write_json(json)
end

function com_version(comname)
	local version = api.get_app_version(comname)
	http_write_json_ok(version)
end

function read_rulelist()
	local rule_type = http.formvalue("type")
	local rule_path
	if rule_type == "gfw" then
		rule_path = "/usr/share/passwall/rules/gfwlist"
	elseif rule_type == "chn" then
		rule_path = "/usr/share/passwall/rules/chnlist"
	elseif rule_type == "chnroute" then
		rule_path = "/usr/share/passwall/rules/chnroute"
	else
		http.status(400, "Invalid rule type")
		return
	end
	if fs.access(rule_path) then
		http.prepare_content("text/plain")
		http.write(fs.readfile(rule_path))
	end
end

function create_backup()
	local runtime = require "luci.passwall.backup_runtime"
	local data = runtime.create(luci.dispatcher.context.authsession, api.get_version())
	local filename = "passwall-" .. os.date("%Y%m%d%H%M%S") .. "-backup.tar.gz"
	http.header("Content-Disposition", "attachment; filename=" .. filename)
	http.header("X-Backup-Filename", filename)
	http.prepare_content("application/octet-stream")
	http.write(data)
end

function restore_backup()
	local kind = http.formvalue("type")
	local result = require("luci.passwall.backup_runtime").upload(luci.dispatcher.context.authsession, {
		kind=kind, index=http.formvalue("chunk_index"), count=http.formvalue("total_chunks"),
		chunk=http.formvalue("chunk"), id=http.formvalue("upload_id")
	}, api.get_version())
	if result.restored then
		-- Release before starting a service that waits for this same update lock.
		if kind ~= "server" then
			uci:revert(c_config)
			require("luci.passwall.config_transaction").after(function() luci.sys.call('/etc/init.d/passwall restart >/dev/null 2>&1 &') end)
		end
		if kind ~= "client" then
			uci:revert(api.s_config)
			require("luci.passwall.config_transaction").after(function() luci.sys.call('/etc/init.d/passwall_server restart >/dev/null 2>&1 &') end)
		end
	end
	http_write_json(result)
end

function reset_config()
	local kind = http.formvalue("type")
	require("luci.passwall.backup_runtime").reset(luci.dispatcher.context.authsession, kind)
	local config = kind == "client" and c_config or api.s_config
	uci:revert(config)
	require("luci.passwall.config_transaction").after(function()
		luci.sys.call('/etc/init.d/' .. config .. ' stop >/dev/null 2>&1 &')
	end)
	api.log(" * 恢复默认配置成功。")
	http_write_json({status="success"})
end

function geo_view()
	local action = http.formvalue("action")
	local value = http.formvalue("value")
	if not value or value == "" then
		http.prepare_content("text/plain")
		http.write(i18n.translate("Please enter query content!"))
		return
	end
	local function get_rules(str, type)
		local rules = {}
		uci_foreach("shunt_rules", function(s)
			local list
			if type == "geoip" then list = s.ip_list else list = s.domain_list end
			for line in string.gmatch((list or ""), "[^\r\n]+") do
				if line ~= "" and not line:find("#") then
					local prefix, main = line:match("^(.-):(.*)")
					if not main then main = line end
					if type == "geoip" and (api.datatypes.ipaddr(str) or api.datatypes.ip6addr(str)) then
						if main:find(str, 1, true) then
							table.insert(rules, {id = s[".name"], group = s.group or i18n.translate("default")})
						end
					else
						if main == str then
							table.insert(rules, {id = s[".name"], group = s.group or i18n.translate("default")})
						end
					end
				end
			end
		end)
		return rules
	end
	local geo_dir = (uci_get("@global_rules[0]", "v2ray_location_asset") or "/usr/share/v2ray/"):match("^(.*)/")
	local geosite_path = geo_dir .. "/geosite.dat"
	local geoip_path = geo_dir .. "/geoip.dat"
	local geo_type, file_path, cmd
	local geo_string = ""
	local bin = api.finded_com("geoview")
	if not bin then http.status(503, "Geoview unavailable"); return end
	if action == "lookup" then
		if api.datatypes.ipaddr(value) or api.datatypes.ip6addr(value) then
			geo_type, file_path = "geoip", geoip_path
		else
			geo_type, file_path = "geosite", geosite_path
		end
		cmd = string.format("%s -type %s -action lookup -input %s -value %s -lowmem=true", util.shellquote(bin), util.shellquote(geo_type), util.shellquote(file_path), util.shellquote(value))
		geo_string = luci.sys.exec(cmd):lower()
		if geo_string ~= "" then
			local lines, rules, seen = {}, {}, {}
			for line in geo_string:gmatch("([^\n]+)") do
				lines[#lines + 1] = geo_type .. ":" .. line
				for _, r in ipairs(get_rules(line, geo_type) or {}) do
					if not seen[r.id] then
						seen[r.id] = true
						rules[#rules + 1] = string.format("[%s]%s", r.group, r.id)
					end
				end
			end
			for _, r in ipairs(get_rules(value, geo_type) or {}) do
				if not seen[r.id] then
					seen[r.id] = true
					rules[#rules + 1] = string.format("[%s]%s", r.group, r.id)
				end
			end
			geo_string = table.concat(lines, "\n")
			if #rules > 0 then
				geo_string = geo_string .. "\n--------------------\n"
				geo_string = geo_string .. i18n.translate("Rules containing this value:") .. "\n"
				geo_string = geo_string .. table.concat(rules, "\n")
			end
		end
	elseif action == "extract" then
		local prefix, list = value:match("^(geoip:)(.*)$")
		if not prefix then
			prefix, list = value:match("^(geosite:)(.*)$")
		end
		if prefix and list and list ~= "" then
			geo_type = prefix:sub(1, -2)
			file_path = (geo_type == "geoip") and geoip_path or geosite_path
			cmd = string.format("%s -type %s -action extract -input %s -list %s -lowmem=true", util.shellquote(bin), util.shellquote(geo_type), util.shellquote(file_path), util.shellquote(list))
			geo_string = luci.sys.exec(cmd)
		end
	end
	http.prepare_content("text/plain")
	if geo_string and geo_string ~="" then
		http.write(geo_string)
	else
		http.write(i18n.translate("No results were found!"))
	end
end

function subscribe_del_node()
	local remark = http.formvalue("remark")
	if remark and remark ~= "" then
		luci.sys.call("lua /usr/share/" .. appname .. "/subscribe.lua truncate " .. luci.util.shellquote(remark) .. " > /dev/null 2>&1")
	end
	http.status(200, "OK")
end

function subscribe_del_all()
	luci.sys.call("lua /usr/share/" .. appname .. "/subscribe.lua truncate > /dev/null 2>&1")
	http.status(200, "OK")
end

function subscribe_manual()
	local section = identifier(http.formvalue("section")); if not section then return end
	local current_url = http.formvalue("url")
	if type(current_url) ~= "string" or current_url == "" or #current_url > 8192 or current_url:find("%z") then
		http.status(400, "Invalid subscription URL"); return
	end
	local uci_url = uci_get(section, "url")
	if uci:get(c_config, section) ~= "subscribe_list" or not uci_url or uci_url == "" then
		http_write_json({ success = false, msg = i18n.translate("Please save and apply before manually subscribing.") })
		return
	end
	if uci_url ~= current_url then
		uci_set(section, "url", current_url); uci_save(true)
	end
	require("luci.passwall.config_transaction").after(function() luci.sys.call("lua /usr/share/" .. appname .. "/subscribe.lua start " .. util.shellquote(section) .. " manual >/dev/null 2>&1 &") end)
	http_write_json({ success = true, msg = "Subscribe triggered." })
end

function subscribe_manual_all()
	local sections = jsonParse(http.formvalue("sections") or "")
	local urls = jsonParse(http.formvalue("urls") or "")
	local function array(value)
		if type(value) ~= "table" or #value < 1 or #value > 256 then return false end
		for key in pairs(value) do if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then return false end end
		return true
	end
	if not array(sections) or not array(urls) or #sections ~= #urls then
		http.status(400, "Invalid subscription list"); return
	end
	local seen = {}
	for i, section in ipairs(sections) do
		if not identifier(section) or seen[section] or type(urls[i]) ~= "string" or urls[i] == "" or #urls[i] > 8192 or urls[i]:find("%z") then
			http.status(400, "Invalid subscription"); return
		end
		seen[section] = true
		if uci:get(c_config, section) ~= "subscribe_list" or not uci_get(section, "url") then
			http_write_json({ success = false, msg = i18n.translate("Please save and apply before manually subscribing.") }); return
		end
	end
	local changed = false
	for i, section in ipairs(sections) do
		if uci_get(section, "url") ~= urls[i] then uci_set(section, "url", urls[i]); changed = true end
	end
	if changed then uci_save(true) end
	require("luci.passwall.config_transaction").after(function() luci.sys.call("lua /usr/share/" .. appname .. "/subscribe.lua start all manual >/dev/null 2>&1 &") end)
	http_write_json({ success = true, msg = "Subscribe triggered." })
end

function flush_set()
	local redirect = http.formvalue("redirect") or "0"
	local reload = http.formvalue("reload") or "0"
	if reload == "1" then
		uci_set('@global[0]', "flush_set", "1")
		uci_save(true, true)
	else
		uci_set("@global[0]", "flush_set", "1"); uci_save(true)
	end
	if redirect == "1" then
		http.redirect(api.url("log"))
	end
end

function fetch_certsha256()
	local id = http.formvalue("id") or ""
	local address = (id ~= "") and uci_get(id, "address") or ""
	local port = (id ~= "") and uci_get(id, "port") or 0
	local sni = (id ~= "") and uci_get(id, "tls_serverName") or ""
	sni = (sni ~= "") and sni or address
	local protocol = uci_get(id, "protocol")
	local h3, timeout = false, 10
	if protocol == "hysteria2" then
		h3 = true
		timeout = 60
		if port == 0 then
			local hop = uci_get(id, "hysteria2_hop") or "0"
			port = tonumber(hop:match("^%s*(%d+)"))
		end
	end
	if address == "" or port == 0 then
		http_write_json_error()
		return
	end
	local data = api.fetch_cert_sha256(address, port, sni, timeout, h3)
	http_write_json(data ~= "" and { code = 1, data = data } or { code = 0 })
end

function get_shunt_rules()
	local id = http.formvalue("id")
	local result = {}

	if id then
		result = uci_get(id)
	else
		local default_items = {}
		local other_items = {}
		uci_foreach("shunt_rules", function(t)
			if not t.group or t.group == "" then
				default_items[#default_items + 1] = t
			else
				other_items[#other_items + 1] = t
			end
		end)
		for i = 1, #default_items do result[#result + 1] = default_items[i] end
		for i = 1, #other_items do result[#result + 1] = other_items[i] end
	end
	http_write_json(result)
end

function add_shunt_rule()
	local add_name = http.formvalue("add_name")
	local redirect = http.formvalue("redirect")

	local uid = add_name
	if add_name then
		local has = uci_get(uid)
		if has then
			http_write_json_error({ message = i18n.translate("This ID already exists.") })
			return
		end
	else
		uid = api.gen_random_char()
	end
	uci:section(c_config, "shunt_rules", uid)

	local group = http.formvalue("group")
	if group and group ~= "default" then
		uci_set(uid, "group", group)
	end

	if redirect == "1" then
		uci_save()
		http.redirect(api.url("shunt_rules", uid))
	else
		uci_save()
		http_write_json_ok({uid = uid, redirect_url = api.url("shunt_rules", uid)})
	end
end

function delete_select_shunt_rules()
	local ids = http.formvalue("ids")
	local redirect = http.formvalue("redirect")
	string.gsub(ids, '[^' .. "," .. ']+', function(w)
		uci_foreach("nodes", function(s)
			if s["protocol"] and s["protocol"] == "_shunt" then
				uci_del(s[".name"], w)
			end
		end)
		uci_del(w)
	end)
	if redirect == "1" then
		uci_save()
		http.redirect(api.url("rule"))
	else
		uci_save(true, true)
	end
end

function gen_wireguard_key()
	local key = api.gen_wireguard_key()
	if key then
		http_write_json_ok(key)
	else
		http_write_json_error()
	end
end

-- Serialize local shortcuts with subscriptions, cloud tasks and guard recovery.
local function config_access(action, permission)
	local backup = action == "restore_backup" or action == "reset_config"
	local server = action:match("^server_") or (backup and http.formvalue("type") == "server")
	local configs = {server and api.s_config or c_config}
	if (backup and http.formvalue("type") == "all") or action == "create_backup" then configs = {c_config, api.s_config} end
	for _, config in ipairs(configs) do
		local access = util.ubus("session", "access", {ubus_rpc_session=luci.dispatcher.context.authsession,
			scope="uci", object=config, ["function"]=permission or (action == "create_backup" and "read" or "write")})
		if not access or not access.access then http.status(403, "Forbidden"); return nil end
	end
	return configs
end

function config_action(action)
	local configs = config_access(action); if not configs then return end
	local T = require "luci.passwall.config_transaction"
	local ok, err = T.run(function()
		local expected = http.formvalue("config_revision")
		if expected and not T.check(expected, configs[1]) then error("config_conflict", 0) end
		return _M[action]()
	end)
	if not ok then
		for _, config in ipairs(configs) do pcall(function() uci:revert(config) end) end
		http.status(409, "Configuration operation rejected")
		local message = tostring(err):match("^[a-z_]+$") and err or "configuration_operation_failed"
		http_write_json({status="error", code=0, message=message})
	end
end

function write_action(action, ...)
	if not config_access(action) then return end
	return _M[action](...)
end

function component_action(action, component)
	if http.formvalue("task") == "progress" then
		if not config_access(action, "read") then return end
	else
		if not luci.dispatcher.test_post_security() then return end
		if not config_access(action) then return end
	end
	return _M[action](component)
end

function menu_action(action)
	if http.getenv("REQUEST_METHOD") == "POST" then
		if not luci.dispatcher.test_post_security() then return end
		return config_action(action)
	end
	if not config_access(action) then return end
	require("luci.template").render("passwall/menu_visibility", {show_menu=action == "show_menu"})
end
