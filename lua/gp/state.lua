--------------------------------------------------------------------------------
-- Persistent plugin state helpers.
--------------------------------------------------------------------------------

local M = {}

M.setup = function(gp)
	local M = gp
---@param update table | nil # table with options
M.refresh_state = function(update)
	local state_file = M.config.state_dir .. "/state.json"
	update = update or {}

	local old_state = vim.deepcopy(M._state)

	local disk_state = {}
	if vim.fn.filereadable(state_file) ~= 0 then
		disk_state = M.helpers.file_to_table(state_file) or {}
	end

	if not disk_state.updated then
		local last = M.config.chat_dir .. "/last.md"
		if vim.fn.filereadable(last) == 1 then
			os.remove(last)
		end
	end

	if not M._state.updated or (disk_state.updated and M._state.updated < disk_state.updated) then
		M._state = vim.deepcopy(disk_state)
	end
	M._state.updated = os.time()

	for k, v in pairs(update) do
		M._state[k] = v
	end

	if not M._state.chat_agent or not M.agents[M._state.chat_agent] then
		M._state.chat_agent = M._chat_agents[1]
	end

	if not M._state.command_agent or not M.agents[M._state.command_agent] then
		M._state.command_agent = M._command_agents[1]
	end

	if M._state.last_chat and vim.fn.filereadable(M._state.last_chat) == 0 then
		M._state.last_chat = nil
	end

	for k, _ in pairs(M._state) do
		if M._state[k] ~= old_state[k] or M._state[k] ~= disk_state[k] then
			M.logger.debug(
				string.format(
					"state[%s]: disk=%s old=%s new=%s",
					k,
					vim.inspect(disk_state[k]),
					vim.inspect(old_state[k]),
					vim.inspect(M._state[k])
				)
			)
		end
	end

	M.helpers.table_to_file(M._state, state_file)

	M.prepare_commands()

	local buf = vim.api.nvim_get_current_buf()
	local file_name = vim.api.nvim_buf_get_name(buf)
	M.display_chat_agent(buf, file_name)
end

end

return M
