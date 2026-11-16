local B = require 'luci.passwall.backup'
local fs, nixio = require 'nixio.fs', require 'nixio'
local json, util = require 'luci.jsonc', require 'luci.util'
local M = {}
local journal_path = '/etc/passwall/.restore-journal.json'
local function check(ok, code) if not ok then error(code, 0) end end
local function regular(path) return fs.lstat(path, 'type') == 'reg' end
local function safe_parent(path)
	local current = ''
	for part in path:match('^(.*)/[^/]+$'):gmatch('[^/]+') do
		current = current .. '/' .. part
		check(fs.lstat(current, 'type') == 'dir', 'unsafe_backup_path')
	end
	check(not fs.lstat(path) or regular(path), 'unsafe_backup_path')
end
local function write(path, data)
	safe_parent(path)
	local tmp = path .. '.restore-new'
	check(not fs.lstat(tmp) or regular(tmp), 'unsafe_backup_path')
	local f = assert(nixio.open(tmp, nixio.open_flags('wronly', 'creat', 'trunc'), '600'))
	assert(fs.chmod(tmp, '600'))
	local offset = 0
	while offset < #data do local n = assert(f:write(data, offset)); assert(n > 0); offset = offset + n end
	assert(f:sync()); f:close()
	assert(fs.rename(tmp, path))
	local dir = assert(nixio.open(path:match('^(.*)/[^/]+$'), 'r')); assert(dir:sync()); dir:close()
end
local function hash(path)
	local f = assert(io.popen('sha256sum ' .. util.shellquote(path) .. ' 2>/dev/null'))
	local value = (f:read('*l') or ''):match('^(%x+)'); f:close(); return value
end
local function clear_journal()
	assert(fs.remove(journal_path))
	local dir = assert(nixio.open('/etc/passwall', 'r')); assert(dir:sync()); dir:close()
end
function M.recover()
	if not fs.lstat(journal_path) then return true end
	check(regular(journal_path), 'restore_recovery_required')
	local j = json.parse(fs.readfile(journal_path) or '')
	check(type(j) == 'table' and j.schema == 1 and type(j.files) == 'table', 'restore_recovery_required')
	local allowed = {}; for _, name in ipairs(B.files) do allowed['/' .. name] = true end
	for _, entry in ipairs(j.files) do
		check(allowed[entry.path] and (entry.old == false or type(entry.old) == 'string'), 'restore_recovery_required')
		safe_parent(entry.path)
		local current = fs.readfile(entry.path)
		check(current == entry.old or (current == nil and entry.old == false) or hash(entry.path) == entry.new_hash, 'restore_recovery_conflict')
	end
	for _, entry in ipairs(j.files) do
		if entry.old == false then fs.remove(entry.path) else write(entry.path, entry.old) end
	end
	clear_journal()
	return true
end
function M.install(files, directory)
	-- Validate both UCI files in isolation before touching any active file.
	assert(fs.mkdir(directory .. '/config', '700')); assert(fs.mkdir(directory .. '/delta', '700'))
	for _, config in ipairs({'passwall', 'passwall_server'}) do
		local data = files['etc/config/' .. config]
		if data then
			check(not data:find('%z') and #data > 0, 'invalid_backup_config')
			write(directory .. '/config/' .. config, data)
			local cursor = require('uci').cursor(directory .. '/config', directory .. '/delta')
			check(cursor:load(config), 'invalid_backup_config')
			local globals = 0
			cursor:foreach(config, 'global', function(s)
				globals = globals + 1
				check(not s.tcp_node and not s.udp_node, 'incompatible_backup_config')
			end)
			check(globals == 1, 'invalid_backup_config')
			cursor:unload(config)
		end
	end
	local j, old_size = {schema = 1, files = {}}, 0
	for _, name in ipairs(B.files) do
		if files[name] ~= nil then
			local path = '/' .. name; safe_parent(path)
			old_size = old_size + (fs.stat(path, 'size') or 0)
			check(old_size <= B.max_expanded, 'backup_too_large')
			write(directory .. '/candidate', files[name])
			j.files[#j.files + 1] = {path = path, old = fs.readfile(path) or false, new_hash = assert(hash(directory .. '/candidate'))}
		end
	end
	write(journal_path, json.stringify(j))
	local ok = pcall(function()
		for _, entry in ipairs(j.files) do write(entry.path, files[entry.path:sub(2)]) end
	end)
	if not ok then M.recover(); error('restore_write_failed_rolled_back', 0) end
	clear_journal()
	return true
end
local function root(session)
	check(type(session) == 'string' and #session == 32 and session:match('^%x+$'), 'invalid_session')
	local dir = '/tmp/passwall-backup-' .. session
	if not fs.lstat(dir) then check(fs.mkdir(dir, '700'), 'backup_storage_unavailable') end
	check(fs.lstat(dir, 'type') == 'dir' and fs.stat(dir, 'uid') == nixio.getuid(), 'unsafe_backup_path'); assert(fs.chmod(dir, '700'))
	return dir
end
function M.cleanup(dir)
	-- All descendants were created here; tar never creates paths or links.
	for _, name in ipairs({'passwall','passwall_server'}) do
		fs.remove(dir .. '/config/' .. name); fs.remove(dir .. '/config/' .. name .. '.restore-new')
	end
	fs.rmdir(dir .. '/config'); fs.rmdir(dir .. '/delta')
	for _, name in ipairs({'upload','meta','candidate','backup.tar.gz','passwall-version','passwall-backup-schema'}) do fs.remove(dir .. '/' .. name); fs.remove(dir .. '/' .. name .. '.restore-new') end
end
function M.reset(session, kind)
	check(kind == 'client' or kind == 'server', 'invalid_restore_type')
	local dir = root(session); M.cleanup(dir)
	local ok, result = pcall(function()
		local files = {}
		if kind == 'server' then files['etc/config/passwall_server'] = "config global 'global'\n"
		else
			files['etc/config/passwall'] = assert(fs.readfile('/usr/share/passwall/0_default_config'))
			for _, name in ipairs(B.files) do
				local rule = name:match('^etc/passwall/rules/(.+)$')
				if rule then files[name] = assert(fs.readfile('/usr/share/passwall/rules/' .. rule)) end
			end
		end
		return M.install(files, dir)
	end)
	M.cleanup(dir)
	if not ok then error(result, 0) end
	return result
end
function M.upload(session, args, version)
	local dir = root(session)
	local index, count = tonumber(args.index), tonumber(args.count)
	check(index and count and index % 1 == 0 and count % 1 == 0 and count >= 1 and count <= 161 and index >= 0 and index < count, 'invalid_chunk_sequence')
	check(type(args.chunk) == 'string' and #args.chunk <= 87384 and #args.chunk > 0 and #args.chunk % 4 == 0 and args.chunk:match('^[A-Za-z0-9+/]*=?=?$'), 'invalid_chunk')
	local data = nixio.bin.b64decode(args.chunk)
	check(data and nixio.bin.b64encode(data) == args.chunk, 'invalid_chunk')
	check(args.kind == 'client' or args.kind == 'server' or args.kind == 'all', 'invalid_restore_type')
	local T = require 'luci.passwall.config_transaction'
	local meta
	if index == 0 then
		M.cleanup(dir)
		meta = {id=(fs.readfile('/proc/sys/kernel/random/uuid') or ''):gsub('[^%x]', ''), next=0, count=count, size=0, kind=args.kind, expires=os.time()+600,
			client=T.revision('passwall'), server=T.revision('passwall_server')}
		meta.files = {}; for _, name in ipairs(B.files) do meta.files[name] = hash('/' .. name) or false end
		check(#meta.id == 32, 'upload_id_unavailable'); write(dir .. '/upload', '')
	else meta = json.parse(fs.readfile(dir .. '/meta') or '') end
	check(meta and meta.next == index and meta.count == count and meta.kind == args.kind and meta.expires > os.time() and (index == 0 or meta.id == args.id), 'invalid_upload_session')
	check(meta.size + #data <= B.max_upload, 'backup_too_large')
	check(regular(dir .. '/upload') and fs.stat(dir .. '/upload', 'size') == meta.size, 'invalid_upload_session')
	local f = assert(io.open(dir .. '/upload', 'ab')); assert(f:write(data)); f:close()
	meta.size, meta.next = meta.size + #data, index + 1
	write(dir .. '/meta', json.stringify(meta))
	if meta.next < count then return {status='success', upload_id=meta.id} end
	local ok, result = pcall(function()
		check(T.check(meta.client, 'passwall') and T.check(meta.server, 'passwall_server'), 'config_conflict')
		local p = assert(io.popen('timeout 10 gzip -dc ' .. util.shellquote(dir .. '/upload') .. ' 2>/dev/null; printf "\\nPW_GZIP_STATUS:%s\\n" "$?"'))
		local expanded = p:read(B.max_expanded + 128) or ''; p:close()
		check(#expanded <= B.max_expanded + 32, 'backup_too_large')
		check(expanded:sub(-18) == '\nPW_GZIP_STATUS:0\n', 'invalid_gzip')
		local files = B.selected(B.parse(expanded:sub(1, -19), version), args.kind)
		for name in pairs(files) do check(meta.files[name] == (hash('/' .. name) or false), 'config_conflict') end
		M.install(files, dir)
		return {status='success', restored=true, upload_id=meta.id}
	end)
	M.cleanup(dir)
	if not ok then error(result, 0) end
	return result
end
function M.create(session, version)
	local dir = root(session); M.cleanup(dir)
	write(dir .. '/passwall-version', assert(version:match('^(%d+%.%d+%.%d+)')) .. '\n')
	write(dir .. '/passwall-backup-schema', B.schema .. '\n')
	local args, size = {}, 4096
	for _, name in ipairs(B.files) do
		safe_parent('/' .. name)
		if regular('/' .. name) then
			size = size + math.ceil(fs.stat('/' .. name, 'size') / 512) * 512 + 512
			check(size <= B.max_expanded, 'backup_too_large')
			args[#args + 1] = util.shellquote('/' .. name)
		end
	end
	check(os.execute('umask 077; tar -czf ' .. util.shellquote(dir .. '/backup.tar.gz') .. ' ' .. table.concat(args, ' ') .. ' -C ' .. util.shellquote(dir) .. ' passwall-version passwall-backup-schema 2>/dev/null') == 0, 'backup_failed')
	check(fs.stat(dir .. '/backup.tar.gz','size') <= B.max_upload, 'backup_too_large')
	local data = assert(fs.readfile(dir .. '/backup.tar.gz')); M.cleanup(dir); return data
end
return M
