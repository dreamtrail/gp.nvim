--------------------------------------------------------------------------------
-- Prompt targets, prompt commands, and prompt execution.
--------------------------------------------------------------------------------

local M = {}

M.setup = function(gp)
	local M = gp
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
end

return M
