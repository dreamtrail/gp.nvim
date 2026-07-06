--------------------------------------------------------------------------------
-- Chat layout migration command.
--------------------------------------------------------------------------------

local storage = require("gp.chat.storage")

local M = {}

local usage = "Usage: GpChatMigrate [dry-run|apply]"

local notify = function(message, level)
	vim.notify(message, level or vim.log.levels.INFO)
end

local summary_message = function(summary)
	return string.format(
		"legacy flat chats: %d movable, %d skipped, %d non-chat, %d conflicts, %d errors",
		summary.move or 0,
		summary.skipped or 0,
		summary.non_chat or 0,
		summary.conflict or 0,
		summary.error or 0
	)
end

M.setup = function(gp)
	gp.cmd.ChatMigrate = function(params)
		local args = (params and params.args or ""):gsub("^%s*(.-)%s*$", "%1")
		local mode = args == "" and "dry-run" or args
		if mode ~= "dry-run" and mode ~= "apply" then
			gp.logger.warning(usage)
			notify(usage, vim.log.levels.WARN)
			return
		end

		local plan = storage.plan_flat_migration(gp.config.chat_dir)
		local summary = storage.summarize_plan(plan)
		if mode == "dry-run" then
			notify("GpChatMigrate dry-run: " .. summary_message(summary))
			return
		end

		if summary.move == 0 then
			notify("GpChatMigrate apply: no legacy flat chats to move; " .. summary_message(summary))
			return
		end

		vim.ui.input({ prompt = "Move " .. summary.move .. " legacy flat chats into YYYY/MM folders? [y/N] " }, function(input)
			if not input or input:lower() ~= "y" then
				notify("GpChatMigrate apply cancelled")
				return
			end

			local result = storage.apply_flat_migration(gp.config.chat_dir, plan)
			local last_update = nil
			for _, item in ipairs(result.moved) do
				if gp._state.last_chat == item.source or vim.fn.resolve(gp._state.last_chat or "") == vim.fn.resolve(item.source) then
					last_update = item.target
				end
			end
			if last_update then
				gp.refresh_state({ last_chat = last_update })
			end
			notify(
				string.format(
					"GpChatMigrate apply: moved %d, skipped %d, errors %d",
					#result.moved,
					#result.skipped,
					#result.errors
				)
			)
		end)
	end
end

return M
