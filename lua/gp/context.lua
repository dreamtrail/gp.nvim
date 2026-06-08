--------------------------------------------------------------------------------
-- Repository context (.gp.md) helpers and command.
--------------------------------------------------------------------------------

local M = {}

M.setup = function(gp)
	-- tries to find an .gp.md file in the root of current git repo
	---@return string # returns instructions from the .gp.md file
	gp.repo_instructions = function()
		local git_root = gp.helpers.find_git_root()

		if git_root == "" then
			return ""
		end

		local instruct_file = git_root .. "/.gp.md"

		if vim.fn.filereadable(instruct_file) == 0 then
			return ""
		end

		local lines = vim.fn.readfile(instruct_file)
		return table.concat(lines, "\n")
	end

	gp.prep_context = function(buf, file_name)
		if not gp.helpers.ends_with(file_name, ".gp.md") then
			return
		end

		if buf ~= vim.api.nvim_get_current_buf() then
			return
		end
		if gp._prepared_bufs[buf] then
			gp.logger.debug("buffer already prepared: " .. buf)
			return
		end
		gp._prepared_bufs[buf] = true

		gp.prep_md(buf)
	end

	gp.cmd.Context = function(params)
		gp._toggle_close(gp._toggle_kind.popup)
		-- if there is no selection, try to close context toggle
		if params.range ~= 2 then
			if gp._toggle_close(gp._toggle_kind.context) then
				return
			end
		end

		local cbuf = vim.api.nvim_get_current_buf()

		local file_name = ""
		local buf = gp.helpers.get_buffer(".gp.md")
		if buf then
			file_name = vim.api.nvim_buf_get_name(buf)
		else
			local git_root = gp.helpers.find_git_root()
			if git_root == "" then
				gp.logger.warning("Not in a git repository")
				return
			end
			file_name = git_root .. "/.gp.md"
		end

		if vim.fn.filereadable(file_name) ~= 1 then
			vim.fn.writefile({ "Additional context is provided below.", "" }, file_name)
		end

		params.args = params.args or ""
		if params.args == "" then
			params.args = gp.config.toggle_target
		end
		local target = gp.resolve_buf_target(params)
		buf = gp.open_buf(file_name, target, gp._toggle_kind.context, true)

		if params.range == 2 then
			gp.render.append_selection(params, cbuf, buf, gp.config.template_selection)
		end

		gp.helpers.feedkeys("G", "xn")
	end
end

return M
