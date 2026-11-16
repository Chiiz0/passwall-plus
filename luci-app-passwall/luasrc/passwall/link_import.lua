-- A manual import is isolated by login session and committed only after all
-- chunks and links have been validated. It never uses /tmp/links.conf.
local fs, nixio = require 'nixio.fs', require 'nixio'
local json = require 'luci.jsonc'
local T = require 'luci.passwall.config_transaction'
local M = {max_bytes=262144}
local function check(ok, code) if not ok then error(code, 0) end end
local function cleanup(dir)
	fs.remove(dir .. '/input'); fs.remove(dir .. '/meta'); fs.rmdir(dir)
end
function M.upload(session, args)
	check(T.active(), 'config_lock_required')
	check(type(session) == 'string' and #session == 32 and session:match('^%x+$'), 'invalid_session')
	local index, count = tonumber(args.index), tonumber(args.count)
	check(index and count and index % 1 == 0 and count % 1 == 0 and count >= 1 and count <= 1024 and index >= 0 and index < count, 'invalid_chunk_sequence')
	check(type(args.chunk) == 'string' and #args.chunk > 0 and #args.chunk <= 8192 and not args.chunk:find('%z'), 'invalid_chunk')
	check(type(args.group) == 'string' and #args.group <= 256 and not args.group:find('%z'), 'invalid_group')
	local dir = '/tmp/passwall-import-' .. session
	if not fs.lstat(dir) then check(fs.mkdir(dir, '700'), 'import_storage_unavailable') end
	check(fs.lstat(dir, 'type') == 'dir' and fs.stat(dir, 'uid') == nixio.getuid(), 'unsafe_import_path')
	assert(fs.chmod(dir, '700'))
	for _, name in ipairs({'input', 'meta'}) do
		check(not fs.lstat(dir .. '/' .. name) or fs.lstat(dir .. '/' .. name, 'type') == 'reg', 'unsafe_import_path')
	end
	local meta
	if index == 0 then
		fs.remove(dir .. '/input'); fs.remove(dir .. '/meta')
		meta = {id=assert(fs.readfile('/proc/sys/kernel/random/uuid')):gsub('[^%x]', ''), next=0, count=count, size=0,
			group=args.group, revision=T.revision('passwall'), expires=os.time()+600}
	else meta = json.parse(fs.readfile(dir .. '/meta') or '') end
	check(meta and meta.next == index and meta.count == count and meta.group == args.group and meta.expires > os.time() and (index == 0 or args.id == meta.id), 'invalid_upload_session')
	check(meta.size + #args.chunk <= M.max_bytes, 'input_too_large')
	check(index == 0 or fs.stat(dir .. '/input', 'size') == meta.size, 'invalid_upload_session')
	local f = assert(nixio.open(dir .. '/input', nixio.open_flags('wronly','creat','append'), '600'))
	local offset = 0
	while offset < #args.chunk do local n = assert(f:write(args.chunk, offset)); assert(n > 0); offset = offset + n end
	f:close()
	meta.next, meta.size = index + 1, meta.size + #args.chunk
	assert(fs.writefile(dir .. '/meta', json.stringify(meta))); assert(fs.chmod(dir .. '/meta', '600'))
	if meta.next < count then return {status='success', upload_id=meta.id} end
	local ok, result = pcall(function()
		check(T.check(meta.revision, 'passwall'), 'config_conflict')
		local parser = assert(loadfile('/usr/share/passwall/subscribe.lua'))({library=true})
		local nodes, issues = parser.parse(assert(fs.readfile(dir .. '/input')), args.group)
		check(#nodes > 0 and #issues == 0, 'invalid_link_input')
		local api = require 'luci.passwall.api'
		for _, node in ipairs(nodes) do
			local values = {}
			for key, value in pairs(node) do if key:match('^[%w_]+$') then values[key] = value end end
			values.add_mode = '1'
			local id = assert(fs.readfile('/proc/sys/kernel/random/uuid')):gsub('[^%x]', '')
			assert(api.uci:section('passwall', 'nodes', id, values))
		end
		api.uci_save_c(true)
		return {status='success', upload_id=meta.id, imported=#nodes}
	end)
	cleanup(dir)
	if not ok then require('luci.passwall.api').uci:revert('passwall'); error(result, 0) end
	return result
end
return M
