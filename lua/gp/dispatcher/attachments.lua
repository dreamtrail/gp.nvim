--------------------------------------------------------------------------------
-- Attachment helpers for dispatcher payload preparation.
--------------------------------------------------------------------------------

local logger = require("gp.logger")
local helpers = require("gp.helper")

local M = {}

---@param message string
---@return table
--- Extracts attachment from message: syntax: attach(/location_of_attachment)
--- Need to Handle multiple attachments in the same message
M.get_attachments_from_message = function(message)
	local attachments = {}
	if not message then
		return attachments
	end
	for attachment in message:gmatch("@attach%(([^)]+)%)") do
		-- Check if the attachment exists
		attachment = vim.fn.expand(attachment)
		if vim.fn.filereadable(attachment) == 1 then
			table.insert(attachments, attachment)
		else
			logger.error("Attachment not found: " .. attachment)
			-- vim.schedule(function()
			-- 	vim.api.nvim_err_writeln("Attachment not found: " .. attachment)
			-- end)
		end
	end
	return attachments
end

---@param message table
---@param provider string|nil
---@return table | nil
M.attach_files_in_message = function(message, provider)
	local content = nil
	if message.parts and message.parts[1] and message.parts[1].text then
		content = message.parts[1].text
	elseif message.content then
		if type(message.content) == "string" then
			content = message.content
		elseif type(message.content) == "table" then
			content = message.content[1].text
		end
	end
	if not content then
		return nil
	end
	local attachments = M.get_attachments_from_message(content)
	local data
	if #attachments == 0 then
		return nil
	end
	local return_message = vim.deepcopy(message)
	for _, file in ipairs(attachments) do
		-- name = vim.fn.fnamemodify(file, ":t") -- get the basename
		local f = io.open(file, "rb")
		if not f then
			vim.schedule(function()
				vim.notify("Attachment not found: " .. file, vim.log.levels.WARN)
			end)
		else
			data = f:read("*all")
			f:close()
			local b64_data = vim.base64.encode(data)
			local mime_type = helpers.guess_mime_type(file)
			local inline_data
			if message.parts then
				inline_data = {
					data = b64_data,
					mime_type = mime_type,
				}
				-- append inline_data to the parts table at the end
				return_message.parts[#return_message.parts + 1] = { inline_data = inline_data }
			elseif message.content then
				-- if mine type starts with image, then it is an image else it is a file
				if provider == "anthropic" then
					inline_data = {
						type = mime_type:find("image") and "image" or "document",
						source = {
							type = "base64",
							media_type = mime_type,
							data = b64_data,
						},
					}
				else
					inline_data = {
						type = "image_url",
						image_url = {
							url = "data:" .. mime_type .. ";base64," .. b64_data,
						},
					}
				end
				if type(return_message.content) == "string" then
					return_message.content = { { type = "text", text = message.content } }
				end
				return_message.content[#return_message.content + 1] = inline_data
			end
		end
	end
	return return_message
end

return M
