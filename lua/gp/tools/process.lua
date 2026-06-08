--------------------------------------------------------------------------------
-- Bounded process runner for native tools.
--------------------------------------------------------------------------------

local logger = require("gp.logger")
local tasker = require("gp.tasker")

local uv = vim.uv or vim.loop

local M = {}

local function append_capped(current, chunk, max_bytes)
	if not chunk or chunk == "" then
		return current, false
	end
	max_bytes = max_bytes or 65536
	local remaining = max_bytes - #current
	if remaining <= 0 then
		return current, true
	end
	if #chunk > remaining then
		return current .. chunk:sub(1, remaining), true
	end
	return current .. chunk, false
end

---@param opts table # { cmd, args, cwd, timeout_ms, max_output_bytes, buf }
---@param callback function # callback(result)
M.run = function(opts, callback)
	callback = callback or function() end
	local cmd = opts.cmd
	local args = opts.args or {}
	local cwd = opts.cwd
	local timeout_ms = tonumber(opts.timeout_ms) or 30000
	if timeout_ms <= 0 then
		timeout_ms = 1
	end
	local max_output_bytes = opts.max_output_bytes or 65536

	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)
	local stdout_data = ""
	local stderr_data = ""
	local stdout_truncated = false
	local stderr_truncated = false
	local timed_out = false
	local handle, pid
	local timer = uv.new_timer()

	local finish_once = tasker.once(vim.schedule_wrap(function(code, signal)
		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
		if stdout and not stdout:is_closing() then
			stdout:read_stop()
			stdout:close()
		end
		if stderr and not stderr:is_closing() then
			stderr:read_stop()
			stderr:close()
		end
		if handle and not handle:is_closing() then
			handle:close()
		end
		if pid then
			tasker.remove_handle(pid)
		end
		callback({
			exit_code = code,
			signal = signal,
			timed_out = timed_out,
			stdout = stdout_data,
			stderr = stderr_data,
			stdout_truncated = stdout_truncated,
			stderr_truncated = stderr_truncated,
		})
	end))

	handle, pid = uv.spawn(cmd, {
		args = args,
		cwd = cwd,
		stdio = { nil, stdout, stderr },
		hide = true,
		detach = true,
	}, finish_once)

	if not handle then
		if timer and not timer:is_closing() then
			timer:close()
		end
		if stdout and not stdout:is_closing() then
			stdout:close()
		end
		if stderr and not stderr:is_closing() then
			stderr:close()
		end
		callback({
			exit_code = -1,
			signal = 0,
			timed_out = false,
			stdout = "",
			stderr = "failed to start command: " .. tostring(cmd),
			stdout_truncated = false,
			stderr_truncated = false,
		})
		return
	end

	logger.debug("tool run command started with pid: " .. tostring(pid), true)
	tasker.add_handle(handle, pid, opts.buf)

	if timeout_ms > 0 then
		timer:start(timeout_ms, 0, vim.schedule_wrap(function()
			timed_out = true
			if handle and not handle:is_closing() and pid then
				uv.kill(pid, 15)
			end
		end))
	end

	uv.read_start(stdout, function(err, data)
		if err then
			logger.error("Error reading tool stdout: " .. vim.inspect(err))
		end
		local truncated
		stdout_data, truncated = append_capped(stdout_data, data, max_output_bytes)
		stdout_truncated = stdout_truncated or truncated
	end)

	uv.read_start(stderr, function(err, data)
		if err then
			logger.error("Error reading tool stderr: " .. vim.inspect(err))
		end
		local truncated
		stderr_data, truncated = append_capped(stderr_data, data, max_output_bytes)
		stderr_truncated = stderr_truncated or truncated
	end)
end

return M
