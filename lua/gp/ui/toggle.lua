--------------------------------------------------------------------------------
-- Shared toggle state for popup, chat, and context windows.
--------------------------------------------------------------------------------

local M = {}

M.setup = function(gp)
	gp._toggle = {}

	gp._toggle_kind = {
		unknown = 0, -- unknown toggle
		chat = 1, -- chat toggle
		popup = 2, -- popup toggle
		context = 3, -- context toggle
	}

	---@param kind number # kind of toggle
	---@return boolean # true if toggle was closed
	gp._toggle_close = function(kind)
		if
			gp._toggle[kind]
			and gp._toggle[kind].win
			and gp._toggle[kind].buf
			and gp._toggle[kind].close
			and vim.api.nvim_win_is_valid(gp._toggle[kind].win)
			and vim.api.nvim_buf_is_valid(gp._toggle[kind].buf)
			and vim.api.nvim_win_get_buf(gp._toggle[kind].win) == gp._toggle[kind].buf
		then
			if #vim.api.nvim_list_wins() == 1 then
				gp.logger.warning("Can't close the last window.")
			else
				gp._toggle[kind].close()
				gp._toggle[kind] = nil
			end
			return true
		end
		gp._toggle[kind] = nil
		return false
	end

	---@param kind number # kind of toggle
	---@param toggle table # table containing `win`, `buf`, and `close` information
	gp._toggle_add = function(kind, toggle)
		gp._toggle[kind] = toggle
	end

	---@param kind string # string representation of the toggle kind
	---@return number # numeric kind of the toggle
	gp._toggle_resolve = function(kind)
		kind = kind:lower()
		if kind == "chat" then
			return gp._toggle_kind.chat
		elseif kind == "popup" then
			return gp._toggle_kind.popup
		elseif kind == "context" then
			return gp._toggle_kind.context
		end
		gp.logger.warning("Unknown toggle kind: " .. kind)
		return gp._toggle_kind.unknown
	end
end

return M
