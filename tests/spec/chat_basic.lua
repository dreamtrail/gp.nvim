test("ChatRespond preserves non-tool path without live provider", function()
	gp.refresh_state({ chat_agent = "ChatGPT4o" })
	local original_query = gp.dispatcher.query
	local original_create_handler = gp.dispatcher.create_handler
	local captured = nil
	gp.dispatcher.create_handler = function(_, _, _, _, _, _)
		return function() end
	end
	gp.dispatcher.query = function(buf, provider, payload, handler, on_exit, callback, stream, show_thinking)
		captured = { buf = buf, provider = provider, payload = payload, handler = handler, on_exit = on_exit, callback = callback, stream = stream, show_thinking = show_thinking }
	end

	local chat_file = vim.fn.tempname() .. ".md"
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_name(buf, chat_file)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"# topic: Test",
		"- file: sample.lua",
		"- provider: openai",
		"- model: gpt-custom",
		"- role: Custom system",
		"---",
		"",
		gp.config.chat_user_prefix .. "hello",
		"more",
	})
	vim.api.nvim_set_option_value("modified", false, { buf = buf })

	local ok, err = pcall(function()
		gp.cmd.ChatRespond({ args = "", range = 0, line1 = 1, line2 = 1 })
	end)
	gp.dispatcher.query = original_query
	gp.dispatcher.create_handler = original_create_handler
	assert_true(ok, "ChatRespond did not error: " .. tostring(err))
	assert_true(captured ~= nil, "ChatRespond dispatched provider request")
	assert_eq(captured.provider, "openai", "ChatRespond uses provider header")
	assert_eq(captured.payload.model, "gpt-custom", "ChatRespond uses model header")
	assert_eq(captured.payload.messages[1].role, "system", "ChatRespond custom role message role")
	assert_eq(captured.payload.messages[1].content, "Custom system", "ChatRespond custom role content")
	assert_eq(captured.payload.messages[2].role, "user", "ChatRespond user message role")
	assert_eq(captured.payload.messages[2].content, "hello\nmore", "ChatRespond captures multiline user message")
	assert_eq(captured.stream, gp.config.chat_stream_response, "ChatRespond preserves chat stream setting")
	assert_eq(captured.show_thinking, gp.config.chat_show_thinking, "ChatRespond preserves thinking setting")
	assert_eq(captured.payload.tools, nil, "tool-disabled chat payload has no native tool schemas")

	local found_prompt = false
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line == "🤖:[gpt-custom & custom role]" then
			found_prompt = true
		end
	end
	assert_true(found_prompt, "ChatRespond writes assistant prompt with model/custom role label")

	vim.api.nvim_buf_delete(buf, { force = true })
	vim.fn.delete(chat_file)
end)

test("ChatRespond non-tool final response without trailing newline separates next prompt", function()
	gp.refresh_state({ chat_agent = "ChatGPT4o" })
	local calls = 0
	local query_stub = function(buf, provider, payload, handler, on_exit, _, stream)
		calls = calls + 1
		assert_eq(stream, false, "non-tool newline test uses non-streaming chat")
		local qid = "non-tool-newline-qid"
		gp.tasker.set_query(qid, {
			timestamp = os.time(),
			buf = buf,
			provider = provider,
			payload = payload,
			response = "final answer",
			stream = stream,
			first_line = -1,
			last_line = -1,
		})
		handler(qid, "final answer")
		on_exit(qid)
	end

	local chat_file = vim.fn.tempname() .. ".md"
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_name(buf, chat_file)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"# topic: Non Tool Newline Test",
		"- file: sample.lua",
		"- provider: openai",
		"- model: gpt-custom",
		"---",
		"",
		gp.config.chat_user_prefix .. "answer without newline",
	})
	vim.api.nvim_set_option_value("modified", false, { buf = buf })

	with_stub(gp.dispatcher, "query", query_stub, function()
		local ok, err = pcall(function()
			gp.cmd.ChatRespond({ args = "", range = 0, line1 = 1, line2 = 1 })
		end)
		assert_true(ok, "non-tool newline ChatRespond did not error: " .. tostring(err))
	end)
	vim.wait(1000, function()
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		return calls == 1 and text:match("final answer") and text:match(gp.config.chat_user_prefix)
	end)
	assert_eq(calls, 1, "non-tool final response performs one provider request")
	assert_single_blank_before_prompt(buf, "final answer", gp.config.chat_user_prefix, "non-tool response without trailing newline")
	vim.api.nvim_buf_delete(buf, { force = true })
	vim.fn.delete(chat_file)
end)

test("ChatRespond non-tool final response with trailing newline is not doubled", function()
	gp.refresh_state({ chat_agent = "ChatGPT4o" })
	local calls = 0
	local query_stub = function(buf, provider, payload, handler, on_exit, _, stream)
		calls = calls + 1
		assert_eq(stream, false, "non-tool trailing newline test uses non-streaming chat")
		local qid = "non-tool-trailing-newline-qid"
		gp.tasker.set_query(qid, {
			timestamp = os.time(),
			buf = buf,
			provider = provider,
			payload = payload,
			response = "final answer\n",
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
		"# topic: Non Tool Existing Newline Test",
		"- file: sample.lua",
		"- provider: openai",
		"- model: gpt-custom",
		"---",
		"",
		gp.config.chat_user_prefix .. "answer with newline",
	})
	vim.api.nvim_set_option_value("modified", false, { buf = buf })

	with_stub(gp.dispatcher, "query", query_stub, function()
		local ok, err = pcall(function()
			gp.cmd.ChatRespond({ args = "", range = 0, line1 = 1, line2 = 1 })
		end)
		assert_true(ok, "non-tool trailing newline ChatRespond did not error: " .. tostring(err))
	end)
	vim.wait(1000, function()
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		return calls == 1 and text:match("final answer") and text:match(gp.config.chat_user_prefix)
	end)
	assert_eq(calls, 1, "non-tool trailing newline response performs one provider request")
	assert_single_blank_before_prompt(buf, "final answer", gp.config.chat_user_prefix, "non-tool response with trailing newline")
	vim.api.nvim_buf_delete(buf, { force = true })
	vim.fn.delete(chat_file)
end)

