--------------------------------------------------------------------------------
-- Chat response orchestration.
--------------------------------------------------------------------------------

local config = require("gp.config")

local M = {}

local function append_lines(gp, buf, lines)
	local last_content_line = gp.helpers.last_content_line(buf)
	gp.helpers.undojoin(buf)
	vim.api.nvim_buf_set_lines(buf, last_content_line, last_content_line, false, lines)
end

local function append_text(gp, buf, text)
	append_lines(gp, buf, vim.split(text, "\n", { plain = true }))
	pcall(function()
		vim.cmd("silent write")
	end)
end

local function ensure_trailing_newline(text)
	if type(text) == "string" and text ~= "" and not text:match("\n$") then
		return text .. "\n"
	end
	return text
end

local function tool_call_args(call)
	local raw = call and call["function"] and call["function"].arguments or "{}"
	if raw == "" then
		raw = "{}"
	end
	local ok, args = pcall(vim.json.decode, raw)
	if ok and type(args) == "table" then
		return args
	end
	return { error = "invalid JSON arguments", raw = raw }
end

local function finish_chat(gp, buf, win, headers, messages, cmd_pattern)
	-- write user prompt
	local last_content_line = gp.helpers.last_content_line(buf)
	gp.helpers.undojoin(buf)
	vim.api.nvim_buf_set_lines(buf, last_content_line, last_content_line, false, { "", gp.config.chat_user_prefix, "" })

	-- delete whitespace lines at the end of the file
	last_content_line = gp.helpers.last_content_line(buf)
	gp.helpers.undojoin(buf)
	vim.api.nvim_buf_set_lines(buf, last_content_line, -1, false, {})
	-- insert a new line at the end of the file
	gp.helpers.undojoin(buf)
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "" })

	-- if topic is ?, then generate it
	if headers.topic == "?" then
		local topic_messages = { { role = "system", content = gp.config.chat_topic_gen_prompt } }
		for _, message in ipairs(messages) do
			if message.role ~= "system" then
				local msg = { role = message.role }
				if type(message.content) == "string" then
					msg.content = message.content
				elseif type(message.content) == "table" then
					for _, line in ipairs(message.content) do
						if line.text then
							msg.content = line.text
							break
						end
					end
				elseif message.parts then
					if message.parts.text then
						msg.content = message.parts.text
					elseif message.parts[1].text then
						msg.content = message.parts[1].text
					end
				end
				if not msg.content then
					vim.api.nvim_err_writeln("Could not find content in message: " .. vim.inspect(message))
					break
				end
				-- remove @attach(.*) with empty string
				msg.content = msg.content:gsub("@attach(.*)", "")
				-- remove @command(cmd_string) commands
				msg.content = msg.content:gsub(cmd_pattern, "")
				if msg.content and #msg.content > 2000 then
					msg.content = gp.helpers.truncate_string_at_newline(msg.content, 2000)
				elseif msg.parts and #msg.parts[1].text > 2000 then
					msg.parts[1].text = gp.helpers.truncate_string_at_newline(msg.parts[1].text, 2000)
				end
				table.insert(topic_messages, msg)
				break
			end
		end
		-- prepare invisible buffer for the model to write to
		local topic_buf = vim.api.nvim_create_buf(false, true)
		local topic_handler = gp.dispatcher.create_handler(topic_buf, nil, 0, false, "", false)
		local topic_gen_agent = gp.get_chat_agent(gp.config.chat_topic_gen_agent)

		-- call the model to generate the topic
		gp.dispatcher.query(
			nil,
			topic_gen_agent.provider,
			gp.dispatcher.prepare_payload(topic_messages, topic_gen_agent.model, topic_gen_agent.provider),
			topic_handler,
			vim.schedule_wrap(function()
				-- get topic from invisible buffer
				local topic = vim.api.nvim_buf_get_lines(topic_buf, 0, -1, false)[1]
				-- close invisible buffer
				vim.api.nvim_buf_delete(topic_buf, { force = true })
				-- strip whitespace from ends of topic
				topic = topic:gsub("^%s*(.-)%s*$", "%1")
				-- strip dot from end of topic
				topic = topic:gsub("%.$", "")

				-- if topic is empty do not replace it
				if topic == "" then
					return
				end

				-- replace topic in current buffer
				gp.helpers.undojoin(buf)
				vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# topic: " .. topic })
			end),
			function()
				pcall(function()
					vim.cmd("silent write")
				end)
			end
		)
	else
		pcall(function()
			vim.cmd("silent write")
		end)
	end
	if not gp.config.chat_free_cursor then
		local line = vim.api.nvim_buf_line_count(buf)
		gp.helpers.cursor_to_line(line, buf, win)
	end
	vim.cmd("doautocmd User GpDone")
end

local function run_tool_chat(gp, ctx)
	local active_messages = ctx.messages
	local tool_state = ctx.tool_state
	local schemas = gp.tools.openai_schemas(tool_state)
	local max_rounds = tool_state.max_rounds or 10
	local round = 0

	local function finish_with_limit()
		append_text(
			gp,
			ctx.buf,
			table.concat({
				"",
				"📎 tool_result: tool_loop",
				"```text",
				"ERROR: maximum tool rounds reached: " .. tostring(max_rounds),
				"```",
			}, "\n")
		)
		finish_chat(gp, ctx.buf, ctx.win, ctx.headers, ctx.messages, ctx.cmd_pattern)
	end

	local function query_round()
		if round >= max_rounds then
			finish_with_limit()
			return
		end
		round = round + 1
		local payload = gp.dispatcher.prepare_payload(active_messages, ctx.model, ctx.provider, {
			stream = false,
			tools = schemas,
			tool_choice = "auto",
		})
		gp.dispatcher.query(
			ctx.buf,
			ctx.provider,
			payload,
			function() end,
			vim.schedule_wrap(function(qid)
				local qt = gp.tasker.get_query(qid)
				if not qt then
					return
				end
				local tool_calls = qt.tool_calls or {}
				if #tool_calls == 0 then
					if qt.response and qt.response ~= "" then
						local final_handler = gp.dispatcher.create_handler(
							ctx.buf,
							ctx.win,
							gp.helpers.last_content_line(ctx.buf),
							true,
							"",
							not gp.config.chat_free_cursor
						)
						final_handler(qid, ensure_trailing_newline(qt.response))
					end
					finish_chat(gp, ctx.buf, ctx.win, ctx.headers, ctx.messages, ctx.cmd_pattern)
					return
				end

				local assistant_message = {
					role = "assistant",
					content = qt.response_message and qt.response_message.content or "",
					tool_calls = tool_calls,
				}
				table.insert(active_messages, assistant_message)

				for _, call in ipairs(tool_calls) do
					local name = call["function"] and call["function"].name or "unknown"
					append_text(gp, ctx.buf, gp.tools.format_call_block(name, tool_call_args(call)))
				end

				gp.tools.execute_calls(tool_calls, ctx.agent, {
					buf = ctx.buf,
					provider = ctx.provider,
				}, function(results)
					for _, result in ipairs(results) do
						append_text(gp, ctx.buf, gp.tools.format_result_block(result.name, result.content))
						table.insert(active_messages, {
							role = "tool",
							tool_call_id = result.id,
							content = result.content,
						})
					end
					vim.defer_fn(query_round, 10)
				end)
			end),
			nil,
			false,
			gp.config.chat_show_thinking
		)
	end

	query_round()
end

M.setup = function(gp)
	gp.chat_respond = function(params)
		local buf = vim.api.nvim_get_current_buf()
		local win = vim.api.nvim_get_current_win()

		if gp.tasker.is_busy(buf) then
			return
		end

		-- go to normal mode
		vim.cmd("stopinsert")

		-- get all lines
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

		-- check if file looks like a chat file
		local file_name = vim.api.nvim_buf_get_name(buf)
		local reason = gp.not_chat(buf, file_name)
		if reason then
			gp.logger.warning(
				"File " .. vim.inspect(file_name) .. " does not look like a chat file: " .. vim.inspect(reason)
			)
			return
		end

		-- headers are fields before first ---
		local headers = {}
		local header_end = nil
		local line_idx = 0
		---parse headers
		for _, line in ipairs(lines) do
			-- first line starts with ---
			if line:sub(1, 3) == "---" then
				header_end = line_idx
				break
			end
			-- parse header fields
			local key, value = line:match("^[-#] (%w+): (.*)")
			if key ~= nil then
				headers[key] = value
			end

			line_idx = line_idx + 1
		end

		if header_end == nil then
			gp.logger.error("Error while parsing headers: --- not found. Check your chat template.")
			return
		end

		-- message needs role and content
		local messages = {}
		local role = ""
		local content = ""

		-- iterate over lines
		local start_index = header_end + 1
		local end_index = #lines
		if params.range == 2 then
			start_index = math.max(start_index, params.line1)
			end_index = math.min(end_index, params.line2)
		end

		local agent = gp.get_chat_agent()
		local agent_name = agent.name

		-- if model contains { } then it is a json string otherwise it is a model name
		if headers.model and headers.model:match("{.*}") then
			-- unescape underscores before decoding json
			headers.model = headers.model:gsub("\\_", "_")
			headers.model = vim.json.decode(headers.model)
		end

		if headers.model and type(headers.model) == "table" then
			agent_name = headers.model.model
		elseif headers.model and headers.model:match("%S") then
			agent_name = headers.model
		end

		-- try to vim.json.decode role if it is start and end with double quotes
		if headers.role and headers.role:match('^".*"$') then
			local success, decoded_role = pcall(vim.json.decode, headers.role)
			if success then
				headers.role = decoded_role
			end
		end

		if headers.role and headers.role:match("%S") then
			---@diagnostic disable-next-line: cast-local-type
			agent_name = agent_name .. " & custom role"
		end

		if headers.model and not headers.provider then
			headers.provider = "openai"
		end

		local agent_prefix = config.chat_assistant_prefix[1]
		local agent_suffix = config.chat_assistant_prefix[2]
		if type(gp.config.chat_assistant_prefix) == "string" then
			---@diagnostic disable-next-line: cast-local-type
			agent_prefix = gp.config.chat_assistant_prefix
		elseif type(gp.config.chat_assistant_prefix) == "table" then
			agent_prefix = gp.config.chat_assistant_prefix[1]
			agent_suffix = gp.config.chat_assistant_prefix[2] or ""
		end
		---@diagnostic disable-next-line: cast-local-type
		agent_suffix = gp.render.template(agent_suffix, { ["{{agent}}"] = agent_name })

		local old_default_user_prefix = "🗨:"
		for index = start_index, end_index do
			local line = lines[index]
			if line:sub(1, #gp.config.chat_user_prefix) == gp.config.chat_user_prefix then
				table.insert(messages, { role = role, content = content })
				role = "user"
				content = line:sub(#gp.config.chat_user_prefix + 1)
			elseif line:sub(1, #old_default_user_prefix) == old_default_user_prefix then
				table.insert(messages, { role = role, content = content })
				role = "user"
				content = line:sub(#old_default_user_prefix + 1)
			elseif line:sub(1, #agent_prefix) == agent_prefix then
				table.insert(messages, { role = role, content = content })
				role = "assistant"
				content = ""
			elseif role ~= "" then
				content = content .. "\n" .. line
			end
		end
		-- insert last message not handled in loop
		table.insert(messages, { role = role, content = content })

		-- replace first empty message with system prompt
		content = ""
		if headers.role and headers.role:match("%S") then
			content = headers.role
		else
			content = agent.system_prompt
		end
		if content and content:match("%S") then
			-- make it multiline again if it contains escaped newlines
			content = content:gsub("\\n", "\n")
			messages[1] = { role = "system", content = content }
		end

		-- strip whitespace from ends of content
		for _, message in ipairs(messages) do
			message.content = message.content:gsub("^%s*(.-)%s*$", "%1")
		end

		-- write assistant prompt
		local last_content_line = gp.helpers.last_content_line(buf)
		vim.api.nvim_buf_set_lines(
			buf,
			last_content_line,
			last_content_line,
			false,
			{ "", agent_prefix .. agent_suffix, "" }
		)
		-- remove the first	message if the content is empty for the system prompt
		if messages[1].content == "" then
			table.remove(messages, 1)
		end

		-- save the buffer before sending the request
		vim.cmd("silent write")

		-- find all ^@command(cmd_string)$ commands in the buffer and execute them then replace them with the output
		local cmd_pattern = "@command%s*%((.-)%)"
		for _, message in ipairs(messages) do
			if message.role == "user" and message.content:find("@command", 1, true) then
				message.content = message.content:gsub(cmd_pattern, function(cmd_string)
					local output, err = gp.helpers.execute_shell_command(cmd_string)
					if err then
						gp.logger.error(err)
						return nil
					else
						return output
					end
				end)
			end
		end

		local provider = headers.provider or agent.provider
		local model = headers.model or agent.model
		local tool_state, tool_reason
		if gp.tools then
			tool_state, tool_reason = gp.tools.resolve(agent, provider)
		end

		if tool_state then
			run_tool_chat(gp, {
				buf = buf,
				win = win,
				headers = headers,
				messages = messages,
				cmd_pattern = cmd_pattern,
				agent = agent,
				provider = provider,
				model = model,
				tool_state = tool_state,
			})
			return
		elseif agent.tools and tool_reason and tool_reason ~= "tools disabled" then
			gp.logger.warning(tool_reason)
		end

		-- call the model and write response
		local stream = agent.stream ~= nil and agent.stream or gp.config.chat_stream_response
		local handler = gp.dispatcher.create_handler(buf, win, gp.helpers.last_content_line(buf), true, "", not gp.config.chat_free_cursor)
		if not stream then
			local base_handler = handler
			handler = function(qid, chunk)
				base_handler(qid, ensure_trailing_newline(chunk))
			end
		end
		gp.dispatcher.query(
			buf,
			provider,
			gp.dispatcher.prepare_payload(messages, model, provider),
			handler,
			vim.schedule_wrap(function(qid)
				local qt = gp.tasker.get_query(qid)
				if not qt then
					return
				end
				finish_chat(gp, buf, win, headers, messages, cmd_pattern)
			end),
			nil,
			stream,
			gp.config.chat_show_thinking
		)
	end

	gp.cmd.ChatRespond = function(params)
		if params.args == "" and vim.v.count == 0 then
			gp.chat_respond(params)
			return
		elseif params.args == "" and vim.v.count ~= 0 then
			params.args = tostring(vim.v.count)
		end

		-- ensure args is a single positive number
		local n_requests = tonumber(params.args)
		if n_requests == nil or math.floor(n_requests) ~= n_requests or n_requests <= 0 then
			gp.logger.warning("args for ChatRespond should be a single positive number, not: " .. params.args)
			return
		end

		local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
		local cur_index = #lines
		while cur_index > 0 and n_requests > 0 do
			if lines[cur_index]:sub(1, #gp.config.chat_user_prefix) == gp.config.chat_user_prefix then
				n_requests = n_requests - 1
			end
			cur_index = cur_index - 1
		end

		params.range = 2
		params.line1 = cur_index + 1
		params.line2 = #lines
		gp.chat_respond(params)
	end
end

return M
