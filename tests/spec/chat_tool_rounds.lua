test("ChatRespond tool loop records tool blocks and finalizes", function()
	gp.refresh_state({ chat_agent = "ToolAgent" })
	vim.fn.writefile({ "tool content" }, workspace .. "/tool.txt")
	vim.fn.writefile({ "second content" }, workspace .. "/tool2.txt")
	local calls = 0
	local handler_stub = function(buf)
		return function(qid, content)
			local qt = gp.tasker.get_query(qid)
			local line = gp.helpers.last_content_line(buf)
			local lines = vim.split(content, "\n", { plain = true })
			vim.api.nvim_buf_set_lines(buf, line, line, false, lines)
			if qt then
				qt.first_line = line
				qt.last_line = line + #lines - 1
			end
		end
	end
	local query_stub = function(buf, provider, payload, handler, on_exit, _, stream)
		calls = calls + 1
		assert_eq(provider, "openai", "tool loop provider")
		assert_eq(payload.stream, true, "tool loop defaults payload stream true")
		assert_true(payload.tools ~= nil, "tool loop sends schemas")
		assert_eq(stream, true, "tool loop defaults UI streaming true")
		local qid = "tool-qid-" .. calls
		if calls == 1 then
			gp.tasker.set_query(qid, {
				timestamp = os.time(),
				buf = buf,
				provider = provider,
				payload = payload,
				response = "transient tool preface",
				tool_calls = {
					tool_call("tc1", "read", [[{"path":"tool.txt"}]]),
					tool_call("tc2", "read", [[{"path":"tool2.txt"}]]),
					tool_call("tc_bad", "read", "{"),
				},
				response_message = { role = "assistant", content = "transient tool preface" },
				stream = stream,
				first_line = -1,
				last_line = -1,
			})
			handler(qid, "transient tool preface")
		else
			local seen_results = {}
			for _, message in ipairs(payload.messages) do
				if message.role == "tool" then
					seen_results[message.tool_call_id] = true
					assert_eq(message.name, nil, "structured OpenAI tool result omits non-spec name field")
				end
			end
			assert_true(seen_results.tc1 and seen_results.tc2 and seen_results.tc_bad, "multiple tool results and argument errors sent in follow-up payload")
			gp.tasker.set_query(qid, {
				timestamp = os.time(),
				buf = buf,
				provider = provider,
				payload = payload,
				response = "final answer",
				tool_calls = {},
				response_message = { role = "assistant", content = "final answer" },
				stream = stream,
				first_line = -1,
				last_line = -1,
			})
			handler(qid, "final answer")
		end
		on_exit(qid)
	end

	local chat_file = vim.fn.tempname() .. ".md"
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_name(buf, chat_file)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"# topic: Tool Test",
		"- file: sample.lua",
		"- provider: openai",
		"- model: gpt-tools",
		"---",
		"",
		gp.config.chat_user_prefix .. "read tool.txt",
	})
	vim.api.nvim_set_option_value("modified", false, { buf = buf })

	with_stubs({
		{ gp.dispatcher, "create_handler", handler_stub },
		{ gp.dispatcher, "query", query_stub },
	}, function()
		local ok, err = pcall(function()
			gp.cmd.ChatRespond({ args = "", range = 0, line1 = 1, line2 = 1 })
		end)
		assert_true(ok, "tool ChatRespond did not error: " .. tostring(err))
		vim.wait(1000, function()
			return calls == 2
		end)
	end)
	assert_eq(calls, 2, "tool loop performs tool round and final round")
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	assert_true(text:match("🔧 tool_call: read"), "visible tool call block written")
	assert_true(text:match("📎 tool_result: read"), "visible tool result block written")
	assert_true(text:match("tool content"), "first tool result content written")
	assert_true(text:match("second content"), "second tool result content written")
	assert_true(text:match("invalid JSON arguments"), "invalid JSON tool args are recorded visibly")
	assert_true(not text:match("transient tool preface"), "streamed assistant text from tool-call round is suppressed")
	assert_true(text:match("final answer"), "final response written")
	assert_eq(count_occurrences(text, "final answer"), 1, "final response written exactly once")
	assert_true(text:match(gp.config.chat_user_prefix), "chat finalized with user prompt")
	assert_single_blank_before_prompt(buf, "final answer", gp.config.chat_user_prefix, "tool response without trailing newline")
	vim.api.nvim_buf_delete(buf, { force = true })
	vim.fn.delete(chat_file)
end)

test("ChatRespond streamed invalid tool arguments stop without execution", function()
	gp.refresh_state({ chat_agent = "ToolAgent" })
	local calls = 0
	local executed = false
	local handler_stub = function(buf)
		return function(qid, content)
			local qt = gp.tasker.get_query(qid)
			local line = gp.helpers.last_content_line(buf)
			local lines = vim.split(content, "\n", { plain = true })
			vim.api.nvim_buf_set_lines(buf, line, line, false, lines)
			qt.first_line = line
			qt.last_line = line + #lines - 1
		end
	end
	local query_stub = function(buf, provider, payload, handler, on_exit, _, stream)
		calls = calls + 1
		assert_eq(payload.stream, true, "invalid streamed tool call uses streaming payload")
		assert_eq(stream, true, "invalid streamed tool call uses streaming query")
		local qid = "tool-invalid-stream-qid"
		gp.tasker.set_query(qid, {
			timestamp = os.time(),
			buf = buf,
			provider = provider,
			payload = payload,
			response = "transient tool preface",
			tool_calls = { tool_call("tc_bad_stream", "read", [[{"path":]]) },
			response_message = { role = "assistant", content = "transient tool preface" },
			tool_call_parse_error = "streamed tool call 1 has invalid JSON arguments",
			stream = stream,
			first_line = -1,
			last_line = -1,
		})
		handler(qid, "transient tool preface")
		on_exit(qid)
	end

	local chat_file = vim.fn.tempname() .. ".md"
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_name(buf, chat_file)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"# topic: Tool Invalid Stream Test",
		"- file: sample.lua",
		"- provider: openai",
		"- model: gpt-tools",
		"---",
		"",
		gp.config.chat_user_prefix .. "read with bad streamed args",
	})
	vim.api.nvim_set_option_value("modified", false, { buf = buf })

	with_stubs({
		{ gp.dispatcher, "create_handler", handler_stub },
		{ gp.dispatcher, "query", query_stub },
		{ gp.tools, "execute_calls", function()
			executed = true
		end },
	}, function()
		local ok, err = pcall(function()
			gp.cmd.ChatRespond({ args = "", range = 0, line1 = 1, line2 = 1 })
		end)
		assert_true(ok, "invalid streamed tool ChatRespond did not error: " .. tostring(err))
	end)
	vim.wait(1000, function()
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		return calls == 1 and text:match("streamed tool call parse failed") and text:match(gp.config.chat_user_prefix)
	end)
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	assert_eq(calls, 1, "invalid streamed tool call performs one provider request")
	assert_true(not executed, "invalid streamed tool call does not execute tools")
	assert_true(not text:match("transient tool preface"), "streamed tool-call preface is suppressed")
	assert_true(text:match("📎 tool_result: tool_loop"), "invalid streamed tool call writes visible error block")
	vim.api.nvim_buf_delete(buf, { force = true })
	vim.fn.delete(chat_file)
end)

test("ChatRespond tool final response with trailing newline is not doubled", function()
	gp.refresh_state({ chat_agent = "ToolAgent" })
	local calls = 0
	local handler_stub = function(buf)
		return function(_, content)
			local line = gp.helpers.last_content_line(buf)
			vim.api.nvim_buf_set_lines(buf, line, line, false, vim.split(content, "\n", { plain = true }))
		end
	end
	local query_stub = function(buf, provider, payload, handler, on_exit, _, stream)
		calls = calls + 1
		assert_eq(payload.stream, true, "tool final response defaults payload stream true")
		assert_eq(stream, true, "tool final response defaults UI streaming true")
		local qid = "tool-newline-qid"
		gp.tasker.set_query(qid, {
			timestamp = os.time(),
			buf = buf,
			provider = provider,
			payload = payload,
			response = "final answer\n",
			tool_calls = {},
			response_message = { role = "assistant", content = "final answer\n" },
			stream = stream,
			first_line = -1,
			last_line = -1,
		})
		handler(qid, "final answer\n")
		on_exit(qid)
	end

	local chat_file = vim.fn.tempname() .. ".md"
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_name(buf, chat_file)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"# topic: Tool Newline Test",
		"- file: sample.lua",
		"- provider: openai",
		"- model: gpt-tools",
		"---",
		"",
		gp.config.chat_user_prefix .. "answer with newline",
	})
	vim.api.nvim_set_option_value("modified", false, { buf = buf })

	with_stubs({
		{ gp.dispatcher, "create_handler", handler_stub },
		{ gp.dispatcher, "query", query_stub },
	}, function()
		local ok, err = pcall(function()
			gp.cmd.ChatRespond({ args = "", range = 0, line1 = 1, line2 = 1 })
		end)
		assert_true(ok, "tool newline ChatRespond did not error: " .. tostring(err))
	end)
	vim.wait(1000, function()
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		return calls == 1 and text:match("final answer\n\n" .. vim.pesc(gp.config.chat_user_prefix)) ~= nil
	end)
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	assert_eq(calls, 1, "tool final response without tool calls performs one provider request")
	assert_eq(count_occurrences(text, "final answer"), 1, "tool final response text appears exactly once")
	assert_single_blank_before_prompt(buf, "final answer", gp.config.chat_user_prefix, "tool response with trailing newline")
	vim.api.nvim_buf_delete(buf, { force = true })
	vim.fn.delete(chat_file)
end)

