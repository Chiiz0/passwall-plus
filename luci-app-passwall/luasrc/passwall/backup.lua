-- Strict archive reader. Uploaded tar files are never passed to tar for extraction.
local M = {max_upload = 10 * 1024 * 1024, max_expanded = 16 * 1024 * 1024, schema = 'passwall-plus-backup-v1'}
M.files = {'etc/config/passwall', 'etc/config/passwall_server'}
for _, name in ipairs({'block_host','block_ip','direct_host','direct_ip','proxy_host','proxy_ip','lanlist_ipv4','lanlist_ipv6','domains_excluded'}) do
	M.files[#M.files + 1] = 'etc/passwall/rules/' .. name
end
local allowed = {['passwall-version'] = true, ['passwall-backup-schema'] = true}
for _, name in ipairs(M.files) do allowed[name] = true end
local directories = {['etc/']=true, ['etc/config/']=true, ['etc/passwall/']=true, ['etc/passwall/rules/']=true}
local function check(ok, code) if not ok then error(code, 0) end end
local function field(header, first, last)
	local text = header:sub(first, last)
	local value, padding = text:match('^([^%z]*)%z(.*)$')
	if value then check(not padding:find('[^%z]'), 'invalid_tar_field'); return value end
	return text
end
local function octal(text)
	check(not text:find('[^0-7%z ]'), 'invalid_tar_number')
	return tonumber(text:match('[0-7]+') or '0', 8)
end
function M.parse(data, version)
	check(type(data) == 'string' and #data <= M.max_expanded, 'backup_too_large')
	local files, seen, pos, entries = {}, {}, 1, 0
	while true do
		local header = data:sub(pos, pos + 511)
		check(#header == 512, 'truncated_archive')
		if header == string.rep('\0', 512) then
			check(data:sub(pos + 512, pos + 1023) == string.rep('\0', 512), 'truncated_archive')
			check(not data:sub(pos):find('[^%z]'), 'archive_trailing_data')
			break
		end
		entries = entries + 1; check(entries <= 32, 'too_many_entries')
		local sum = 0
		for i = 1, 512 do sum = sum + ((i >= 149 and i <= 156) and 32 or header:byte(i)) end
		check(sum == octal(header:sub(149, 156)), 'invalid_tar_checksum')
		local name, prefix = field(header, 1, 100), field(header, 346, 500)
		if prefix ~= '' then name = prefix .. '/' .. name end
		check(not seen[name], 'duplicate_archive_entry'); seen[name] = true
		local kind, size = header:sub(157, 157), octal(header:sub(125, 136))
		check(kind == '0' or kind == '\0' or kind == '5', 'unsupported_archive_entry')
		check(field(header, 158, 257) == '', 'archive_link_forbidden')
		if kind == '5' then check(directories[name] and size == 0, 'unexpected_archive_path')
		else
			check(allowed[name], 'unexpected_archive_path')
			check(size <= M.max_expanded and pos + 511 + size <= #data, 'truncated_archive')
			files[name] = data:sub(pos + 512, pos + 511 + size)
		end
		pos = pos + 512 + math.ceil(size / 512) * 512
	end
	local archived = (files['passwall-version'] or ''):match('^%s*(.-)%s*$')
	local current = (version or ''):match('^(%d+%.%d+%.%d+)')
	check(current and archived == current, 'incompatible_backup_version')
	if files['passwall-backup-schema'] then
		check(files['passwall-backup-schema'] == M.schema .. '\n', 'incompatible_backup_schema')
	end
	check(files['etc/config/passwall'] or files['etc/config/passwall_server'], 'missing_backup_config')
	return files
end
function M.selected(files, kind)
	check(kind == 'client' or kind == 'server' or kind == 'all', 'invalid_restore_type')
	local selected = {}
	for _, name in ipairs(M.files) do
		local server = name == 'etc/config/passwall_server'
		if kind == 'all' or (server and kind == 'server') or (not server and kind == 'client') then
			if files[name] ~= nil then selected[name] = files[name] end
		end
	end
	check((kind == 'server' or selected['etc/config/passwall']) and (kind == 'client' or selected['etc/config/passwall_server']), 'missing_backup_config')
	return selected
end
return M
