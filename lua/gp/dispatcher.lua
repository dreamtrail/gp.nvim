--------------------------------------------------------------------------------
-- Dispatcher handles the communication between the plugin and LLM providers.
--------------------------------------------------------------------------------

local logger = require("gp.logger")
local tasker = require("gp.tasker")
local vault = require("gp.vault")
local render = require("gp.render")
local helpers = require("gp.helper")

local default_config = require("gp.config")

local D = {
	config = {},
	providers = {},
	query_dir = vim.fn.stdpath("cache") .. "/gp/query",
}

---@param opts table #	user config
D.setup = function(opts)
	logger.debug("dispatcher setup started\n" .. vim.inspect(opts))

	D.config.curl_params = opts.curl_params or default_config.curl_params

	D.providers = vim.deepcopy(default_config.providers)
	opts.providers = opts.providers or {}
	for k, v in pairs(opts.providers) do
		D.providers[k] = D.providers[k] or {}
		D.providers[k].disable = false
		for pk, pv in pairs(v) do
			D.providers[k][pk] = pv
		end
		if next(v) == nil then
			D.providers[k].disable = true
		end
	end

	-- remove invalid providers
	for name, provider in pairs(D.providers) do
		if type(provider) ~= "table" or provider.disable then
			D.providers[name] = nil
		elseif not provider.endpoint then
			D.logger.warning("Provider " .. name .. " is missing endpoint")
			D.providers[name] = nil
		end
	end

	for name, provider in pairs(D.providers) do
		vault.add_secret(name, provider.secret)
		provider.secret = nil
	end

	D.query_dir = helpers.prepare_dir(D.query_dir, "query store")

	local files = vim.fn.glob(D.query_dir .. "/*.json", false, true)
	if #files > 200 then
		logger.debug("too many query files, truncating cache")
		table.sort(files, function(a, b)
			return a > b
		end)
		for i = 100, #files do
			helpers.delete_file(files[i])
		end
	end

	logger.debug("dispatcher setup finished\n" .. vim.inspect(D))
end

D.update_status_msg = function(msg)
	---@diagnostic disable-next-line: undefined-field
	local current_time = vim.loop.now()
	local update_interval_ms = 500

	-- If we recently updated, schedule this update for later
	if current_time - D.last_refresh_time < update_interval_ms then
		D.pending_message = msg

		-- If timer isn't already scheduled, schedule it
		if not D.refresh_timer:is_active() then
			D.refresh_timer:start(
				update_interval_ms - (current_time - D.last_refresh_time),
				0,
				vim.schedule_wrap(function()
					if D.pending_message then
						vim.g.status_msg = D.pending_message
						D.pending_message = nil
						vim.cmd("redrawstatus")
						---@diagnostic disable-next-line: undefined-field
						D.last_refresh_time = vim.loop.now()
					end
				end)
			)
		end
		return
	end
	-- Otherwise update immediately
	vim.g.status_msg = msg
	vim.cmd("redrawstatus")
	D.last_refresh_time = current_time
end

-- Print the start of the query
-- @param provider string
D.show_query_start = function(provider)
	if vim.o.laststatus ~= 2 then
		vim.g.gp_laststatus = vim.o.laststatus
		vim.o.laststatus = 2
	end
	vim.o.statusline = "%{g:status_msg}%=%l,%c %P" -- Adjust formatting as needed
	local msg = "Querying " .. provider:gsub("^%l", string.upper) .. " ..."
	---@diagnostic disable-next-line: undefined-field
	D.refresh_timer = vim.loop.new_timer()
	D.last_refresh_time = 0
	D.pending_message = nil
	D.update_status_msg(msg)
end

-- Print the progress of the query
-- @param msg string
D.show_query_progress = function(msg)
	D.update_status_msg(msg)
end

-- Print the end of the query
D.print_query_end = function()
	vim.o.laststatus = vim.g.gp_laststatus
	D.refresh_timer:close()
	D.refresh_timer = nil
end

---@param model string
---@return boolean
D.is_openai_reason_model = function(model)
	return model:match("^o%d+%p?") ~= nil or model:match("^openai/o%d+%p?") ~= nil
end

D.is_google_provider = function(provider)
	return provider:match("^google") ~= nil or provider:match("^vertex") ~= nil
end

---@param model string
---@return integer | nil
D.is_other_reason_model = function(model)
	model = model:lower()
	return (model:find("deepseek") and (model:find("reasoner") or model:find("r1")))
		or model:find("qwq")
		or model:find("grok%-3")
end

---@param message string
---@return table
--- Extracts attachment from message: syntax: attach(/location_of_attachment)
--- Need to Handle multiple attachments in the same message
D.get_attachments_from_message = function(message)
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
D.attach_files_in_message = function(message, provider)
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
	local attachments = D.get_attachments_from_message(content)
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

---@param messages table
---@param model string | table
---@param provider string | nil
D.prepare_payload = function(messages, model, provider)
	if type(model) == "string" then
		return {
			model = model,
			stream = true,
			messages = messages,
		}
	end

	-- Remove <think> tags from reasoning models
	if
		D.is_other_reason_model(model.model)
		or (provider == "anthropic" and model.reason_tokens ~= nil)
		or D.is_google_provider(provider)
	then
		for i = 1, #messages do
			if messages[i].role == "assistant" then
				messages[i].content = messages[i].content:gsub("^<think>.-</think>[\n]*", "")
			end
		end
	end

	local payload

	if D.is_google_provider(provider) then
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
				{ thinking_budget = model.thinking_budget, include_thoughts = true }
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
			return_message = D.attach_files_in_message(message, provider)
			if return_message ~= nil then
				messages[k] = return_message
			end
		end
	end

	if provider == "anthropic" then
		payload.messages = messages
		return payload
	elseif D.is_google_provider(provider) then
		payload.contents = messages
		return payload
	end

	payload = vim.deepcopy(model)
	if payload.stream == nil then
		payload.stream = true
	end
	payload.messages = messages

	-- If it's a OpenAI reason model, we change the role from "system" to "developer"
	if D.is_openai_reason_model(payload.model) then
		if messages[1].role == "system" then
			messages[1].role = "developer"
		end
	end

	return payload
end

-- gpt query
---@param buf number | nil # buffer number
---@param provider string # provider name
---@param payload table # payload for api
---@param handler function # response handler
---@param on_exit function | nil # optional on_exit handler
---@param callback function | nil # optional callback handler
---@param stream boolean # streaming flag
local query = function(buf, provider, payload, handler, on_exit, callback, stream)
	-- make sure handler is a function
	if type(handler) ~= "function" then
		logger.error(
			string.format("query() expects a handler function, but got %s:\n%s", type(handler), vim.inspect(handler))
		)
		return
	end

	local qid = helpers.uuid()
	local is_other_reasoner = D.is_other_reason_model(payload.model)
	local is_anthropic_reasoner = provider == "anthropic" and payload.thinking ~= nil

	-- if not stream then
	-- 	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	-- end
	vim.schedule(function()
		D.show_query_start(provider)
	end)
	tasker.set_query(qid, {
		timestamp = os.time(),
		buf = buf,
		provider = provider,
		payload = payload,
		handler = handler,
		on_exit = on_exit,
		raw_response = "",
		response = "",
		first_line = -1,
		last_line = -1,
		ns_id = nil,
		ex_id = nil,
		stream = stream, -- Store the stream flag
	})

	local out_reader = function()
		local buffer = ""
		local full_response = {} -- To accumulate response if not streaming
		local last_content = nil
		local start_time = os.time()
		local total_length = 0
		local total_reasoning_length = 0
		local content_buffer = ""
		---@diagnostic disable-next-line: undefined-field
		local last_update_time = vim.loop.now()

		---@param qt table query table
		---@param content string content to process
		local function process_content(qt, content)
			local UPDATE_INTERVAL_MS = 100 -- Update UI every 100ms
			local MIN_CHUNK_SIZE = 100 -- Minimum characters before forcing an update

			if content and type(content) == "string" and content ~= "" then
				last_content = content
				if qt.stream then
					qt.response = qt.response .. content
					content_buffer = content_buffer .. content

					-- Check if it's time to update the UI
					---@diagnostic disable-next-line: undefined-field
					local now = vim.loop.now()
					if now - last_update_time >= UPDATE_INTERVAL_MS or #content_buffer >= MIN_CHUNK_SIZE then
						handler(qid, content_buffer)
						content_buffer = "" -- Reset buffer after updating
						last_update_time = now
					end
				else
					table.insert(full_response, content)
				end
				total_length = total_length + #content
				vim.schedule(function()
					local speed = math.floor(total_length / (os.time() - start_time) + 0.5)
					local msg = "Received: " .. total_length .. " B (" .. speed .. " B/s)"
					D.show_query_progress(msg)
				end)
			end
		end

		---@param lines_chunk string
		local function process_lines(lines_chunk)
			local qt = tasker.get_query(qid)
			if not qt then
				return
			end

			local lines = vim.split(lines_chunk, "\n")
			for _, line in ipairs(lines) do
				if line ~= "" and line ~= nil then
					qt.raw_response = qt.raw_response .. line .. "\n"
				end
				line = line:gsub("^data: ", "")
				local content = ""

				if D.is_google_provider(qt.provider) then
					if line:match('"text":') then
						-- logger.debug("google/vertex line: " .. vim.inspect(line))
						-- If the content is thinking content, wrap it in <think> tags
						if payload.generationConfig.thinking_config and line:sub(-1) == "," then
							pcall(function()
								content = vim.json.decode("{" .. line:sub(1, -2) .. "}").text
							end)
							-- replace "\n+" with "\n" to avoid multiple newlines
							content = content:gsub("\n+", "\n")
							if total_reasoning_length == 0 and type(content) == "string" and content ~= "" then
								content = content:gsub("^[\n]+", "")
								content = "<think>\n" .. content
								total_reasoning_length = total_reasoning_length + #content
							end
						else
							pcall(function()
								content = vim.json.decode("{" .. line .. "}").text
							end)
							if total_reasoning_length > 0 and type(content) == "string" and content ~= "" then
								content = content:gsub("^[\n]+", "")
								content = "</think>\n\n" .. content
								total_reasoning_length = -1
							end
						end
					end
				elseif qt.provider == "anthropic" and line ~= nil then
					if line:match('"text":') then
						if line:match("content_block_start") or line:match("content_block_delta") then
							line = vim.json.decode(line)
							if line.delta and line.delta.text then
								content = line.delta.text
							end
							if line.content_block and line.content_block.text then
								content = line.content_block.text
							end
						end
					end
					if is_anthropic_reasoner then
						if line:match('"thinking":') then
							if line:match("content_block_start") or line:match("content_block_delta") then
								line = vim.json.decode(line)
								if line.delta and line.delta.thinking then
									content = line.delta.thinking
								end
								if line.content_block and line.content_block.thinking then
									content = line.content_block.thinking
								end
							end
							if content and type(content) == "string" then
								local len = #content
								if total_reasoning_length == 0 and len > 0 then
									content = content:gsub("^[\n]+", "")
									content = "<think>\n" .. content
									total_reasoning_length = total_reasoning_length + len
								end
							end
						elseif line:match("content_block_stop") and total_reasoning_length > 0 then
							content = "\n</think>\n\n"
							is_anthropic_reasoner = false
						end
					end
				elseif line:match("choices") and line:match("delta") and line:match("content") then
					line = vim.json.decode(line)
					if line.choices and line.choices[1] and line.choices[1].delta then
						if line.choices[1].delta.content then
							content = line.choices[1].delta.content
						end
						if is_other_reasoner then
							if type(content) ~= "string" or content == "" then
								local reasoning_content = line.choices[1].delta.reasoning_content
									or line.choices[1].delta.reasoning
								if type(reasoning_content) == "string" and reasoning_content ~= "" then
									local len = #reasoning_content
									if total_reasoning_length == 0 and len > 0 then
										reasoning_content = reasoning_content:gsub("^[\n]+", "")
										content = "<think>\n" .. reasoning_content
									else
										content = reasoning_content
									end
									total_reasoning_length = total_reasoning_length + len
								end
							elseif total_reasoning_length > 0 and type(content) == "string" and content ~= "" then
								content = content:gsub("^[\n]+", "")
								if last_content and last_content:match("\n$") then
									content = "</think>\n\n" .. content
								else
									content = "\n</think>\n\n" .. content
								end
								total_reasoning_length = -1
							end
						end
					end
				end
				process_content(qt, content)
			end
		end

		-- closure for uv.read_start(stdout, fn)
		return function(err, chunk)
			local qt = tasker.get_query(qid)
			if not qt then
				return
			end

			if err then
				logger.error(qt.provider .. " query stdout error: " .. vim.inspect(err))
			elseif chunk then
				-- add the incoming chunk to the buffer
				buffer = buffer .. chunk
				local last_newline_pos = buffer:find("\n[^\n]*$")
				if last_newline_pos then
					local complete_lines = buffer:sub(1, last_newline_pos - 1)
					-- save the rest of the buffer for the next chunk
					buffer = buffer:sub(last_newline_pos + 1)
					process_lines(complete_lines)
				end
			-- chunk is nil when EOF is reached
			else
				-- if there's remaining data in the buffer, process it
				if #buffer > 0 then
					process_lines(buffer)
				end
				if #content_buffer > 0 then
					handler(qid, content_buffer)
				end

				if not qt.stream then
					-- Non-Streaming: Combine all accumulated response
					local combined_response = table.concat(full_response, "")
					qt.response = combined_response
					handler(qid, combined_response) -- Optionally, trigger a final handler call
				end

				local raw_response = qt.raw_response
				local content = qt.response
				if
					(qt.provider == "openai" or qt.provider == "openrouter" or qt.provider == "copilot")
					and content == ""
					and raw_response:match("choices")
					and raw_response:match("content")
				then
					local response = vim.json.decode(raw_response)
					if
						response.choices
						and response.choices[1]
						and response.choices[1].message
						and response.choices[1].message.content
					then
						content = response.choices[1].message.content
					end
					if content and type(content) == "string" then
						qt.response = qt.response .. content
						handler(qid, content)
					end
				end

				if qt.provider == "pplx" then
					-- find "citations": ["..."] in the response
					local citations = raw_response:match('"citations": %["(.-)"%]')
					if citations then
						-- split citations by '", "' to table
						citations = vim.split(citations, '", "') or {}
						-- add number for each citation from 1
						for i, citation in ipairs(citations) do
							citations[i] = i .. ". " .. citation
						end
						-- add '\nCitations:\n' to the beginning of the table
						table.insert(citations, 1, "\n\n# Citations:")
						-- join citations with newline
						citations = table.concat(citations, "\n")
						content = citations
					end
					if content and type(content) == "string" then
						qt.response = qt.response .. content
						handler(qid, content)
					end
				end
				-- if the response is empty, log an error
				if qt.response == "" then
					logger.error(qt.provider .. " response is empty: \n" .. vim.inspect(qt.raw_response))
				end
				-- clear the speed message and highlight
				vim.schedule(function()
					D.print_query_end()
					if qt.ns_id and qt.buf then
						vim.api.nvim_buf_clear_namespace(qt.buf, qt.ns_id, 0, -1)
					end
				end)
				-- optional on_exit handler
				if type(on_exit) == "function" then
					on_exit(qid)
				end
				-- optional callback handler
				if type(callback) == "function" then
					vim.schedule(function()
						callback(qt.response, qt.buf)
					end)
				end
			end
		end
	end

	---TODO: this could be moved to a separate function returning endpoint and headers
	local endpoint = D.providers[provider].endpoint
	local headers = {}

	local secret = provider
	if provider == "copilot" then
		secret = "copilot_bearer"
	elseif provider == "vertex" then
		secret = "vertex_bearer"
	end
	local bearer = vault.get_secret(secret)
	if not bearer then
		logger.warning(provider .. " bearer token is missing")
		return
	end

	if provider == "copilot" then
		headers = {
			"-H",
			"Content-Type: application/json",
			"-H",
			"editor-version: vscode/1.96.0-insider",
			"-H",
			"copilot-integration-id: vscode-chat",
			"-H",
			"editor-plugin-version: copilot-chat/0.23.2024110601",
			"-H",
			"openai-intent: conversation-panel",
			"-H",
			"openai-organization: github-copilot",
			"-H",
			"user-agent: GitHubCopilotChat/0.23.2024110601",
			"-H",
			"x-github-api-version: 2023-07-07",
			-- "-H",
			-- "copilot-vision-request: true",
			"-H",
			"Authorization: Bearer " .. bearer,
		}
	elseif provider == "openai" then
		headers = {
			"-H",
			"Authorization: Bearer " .. bearer,
			-- backwards compatibility
			"-H",
			"api-key: " .. bearer,
		}
	elseif provider:match("^google") then
		headers = {}
		endpoint = render.template_replace(endpoint, "{{secret}}", bearer)
		endpoint = render.template_replace(endpoint, "{{model}}", payload.model)
		payload.model = nil
	elseif provider:match("^vertex") then
		headers = {
			"-H",
			"Authorization: Bearer " .. bearer,
		}
		endpoint = render.template_replace(endpoint, "{{model}}", payload.model)
		payload.model = nil
	elseif provider == "anthropic" then
		headers = {
			"-H",
			"x-api-key: " .. bearer,
			"-H",
			"anthropic-version: 2023-06-01",
			"-H",
			"anthropic-beta: output-128k-2025-02-19",
		}
	elseif provider == "azure" then
		headers = {
			"-H",
			"api-key: " .. bearer,
		}
		endpoint = render.template_replace(endpoint, "{{model}}", payload.model)
	else -- default to openai compatible headers
		headers = {
			"-H",
			"Authorization: Bearer " .. bearer,
		}
	end

	local temp_file = D.query_dir
		.. "/"
		.. logger.now()
		.. "."
		.. string.format("%x", math.random(0, 0xFFFFFF))
		.. ".json"
	helpers.table_to_file(payload, temp_file)

	local curl_params = vim.deepcopy(D.config.curl_params or {})
	local args = {
		"--no-buffer",
		"-s",
		endpoint,
		"-H",
		"Content-Type: application/json",
		"-d",
		"@" .. temp_file,
	}

	for _, arg in ipairs(args) do
		table.insert(curl_params, arg)
	end

	for _, header in ipairs(headers) do
		table.insert(curl_params, header)
	end

	tasker.run(buf, "curl", curl_params, nil, out_reader(), nil)
end

-- gpt query
---@param buf number | nil # buffer number
---@param provider string # provider name
---@param payload table # payload for api
---@param handler function # response handler
---@param on_exit function | nil # optional on_exit handler
---@param callback function | nil # optional callback handler
---@param stream boolean | nil # optional streaming flag, defaults to false
D.query = function(buf, provider, payload, handler, on_exit, callback, stream)
	stream = (stream == nil) and false or stream
	if provider == "copilot" then
		return vault.run_with_secret(provider, function()
			vault.refresh_copilot_bearer(function()
				---@diagnostic disable-next-line: param-type-mismatch
				query(buf, provider, payload, handler, on_exit, callback, stream)
			end)
		end)
	elseif provider == "vertex" then
		return vault.run_with_secret(provider, function()
			vault.refresh_vertex_bearer(function()
				---@diagnostic disable-next-line: param-type-mismatch
				query(buf, provider, payload, handler, on_exit, callback, stream)
			end)
		end)
	end
	vault.run_with_secret(provider, function()
		---@diagnostic disable-next-line: param-type-mismatch
		query(buf, provider, payload, handler, on_exit, callback, stream)
	end)
	-- if not stream then
	-- 	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	-- end
end

-- response handler
---@param buf number | nil # buffer to insert response into
---@param win number | nil # window to insert response into
---@param line number | nil # line to insert response into
---@param first_undojoin boolean | nil # whether to skip first undojoin
---@param prefix string | nil # prefix to insert before each response line
---@param cursor boolean # whether to move cursor to the end of the response
D.create_handler = function(buf, win, line, first_undojoin, prefix, cursor)
	buf = buf or vim.api.nvim_get_current_buf()
	prefix = prefix or ""
	local first_line = line or vim.api.nvim_win_get_cursor(win or 0)[1] - 1
	local finished_lines = 0
	local skip_first_undojoin = not first_undojoin
	local use_hl_range = vim.fn.has("nvim-0.11") == 1

	local hl_handler_group = "GpHandlerStandout"
	vim.cmd("highlight default link " .. hl_handler_group .. " CursorLine")

	local ns_id = vim.api.nvim_create_namespace("GpHandler_" .. helpers.uuid())

	local ex_id = vim.api.nvim_buf_set_extmark(buf, ns_id, first_line, 0, {
		strict = false,
		right_gravity = false,
	})

	local response = ""
	return vim.schedule_wrap(function(qid, chunk)
		local qt = tasker.get_query(qid)
		if not qt or not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		-- undojoin takes previous change into account, so skip it for the first chunk
		if skip_first_undojoin then
			skip_first_undojoin = false
		else
			helpers.undojoin(buf)
		end

		if not qt.ns_id then
			qt.ns_id = ns_id
		end

		if not qt.ex_id then
			qt.ex_id = ex_id
		end

		first_line = vim.api.nvim_buf_get_extmark_by_id(buf, ns_id, ex_id, {})[1]

		-- if not qt.stream then
		-- 	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		-- end

		local line_count = #vim.split(response, "\n")
		vim.api.nvim_buf_set_lines(buf, first_line + finished_lines, first_line + line_count, false, {})
		-- append new response
		response = response .. chunk
		helpers.undojoin(buf)
		-- prepend prefix to each line
		local lines = vim.split(response, "\n")
		for i, l in ipairs(lines) do
			lines[i] = prefix .. l
		end

		local unfinished_lines = {}
		for i = finished_lines + 1, #lines do
			table.insert(unfinished_lines, lines[i])
		end

		vim.api.nvim_buf_set_lines(
			buf,
			first_line + finished_lines,
			first_line + finished_lines,
			false,
			unfinished_lines
		)
		if qt.stream then
			local new_finished_lines = math.max(0, #lines - 1)
			for i = finished_lines, new_finished_lines do
				if use_hl_range then
					vim.hl.range(buf, ns_id, hl_handler_group, { first_line + i, 0 }, { first_line + i, -1 }, {
						regtype = "V",
					})
				else
					---@diagnostic disable-next-line: deprecated
					vim.api.nvim_buf_add_highlight(buf, qt.ns_id, hl_handler_group, first_line + i, 0, -1)
				end
			end
			finished_lines = new_finished_lines
		end
		local end_line = first_line + #vim.split(response, "\n")
		qt.first_line = first_line
		qt.last_line = end_line - 1

		-- move cursor to the end of the response
		if cursor then
			helpers.cursor_to_line(end_line, buf, win)
		end
	end)
end

return D
