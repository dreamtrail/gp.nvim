--------------------------------------------------------------------------------
-- Built-in native tools.
--------------------------------------------------------------------------------

local path = require("gp.tools.path")
local process = require("gp.tools.process")
local helpers = require("gp.helper")

local M = {}

local DEFAULTS = {
	read = { max_bytes = 65536, max_lines = 2000, confirm = false },
	write = { max_bytes = 262144, confirm = true },
	edit = { max_bytes = 1048576, max_edits = 20, confirm = true },
	run = { timeout_ms = 30000, max_output_bytes = 65536, confirm = true, allowed_commands = {}, workspace_only = true },
}

local function merge(defaults, override)
	local result = vim.deepcopy(defaults or {})
	for k, v in pairs(override or {}) do
		result[k] = v
	end
	return result
end

local function relpath(root, file)
	root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
	file = vim.fn.fnamemodify(file, ":p"):gsub("/$", "")
	if file == root then
		return "."
	end
	if file:sub(1, #root + 1) == root .. "/" then
		return file:sub(#root + 2)
	end
	return file
end

local function read_file_limited(file, max_bytes)
	local stat = vim.uv and vim.uv.fs_stat(file) or vim.loop.fs_stat(file)
	if not stat then
		return nil, "file not found: " .. file
	end
	if stat.type ~= "file" then
		return nil, "path is not a file: " .. file
	end
	local f, err = io.open(file, "rb")
	if not f then
		return nil, "failed to open file: " .. tostring(err)
	end
	local data = f:read(max_bytes + 1) or ""
	f:close()
	local truncated = #data > max_bytes
	if truncated then
		data = data:sub(1, max_bytes)
	end
	if data:find("%z") then
		return nil, "binary files are not supported"
	end
	return { content = data, bytes = #data, total_bytes = stat.size or #data, truncated = truncated }, nil
end

local function truncate_lines(content, max_lines)
	local lines = vim.split(content, "\n", { plain = true })
	if #lines <= max_lines then
		return content, false
	end
	local kept = {}
	for i = 1, max_lines do
		kept[i] = lines[i]
	end
	return table.concat(kept, "\n"), true
end

local function mkdir_parent(file)
	local parent = vim.fn.fnamemodify(file, ":h")
	if vim.fn.isdirectory(parent) == 0 then
		vim.fn.mkdir(parent, "p")
	end
end

local function atomic_write(file, content, revalidate)
	mkdir_parent(file)
	local parent = vim.fn.fnamemodify(file, ":h")
	local temp = parent .. "/.gp-tool-" .. helpers.uuid() .. ".tmp"
	local f, err = io.open(temp, "wb")
	if not f then
		return nil, "failed to open temporary file: " .. tostring(err)
	end
	local ok, write_err = f:write(content)
	f:close()
	if not ok then
		pcall(os.remove, temp)
		return nil, "failed to write temporary file: " .. tostring(write_err)
	end
	if revalidate then
		local resolved, resolve_err = path.resolve(revalidate.path, revalidate.config, revalidate.for_new)
		if not resolved then
			pcall(os.remove, temp)
			return nil, "target path revalidation failed: " .. tostring(resolve_err)
		end
	end
	local renamed, rename_err = os.rename(temp, file)
	if not renamed then
		pcall(os.remove, temp)
		return nil, "atomic rename failed: " .. tostring(rename_err)
	end
	return true, nil
end

local function find_all_plain(content, needle)
	local matches = {}
	local start = 1
	while true do
		local s, e = content:find(needle, start, true)
		if not s then
			break
		end
		table.insert(matches, { start = s, finish = e })
		start = e + 1
	end
	return matches
end

local function allowed_command(cmd, allowed)
	for _, name in ipairs(allowed or {}) do
		if cmd == name then
			return true
		end
	end
	return false
end

local function rejects_shell_c(cmd, args)
	local shell = cmd:match("([^/\\]+)$") or cmd
	shell = shell:lower()
	if shell ~= "sh" and shell ~= "bash" and shell ~= "zsh" and shell ~= "fish" and shell ~= "pwsh" and shell ~= "powershell" then
		return false
	end
	for _, arg in ipairs(args or {}) do
		if arg == "-c" or arg == "/c" then
			return true
		end
	end
	return false
end

local specs = {
	read = {
		name = "read",
		description = "Read a text file. Returns path, byte count, truncation status, and content.",
		parameters = {
			type = "object",
			additionalProperties = false,
			properties = {
				path = { type = "string", description = "File path to read." },
			},
			required = { "path" },
		},
		risk = "read-only",
		handler = function(args, ctx, done)
			local cfg = merge(DEFAULTS.read, ctx.config.read)
			local file, err = path.resolve(args.path, ctx.config, false)
			if not file then
				done(nil, err)
				return
			end
			local data
			data, err = read_file_limited(file, cfg.max_bytes)
			if not data then
				done(nil, err)
				return
			end
			local content, line_truncated = truncate_lines(data.content, cfg.max_lines)
			local truncated = data.truncated or line_truncated
			local result = table.concat({
				"path: " .. relpath(path.workspace_root(ctx.config), file),
				"bytes: " .. tostring(#content),
				"total_bytes: " .. tostring(data.total_bytes),
				"truncated: " .. tostring(truncated),
				"max_bytes: " .. tostring(cfg.max_bytes),
				"max_lines: " .. tostring(cfg.max_lines),
				"",
				"content:",
				content,
			}, "\n")
			done(result, nil)
		end,
	},

	write = {
		name = "write",
		description = "Write a text file. Creates parent directories. Existing files require overwrite=true.",
		parameters = {
			type = "object",
			additionalProperties = false,
			properties = {
				path = { type = "string", description = "File path to write." },
				content = { type = "string", description = "Text content to write." },
				overwrite = { type = "boolean", description = "Overwrite an existing file. Defaults to false." },
			},
			required = { "path", "content" },
		},
		risk = "write",
		handler = function(args, ctx, done)
			local cfg = merge(DEFAULTS.write, ctx.config.write)
			if args.content:find("%z") then
				done(nil, "binary content is not supported")
				return
			end
			if #args.content > cfg.max_bytes then
				done(nil, "content exceeds max_bytes: " .. tostring(#args.content) .. " > " .. tostring(cfg.max_bytes))
				return
			end
			local file, err = path.resolve(args.path, ctx.config, true)
			if not file then
				done(nil, err)
				return
			end
			local exists = vim.fn.filereadable(file) == 1
			if exists and args.overwrite ~= true then
				done(nil, "file exists; pass overwrite=true to replace it")
				return
			end
			local ok
			ok, err = atomic_write(file, args.content, { path = args.path, config = ctx.config, for_new = true })
			if not ok then
				done(nil, err)
				return
			end
			done(
				table.concat({
					"path: " .. relpath(path.workspace_root(ctx.config), file),
					"bytes_written: " .. tostring(#args.content),
					"overwritten: " .. tostring(exists),
				}, "\n"),
				nil
			)
		end,
	},

	edit = {
		name = "edit",
		description = "Apply one or more exact text replacements to a text file atomically.",
		parameters = {
			type = "object",
			additionalProperties = false,
			properties = {
				path = { type = "string", description = "File path to edit." },
				edits = {
					type = "array",
					description = "Exact replacements to apply against the original file content.",
					items = {
						type = "object",
						additionalProperties = false,
						properties = {
							old_text = { type = "string" },
							new_text = { type = "string" },
						},
						required = { "old_text", "new_text" },
					},
				},
			},
			required = { "path", "edits" },
		},
		risk = "write",
		handler = function(args, ctx, done)
			local cfg = merge(DEFAULTS.edit, ctx.config.edit)
			if #args.edits > cfg.max_edits then
				done(nil, "too many edits: " .. tostring(#args.edits) .. " > max_edits " .. tostring(cfg.max_edits))
				return
			end
			local file, err = path.resolve(args.path, ctx.config, false)
			if not file then
				done(nil, err)
				return
			end
			local data
			data, err = read_file_limited(file, cfg.max_bytes)
			if not data then
				done(nil, err)
				return
			end
			if data.truncated then
				done(nil, "file exceeds max_bytes: " .. tostring(data.total_bytes) .. " > " .. tostring(cfg.max_bytes))
				return
			end
			local ranges = {}
			for i, edit in ipairs(args.edits) do
				if edit.new_text:find("%z") then
					done(nil, "edits[" .. i .. "].new_text contains binary content")
					return
				end
				if edit.old_text == "" then
					done(nil, "edits[" .. i .. "].old_text must not be empty")
					return
				end
				local matches = find_all_plain(data.content, edit.old_text)
				if #matches ~= 1 then
					done(nil, "edits[" .. i .. "].old_text matched " .. #matches .. " times; expected exactly 1")
					return
				end
				ranges[i] = { start = matches[1].start, finish = matches[1].finish, new_text = edit.new_text }
			end
			table.sort(ranges, function(a, b)
				return a.start < b.start
			end)
			for i = 2, #ranges do
				if ranges[i].start <= ranges[i - 1].finish then
					done(nil, "edits overlap; merge nearby replacements")
					return
				end
			end
			local output = {}
			local cursor = 1
			for _, range in ipairs(ranges) do
				table.insert(output, data.content:sub(cursor, range.start - 1))
				table.insert(output, range.new_text)
				cursor = range.finish + 1
			end
			table.insert(output, data.content:sub(cursor))
			local new_content = table.concat(output, "")
			local ok
			ok, err = atomic_write(file, new_content, { path = args.path, config = ctx.config, for_new = false })
			if not ok then
				done(nil, err)
				return
			end
			done(
				table.concat({
					"path: " .. relpath(path.workspace_root(ctx.config), file),
					"edits_applied: " .. tostring(#ranges),
					"bytes_before: " .. tostring(#data.content),
					"bytes_after: " .. tostring(#new_content),
				}, "\n"),
				nil
			)
		end,
	},

	run = {
		name = "run",
		description = "Run a command with arguments. Does not invoke a shell. Returns exit code, stdout, and stderr.",
		parameters = {
			type = "object",
			additionalProperties = false,
			properties = {
				cmd = { type = "string", description = "Executable command to run." },
				args = { type = "array", items = { type = "string" }, description = "Command arguments." },
				cwd = { type = "string", description = "Working directory. Defaults to workspace root." },
				timeout_ms = { type = "number", description = "Timeout in milliseconds." },
			},
			required = { "cmd" },
		},
		risk = "command",
		bypass_confirm = function(args, config)
			local cfg = merge(DEFAULTS.run, config.run)
			return allowed_command(args.cmd, cfg.allowed_commands)
		end,
		handler = function(args, ctx, done)
			local cfg = merge(DEFAULTS.run, ctx.config.run)
			local cmd = args.cmd
			local cmd_args = args.args or {}
			if type(cmd_args) ~= "table" then
				done(nil, "args must be an array of strings")
				return
			end
			if rejects_shell_c(cmd, cmd_args) then
				done(nil, "shell -c style commands are not supported by the run tool")
				return
			end
			local run_cwd
			if args.cwd and args.cwd ~= "" then
				local err
				local path_config = ctx.config
				if cfg.workspace_only == false then
					path_config = vim.deepcopy(ctx.config)
					path_config.workspace_only = false
				end
				run_cwd, err = path.resolve(args.cwd, path_config, false)
				if not run_cwd then
					done(nil, err)
					return
				end
			else
				run_cwd = path.workspace_root(ctx.config)
			end
			local max_timeout = tonumber(cfg.timeout_ms) or DEFAULTS.run.timeout_ms
			local requested_timeout = tonumber(args.timeout_ms) or max_timeout
			local timeout_ms = math.min(requested_timeout, max_timeout)
			process.run({
				cmd = cmd,
				args = cmd_args,
				cwd = run_cwd,
				timeout_ms = timeout_ms,
				max_output_bytes = cfg.max_output_bytes,
				buf = ctx.buf,
			}, function(result)
				local lines = {
					"exit_code: " .. tostring(result.exit_code),
					"timed_out: " .. tostring(result.timed_out),
					"stdout_truncated: " .. tostring(result.stdout_truncated),
					"stderr_truncated: " .. tostring(result.stderr_truncated),
					"",
					"stdout:",
					result.stdout or "",
					"",
					"stderr:",
					result.stderr or "",
				}
				done(table.concat(lines, "\n"), nil)
			end)
		end,
	},
}

M.defaults = DEFAULTS
M.specs = specs

return M
