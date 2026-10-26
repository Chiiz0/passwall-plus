module("luci.controller.passwall_ezcnet", package.seeall)

function index()
	local page = entry({"admin", "services", "passwall_ezcnet"}, cbi("passwall_ezcnet"), "passwall-EzCNet", 90)
	page.dependent = true
	page.acl_depends = {"luci-app-passwall-ezcnet"}
end
