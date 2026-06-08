-- Gp (GPT prompt) lua plugin for Neovim
-- https://github.com/Robitx/gp.nvim/

--------------------------------------------------------------------------------
-- Module structure
--------------------------------------------------------------------------------
local config = require("gp.config")

local M = {
	_Name = "Gp", -- plugin name
	_state = {}, -- table of state variables
	agents = {}, -- table of agents
	cmd = {}, -- default command functions
	config = {}, -- config variables
	hooks = {}, -- user defined command functions
	defaults = require("gp.defaults"), -- some useful defaults
	deprecator = require("gp.deprecator"), -- handle deprecated options
	dispatcher = require("gp.dispatcher"), -- handle communication with LLM providers
	helpers = require("gp.helper"), -- helper functions
	imager = require("gp.imager"), -- image generation module
	logger = require("gp.logger"), -- logger module
	render = require("gp.render"), -- render module
	spinner = require("gp.spinner"), -- spinner module
	tasker = require("gp.tasker"), -- tasker module
	vault = require("gp.vault"), -- handles secrets
	whisper = require("gp.whisper"), -- whisper module
}

--------------------------------------------------------------------------------
-- Extracted module wiring
--------------------------------------------------------------------------------
require("gp.ui.toggle").setup(M)
require("gp.ui.buffer").setup(M)
require("gp.chat").setup(M)
require("gp.agents").setup(M)
require("gp.context").setup(M)
require("gp.chat.respond").setup(M)
require("gp.tools").setup(M)

-- setup function
M._setup_called = false
---@param opts GpConfig? # table with options
M.setup = function(opts)
	M._setup_called = true

	math.randomseed(os.time())

	-- make sure opts is a table
	opts = opts or {}
	if type(opts) ~= "table" then
		M.logger.error(string.format("setup() expects table, but got %s:\n%s", type(opts), vim.inspect(opts)))
		opts = {}
	end

	-- reset M.config
	M.config = vim.deepcopy(config)

	local curl_params = opts.curl_params or M.config.curl_params
	local cmd_prefix = opts.cmd_prefix or M.config.cmd_prefix
	local state_dir = opts.state_dir or M.config.state_dir
	local openai_api_key = opts.openai_api_key or M.config.openai_api_key

	M.logger.setup(opts.log_file or M.config.log_file, opts.log_sensitive)

	M.vault.setup({ state_dir = state_dir, curl_params = curl_params })

	M.vault.add_secret("openai_api_key", openai_api_key)
	M.config.openai_api_key = nil
	opts.openai_api_key = nil

	M.dispatcher.setup({ providers = opts.providers, curl_params = curl_params })
	M.config.providers = nil
	opts.providers = nil

	local image_opts = opts.image or {}
	image_opts.state_dir = state_dir
	image_opts.cmd_prefix = cmd_prefix
	image_opts.secret = image_opts.secret or openai_api_key
	M.imager.setup(image_opts)
	M.config.image = nil
	opts.image = nil

	local whisper_opts = opts.whisper or {}
	whisper_opts.style_popup_border = opts.style_popup_border or M.config.style_popup_border
	whisper_opts.curl_params = curl_params
	whisper_opts.cmd_prefix = cmd_prefix
	M.whisper.setup(whisper_opts)
	M.config.whisper = nil
	opts.whisper = nil

	-- merge nested tables
	local mergeTables = { "hooks", "agents" }
	for _, tbl in ipairs(mergeTables) do
		M[tbl] = M[tbl] or {}
		---@diagnostic disable-next-line
		for k, v in pairs(M.config[tbl]) do
			if tbl == "hooks" then
				M[tbl][k] = v
			elseif tbl == "agents" then
				---@diagnostic disable-next-line
				M[tbl][v.name] = v
			end
		end
		M.config[tbl] = nil

		opts[tbl] = opts[tbl] or {}
		for k, v in pairs(opts[tbl]) do
			if tbl == "hooks" then
				M[tbl][k] = v
			elseif tbl == "agents" then
				M[tbl][v.name] = v
			end
		end
		opts[tbl] = nil
	end

	for k, v in pairs(opts) do
		if M.deprecator.is_valid(k, v) then
			M.config[k] = v
		end
	end
	M.deprecator.report()

	-- make sure _dirs exists
	for k, v in pairs(M.config) do
		if k:match("_dir$") and type(v) == "string" then
			M.config[k] = M.helpers.prepare_dir(v, k)
		end
	end

	-- remove invalid agents
	for name, agent in pairs(M.agents) do
		if type(agent) ~= "table" or agent.disable then
			M.agents[name] = nil
		elseif not agent.model then
			M.logger.warning(
				"Agent "
					.. name
					.. " is missing model\n"
					.. "If you want to disable an agent, use: { name = '"
					.. name
					.. "', disable = true },"
			)
			M.agents[name] = nil
		end
	end

	-- prepare agent completions
	M._chat_agents = {}
	M._command_agents = {}
	for name, agent in pairs(M.agents) do
		M.agents[name].provider = M.agents[name].provider or "openai"

		if M.dispatcher.providers[M.agents[name].provider] then
			if agent.command then
				table.insert(M._command_agents, name)
			end
			if agent.chat then
				table.insert(M._chat_agents, name)
			end
		else
			M.agents[name] = nil
		end
	end
	table.sort(M._chat_agents)
	table.sort(M._command_agents)

	M.refresh_state()

	if M.config.default_command_agent then
		M.refresh_state({ command_agent = M.config.default_command_agent })
	end

	if M.config.default_chat_agent then
		M.refresh_state({ chat_agent = M.config.default_chat_agent })
	end

	-- register user commands
	for hook, _ in pairs(M.hooks) do
		M.helpers.create_user_command(M.config.cmd_prefix .. hook, function(params)
			if M.hooks[hook] ~= nil then
				M.refresh_state()
				M.logger.debug("running hook: " .. hook)
				return M.hooks[hook](M, params)
			end
			M.logger.error("The hook '" .. hook .. "' does not exist.")
		end)
	end

	local completions = {
		ChatNew = { "popup", "split", "vsplit", "tabnew" },
		ChatPaste = { "popup", "split", "vsplit", "tabnew" },
		ChatToggle = { "popup", "split", "vsplit", "tabnew" },
		Context = { "popup", "split", "vsplit", "tabnew" },
		Agent = M.agent_completion,
	}

	-- register default commands
	for cmd, _ in pairs(M.cmd) do
		if M.hooks[cmd] == nil then
			M.helpers.create_user_command(M.config.cmd_prefix .. cmd, function(params)
				M.logger.debug("running command: " .. cmd)
				M.refresh_state()
				M.cmd[cmd](params)
			end, completions[cmd])
		end
	end

	M.buf_handler()

	if vim.fn.executable("curl") == 0 then
		M.logger.error("curl is not installed, run :checkhealth gp")
	end

	M.logger.debug("setup finished")
end

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

M.Target = {
	rewrite = 0, -- for replacing the selection, range or the current line
	append = 1, -- for appending after the selection, range or the current line
	prepend = 2, -- for prepending before the selection, range or the current line
	popup = 3, -- for writing into the popup window

	-- for writing into a new buffer
	---@param filetype nil | string # nil = same as the original buffer
	---@return table # a table with type=4 and filetype=filetype
	enew = function(filetype)
		return { type = 4, filetype = filetype }
	end,

	--- for creating a new horizontal split
	---@param filetype nil | string # nil = same as the original buffer
	---@return table # a table with type=5 and filetype=filetype
	new = function(filetype)
		return { type = 5, filetype = filetype }
	end,

	--- for creating a new vertical split
	---@param filetype nil | string # nil = same as the original buffer
	---@return table # a table with type=6 and filetype=filetype
	vnew = function(filetype)
		return { type = 6, filetype = filetype }
	end,

	--- for creating a new tab
	---@param filetype nil | string # nil = same as the original buffer
	---@return table # a table with type=7 and filetype=filetype
	tabnew = function(filetype)
		return { type = 7, filetype = filetype }
	end,
}

-- creates prompt commands for each target
M.prepare_commands = function()
	for name, target in pairs(M.Target) do
		-- uppercase first letter
		local command = name:gsub("^%l", string.upper)

		local cmd = function(params, whisper)
			local agent = M.get_command_agent()
			-- popup is like ephemeral one off chat
			if target == M.Target.popup then
				agent = M.get_chat_agent()
			end

			-- template is chosen dynamically based on mode in which the command is called
			local template = M.config.template_command
			if params.range > 0 then
				template = M.config.template_selection
			end
			-- rewrite needs custom template
			if target == M.Target.rewrite then
				template = M.config.template_rewrite
			end
			if target == M.Target.append then
				template = M.config.template_append
			end
			if target == M.Target.prepend then
				template = M.config.template_prepend
			end
			if agent then
				M.Prompt(params, target, agent, template, agent.cmd_prefix, whisper)
			end
		end

		M.cmd[command] = function(params)
			cmd(params)
		end

		if not M.whisper.disabled then
			M.cmd["Whisper" .. command] = function(params)
				M.whisper.Whisper(function(text)
					vim.schedule(function()
						cmd(params, text)
					end)
				end)
			end
		end
	end
end

-- stop receiving gpt responses for all processes and clean the handles
---@param signal number | nil # signal to send to the process
M.cmd.Stop = function(signal)
	M.tasker.stop(signal)
end

--------------------------------------------------------------------------------
-- Chat logic
--------------------------------------------------------------------------------

M._chat_finder_opened = false
M.cmd.ChatFinder = function()
	if M._chat_finder_opened then
		M.logger.warning("Chat finder is already open")
		return
	end
	M._chat_finder_opened = true

	local dir = M.config.chat_dir
	local delete_shortcut = M.config.chat_finder_mappings.delete or M.config.chat_shortcut_delete

	-- prepare unique group name and register augroup
	local gid = M.helpers.create_augroup("GpChatFinder", { clear = true })

	-- prepare three popup buffers and windows
	local style = { border = M.config.style_chat_finder_border or "single", zindex = M.config.zindex }
	local ratio = M.config.style_chat_finder_preview_ratio or 0.5
	local top = M.config.style_chat_finder_margin_top or 2
	local bottom = M.config.style_chat_finder_margin_bottom or 8
	local left = M.config.style_chat_finder_margin_left or 1
	local right = M.config.style_chat_finder_margin_right or 2
	local picker_buf, picker_win, picker_close, picker_resize = M.render.popup(
		nil,
		"Picker: j/k <Esc>|exit <Enter>|open " .. delete_shortcut.shortcut .. "|del i|srch",
		function(w, h)
			local wh = h - top - bottom - 2
			local ww = w - left - right - 2
			return math.floor(ww * (1 - ratio)), wh, top, left
		end,
		{ gid = gid },
		style
	)

	local preview_buf, preview_win, preview_close, preview_resize = M.render.popup(
		nil,
		"Preview (edits are ephemeral)",
		function(w, h)
			local wh = h - top - bottom - 2
			local ww = w - left - right - 1
			return ww * ratio, wh, top, left + math.ceil(ww * (1 - ratio)) + 2
		end,
		{ gid = gid },
		style
	)

	vim.api.nvim_set_option_value("filetype", "markdown", { buf = preview_buf })

	local command_buf, command_win, command_close, command_resize = M.render.popup(
		nil,
		"Search: <Tab>/<Shift+Tab>|navigate <Esc>|picker <C-c>|exit "
			.. "<Enter>/<C-f>/<C-x>/<C-v>/<C-t>/<C-g>t|open/float/split/vsplit/tab/toggle",
		function(w, h)
			return w - left - right, 1, h - bottom, left
		end,
		{ gid = gid },
		style
	)
	-- set initial content of command buffer
	vim.api.nvim_buf_set_lines(command_buf, 0, -1, false, { M.config.chat_finder_pattern })

	local hl_search_group = "GpExplorerSearch"
	vim.cmd("highlight default link " .. hl_search_group .. " Search ")
	local hl_cursorline_group = "GpExplorerCursorLine"
	vim.cmd("highlight default " .. hl_cursorline_group .. " gui=standout cterm=standout")

	local picker_pos_id = 0
	local picker_match_id = 0
	local preview_match_id = 0
	local regex = ""

	-- clean up augroup and popup buffers/windows
	local close = M.tasker.once(function()
		vim.api.nvim_del_augroup_by_id(gid)
		picker_close()
		preview_close()
		command_close()
		M._chat_finder_opened = false
	end)

	local resize = function()
		picker_resize()
		preview_resize()
		command_resize()
	end

	-- logic for updating picker and preview
	local picker_files = {}
	local preview_lines = {}

	local refresh = function()
		if not vim.api.nvim_buf_is_valid(picker_buf) then
			return
		end

		-- empty preview buffer
		vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, {})
		vim.api.nvim_win_set_cursor(preview_win, { 1, 0 })

		local index = vim.api.nvim_win_get_cursor(picker_win)[1]
		local file = picker_files[index]
		if not file then
			return
		end

		local lines = {}
		for l in io.lines(file) do
			table.insert(lines, l)
		end
		vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)

		local preview_line = preview_lines[index]
		if preview_line then
			vim.api.nvim_win_set_cursor(preview_win, { preview_line, 0 })
		end

		-- highlight grep results and current line
		if picker_pos_id ~= 0 then
			vim.fn.matchdelete(picker_pos_id, picker_win)
		end
		if picker_match_id ~= 0 then
			vim.fn.matchdelete(picker_match_id, picker_win)
		end
		if preview_match_id ~= 0 then
			vim.fn.matchdelete(preview_match_id, preview_win)
		end

		if regex == "" then
			picker_pos_id = 0
			picker_match_id = 0
			preview_match_id = 0
			return
		end

		picker_match_id = vim.fn.matchadd(hl_search_group, regex, 0, -1, { window = picker_win })
		preview_match_id = vim.fn.matchadd(hl_search_group, regex, 0, -1, { window = preview_win })
		picker_pos_id = vim.fn.matchaddpos(hl_cursorline_group, { { index } }, 0, -1, { window = picker_win })
	end

	local refresh_picker = function()
		-- get last line of command buffer
		local cmd = vim.api.nvim_buf_get_lines(command_buf, -2, -1, false)[1]

		M.tasker.grep_directory(nil, dir, cmd, function(results, re)
			if not vim.api.nvim_buf_is_valid(picker_buf) then
				return
			end

			picker_files = {}
			preview_lines = {}
			local picker_lines = {}
			for _, f in ipairs(results) do
				if f.line:len() > 0 then
					table.insert(picker_files, dir .. "/" .. f.file)
					local fline = string.format("%s:%s %s", f.file:sub(3, -11), f.lnum, f.line)
					table.insert(picker_lines, fline)
					table.insert(preview_lines, tonumber(f.lnum))
				end
			end

			vim.api.nvim_buf_set_lines(picker_buf, 0, -1, false, picker_lines)

			-- prepare regex for highlighting
			regex = re
			if regex ~= "" then
				-- case insensitive
				regex = "\\c" .. regex
			end

			refresh()
		end)
	end

	refresh_picker()
	vim.api.nvim_set_current_win(command_win)
	vim.api.nvim_command("startinsert!")

	-- resize on VimResized
	M.helpers.autocmd({ "VimResized" }, nil, resize, gid)

	-- moving cursor on picker window will update preview window
	M.helpers.autocmd({ "CursorMoved", "CursorMovedI" }, { picker_buf }, function()
		vim.api.nvim_command("stopinsert")
		refresh()
	end, gid)

	-- InsertEnter on picker or preview window will go to command window
	M.helpers.autocmd({ "InsertEnter" }, { picker_buf, preview_buf }, function()
		vim.api.nvim_set_current_win(command_win)
		vim.api.nvim_command("startinsert!")
	end, gid)

	-- InsertLeave on command window will go to picker window
	M.helpers.autocmd({ "InsertLeave" }, { command_buf }, function()
		vim.api.nvim_set_current_win(picker_win)
		vim.api.nvim_command("stopinsert")
	end, gid)

	-- when preview becomes active call some function
	M.helpers.autocmd({ "WinEnter" }, { preview_buf }, function()
		-- go to normal mode
		vim.api.nvim_command("stopinsert")
	end, gid)

	-- when command buffer is written, execute it
	M.helpers.autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "TextChangedT" }, { command_buf }, function()
		vim.api.nvim_win_set_cursor(picker_win, { 1, 0 })
		refresh_picker()
	end, gid)

	-- close on buffer delete
	M.helpers.autocmd({ "BufWipeout", "BufHidden", "BufDelete" }, { picker_buf, preview_buf, command_buf }, close, gid)

	-- close by escape key on any window
	M.helpers.set_keymap({ picker_buf, preview_buf, command_buf }, "n", "<esc>", close)
	M.helpers.set_keymap({ picker_buf, preview_buf, command_buf }, { "i", "n" }, "<C-c>", close)

	---@param target number
	---@param toggle boolean
	local open_chat = function(target, toggle)
		local index = vim.api.nvim_win_get_cursor(picker_win)[1]
		local file = picker_files[index]
		close()
		-- delay so explorer can close before opening file
		vim.defer_fn(function()
			if not file then
				return
			end
			M.open_buf(file, target, M._toggle_kind.chat, toggle)
		end, 200)
	end

	-- enter on picker window will open file
	M.helpers.set_keymap({ picker_buf, preview_buf, command_buf }, { "i", "n", "v" }, "<cr>", open_chat)
	M.helpers.set_keymap({ picker_buf, preview_buf, command_buf }, { "i", "n", "v" }, "<C-f>", function()
		open_chat(M.BufTarget.popup, false)
	end)
	M.helpers.set_keymap({ picker_buf, preview_buf, command_buf }, { "i", "n", "v" }, "<C-x>", function()
		open_chat(M.BufTarget.split, false)
	end)
	M.helpers.set_keymap({ picker_buf, preview_buf, command_buf }, { "i", "n", "v" }, "<C-v>", function()
		open_chat(M.BufTarget.vsplit, false)
	end)
	M.helpers.set_keymap({ picker_buf, preview_buf, command_buf }, { "i", "n", "v" }, "<C-t>", function()
		open_chat(M.BufTarget.tabnew, false)
	end)
	M.helpers.set_keymap({ picker_buf, preview_buf, command_buf }, { "i", "n", "v" }, "<C-g>t", function()
		local target = M.resolve_buf_target(M.config.toggle_target)
		open_chat(target, true)
	end)

	-- tab in command window will cycle through lines in picker window
	M.helpers.set_keymap({ command_buf, picker_buf }, { "i", "n" }, "<tab>", function()
		local index = vim.api.nvim_win_get_cursor(picker_win)[1]
		local next_index = index + 1
		if next_index > #picker_files then
			next_index = 1
		end
		vim.api.nvim_win_set_cursor(picker_win, { next_index, 0 })
		refresh()
	end)

	-- shift-tab in command window will cycle through lines in picker window
	M.helpers.set_keymap({ command_buf, picker_buf }, { "i", "n" }, "<s-tab>", function()
		local index = vim.api.nvim_win_get_cursor(picker_win)[1]
		local next_index = index - 1
		if next_index < 1 then
			next_index = #picker_files
		end
		vim.api.nvim_win_set_cursor(picker_win, { next_index, 0 })
		refresh()
	end)

	-- dd on picker or preview window will delete file
	M.helpers.set_keymap(
		{ command_buf, picker_buf, preview_buf },
		delete_shortcut.modes,
		delete_shortcut.shortcut,
		function()
			local index = vim.api.nvim_win_get_cursor(picker_win)[1]
			local file = picker_files[index]

			-- delete without confirmation
			if not M.config.chat_confirm_delete then
				M.helpers.delete_file(file, refresh_picker)
				return
			end

			-- ask for confirmation
			vim.ui.input({ prompt = "Delete " .. file .. "? [y/N] " }, function(input)
				if input and input:lower() == "y" then
					M.helpers.delete_file(file, refresh_picker)
				end
			end)
		end
	)
end

--------------------------------------------------------------------------------
-- Prompt logic
--------------------------------------------------------------------------------

---@param params table  # vim command parameters such as range, args, etc.
---@param target number | function | table  # where to put the response
---@param agent table  # obtained from get_command_agent or get_chat_agent
---@param template string  # template with model instructions
---@param prompt string | nil  # nil for non interactive commads
---@param whisper string | nil  # predefined input (e.g. obtained from Whisper)
---@param callback function | nil  # callback after completing the prompt
M.Prompt = function(params, target, agent, template, prompt, whisper, callback)
	if M.deprecator.has_old_prompt_signature(agent) then
		return
	end

	-- enew, new, vnew, tabnew should be resolved into table
	if type(target) == "function" then
		target = target()
	end

	target = target or M.Target.enew()

	-- get current buffer
	local buf = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()

	if M.tasker.is_busy(buf) then
		return
	end

	local start_line = params.line1
	local end_line = params.line2
	local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)

	local min_indent = nil
	local use_tabs = false
	-- measure minimal common indentation for lines with content
	for i, line in ipairs(lines) do
		lines[i] = line
		-- skip whitespace only lines
		if not line:match("^%s*$") then
			local indent = line:match("^%s*")
			-- contains tabs
			if indent:match("\t") then
				use_tabs = true
			end
			if min_indent == nil or #indent < min_indent then
				min_indent = #indent
			end
		end
	end
	if min_indent == nil then
		min_indent = 0
	end
	local prefix = string.rep(use_tabs and "\t" or " ", min_indent)

	for i, line in ipairs(lines) do
		lines[i] = line:sub(min_indent + 1)
	end

	local selection = table.concat(lines, "\n")

	M._selection_first_line = start_line
	M._selection_last_line = end_line

	local cb = function(command)
		-- dummy handler
		local handler = function() end
		-- default on_exit strips trailing backticks if response was markdown snippet
		local on_exit = function(qid)
			local qt = M.tasker.get_query(qid)
			if not qt then
				return
			end
			-- if buf is not valid, return
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end

			local flc, llc
			local fl = qt.first_line
			local ll = qt.last_line
			-- remove empty lines from the start and end of the response
			while fl < ll do
				-- get content of first_line and last_line
				flc = vim.api.nvim_buf_get_lines(buf, fl, fl + 1, false)[1]
				llc = vim.api.nvim_buf_get_lines(buf, ll, ll + 1, false)[1]

				if not flc or not llc then
					break
				end

				local flm = flc:match("%S")
				local llm = llc:match("%S")

				-- break loop if both lines contain non-whitespace characters
				if flm and llm then
					break
				end

				if not flm then
					M.helpers.undojoin(buf)
					vim.api.nvim_buf_set_lines(buf, fl, fl + 1, false, {})
				else
					M.helpers.undojoin(buf)
					vim.api.nvim_buf_set_lines(buf, ll, ll + 1, false, {})
				end
				ll = ll - 1
			end

			-- if fl and ll starts with triple backticks, remove these lines
			if fl < ll and flc and llc and flc:match("^%s*```") and llc:match("^%s*```") then
				-- remove first line with undojoin
				M.helpers.undojoin(buf)
				vim.api.nvim_buf_set_lines(buf, fl, fl + 1, false, {})
				-- remove last line
				M.helpers.undojoin(buf)
				vim.api.nvim_buf_set_lines(buf, ll - 1, ll, false, {})
				ll = ll - 2
			end
			qt.first_line = fl
			qt.last_line = ll

			-- option to not select response automatically
			if not M.config.command_auto_select_response then
				return
			end

			-- don't select popup response
			if target == M.Target.popup then
				return
			end

			-- default works for rewrite and enew
			local start = fl
			local finish = ll

			if target == M.Target.append then
				start = M._selection_first_line - 1
			end

			if target == M.Target.prepend then
				finish = M._selection_last_line + ll - fl
			end

			-- select from first_line to last_line
			vim.api.nvim_win_set_cursor(0, { start + 1, 0 })
			vim.api.nvim_command("normal! V")
			vim.api.nvim_win_set_cursor(0, { finish + 1, 0 })
		end

		-- prepare messages
		local messages = {}
		local filetype = M.helpers.get_filetype(buf)
		local filename = vim.api.nvim_buf_get_name(buf)

		if agent.system_prompt and agent.system_prompt ~= "" then
			local sys_prompt = M.render.prompt_template(agent.system_prompt, command, selection, filetype, filename)
			table.insert(messages, { role = "system", content = sys_prompt })
		end

		local repo_instructions = M.repo_instructions()
		if repo_instructions ~= "" then
			table.insert(messages, { role = "user", content = repo_instructions })
		end

		local user_prompt = M.render.prompt_template(template, command, selection, filetype, filename)
		table.insert(messages, { role = "user", content = user_prompt })

		-- cancel possible visual mode before calling the model
		M.helpers.feedkeys("<esc>", "xn")

		local cursor = true
		if not M.config.command_auto_select_response then
			cursor = false
		end

		-- mode specific logic
		if target == M.Target.rewrite then
			-- delete selection
			vim.api.nvim_buf_set_lines(buf, start_line - 1, end_line - 1, false, {})
			-- prepare handler
			handler = M.dispatcher.create_handler(buf, win, start_line - 1, true, prefix, cursor)
		elseif target == M.Target.append then
			-- move cursor to the end of the selection
			vim.api.nvim_win_set_cursor(0, { end_line, 0 })
			-- put newline after selection
			vim.api.nvim_put({ "" }, "l", true, true)
			-- prepare handler
			handler = M.dispatcher.create_handler(buf, win, end_line, true, prefix, cursor)
		elseif target == M.Target.prepend then
			-- move cursor to the start of the selection
			vim.api.nvim_win_set_cursor(0, { start_line, 0 })
			-- put newline before selection
			vim.api.nvim_put({ "" }, "l", false, true)
			-- prepare handler
			handler = M.dispatcher.create_handler(buf, win, start_line - 1, true, prefix, cursor)
		elseif target == M.Target.popup then
			M._toggle_close(M._toggle_kind.popup)
			-- create a new buffer
			local popup_close = nil
			buf, win, popup_close, _ = M.render.popup(
				nil,
				M._Name .. " popup (close with <esc>/<C-c>)",
				function(w, h)
					local top = M.config.style_popup_margin_top or 2
					local bottom = M.config.style_popup_margin_bottom or 8
					local left = M.config.style_popup_margin_left or 1
					local right = M.config.style_popup_margin_right or 1
					local max_width = M.config.style_popup_max_width or 160
					local ww = math.min(w - (left + right), max_width)
					local wh = h - (top + bottom)
					return ww, wh, top, (w - ww) / 2
				end,
				{ on_leave = true, escape = true },
				{ border = M.config.style_popup_border or "single", zindex = M.config.zindex }
			)
			-- set the created buffer as the current buffer
			vim.api.nvim_set_current_buf(buf)
			-- set the filetype to markdown
			vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
			-- better text wrapping
			vim.api.nvim_command("setlocal wrap linebreak")
			-- prepare handler
			handler = M.dispatcher.create_handler(buf, win, 0, false, "", false)
			M._toggle_add(M._toggle_kind.popup, { win = win, buf = buf, close = popup_close })
		elseif type(target) == "table" then
			if target.type == M.Target.new().type then
				vim.cmd("split")
				win = vim.api.nvim_get_current_win()
			elseif target.type == M.Target.vnew().type then
				vim.cmd("vsplit")
				win = vim.api.nvim_get_current_win()
			elseif target.type == M.Target.tabnew().type then
				vim.cmd("tabnew")
				win = vim.api.nvim_get_current_win()
			end

			if target.type == M.Target.tabnew().type then
				buf = vim.api.nvim_get_current_buf()
			else
				buf = vim.api.nvim_create_buf(true, true)
				vim.api.nvim_set_current_buf(buf)
			end

			local group = M.helpers.create_augroup("GpScratchSave" .. M.helpers.uuid(), { clear = true })
			vim.api.nvim_create_autocmd({ "BufWritePre" }, {
				buffer = buf,
				group = group,
				callback = function(ctx)
					vim.api.nvim_set_option_value("buftype", "", { buf = ctx.buf })
					vim.api.nvim_buf_set_name(ctx.buf, ctx.file)
					vim.api.nvim_command("w!")
					vim.api.nvim_del_augroup_by_id(ctx.group)
				end,
			})

			local ft = target.filetype or filetype
			vim.api.nvim_set_option_value("filetype", ft, { buf = buf })

			handler = M.dispatcher.create_handler(buf, win, 0, false, "", cursor)
		end

		-- call the model and write the response
		M.dispatcher.query(
			buf,
			agent.provider,
			M.dispatcher.prepare_payload(messages, agent.model, agent.provider),
			handler,
			vim.schedule_wrap(function(qid)
				on_exit(qid)
				vim.cmd("doautocmd User GpDone")
			end),
			callback,
			agent.stream ~= nil and agent.stream or M.config.command_stream_response,
			M.config.command_show_thinking
		)
	end

	vim.schedule(function()
		local args = params.args or ""
		if args:match("%S") then
			cb(args)
			return
		end

		-- if prompt is not provided, run the command directly
		if not prompt or prompt == "" then
			cb(nil)
			return
		end

		-- if prompt is provided, ask the user to enter the command
		vim.ui.input({ prompt = prompt, default = whisper }, function(input)
			if not input or input == "" then
				return
			end
			cb(input)
		end)
	end)
end

return M
