--------------------------------------------------------------------------------
-- Dispatcher statusline progress helpers.
--------------------------------------------------------------------------------

local M = {}

local function close_timer(state)
	local timer = state.refresh_timer
	state.refresh_timer = nil
	if timer and not timer:is_closing() then
		if timer:is_active() then
			timer:stop()
		end
		timer:close()
	end
end

M.update_status_msg = function(state, msg)
	---@diagnostic disable-next-line: undefined-field
	local current_time = vim.loop.now()
	local update_interval_ms = 500
	local last_refresh_time = state.last_refresh_time or 0
	local timer = state.refresh_timer

	-- If we recently updated and have an active timer, schedule this update for later
	if timer and not timer:is_closing() and current_time - last_refresh_time < update_interval_ms then
		state.pending_message = msg

		-- If timer isn't already scheduled, schedule it
		if not timer:is_active() then
			timer:start(
				update_interval_ms - (current_time - last_refresh_time),
				0,
				vim.schedule_wrap(function()
					if state.pending_message then
						vim.g.status_msg = state.pending_message
						state.pending_message = nil
						vim.cmd("redrawstatus")
						---@diagnostic disable-next-line: undefined-field
						state.last_refresh_time = vim.loop.now()
					end
				end)
			)
		end
		return
	end
	-- Otherwise update immediately
	vim.g.status_msg = msg
	vim.cmd("redrawstatus")
	state.last_refresh_time = current_time
end

-- Print the start of the query
-- @param provider string
M.show_query_start = function(state, provider)
	if vim.o.laststatus ~= 2 then
		vim.g.gp_laststatus = vim.o.laststatus
		vim.o.laststatus = 2
	end
	vim.o.statusline = "%{g:status_msg}%=%l,%c %P" -- Adjust formatting as needed
	local msg = "Querying " .. provider:gsub("^%l", string.upper) .. " ..."
	close_timer(state)
	---@diagnostic disable-next-line: undefined-field
	state.refresh_timer = vim.loop.new_timer()
	state.last_refresh_time = 0
	state.pending_message = nil
	M.update_status_msg(state, msg)
end

-- Print the progress of the query
-- @param msg string
M.show_query_progress = function(state, msg)
	M.update_status_msg(state, msg)
end

-- Print the end of the query
M.print_query_end = function(state)
	if type(vim.g.gp_laststatus) == "number" then
		vim.o.laststatus = vim.g.gp_laststatus
	end
	state.pending_message = nil
	close_timer(state)
end

return M
