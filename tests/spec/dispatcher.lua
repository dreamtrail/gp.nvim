test("tool payloads and response parser support OpenAI-compatible tool calls only", function()
	local schemas = gp.tools.openai_schemas(assert(gp.tools.resolve(gp.get_chat_agent("ToolAgent"), "openai")))
	local openai_payload = dispatcher.prepare_payload(
		{ { role = "user", content = "use tools" } },
		{ model = "gpt-test", temperature = 0 },
		"openai",
		{ stream = false, tools = schemas, tool_choice = "auto" }
	)
	assert_eq(openai_payload.stream, false, "tool payload can opt out of streaming")
	assert_eq(openai_payload.tool_choice, "auto", "tool choice auto")
	assert_eq(openai_payload.tools[1]["function"].name, "read", "read schema injected")

	local anthropic_payload = dispatcher.prepare_payload(
		{ { role = "user", content = "hello" } },
		{ model = "claude-test" },
		"anthropic",
		{ stream = false, tools = schemas, tool_choice = "auto" }
	)
	assert_eq(anthropic_payload.tools, nil, "anthropic does not receive OpenAI tools")
	assert_eq(anthropic_payload.stream, false, "anthropic tool fallback payload can force non-streaming")
	local google_payload = dispatcher.prepare_payload(
		{ { role = "user", content = "hello" } },
		{ model = "gemini-test" },
		"google",
		{ stream = false, tools = schemas, tool_choice = "auto" }
	)
	assert_eq(google_payload.tools, nil, "google does not receive OpenAI tools")

	local final_message = dispatcher._parse_openai_response([[{"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}]])
	assert_eq(final_message.content, "done", "content-only response parsed")
	local one_message, one_calls = dispatcher._parse_openai_response([[{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"read","arguments":"{\"path\":\"a.txt\"}"}}]},"finish_reason":"tool_calls"}]}]])
	assert_eq(one_message.content, vim.NIL, "tool-call response may have null content")
	assert_eq(#one_calls, 1, "one tool call parsed")
	local _, many_calls = dispatcher._parse_openai_response([[{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"c1","type":"function","function":{"name":"read","arguments":"{}"}},{"id":"c2","type":"function","function":{"name":"run","arguments":"{}"}}]}}]}]])
	assert_eq(#many_calls, 2, "multiple tool calls parsed")
end)

test("OpenAI streamed tool call deltas merge fragmented arguments", function()
	local calls = {}
	dispatcher._merge_openai_tool_call_delta(calls, {
		index = 0,
		id = "call_1",
		type = "function",
		["function"] = { name = "read", arguments = [[{"path":]] },
	})
	dispatcher._merge_openai_tool_call_delta(calls, {
		index = 0,
		["function"] = { arguments = [["a.txt"}]] },
	})
	dispatcher._merge_openai_tool_call_delta(calls, {
		index = 1,
		id = "call_2",
		type = "function",
		["function"] = { name = "run", arguments = [[{}]] },
	})
	assert_eq(#calls, 2, "streamed deltas produce two calls")
	assert_eq(calls[1].id, "call_1", "streamed call id preserved")
	assert_eq(calls[1]["function"].name, "read", "streamed function name preserved")
	assert_eq(calls[1]["function"].arguments, [[{"path":"a.txt"}]], "streamed arguments concatenated")
	assert_eq(dispatcher._validate_openai_stream_tool_calls(calls), nil, "merged calls validate")
	calls[1]["function"].arguments = [[{"path":]]
	assert_true(dispatcher._validate_openai_stream_tool_calls(calls):match("invalid JSON arguments"), "invalid streamed arguments are reported")
end)

test("OpenAI streamed tool call validation reports incomplete calls", function()
	local valid = { tool_call("call_valid", "read", [[{"path":"a.txt"}]]) }
	assert_eq(dispatcher._validate_openai_stream_tool_calls(valid), nil, "complete streamed call validates")

	local missing_id = { { type = "function", ["function"] = { name = "read", arguments = [[{}]] } } }
	assert_true(dispatcher._validate_openai_stream_tool_calls(missing_id):match("missing id"), "missing id is rejected")

	local missing_type = { { id = "call_missing_type", ["function"] = { name = "read", arguments = [[{}]] } } }
	assert_true(dispatcher._validate_openai_stream_tool_calls(missing_type):match("missing type"), "missing type is rejected")

	local missing_name = { { id = "call_missing_name", type = "function", ["function"] = { arguments = [[{}]] } } }
	assert_true(dispatcher._validate_openai_stream_tool_calls(missing_name):match("missing function name"), "missing function name is rejected")

	local missing_args = { { id = "call_missing_args", type = "function", ["function"] = { name = "read" } } }
	assert_true(dispatcher._validate_openai_stream_tool_calls(missing_args):match("missing function arguments"), "missing arguments are rejected")
end)

test("OpenAI dispatcher streaming assembles valid fragmented tool calls", function()
	local tasker = require("gp.tasker")
	local captured_qid = nil
	local handler_chunks = {}
	local old_run = tasker.run
	tasker.run = function(_, _, _, _, stdout)
		local event1 = {
			choices = {
				{
					delta = {
						tool_calls = {
							{
								index = 0,
								id = "call_stream_ok",
								type = "function",
								["function"] = { name = "read", arguments = [[{"path":]] },
							},
						},
					},
				},
			},
		}
		local event2 = {
			choices = {
				{
					delta = {
						tool_calls = {
							{ index = 0, ["function"] = { arguments = [["streamed.txt"}]] } },
						},
					},
				},
			},
		}
		local done = { choices = { { delta = {}, finish_reason = "tool_calls" } } }
		stdout(nil, "data: " .. vim.json.encode(event1) .. "\n")
		stdout(nil, "data: " .. vim.json.encode(event2) .. "\n")
		stdout(nil, "data: " .. vim.json.encode(done) .. "\n")
		stdout(nil, "data: [DONE]\n")
		stdout(nil, nil)
	end
	local ok, err = xpcall(function()
		dispatcher.query(
			nil,
			"openai",
			{ model = "gpt-test", stream = true, messages = { { role = "user", content = "hello" } } },
			function(_, chunk)
				table.insert(handler_chunks, chunk)
			end,
			function(qid)
				captured_qid = qid
			end,
			nil,
			true,
			false
		)
	end, debug.traceback)
	tasker.run = old_run
	if not ok then
		error(err, 0)
	end
	assert_true(captured_qid ~= nil, "streaming query exit callback captured qid")
	local qt = tasker.get_query(captured_qid)
	assert_true(qt ~= nil, "streaming query state remains inspectable")
	assert_eq(#qt.tool_calls, 1, "streaming query collected one tool call")
	assert_eq(qt.tool_calls[1].id, "call_stream_ok", "streaming query preserved tool call id")
	assert_eq(qt.tool_calls[1].type, "function", "streaming query preserved tool call type")
	assert_eq(qt.tool_calls[1]["function"].name, "read", "streaming query preserved function name")
	assert_eq(qt.tool_calls[1]["function"].arguments, [[{"path":"streamed.txt"}]], "streaming query concatenated fragmented arguments")
	assert_eq(qt.response_message.tool_calls, qt.tool_calls, "streaming query exposes tool calls on response message")
	assert_eq(qt.finish_reason, "tool_calls", "streaming query tracks finish reason")
	assert_eq(qt.tool_call_parse_error, nil, "valid streamed tool call has no parse error")
	assert_eq(#handler_chunks, 0, "tool-only valid stream did not emit assistant content")
end)

test("OpenAI dispatcher streaming validates tool-only invalid arguments at EOF", function()
	local tasker = require("gp.tasker")
	local captured_qid = nil
	local handler_chunks = {}
	local old_run = tasker.run
	tasker.run = function(_, _, _, _, stdout)
		local event = {
			choices = {
				{
					delta = {
						tool_calls = {
							{
								index = 0,
								id = "call_bad",
								type = "function",
								["function"] = { name = "read", arguments = "{" },
							},
						},
					},
					finish_reason = "tool_calls",
				},
			},
		}
		stdout(nil, "data: " .. vim.json.encode(event) .. "\n")
		stdout(nil, "data: [DONE]\n")
		stdout(nil, nil)
	end
	local ok, err = xpcall(function()
		dispatcher.query(
			nil,
			"openai",
			{ model = "gpt-test", stream = true, messages = { { role = "user", content = "hello" } } },
			function(_, chunk)
				table.insert(handler_chunks, chunk)
			end,
			function(qid)
				captured_qid = qid
			end,
			nil,
			true,
			false
		)
	end, debug.traceback)
	tasker.run = old_run
	if not ok then
		error(err, 0)
	end
	assert_true(captured_qid ~= nil, "streaming query exit callback captured qid")
	local qt = tasker.get_query(captured_qid)
	assert_true(qt ~= nil, "streaming query state remains inspectable")
	assert_eq(#qt.tool_calls, 1, "streaming query collected tool call")
	assert_true(qt.tool_call_parse_error:match("invalid JSON arguments"), "streaming query validates invalid tool arguments at EOF")
	assert_eq(#handler_chunks, 0, "tool-only stream did not emit assistant content")
end)

test("OpenAI response parser reports malformed and mixed tool responses", function()
	local message, calls, finish_reason, err = dispatcher._parse_openai_response("{")
	assert_eq(message, nil, "malformed response has no message")
	assert_eq(calls, nil, "malformed response has no calls")
	assert_true(err:match("failed to decode response"), "malformed response reports decode error")

	message, calls, finish_reason, err = dispatcher._parse_openai_response([[{"choices":[]}]])
	assert_eq(message, nil, "missing choice has no message")
	assert_eq(calls, nil, "missing choice has no calls")
	assert_true(err:match("response missing choices%[1%]%.message"), "missing message reports parser error")

	message, calls, finish_reason, err = dispatcher._parse_openai_response([[{"choices":[{"message":{"role":"assistant","content":"I need a file","tool_calls":[{"id":"c1","type":"function","function":{"name":"read","arguments":"{\"path\":\"a.txt\"}"}}]},"finish_reason":"tool_calls"}]}]])
	assert_eq(err, nil, "mixed content and tool calls parses without error")
	assert_eq(message.content, "I need a file", "mixed content preserved")
	assert_eq(#calls, 1, "mixed response tool call parsed")
	assert_eq(finish_reason, "tool_calls", "finish reason propagated")
end)

test("attachment payloads preserve OpenAI Anthropic and Google shapes", function()
	local attachment = vim.fn.tempname() .. ".txt"
	vim.fn.writefile({ "fixture attachment" }, attachment)
	local attachment_ref = "@attach(" .. attachment .. ")"

	local openai_messages = { { role = "user", content = "see " .. attachment_ref } }
	local openai_payload = dispatcher.prepare_payload(openai_messages, { model = "gpt-test" }, "openai")
	assert_eq(type(openai_payload.messages[1].content), "table", "openai attachment content table")
	assert_eq(openai_payload.messages[1].content[1].type, "text", "openai keeps text part")
	assert_eq(openai_payload.messages[1].content[2].type, "image_url", "openai attachment url part")
	assert_true(openai_payload.messages[1].content[2].image_url.url:match("^data:text/plain;base64,"), "openai attachment includes text/plain data url")

	local anthropic_messages = { { role = "user", content = "see " .. attachment_ref } }
	local anthropic_payload = dispatcher.prepare_payload(anthropic_messages, { model = "claude-test" }, "anthropic")
	assert_eq(type(anthropic_payload.messages[1].content), "table", "anthropic attachment content table")
	assert_eq(anthropic_payload.messages[1].content[1].type, "text", "anthropic keeps text block")
	assert_eq(anthropic_payload.messages[1].content[2].type, "document", "anthropic text file becomes document")
	assert_eq(anthropic_payload.messages[1].content[2].source.media_type, "text/plain", "anthropic media type")

	local google_messages = { { role = "user", content = "see " .. attachment_ref } }
	local google_payload = dispatcher.prepare_payload(google_messages, { model = "gemini-test" }, "google")
	assert_true(google_payload.contents == google_messages, "google attachment uses mutated messages")
	assert_eq(google_payload.contents[1].parts[1].text, "see " .. attachment_ref, "google keeps text part")
	assert_eq(google_payload.contents[1].parts[2].inline_data.mime_type, "text/plain", "google inline mime type")
	assert_true(#google_payload.contents[1].parts[2].inline_data.data > 0, "google inline data encoded")

	vim.fn.delete(attachment)
end)

