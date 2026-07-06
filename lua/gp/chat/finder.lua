--------------------------------------------------------------------------------
-- Chat finder UI.
--------------------------------------------------------------------------------

local storage = require("gp.chat.storage")

local M = {}

local compact_timestamp_label = function(relative, include_seconds)
	local name = (relative or ""):match("([^/]+)$") or ""
	local date, hour, minute, second = name:match("^(%d%d%d%d%-%d%d%-%d%d)%.(%d%d)%-(%d%d)%-(%d%d)%.%d%d%d%.md$")
	if not date then
		date, hour, minute, second = name:match("^(%d%d%d%d%-%d%d%-%d%d)%.(%d%d)%-(%d%d)%-(%d%d)%.md$")
	end
	if not date then
		return nil
	end
	if include_seconds then
		return string.format("%s %s:%s:%s", date, hour, minute, second)
	end
	return string.format("%s %s:%s", date, hour, minute)
end

local clean_topic = function(line)
	local text = (line or ""):gsub("^%s*(.-)%s*$", "%1")
	text = text:gsub("^#%s*[Tt][Oo][Pp][Ii][Cc]%s*:%s*", "")
	text = text:gsub("^#%s*", "")
	return text
end

local picker_line = function(result, is_default_query)
	local label = compact_timestamp_label(result.relative, not is_default_query)
	if not label then
		return string.format("%s:%s %s", result.relative, result.lnum, result.line)
	end
	if is_default_query then
		return string.format("%s  %s", label, clean_topic(result.line))
	end
	return string.format("%s  L%s  %s", label, result.lnum, result.line)
end

M.setup = function(gp)
	local M = gp
M._chat_finder_opened = false
M._chat_finder_collect = function(dir, cmd, default_pattern)
	local results = {}
	local re = ""
	local is_default_query = storage.is_default_finder_query(cmd, default_pattern)
	if is_default_query then
		for _, chat in ipairs(storage.list_canonical_chats(dir)) do
			table.insert(results, {
				path = chat.path,
				relative = chat.relative,
				lnum = 1,
				line = chat.topic,
			})
		end
	else
		results, re = storage.search_canonical_chats(dir, cmd)
	end

	local files = {}
	local preview_lines = {}
	local picker_lines = {}
	for _, f in ipairs(results) do
		if f.line:len() > 0 then
			table.insert(files, f.path)
			table.insert(preview_lines, tonumber(f.lnum))
			table.insert(picker_lines, picker_line(f, is_default_query))
		end
	end
	return { files = files, preview_lines = preview_lines, picker_lines = picker_lines, regex = re }
end

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
	local search_timer = nil
	local request_id = 0

	-- clean up augroup and popup buffers/windows
	local close = M.tasker.once(function()
		if search_timer and not search_timer:is_closing() then
			search_timer:stop()
			search_timer:close()
		end
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
		request_id = request_id + 1
		local token = request_id

		local collected = M._chat_finder_collect(dir, cmd, M.config.chat_finder_pattern)
		if token ~= request_id or not vim.api.nvim_buf_is_valid(picker_buf) then
			return
		end
		picker_files = collected.files
		preview_lines = collected.preview_lines
		vim.api.nvim_buf_set_lines(picker_buf, 0, -1, false, collected.picker_lines)
		regex = collected.regex
		if regex ~= "" then
			regex = "\\c" .. regex
		end
		refresh()
	end

	local schedule_refresh_picker = function()
		if search_timer and not search_timer:is_closing() then
			search_timer:stop()
			search_timer:close()
		end
		search_timer = (vim.uv or vim.loop).new_timer()
		search_timer:start(120, 0, vim.schedule_wrap(function()
			if search_timer and not search_timer:is_closing() then
				search_timer:close()
			end
			search_timer = nil
			if vim.api.nvim_win_is_valid(picker_win) then
				vim.api.nvim_win_set_cursor(picker_win, { 1, 0 })
			end
			refresh_picker()
		end))
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
		schedule_refresh_picker()
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

end

return M
