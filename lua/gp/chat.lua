--------------------------------------------------------------------------------
-- Chat buffer lifecycle helpers and commands.
--------------------------------------------------------------------------------

local storage = require("gp.chat.storage")

local path_is_under = function(base, path)
	if not base or not path or base == "" or path == "" then
		return false
	end
	base = vim.fn.resolve(vim.fn.fnamemodify(base, ":p")):gsub("[\\/]$", "")
	path = vim.fn.resolve(vim.fn.fnamemodify(path, ":p")):gsub("[\\/]$", "")
	return path == base or path:sub(1, #base + 1) == base .. "/" or path:sub(1, #base + 1) == base .. "\\"
end

local M = {}

M.setup = function(gp)
	---@param buf number # buffer number
	---@param file_name string # file name
	---@return string | nil # reason for not being a chat or nil if it is a chat
	gp.not_chat = function(buf, file_name)
		file_name = vim.fn.resolve(file_name)
		-- local chat_dir = vim.fn.resolve(gp.config.chat_dir)
		--
		-- if not gp.helpers.starts_with(file_name, chat_dir) then
		-- 	return "resolved file (" .. file_name .. ") not in chat dir (" .. chat_dir .. ")"
		-- end

		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		if #lines < 5 then
			return "file too short"
		end

		if not lines[1]:match("^# ") then
			return "missing topic header"
		end

		local header_found = nil
		for i = 1, 10 do
			if i < #lines and lines[i]:match("^- file: ") then
				header_found = true
				break
			end
		end
		if not header_found then
			return "missing file header"
		end

		return nil
	end

	gp.display_chat_agent = function(buf, file_name)
		if gp.not_chat(buf, file_name) then
			return
		end

		if buf ~= vim.api.nvim_get_current_buf() then
			return
		end

		local ns_id = vim.api.nvim_create_namespace("GpChatExt_" .. file_name)
		vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

		vim.api.nvim_buf_set_extmark(buf, ns_id, 0, 0, {
			strict = false,
			right_gravity = true,
			virt_text_pos = "right_align",
			virt_text = {
				{ "Current Agent: [" .. gp._state.chat_agent .. "]", "DiagnosticHint" },
			},
			hl_mode = "combine",
		})
	end

	gp._prepared_bufs = gp._prepared_bufs or {}
	gp.prep_chat = function(buf, file_name)
		if gp.not_chat(buf, file_name) then
			return
		end

		if buf ~= vim.api.nvim_get_current_buf() then
			return
		end

		gp.refresh_state({ last_chat = file_name })
		if gp._prepared_bufs[buf] then
			gp.logger.debug("buffer already prepared: " .. buf)
			return
		end
		gp._prepared_bufs[buf] = true

		gp.prep_md(buf)

		if gp.config.chat_prompt_buf_type then
			vim.api.nvim_set_option_value("buftype", "prompt", { buf = buf })
			vim.fn.prompt_setprompt(buf, "")
			vim.fn.prompt_setcallback(buf, function()
				gp.cmd.ChatRespond({ args = "" })
			end)
		end

		-- setup chat specific commands
		local range_commands = {
			{
				command = "ChatRespond",
				modes = gp.config.chat_shortcut_respond.modes,
				shortcut = gp.config.chat_shortcut_respond.shortcut,
				comment = "GPT prompt Chat Respond",
			},
			{
				command = "ChatNew",
				modes = gp.config.chat_shortcut_new.modes,
				shortcut = gp.config.chat_shortcut_new.shortcut,
				comment = "GPT prompt Chat New",
			},
		}
		for _, rc in ipairs(range_commands) do
			local cmd = gp.config.cmd_prefix .. rc.command .. "<cr>"
			for _, mode in ipairs(rc.modes) do
				if mode == "n" or mode == "i" then
					gp.helpers.set_keymap({ buf }, mode, rc.shortcut, function()
						vim.api.nvim_command(gp.config.cmd_prefix .. rc.command)
						-- go to normal mode
						vim.api.nvim_command("stopinsert")
						gp.helpers.feedkeys("<esc>", "xn")
					end, rc.comment)
				else
					gp.helpers.set_keymap({ buf }, mode, rc.shortcut, ":<C-u>'<,'>" .. cmd, rc.comment)
				end
			end
		end

		local ds = gp.config.chat_shortcut_delete
		gp.helpers.set_keymap({ buf }, ds.modes, ds.shortcut, gp.cmd.ChatDelete, "GPT prompt Chat Delete")

		local ss = gp.config.chat_shortcut_stop
		gp.helpers.set_keymap({ buf }, ss.modes, ss.shortcut, gp.cmd.Stop, "GPT prompt Chat Stop")

		-- conceal parameters in model header so it's not distracting
		if gp.config.chat_conceal_model_params then
			vim.opt_local.conceallevel = 2
			vim.opt_local.concealcursor = ""
			vim.fn.matchadd("Conceal", [[^- model: .*model.:.[^"]*\zs".*\ze]], 10, -1, { conceal = "…" })
			vim.fn.matchadd("Conceal", [[^- model: \zs.*model.:.\ze.*]], 10, -1, { conceal = "…" })
			vim.fn.matchadd("Conceal", [[^- role: .\{64,64\}\zs.*\ze]], 10, -1, { conceal = "…" })
			vim.fn.matchadd("Conceal", [[^- role: .[^\\]*\zs\\.*\ze]], 10, -1, { conceal = "…" })
		end
	end

	gp.buf_handler = function()
		local gid = gp.helpers.create_augroup("GpBufHandler", { clear = true })

		gp.helpers.autocmd({ "BufEnter" }, nil, function(event)
			local buf = event.buf

			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end

			local file_name = vim.api.nvim_buf_get_name(buf)

			gp.prep_chat(buf, file_name)
			gp.display_chat_agent(buf, file_name)
			gp.prep_context(buf, file_name)
		end, gid)

		gp.helpers.autocmd({ "WinEnter" }, nil, function(event)
			local buf = event.buf

			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end

			local file_name = vim.api.nvim_buf_get_name(buf)

			gp.display_chat_agent(buf, file_name)
		end, gid)
	end

	---@param params table  # vim command parameters such as range, args, etc.
	---@param toggle boolean # whether chat is toggled
	---@param system_prompt string | nil # system prompt to use
	---@param agent table | nil # obtained from get_command_agent or get_chat_agent
	---@return number # buffer number
	gp.new_chat = function(params, toggle, system_prompt, agent)
		gp._toggle_close(gp._toggle_kind.popup)

		local filename, parent = storage.timestamp_path(gp.config.chat_dir, gp.logger.now())
		vim.fn.mkdir(parent, "p")

		-- encode as json if model is a table
		local model = ""
		local provider = ""
		if not agent then
			agent = gp.get_chat_agent()
		end
		if agent and agent.model and agent.provider then
			model = agent.model
			provider = agent.provider
			if type(model) == "table" then
				model = "- model: " .. vim.json.encode(model) .. "\n"
			else
				model = "- model: " .. model .. "\n"
			end

			provider = "- provider: " .. provider:gsub("\n", "\\n") .. "\n"
		end

		-- display system prompt as single line with escaped newlines
		if system_prompt then
			system_prompt = "- role: " .. system_prompt:gsub("\n", "\\n") .. "\n"
		else
			system_prompt = ""
		end

		local template = gp.render.template(gp.config.chat_template or require("gp.defaults").chat_template, {
			["{{filename}}"] = string.match(filename, "([^/]+)$"),
			["{{optional_headers}}"] = model .. provider .. system_prompt,
			["{{user_prefix}}"] = gp.config.chat_user_prefix,
			["{{respond_shortcut}}"] = gp.config.chat_shortcut_respond.shortcut,
			["{{cmd_prefix}}"] = gp.config.cmd_prefix,
			["{{stop_shortcut}}"] = gp.config.chat_shortcut_stop.shortcut,
			["{{delete_shortcut}}"] = gp.config.chat_shortcut_delete.shortcut,
			["{{new_shortcut}}"] = gp.config.chat_shortcut_new.shortcut,
		})

		-- escape underscores (for markdown)
		template = template:gsub("_", "\\_")

		local cbuf = vim.api.nvim_get_current_buf()

		-- strip leading and trailing newlines
		template = template:gsub("^%s*(.-)%s*$", "%1") .. "\n"

		-- create chat file
		-- vim.fn.writefile(vim.split(template, "\n"), filename)
		local target = gp.resolve_buf_target(params)
		local buf = gp.open_buf(filename, target, gp._toggle_kind.chat, toggle)
		-- write template to buffer
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(template, "\n"))

		if params.range == 2 then
			gp.render.append_selection(params, cbuf, buf, gp.config.template_selection)
		end
		gp.helpers.feedkeys("G", "xn")
		return buf
	end

	---@param params table
	---@param system_prompt string | nil
	---@param agent table | nil # obtained from get_command_agent or get_chat_agent
	---@return number # buffer number
	gp.cmd.ChatNew = function(params, system_prompt, agent)
		if gp.deprecator.has_old_chat_signature(agent) then
			return -1
		end

		-- if chat toggle is open, close it and start a new one
		if gp._toggle_close(gp._toggle_kind.chat) then
			params.args = params.args or ""
			if params.args == "" then
				params.args = gp.config.toggle_target
			end
			return gp.new_chat(params, true, system_prompt, agent)
		end

		return gp.new_chat(params, false, system_prompt, agent)
	end

	---@param params table
	---@param system_prompt string | nil
	---@param agent table | nil # obtained from get_command_agent or get_chat_agent
	gp.cmd.ChatToggle = function(params, system_prompt, agent)
		if gp._toggle_close(gp._toggle_kind.popup) then
			return
		end
		if gp._toggle_close(gp._toggle_kind.chat) and params.range ~= 2 then
			return
		end

		-- create new chat file otherwise
		params.args = params.args or ""
		if params.args == "" then
			params.args = gp.config.toggle_target
		end

		-- if the range is 2, we want to create a new chat file with the selection
		if params.range ~= 2 then
			local last = gp._state.last_chat
			if last and vim.fn.filereadable(last) == 1 then
				last = vim.fn.resolve(last)
				gp.open_buf(last, gp.resolve_buf_target(params), gp._toggle_kind.chat, true)
				return
			end
		end

		gp.new_chat(params, true, system_prompt, agent)
	end

	gp.cmd.ChatPaste = function(params)
		-- if there is no selection, do nothing
		if params.range ~= 2 then
			gp.logger.warning("Please select some text to paste into the chat.")
			return
		end

		-- get current buffer
		local cbuf = vim.api.nvim_get_current_buf()

		-- make new chat if last doesn't exist
		local last = gp._state.last_chat
		if not last or vim.fn.filereadable(last) ~= 1 then
			-- skip rest since new chat will handle snippet on it's own
			gp.cmd.ChatNew(params, nil, nil)
			return
		end

		params.args = params.args or ""
		if params.args == "" then
			params.args = gp.config.toggle_target
		end
		local target = gp.resolve_buf_target(params)

		last = vim.fn.resolve(last)
		local buf = gp.helpers.get_buffer(last)
		local win_found = false
		if buf then
			for _, w in ipairs(vim.api.nvim_list_wins()) do
				if vim.api.nvim_win_get_buf(w) == buf then
					vim.api.nvim_set_current_win(w)
					vim.api.nvim_set_current_buf(buf)
					win_found = true
					break
				end
			end
		end
		buf = win_found and buf or gp.open_buf(last, target, gp._toggle_kind.chat, true)

		gp.render.append_selection(params, cbuf, buf, gp.config.template_selection)
		gp.helpers.feedkeys("G", "xn")
	end

	gp.cmd.ChatDelete = function()
		-- get buffer and file
		local buf = vim.api.nvim_get_current_buf()
		local file_name = vim.api.nvim_buf_get_name(buf)

		-- check if file is in the chat dir
		if not path_is_under(gp.config.chat_dir, file_name) then
			gp.logger.warning("File " .. vim.inspect(file_name) .. " is not in chat dir")
			return
		end

		-- delete without confirmation
		if not gp.config.chat_confirm_delete then
			gp.helpers.delete_file(file_name)
			return
		end

		-- ask for confirmation
		vim.ui.input({ prompt = "Delete " .. file_name .. "? [y/N] " }, function(input)
			if input and input:lower() == "y" then
				gp.helpers.delete_file(file_name)
			end
		end)
	end
end

return M
