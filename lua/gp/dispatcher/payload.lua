--------------------------------------------------------------------------------
-- Provider-specific payload preparation for dispatcher.
--------------------------------------------------------------------------------

local reasoning = require("gp.dispatcher.reasoning")
local attachments = require("gp.dispatcher.attachments")

local M = {}

---@param messages table
---@param model string | table
---@param provider string | nil
---@param opts table | nil # optional payload overrides, e.g. { stream=false, tools={...}, tool_choice="auto" }
M.prepare_payload = function(messages, model, provider, opts)
	opts = opts or {}
	local openai_tools = opts.tools
	local tool_choice = opts.tool_choice
	local stream_override = opts.stream
	local is_openai_compatible = not reasoning.is_google_provider(provider or "") and provider ~= "anthropic"

	if type(model) == "string" then
		local stream = true
		if stream_override ~= nil then
			stream = stream_override
		end
		local result = {
			model = model,
			stream = stream,
			messages = messages,
		}
		if is_openai_compatible and openai_tools then
			result.tools = openai_tools
			result.tool_choice = tool_choice or "auto"
		end
		return result
	end

	-- Remove <think> tags from reasoning models
	-- if
	-- 	reasoning.is_other_reason_model(model.model)
	-- 	or (provider == "anthropic" and model.reason_tokens ~= nil)
	-- 	or reasoning.is_google_provider(provider)
	-- then
	for i = 1, #messages do
		if messages[i].role == "assistant" and type(messages[i].content) == "string" then
			messages[i].content = messages[i].content:gsub("^<think>.-</think>[\n]*", "")
		end
	end
	-- end

	local payload

	if reasoning.is_google_provider(provider) then
		-- extract system messages and add them to the system_instruction field
		local system = ""
		local j = 1
		while j < #messages do
			if messages[j].role == "system" then
				system = system .. messages[j].content .. "\n"
				table.remove(messages, j)
			else
				j = j + 1
			end
		end
		-- convert messages to google format
		for i, message in ipairs(messages) do
			if message.role == "assistant" then
				messages[i].role = "model"
			end
			if message.content then
				messages[i].parts = {
					{
						text = message.content,
					},
				}
				messages[i].content = nil
			end
		end
		-- combine consecutive messages with the same role
		local i = 1
		while i < #messages do
			if messages[i].role == messages[i + 1].role then
				table.insert(messages[i].parts, {
					text = messages[i + 1].parts[1].text,
				})
				table.remove(messages, i + 1)
			else
				i = i + 1
			end
		end

		payload = {
			safetySettings = {
				{
					category = "HARM_CATEGORY_HARASSMENT",
					threshold = "BLOCK_NONE",
				},
				{
					category = "HARM_CATEGORY_HATE_SPEECH",
					threshold = "BLOCK_NONE",
				},
				{
					category = "HARM_CATEGORY_SEXUALLY_EXPLICIT",
					threshold = "BLOCK_NONE",
				},
				{
					category = "HARM_CATEGORY_DANGEROUS_CONTENT",
					threshold = "BLOCK_NONE",
				},
			},
			generationConfig = {
				temperature = model.temperature,
				maxOutputTokens = model.max_tokens,
				topP = model.top_p,
				topK = model.top_k,
			},
			model = model.model,
		}
		if system ~= "" then
			payload.system_instruction = { parts = { text = system } }
		end
		if model.thinking_budget then
			payload.generationConfig.thinking_config =
				{ thinking_budget = model.thinking_budget, include_thoughts = model.thinking_budget > 0 }
		elseif model.thinking_level then
			payload.generationConfig.thinking_config =
				{ thinking_level = model.thinking_level, include_thoughts = true }
		end
		-- add google search if model.search is true
		if model.search and model.search == "on" then
			payload.tools = { { google_search = vim.empty_dict() } }
		end
	end

	if provider == "anthropic" then
		local system = ""
		local i = 1
		local total_length = 0
		while i < #messages do
			if messages[i].role == "system" then
				total_length = total_length + #messages[i].content
				system = system .. messages[i].content .. "\n"
				table.remove(messages, i)
			else
				i = i + 1
			end
		end
		-- Add most to 2 cache_controls to the messages if the condition is met
		-- 4096 is a safe minimum bet for 1000 tokens
		local max_cache_breaks = 1
		if #messages > 1 then
			total_length = total_length + #messages[1].content + #messages[2].content
			if total_length > 4096 then
				for j = 2, math.min(max_cache_breaks * 2, #messages), 2 do
					messages[j] = {
						role = messages[j].role,
						content = {
							{
								type = "text",
								text = messages[j].content,
								cache_control = { type = "ephemeral" },
							},
						},
					}
				end
			end
		end
		payload = {
			model = model.model,
			stream = model.stream or true,
			system = system,
			max_tokens = model.max_tokens,
			temperature = model.temperature,
			top_p = model.top_p,
		}
		if model.reason_tokens then
			payload.thinking = {
				type = "enabled",
				budget_tokens = model.reason_tokens,
			}
		end
	end

	-- attach files to messages
	local return_message
	for k, message in ipairs(messages) do
		if message.role == "user" then
			return_message = attachments.attach_files_in_message(message, provider)
			if return_message ~= nil then
				messages[k] = return_message
			end
		end
	end

	if provider == "anthropic" then
		payload.messages = messages
		return payload
	elseif reasoning.is_google_provider(provider) then
		payload.contents = messages
		return payload
	end

	payload = vim.deepcopy(model)
	if stream_override ~= nil then
		payload.stream = stream_override
	elseif payload.stream == nil then
		payload.stream = true
	end
	payload.messages = messages
	if is_openai_compatible and openai_tools then
		payload.tools = openai_tools
		payload.tool_choice = tool_choice or "auto"
	end

	-- If it's a OpenAI reason model, we change the role from "system" to "developer"
	if reasoning.is_openai_reason_model(payload.model) then
		if messages[1].role == "system" then
			messages[1].role = "developer"
		end
	end

	return payload
end

return M
