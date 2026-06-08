--------------------------------------------------------------------------------
-- Shared buffer target and opening helpers.
--------------------------------------------------------------------------------

local M = {}

M.setup = function(gp)
	---@param buf number | nil # buffer number
	gp.prep_md = function(buf)
		-- disable swapping for this buffer and set filetype to markdown
		vim.api.nvim_command("setlocal noswapfile")
		-- better text wrapping
		vim.api.nvim_command("setlocal wrap linebreak")
		-- auto save on TextChanged, InsertLeave
		-- vim.api.nvim_command("autocmd TextChanged,InsertLeave <buffer=" .. buf .. "> silent! write")
		-- set autowrite off
		vim.api.nvim_command("setlocal noautowrite")

		-- register shortcuts local to this buffer
		buf = buf or vim.api.nvim_get_current_buf()

		-- ensure normal mode
		vim.api.nvim_command("stopinsert")
		gp.helpers.feedkeys("<esc>", "xn")
	end

	gp.BufTarget = {
		current = 0, -- current window
		popup = 1, -- popup window
		split = 2, -- split window
		vsplit = 3, -- vsplit window
		tabnew = 4, -- new tab
	}

	---@param params table | string # table with args or string args
	---@return number # buf target
	gp.resolve_buf_target = function(params)
		local args = ""
		if type(params) == "table" then
			args = params.args or ""
		else
			args = params
		end

		args = args:match("^%s*(.-)%s*$")

		if args == "popup" then
			return gp.BufTarget.popup
		elseif args == "split" then
			return gp.BufTarget.split
		elseif args == "vsplit" then
			return gp.BufTarget.vsplit
		elseif args == "tabnew" then
			return gp.BufTarget.tabnew
		else
			return gp.BufTarget.current
		end
	end

	---@param file_name string
	---@param target number | nil # buf target
	---@param kind number # nil or a toggle kind
	---@param toggle boolean # whether to toggle
	---@return number # buffer number
	gp.open_buf = function(file_name, target, kind, toggle)
		target = target or gp.BufTarget.current

		-- close previous popup if it exists
		gp._toggle_close(gp._toggle_kind.popup)

		if toggle then
			gp._toggle_close(kind)
		end

		local close, buf, win

		if target == gp.BufTarget.popup then
			local old_buf = gp.helpers.get_buffer(file_name)

			buf, win, close, _ = gp.render.popup(old_buf, gp._Name .. " Popup", function(w, h)
				local top = gp.config.style_popup_margin_top or 2
				local bottom = gp.config.style_popup_margin_bottom or 8
				local left = gp.config.style_popup_margin_left or 1
				local right = gp.config.style_popup_margin_right or 1
				local max_width = gp.config.style_popup_max_width or 160
				local ww = math.min(w - (left + right), max_width)
				local wh = h - (top + bottom)
				return ww, wh, top, (w - ww) / 2
			end, { on_leave = false, escape = false, persist = true }, {
				border = gp.config.style_popup_border or "single",
				zindex = gp.config.zindex,
			})

			if not toggle then
				gp._toggle_add(gp._toggle_kind.popup, { win = win, buf = buf, close = close })
			end

			if old_buf == nil then
				-- read file into buffer and force write it
				vim.api.nvim_command("silent 0read " .. file_name)
				vim.api.nvim_command("silent file " .. file_name)
				-- set the filetype to markdown
				vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
			else
				-- move cursor to the beginning of the file and scroll to the end
				gp.helpers.feedkeys("ggG", "xn")
			end

			-- delete whitespace lines at the end of the file
			local last_content_line = gp.helpers.last_content_line(buf)
			vim.api.nvim_buf_set_lines(buf, last_content_line, -1, false, {})
			-- insert a new line at the end of the file
			vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "" })
			vim.api.nvim_command("silent write! " .. file_name)
		elseif target == gp.BufTarget.split then
			vim.api.nvim_command("botright split " .. file_name)
		elseif target == gp.BufTarget.vsplit then
			vim.api.nvim_command("botright vsplit " .. file_name)
			vim.api.nvim_command("vertical resize 50%")
		elseif target == gp.BufTarget.tabnew then
			vim.api.nvim_command("tabnew " .. file_name)
		else
			-- is it already open in a buffer?
			for _, b in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_get_name(b) == file_name then
					for _, w in ipairs(vim.api.nvim_list_wins()) do
						if vim.api.nvim_win_get_buf(w) == b then
							vim.api.nvim_set_current_win(w)
							return b
						end
					end
				end
			end

			-- open in new buffer
			vim.api.nvim_command("edit " .. file_name)
		end

		buf = vim.api.nvim_get_current_buf()
		win = vim.api.nvim_get_current_win()
		close = close or function() end

		if not toggle then
			return buf
		end

		vim.api.nvim_set_option_value("buflisted", false, { buf = buf })
		vim.api.nvim_set_option_value("swapfile", false, { buf = buf })

		if target == gp.BufTarget.split or target == gp.BufTarget.vsplit then
			close = function()
				if vim.api.nvim_win_is_valid(win) then
					vim.api.nvim_win_close(win, true)
				end
			end
		end

		if target == gp.BufTarget.tabnew then
			close = function()
				if vim.api.nvim_win_is_valid(win) then
					local tab = vim.api.nvim_win_get_tabpage(win)
					vim.api.nvim_set_current_tabpage(tab)
					vim.api.nvim_command("tabclose")
				end
			end
		end

		gp._toggle_add(kind, { win = win, buf = buf, close = close })

		return buf
	end
end

return M
