test("ChatRespond tool loop stops at configured max rounds", function()
	gp.refresh_state({ chat_agent = "ToolAgent" })
	vim.fn.writefile({ "loop content" }, workspace .. "/loop.txt")
	local old_tools = gp.agents.ToolAgent.tools
	local limited_tools = vim.deepcopy(old_tools)
	limited_tools.max_rounds = 2
	gp.agents.ToolAgent.tools = limited_tools
	local calls = 0
	local chat_file = vim.fn.tempname() .. ".md"
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_name(buf, chat_file)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"# topic: Tool Limit Test",
		"- file: sample.lua",
		"- provider: openai",
		"- model: gpt-tools",
		"---",
		"",
		gp.config.chat_user_prefix .. "loop forever",
	})
	vim.api.nvim_set_option_value("modified", false, { buf = buf })

	local ok_run, err_run = xpcall(function()
		with_stubs({
			{ gp.dispatcher, "create_handler", function()
				return function() end
			end },
			{ gp.dispatcher, "query", function(qbuf, provider, payload, _, on_exit, _, stream)
				calls = calls + 1
				assert_eq(payload.stream, true, "max-round tool loop defaults payload stream true")
				assert_eq(stream, true, "max-round tool loop defaults UI streaming true")
				local qid = "max-round-qid-" .. calls
				gp.tasker.set_query(qid, {
					timestamp = os.time(),
					buf = qbuf,
					provider = provider,
					payload = payload,
					response = "",
					tool_calls = { tool_call("loop" .. calls, "read", [[{"path":"loop.txt"}]]) },
					response_message = { role = "assistant", content = nil },
				})
				on_exit(qid)
			end },
		}, function()
			local ok, err = pcall(function()
				gp.cmd.ChatRespond({ args = "", range = 0, line1 = 1, line2 = 1 })
			end)
			assert_true(ok, "max-round ChatRespond did not error: " .. tostring(err))
			vim.wait(1000, function()
				local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
				return text:match("maximum tool rounds reached") ~= nil
			end)
		end)
	end, debug.traceback)
	gp.agents.ToolAgent.tools = old_tools
	if not ok_run then
		error(err_run, 0)
	end
	assert_eq(calls, 2, "tool loop stops provider calls at max_rounds")
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	assert_true(text:match("📎 tool_result: tool_loop"), "max-round visible tool_loop result block written")
	assert_true(text:match("maximum tool rounds reached: 2"), "max-round error explains limit")
	vim.api.nvim_buf_delete(buf, { force = true })
	vim.fn.delete(chat_file)
end)

test("ChatRespond tool loop honors stream=false opt-out", function()
	gp.refresh_state({ chat_agent = "ToolAgent" })
	vim.fn.writefile({ "opt-out tool content" }, workspace .. "/optout.txt")
	local old_tools = gp.agents.ToolAgent.tools
	local optout_tools = vim.deepcopy(old_tools)
	optout_tools.stream = false
	gp.agents.ToolAgent.tools = optout_tools
	local calls = 0
	local query_stub = function(buf, provider, payload, _, on_exit, _, stream)
		calls = calls + 1
		assert_eq(payload.stream, false, "tool stream=false sends non-streaming payload")
		assert_eq(stream, false, "tool stream=false disables UI streaming")
		local qid = "tool-optout-qid-" .. calls
		if calls == 1 then
			gp.tasker.set_query(qid, {
				timestamp = os.time(),
				buf = buf,
				provider = provider,
				payload = payload,
				response = "",
				tool_calls = { tool_call("tc_optout", "read", [[{"path":"optout.txt"}]]) },
				response_message = { role = "assistant", content = nil },
				stream = stream,
				first_line = -1,
				last_line = -1,
			})
		else
			local saw_tool_result = false
			for _, message in ipairs(payload.messages) do
				if message.role == "tool" and message.tool_call_id == "tc_optout" then
					saw_tool_result = message.content:match("opt%-out tool content") ~= nil
				end
			end
			assert_true(saw_tool_result, "tool stream=false sends structured tool result to follow-up round")
			gp.tasker.set_query(qid, {
				timestamp = os.time(),
				buf = buf,
				provider = provider,
				payload = payload,
				response = "opt-out final",
				tool_calls = {},
				response_message = { role = "assistant", content = "opt-out final" },
				stream = stream,
				first_line = -1,
				last_line = -1,
			})
		end
		on_exit(qid)
	end

	local chat_file = vim.fn.tempname() .. ".md"
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_name(buf, chat_file)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"# topic: Tool Opt Out Test",
		"- file: sample.lua",
		"- provider: openai",
		"- model: gpt-tools",
		"---",
		"",
		gp.config.chat_user_prefix .. "read optout.txt without streaming",
	})
	vim.api.nvim_set_option_value("modified", false, { buf = buf })

	local ok_run, err_run = xpcall(function()
		with_stub(gp.dispatcher, "query", query_stub, function()
			local ok, err = pcall(function()
				gp.cmd.ChatRespond({ args = "", range = 0, line1 = 1, line2 = 1 })
			end)
			assert_true(ok, "tool opt-out ChatRespond did not error: " .. tostring(err))
			vim.wait(1000, function()
				return calls == 2
			end)
		end)
	end, debug.traceback)
	gp.agents.ToolAgent.tools = old_tools
	if not ok_run then
		error(err_run, 0)
	end
	vim.wait(1000, function()
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		return calls == 2 and text:match("opt%-out final") and text:match(gp.config.chat_user_prefix)
	end)
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	assert_eq(calls, 2, "tool stream=false performs tool and final provider requests")
	assert_true(text:match("🔧 tool_call: read"), "tool stream=false writes visible tool call block")
	assert_true(text:match("📎 tool_result: read"), "tool stream=false writes visible tool result block")
	assert_true(text:match("opt%-out tool content"), "tool stream=false records tool result content")
	assert_single_blank_before_prompt(buf, "opt-out final", gp.config.chat_user_prefix, "tool stream=false response")
	vim.api.nvim_buf_delete(buf, { force = true })
	vim.fn.delete(chat_file)
end)

test("ChatRespond tool loop honors explicit stream=true", function()
	gp.refresh_state({ chat_agent = "ToolAgent" })
	local old_tools = gp.agents.ToolAgent.tools
	local stream_tools = vim.deepcopy(old_tools)
	stream_tools.stream = true
	gp.agents.ToolAgent.tools = stream_tools
	local captured = nil
	local query_stub = function(buf, provider, payload, handler, on_exit, _, stream)
		captured = { provider = provider, payload = payload, stream = stream }
		local qid = "tool-explicit-stream-qid"
		gp.tasker.set_query(qid, {
			timestamp = os.time(),
			buf = buf,
			provider = provider,
			payload = payload,
			response = "explicit stream final",
			tool_calls = {},
			response_message = { role = "assistant", content = "explicit stream final" },
			stream = stream,
			first_line = -1,
			last_line = -1,
		})
		handler(qid, "explicit stream final")
		on_exit(qid)
	end

	local chat_file = vim.fn.tempname() .. ".md"
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_name(buf, chat_file)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"# topic: Explicit Tool Stream Test",
		"- file: sample.lua",
		"- provider: openai",
		"- model: gpt-tools",
		"---",
		"",
		gp.config.chat_user_prefix .. "answer with explicit tool streaming",
	})
	vim.api.nvim_set_option_value("modified", false, { buf = buf })

	local ok_run, err_run = xpcall(function()
		with_stub(gp.dispatcher, "query", query_stub, function()
			local ok, err = pcall(function()
				gp.cmd.ChatRespond({ args = "", range = 0, line1 = 1, line2 = 1 })
			end)
			assert_true(ok, "explicit stream=true ChatRespond did not error: " .. tostring(err))
		end)
	end, debug.traceback)
	gp.agents.ToolAgent.tools = old_tools
	if not ok_run then
		error(err_run, 0)
	end
	assert_true(captured ~= nil, "explicit stream=true dispatched request")
	assert_eq(captured.provider, "openai", "explicit stream=true keeps provider")
	assert_eq(captured.payload.stream, true, "explicit stream=true sends streaming payload")
	assert_eq(captured.stream, true, "explicit stream=true sends streaming query")
	vim.wait(1000, function()
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		return text:match("explicit stream final") and text:match(gp.config.chat_user_prefix)
	end)
	vim.api.nvim_buf_delete(buf, { force = true })
	vim.fn.delete(chat_file)
end)

test("ChatRespond tool stream unsupported provider falls back to non-streaming", function()
	gp.refresh_state({ chat_agent = "ToolAgent" })
	local old_provider = gp.agents.ToolAgent.provider
	local old_model = gp.agents.ToolAgent.model
	gp.agents.ToolAgent.provider = "anthropic"
	gp.agents.ToolAgent.model = { model = "claude-test", max_tokens = 100, stream = true }
	local captured = nil
	local warnings = 0
	local function make_chat()
		local chat_file = vim.fn.tempname() .. ".md"
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_buf_set_name(buf, chat_file)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"# topic: Unsupported Tool Stream Test",
			"- file: sample.lua",
			"---",
			"",
			gp.config.chat_user_prefix .. "hello",
		})
		vim.api.nvim_set_option_value("modified", false, { buf = buf })
		return buf, chat_file
	end

	local ok_run, err_run = xpcall(function()
		with_stubs({
			{ gp.dispatcher, "create_handler", function()
				return function() end
			end },
			{ gp.dispatcher, "query", function(buf, provider, payload, handler, on_exit, callback, stream, show_thinking)
				captured = { buf = buf, provider = provider, payload = payload, handler = handler, on_exit = on_exit, callback = callback, stream = stream, show_thinking = show_thinking }
			end },
			{ gp.logger, "warning", function(msg)
				if tostring(msg):match("falling back to non%-streaming") then
					warnings = warnings + 1
				end
			end },
		}, function()
			for i = 1, 2 do
				local buf, chat_file = make_chat()
				local ok, err = pcall(function()
					gp.cmd.ChatRespond({ args = "", range = 0, line1 = 1, line2 = 1 })
				end)
				assert_true(ok, "unsupported tool stream ChatRespond did not error: " .. tostring(err))
				vim.api.nvim_buf_delete(buf, { force = true })
				vim.fn.delete(chat_file)
			end
		end)
	end, debug.traceback)
	gp.agents.ToolAgent.provider = old_provider
	gp.agents.ToolAgent.model = old_model
	if not ok_run then
		error(err_run, 0)
	end
	assert_true(captured ~= nil, "unsupported provider fallback dispatched normal request")
	assert_eq(captured.provider, "anthropic", "unsupported provider fallback keeps provider")
	assert_eq(captured.payload.stream, false, "unsupported provider fallback sends non-streaming table-model payload")
	assert_eq(captured.stream, false, "unsupported provider fallback sends non-streaming query")
	assert_eq(warnings, 1, "unsupported provider stream fallback warns once")
end)

