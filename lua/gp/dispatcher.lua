--------------------------------------------------------------------------------
-- Dispatcher handles the communication between the plugin and LLM providers.
--------------------------------------------------------------------------------

local logger = require("gp.logger")
local tasker = require("gp.tasker")
local vault = require("gp.vault")
local render = require("gp.render")
local helpers = require("gp.helper")

local default_config = require("gp.config")

local reasoning = require("gp.dispatcher.reasoning")
local attachments = require("gp.dispatcher.attachments")
local payload = require("gp.dispatcher.payload")
local status = require("gp.dispatcher.status")
local handler = require("gp.dispatcher.handler")

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
	return status.update_status_msg(D, msg)
end

D.show_query_start = function(provider)
	return status.show_query_start(D, provider)
end

D.show_query_progress = function(msg)
	return status.show_query_progress(D, msg)
end

D.print_query_end = function()
	return status.print_query_end(D)
end

D.is_openai_reason_model = reasoning.is_openai_reason_model
D.is_google_provider = reasoning.is_google_provider
D.is_other_reason_model = reasoning.is_other_reason_model

D.get_attachments_from_message = attachments.get_attachments_from_message
D.attach_files_in_message = attachments.attach_files_in_message

D.prepare_payload = payload.prepare_payload

-- gpt query
---@param buf number | nil # buffer number
---@param provider string # provider name
---@param payload table # payload for api
---@param handler function # response handler
---@param on_exit function | nil # optional on_exit handler
---@param callback function | nil # optional callback handler
---@param stream boolean # streaming flag
local query = function(buf, provider, payload, handler, on_exit, callback, stream, show_thinking)
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
		show_thinking = show_thinking, -- Store the show_thinking flag
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
			for n, line in ipairs(lines) do
				if line ~= "" and line ~= nil then
					qt.raw_response = qt.raw_response .. line .. "\n"
				end
				line = line:gsub("^data: ", "")
				local content = ""

				if D.is_google_provider(qt.provider) then
					if line:match('"text":') then
						-- logger.debug("google/vertex line: " .. vim.inspect(line))
						local next_line = lines[n + 1] or ""
						-- logger.debug("google/vertex next line: " .. vim.inspect(next_line))
						-- If the content is thinking content, wrap it in <think> tags
						if next_line:match('"thought":') then
							if qt.show_thinking then
								pcall(function()
									content = vim.json.decode("{" .. line:sub(1, -2) .. "}").text
								end)
								-- replace "\n+" with "\n" to avoid multiple newlines
								content = content:gsub("\n+", "\n")
								if total_reasoning_length == 0 and type(content) == "string" and content ~= "" then
									content = content:gsub("^[\n]+", "")
									--- print the content of qt
									-- logger.debug("qt: " .. vim.inspect(qt))
									content = "<think>\n" .. content
									total_reasoning_length = total_reasoning_length + #content
								end
							end
						else
							pcall(function()
								if line:sub(-1) == "," then
									content = vim.json.decode("{" .. line:sub(1, -2) .. "}").text
								else
									content = vim.json.decode("{" .. line .. "}").text
								end
							end)
							if total_reasoning_length > 0 and type(content) == "string" and content ~= "" then
								content = content:gsub("^[\n]+", "")
								if payload.model:match("gemma") then
									content = "\n</think>\n\n" .. content
								else
									content = "</think>\n\n" .. content
								end
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
					if show_thinking and is_anthropic_reasoner then
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
				elseif
					line:match("choices")
					and line:match("delta")
					and (line:match("content") or line:match("reasoning"))
				then
					line = vim.json.decode(line)
					-- logger.debug("line: " .. vim.inspect(line))
					if line.choices and line.choices[1] and line.choices[1].delta then
						if line.choices[1].delta.content then
							content = line.choices[1].delta.content
						end
						if show_thinking and is_other_reasoner then
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
			"editor-version: vscode/1.104.1",
			"-H",
			"copilot-integration-id: vscode-chat",
			"-H",
			"editor-plugin-version: copilot-chat/0.26.7",
			"-H",
			"openai-intent: conversation-panel",
			"-H",
			"openai-organization: github-copilot",
			"-H",
			"user-agent: GitHubCopilotChat/0.26.7",
			"-H",
			"x-github-api-version: 2023-07-07",
			"-H",
			"copilot-vision-request: true",
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
		-- payload.model = nil
	elseif provider:match("^vertex") then
		headers = {
			"-H",
			"Authorization: Bearer " .. bearer,
		}
		endpoint = render.template_replace(endpoint, "{{model}}", payload.model)
		-- payload.model = nil
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
D.query = function(buf, provider, payload, handler, on_exit, callback, stream, show_thinking)
	stream = (stream == nil) and false or stream
	if provider == "copilot" then
		return vault.run_with_secret(provider, function()
			vault.refresh_copilot_bearer(function()
				---@diagnostic disable-next-line: param-type-mismatch
				query(buf, provider, payload, handler, on_exit, callback, stream, show_thinking)
			end)
		end)
	elseif provider == "vertex" then
		return vault.run_with_secret(provider, function()
			vault.refresh_vertex_bearer(function()
				---@diagnostic disable-next-line: param-type-mismatch
				query(buf, provider, payload, handler, on_exit, callback, stream, show_thinking)
			end)
		end)
	end
	vault.run_with_secret(provider, function()
		---@diagnostic disable-next-line: param-type-mismatch
		query(buf, provider, payload, handler, on_exit, callback, stream, show_thinking)
	end)
	-- if not stream then
	-- 	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	-- end
end

D.create_handler = handler.create_handler

return D
