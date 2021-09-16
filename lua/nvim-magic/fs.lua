local M = {}

local pathlib = require('plenary.path')

function M.read(path)
	-- @returns [string]
	assert(path ~= nil, 'path cannot be nil')
	assert(type(path) == 'string', 'path must be a string')
	local fh, errmsg = io.open(path, 'r')
	assert(errmsg == nil, errmsg)
	local contents = fh:read('*all')
	fh:close()
	return contents
end

function M.chomp_path_separator(s)
	if s:sub(-1) ~= pathlib.path.sep then
		error('string does not end with trailing path separator')
	end
	return s:sub(1, -2)
end

function M.get_dir_name(path)
	return vim.fn.fnamemodify(M.chomp_path_separator(path), ':t')
end

return M
