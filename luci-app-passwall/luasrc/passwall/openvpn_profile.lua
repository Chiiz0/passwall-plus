-- Only validate profile structure here; the runtime sanitizer remains authoritative.
local M = {}
function M.validate(value)
	value = (value or ""):gsub("^\239\187\191", ""):gsub("\r\n", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
	if value == "" then return nil, "OpenVPN client profile is required." end
	if #value > 131072 then return nil, "OpenVPN client profile must not exceed 128 KiB." end
	if value:find("%z") then return nil, "OpenVPN client profile contains invalid data." end
	local inline, remote, ipv4_remote = nil, false, false
	for line in (value .. "\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("^%s+", ""):gsub("%s+$", "")
		local lower = line:lower()
		if inline then
			if lower:match("^</" .. inline .. ">%s*$") then inline = nil end
		else
			local tag = lower:match("^<([%w%-]+)>%s*$")
			if tag and tag ~= "connection" then inline = tag
			elseif not lower:match("^[#;]") then
				local host = lower:gsub("^%-%-", ""):match("^remote%s+(%S+)")
				if host then
					remote = true
					if not host:find(":", 1, true) and not host:find("[", 1, true) then ipv4_remote = true end
				end
			end
		end
	end
	if not remote then return nil, "OpenVPN client profile must contain a remote directive." end
	if not ipv4_remote then return nil, "This firmware requires an IPv4 address or hostname in a remote directive." end
	return value
end
return M
