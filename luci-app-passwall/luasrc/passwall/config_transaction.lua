-- All Plus configuration writers use the subscription/guard POSIX record lock.
-- Never hold it while waiting for the protected service restart.
local M = {}
local held, depth = nil, 0
local deferred = {}
function M.active() return held ~= nil end
function M.after(callback) deferred[#deferred + 1] = callback end
function M.acquire()
	if held then depth = depth + 1; return true end
	local nixio = require "nixio"
	local f = nixio.open('/var/lock/passwall_sub_rule.lock', nixio.open_flags('rdwr', 'creat'), '600')
	if not f then return nil, 'config_lock_unavailable' end
	if not f:lock('tlock') then f:close(); return nil, 'config_busy' end
	held, depth = f, 1
	local ok, err = pcall(function() require('luci.passwall.backup_runtime').recover() end)
	if not ok then
		nixio.syslog('err', 'PassWall restore recovery failed: ' .. (tostring(err):match('^[a-z_]+$') and err or 'restore_recovery_required'))
		M.release(); return nil, 'restore_recovery_required'
	end
	return true
end
function M.release()
	depth = depth - 1
	if depth <= 0 then
		if held then held:close() end
		held, depth = nil, 0
	end
end
function M.revision(config)
	assert(config == 'passwall' or config == 'passwall_server', 'invalid_config')
	local f = assert(io.popen('sha256sum /etc/config/' .. config .. ' 2>/dev/null'))
	local digest = (f:read('*l') or ''):match('^(%x+)')
	f:close()
	assert(digest and #digest == 64, 'config_unavailable')
	return digest
end
function M.form_revision(config)
	M.revision(config) -- Fail if the active UCI file is missing.
	local paths = {'/etc/config/' .. config}
	if config == 'passwall' then
		for _, name in ipairs(require('luci.passwall.backup').files) do
			if name:match('^etc/passwall/rules/') then paths[#paths + 1] = '/' .. name end
		end
		paths[#paths + 1] = '/etc/hosts'
	end
	local f = assert(io.popen('sha256sum ' .. table.concat(paths, ' ') .. ' 2>/dev/null | sha256sum'))
	local digest = (f:read('*l') or ''):match('^(%x+)'); f:close()
	assert(digest and #digest == 64, 'config_unavailable'); return digest
end
function M.check(expected, config)
	return type(expected) == 'string' and #expected == 64 and expected == M.revision(config)
end
-- Persist this cursor's view without rpcd's commit-triggered service reload.
-- This also consumes its session delta, so LuCI's global Apply cannot replay it.
function M.commit(cursor, config)
	assert(held, 'config_lock_required')
	assert(config == 'passwall' or config == 'passwall_server', 'invalid_config')
	local fs, nixio = require 'nixio.fs', require 'nixio'
	local sections, lines = {}, {}
	for _, section in pairs(assert(cursor:get_all(config))) do sections[#sections + 1] = section end
	table.sort(sections, function(a,b) return a['.index'] < b['.index'] end)
	local function quote(value)
		value = tostring(value); assert(not value:find('%z'), 'invalid_config_value')
		return "'" .. value:gsub("'", "'\\''") .. "'"
	end
	for _, section in ipairs(sections) do
		lines[#lines + 1] = 'config ' .. quote(section['.type']) .. (section['.anonymous'] and '' or ' ' .. quote(section['.name']))
		local keys = {}; for key in pairs(section) do if key:sub(1,1) ~= '.' then keys[#keys + 1] = key end end
		table.sort(keys)
		for _, key in ipairs(keys) do
			local value = section[key]
			if type(value) == 'table' then
				for _, item in ipairs(value) do lines[#lines + 1] = '\tlist ' .. quote(key) .. ' ' .. quote(item) end
			else lines[#lines + 1] = '\toption ' .. quote(key) .. ' ' .. quote(value) end
		end
		lines[#lines + 1] = ''
	end
	local data = table.concat(lines, '\n') .. '\n'
	local id = assert(fs.readfile('/proc/sys/kernel/random/uuid')):gsub('[^%x]', '')
	local tmp = '/etc/config/.' .. config .. '-' .. id
	local f = assert(nixio.open(tmp, nixio.open_flags('wronly','creat','excl'), '600'))
	local ok, err = pcall(function()
		local offset = 0
		while offset < #data do local count = assert(f:write(data, offset)); assert(count > 0); offset = offset + count end
		assert(f:sync()); f:close(); f = nil
		assert(cursor:revert(config))
		assert(fs.rename(tmp, '/etc/config/' .. config))
		local directory = assert(nixio.open('/etc/config', 'r')); assert(directory:sync()); directory:close()
	end)
	if f then f:close() end
	fs.remove(tmp)
	if not ok then error(err, 0) end
	return true
end
function M.run(callback)
	local ok, err = M.acquire()
	if not ok then return nil, err end
	local result = {pcall(callback)}
	M.release()
	if depth == 0 then
		local callbacks = deferred; deferred = {}
		if result[1] then for _, fn in ipairs(callbacks) do fn() end end
	end
	if not result[1] then return nil, tostring(result[2]) end
	return true, unpack(result, 2)
end
return M
