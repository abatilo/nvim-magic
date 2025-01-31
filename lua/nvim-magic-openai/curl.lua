--[[
***
This file adapted from https://github.com/nvim-lua/plenary.nvim

MIT License

Copyright (c) 2020 TJ DeVries

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
****
]]
--[[
Curl Wrapper

all curl methods accepts

  url        = "The url to make the request to.", (string)
  query      = "url query, append after the url", (table)
  body       = "The request body" (string/filepath/table)
  auth       = "Basic request auth, 'user:pass', or {"user", "pass"}" (string/array)
  form       = "request form" (table)
  raw        = "any additonal curl args, it must be an array/list." (array)
  dry_run    = "whether to return the args to be ran through curl." (boolean)
  output     = "where to download something." (filepath)
  timeout    = "timeout in milliseconds for synchronous requests" (number)
  return_job = "whether to return the Job and a function which can be called to check the response" (boolean)

and returns table:

  exit    = "The shell process exit code." (number)
  status  = "The https response status." (number)
  headers = "The https response headers." (array)
  body    = "The http response body." (string)

see test/plenary/curl_spec.lua for examples.

author = github.com/tami5
]]
--

local util, parse = {}, {}

-- Helpers --------------------------------------------------
-------------------------------------------------------------
local F = require('plenary.functional')
local J = require('plenary.job')
local P = require('plenary.path')

local DEFAULT_TIMEOUT = 10000 -- milliseconds

local function is_windows()
	return P.path.sep == '\\'
end

local function default_compressed()
	return not is_windows() -- it may be more common on Windows for curl to be installed without compression support
end

-- Utils ----------------------------------------------------
-------------------------------------------------------------

util.url_encode = function(str)
	if type(str) ~= 'number' then
		str = str:gsub('\r?\n', '\r\n')
		str = str:gsub('([^%w%-%.%_%~ ])', function(c)
			return string.format('%%%02X', c:byte())
		end)
		str = str:gsub(' ', '+')
		return str
	else
		return str
	end
end

util.kv_to_list = function(kv, prefix, sep)
	return vim.tbl_flatten(F.kv_map(function(kvp)
		return { prefix, kvp[1] .. sep .. kvp[2] }
	end, kv))
end

util.kv_to_str = function(kv, sep, kvsep)
	return F.join(
		F.kv_map(function(kvp)
			return kvp[1] .. kvsep .. util.url_encode(kvp[2])
		end, kv),
		sep
	)
end

util.gen_dump_path = function()
	local path
	local id = string.gsub('xxxx4xxx', '[xy]', function(l)
		local v = (l == 'x') and math.random(0, 0xf) or math.random(0, 0xb)
		return string.format('%x', v)
	end)
	if is_windows() then
		path = string.format('%s\\AppData\\Local\\Temp\\plenary_curl_%s.headers', os.getenv('USERPROFILE'), id)
	else
		path = '/tmp/plenary_curl_' .. id .. '.headers'
	end
	return { '-D', path }
end

-- Parsers ----------------------------------------------------
---------------------------------------------------------------

parse.headers = function(t)
	if not t then
		return
	end
	local upper = function(str)
		return string.gsub(' ' .. str, '%W%l', string.upper):sub(2)
	end
	return util.kv_to_list(
		(function()
			local normilzed = {}
			for k, v in pairs(t) do
				normilzed[upper(k:gsub('_', '%-'))] = v
			end
			return normilzed
		end)(),
		'-H',
		': '
	)
end

parse.data_body = function(t)
	if not t then
		return
	end
	return util.kv_to_list(t, '-d', '=')
end

parse.raw_body = function(xs)
	if not xs then
		return
	end
	if type(xs) == 'table' then
		return parse.data_body(xs)
	else
		return { '--data-raw', xs }
	end
end

parse.form = function(t)
	if not t then
		return
	end
	return util.kv_to_list(t, '-F', '=')
end

parse.curl_query = function(t)
	if not t then
		return
	end
	return util.kv_to_str(t, '&', '=')
end

parse.method = function(s)
	if not s then
		return
	end
	if s ~= 'head' then
		return { '-X', string.upper(s) }
	else
		return { '-I' }
	end
end

parse.file = function(p)
	if not p then
		return
	end
	return { '-d', '@' .. P.expand(P.new(p)) }
end

parse.auth = function(xs)
	if not xs then
		return
	end
	return { '-u', type(xs) == 'table' and util.kv_to_str(xs, nil, ':') or xs }
end

parse.url = function(xs, q)
	if not xs then
		return
	end
	q = parse.curl_query(q)
	if type(xs) == 'string' then
		return q and xs .. '?' .. q or xs
	elseif type(xs) == 'table' then
		error('Low level URL definition is not supported.')
	end
end

parse.accept_header = function(s)
	if not s then
		return
	end
	return { '-H', 'Accept: ' .. s }
end

-- Parse Request -------------------------------------------
------------------------------------------------------------
parse.request = function(opts)
	if opts.body then
		local b = opts.body
		opts.body = nil
		if type(b) == 'table' then
			opts.data = b
		elseif P.is_file(P.new(b)) then
			opts.in_file = b
		elseif type(b) == 'string' then
			opts.raw_body = b
		end
	end
	return vim.tbl_flatten({
		'-sSL',
		opts.dump,
		opts.compressed and '--compressed' or nil,
		parse.method(opts.method),
		parse.headers(opts.headers),
		parse.accept_header(opts.accept),
		parse.raw_body(opts.raw_body),
		parse.data_body(opts.data),
		parse.form(opts.form),
		parse.file(opts.in_file),
		parse.auth(opts.auth),
		opts.raw,
		opts.output and { '-o', opts.output } or nil,
		parse.url(opts.url, opts.query),
	}),
		opts
end

-- Parse response ------------------------------------------
------------------------------------------------------------
parse.response = function(lines, dump_path, code)
	local headers = P.readlines(dump_path)
	local status = tonumber(string.match(headers[1], '([%w+]%d+)'))
	local body = F.join(lines, '\n')

	vim.loop.fs_unlink(dump_path)
	table.remove(headers, 1)

	return {
		status = status,
		headers = headers,
		body = body,
		exit = code,
	}
end

local curl_job = function(args, dump_path, callback)
	return J:new({
		command = 'curl',
		args = args,
		on_exit = function(j, code)
			if code ~= 0 then
				callback(
					nil,
					'curl exited with code=' .. tostring(code) .. ' stderr=' .. vim.inspect(j:stderr_result())
				)
				return
			end
			local output = parse.response(j:result(), dump_path, code)
			callback(output)
		end,
	})
end

local request = function(specs)
	local args, opts = parse.request(vim.tbl_extend('force', {
		compressed = default_compressed(),
		dry_run = false,
		dump = util.gen_dump_path(),
	}, specs))

	if opts.dry_run then
		return args
	end

	local response
	local cb
	local errmsg
	if opts.callback then
		cb = opts.callback
	else
		cb = function(output, error_msg)
			if error_msg then
				errmsg = error_msg
			end
			response = output
		end
	end

	local job = curl_job(args, opts.dump[2], cb)

	if opts.return_job then
		return job, function()
			return response, errmsg
		end
	end

	if opts.callback then
		return job:start()
	else
		local timeout
		if opts.timeout then
			timeout = opts.timeout
		else
			timeout = DEFAULT_TIMEOUT
		end
		job:sync(timeout)
		return response
	end
end

-- Main ----------------------------------------------------
------------------------------------------------------------
return (function()
	local spec = {}
	local partial = function(method)
		return function(url, opts)
			opts = opts or {}
			if type(url) == 'table' then
				opts = url
				spec.method = method
			else
				spec.url = url
				spec.method = method
			end
			opts = method == 'request' and opts or (vim.tbl_extend('keep', opts, spec))
			return request(opts)
		end
	end
	return {
		get = partial('get'),
		post = partial('post'),
		put = partial('put'),
		head = partial('head'),
		patch = partial('patch'),
		delete = partial('delete'),
		request = partial('request'),
	}
end)()
