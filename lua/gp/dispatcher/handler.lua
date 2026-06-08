--------------------------------------------------------------------------------
-- Buffer response handler helpers for dispatcher.
--------------------------------------------------------------------------------

local tasker = require("gp.tasker")
local helpers = require("gp.helper")

local M = {}

-- response handler
---@param buf number | nil # buffer to insert response into
---@param win number | nil # window to insert response into
---@param line number | nil # line to insert response into
---@param first_undojoin boolean | nil # whether to skip first undojoin
---@param prefix string | nil # prefix to insert before each response line
---@param cursor boolean # whether to move cursor to the end of the response
M.create_handler = function(buf, win, line, first_undojoin, prefix, cursor)
	buf = buf or vim.api.nvim_get_current_buf()
	prefix = prefix or ""
	local first_line = line or vim.api.nvim_win_get_cursor(win or 0)[1] - 1
	local finished_lines = 0
	local skip_first_undojoin = not first_undojoin
	local use_hl_range = vim.fn.has("nvim-0.11") == 1

	local hl_handler_group = "GpHandlerStandout"
	vim.cmd("highlight default link " .. hl_handler_group .. " CursorLine")

	local ns_id = vim.api.nvim_create_namespace("GpHandler_" .. helpers.uuid())

	local ex_id = vim.api.nvim_buf_set_extmark(buf, ns_id, first_line, 0, {
		strict = false,
		right_gravity = false,
	})

	local response = ""
	return vim.schedule_wrap(function(qid, chunk)
		local qt = tasker.get_query(qid)
		if not qt or not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		-- undojoin takes previous change into account, so skip it for the first chunk
		if skip_first_undojoin then
			skip_first_undojoin = false
		else
			helpers.undojoin(buf)
		end

		if not qt.ns_id then
			qt.ns_id = ns_id
		end

		if not qt.ex_id then
			qt.ex_id = ex_id
		end

		first_line = vim.api.nvim_buf_get_extmark_by_id(buf, ns_id, ex_id, {})[1]

		-- if not qt.stream then
		-- 	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		-- end

		local line_count = #vim.split(response, "\n")
		vim.api.nvim_buf_set_lines(buf, first_line + finished_lines, first_line + line_count, false, {})
		-- append new response
		response = response .. chunk
		helpers.undojoin(buf)
		-- prepend prefix to each line
		local lines = vim.split(response, "\n")
		for i, l in ipairs(lines) do
			lines[i] = prefix .. l
		end

		local unfinished_lines = {}
		for i = finished_lines + 1, #lines do
			table.insert(unfinished_lines, lines[i])
		end

		vim.api.nvim_buf_set_lines(
			buf,
			first_line + finished_lines,
			first_line + finished_lines,
			false,
			unfinished_lines
		)
		if qt.stream then
			local new_finished_lines = math.max(0, #lines - 1)
			for i = finished_lines, new_finished_lines do
				if use_hl_range then
					vim.hl.range(buf, ns_id, hl_handler_group, { first_line + i, 0 }, { first_line + i, -1 }, {
						regtype = "V",
					})
				else
					---@diagnostic disable-next-line: deprecated
					vim.api.nvim_buf_add_highlight(buf, qt.ns_id, hl_handler_group, first_line + i, 0, -1)
				end
			end
			finished_lines = new_finished_lines
		end
		local end_line = first_line + #vim.split(response, "\n")
		qt.first_line = first_line
		qt.last_line = end_line - 1

		-- move cursor to the end of the response
		if cursor then
			helpers.cursor_to_line(end_line, buf, win)
		end
	end)
end

return M
