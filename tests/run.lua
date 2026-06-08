local tests = {}

local function test(name, fn)
	table.insert(tests, { name = name, fn = fn })
end

local function assert_eq(actual, expected, label)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function assert_true(value, label)
	if not value then
		error(label .. ": expected truthy, got " .. vim.inspect(value))
	end
end

local function sorted_gp_commands()
	local commands = {}
	for name, _ in pairs(vim.api.nvim_get_commands({})) do
		if name:match("^Gp") then
			table.insert(commands, name)
		end
	end
	table.sort(commands)
	return commands
end

local function tool_call(id, name, args_json)
	return { id = id, type = "function", ["function"] = { name = name, arguments = args_json } }
end

local function exec_tool(gp, call, agent, provider)
	local done = false
	local result
	gp.tools.execute_call(call, agent, { buf = vim.api.nvim_get_current_buf(), provider = provider or agent.provider }, function(res)
		result = res
		done = true
	end)
	vim.wait(1000, function()
		return done
	end)
	assert_true(done, "tool execution completed")
	return result
end

local function with_stub(tbl, key, value, fn)
	local original = tbl[key]
	tbl[key] = value
	local ok, err = xpcall(fn, debug.traceback)
	tbl[key] = original
	if not ok then
		error(err, 0)
	end
end

local function with_stubs(stubs, fn)
	local originals = {}
	for i, stub in ipairs(stubs) do
		originals[i] = stub[1][stub[2]]
		stub[1][stub[2]] = stub[3]
	end
	local ok, err = xpcall(fn, debug.traceback)
	for i = #stubs, 1, -1 do
		stubs[i][1][stubs[i][2]] = originals[i]
	end
	if not ok then
		error(err, 0)
	end
end

local function write_binary(path, content)
	local f = assert(io.open(path, "wb"))
	f:write(content)
	f:close()
end

local function with_cwd(dir, fn)
	local original = vim.fn.getcwd()
	vim.fn.chdir(dir)
	local ok, err = xpcall(fn, debug.traceback)
	vim.fn.chdir(original)
	if not ok then
		error(err, 0)
	end
end

local function assert_single_blank_before_prompt(buf, response_line, user_prefix, label)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for i, line in ipairs(lines) do
		if line == response_line then
			assert_eq(lines[i + 1], "", label .. " has one blank line after response")
			assert_eq(lines[i + 2], user_prefix, label .. " prompt follows exactly one blank line")
			return
		end
	end
	error(label .. ": response line not found: " .. response_line)
end

vim.opt.runtimepath:append(vim.fn.getcwd())

local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, "p")

local gp = require("gp")
local dispatcher = require("gp.dispatcher")
local dispatcher_status = require("gp.dispatcher.status")

local expected_commands = {
	"GpAgent",
	"GpAppend",
	"GpChatDelete",
	"GpChatFinder",
	"GpChatNew",
	"GpChatPaste",
	"GpChatRespond",
	"GpChatToggle",
	"GpContext",
	"GpEnew",
	"GpImplement",
	"GpInspectLog",
	"GpInspectPlugin",
	"GpNew",
	"GpNextAgent",
	"GpPopup",
	"GpPrepend",
	"GpRewrite",
	"GpStop",
	"GpTabnew",
	"GpTools",
	"GpVnew",
}

local tool_agent = {
	name = "ToolAgent",
	provider = "openai",
	chat = true,
	command = false,
	model = { model = "gpt-test", temperature = 0 },
	system_prompt = "Tool test agent.",
	tools = {
		enabled = { "read", "write", "edit", "run" },
		workspace_root = workspace,
		workspace_only = true,
		write = { confirm = false },
		edit = { confirm = false },
		run = { allowed_commands = { "printf" }, timeout_ms = 1000, max_output_bytes = 1024 },
	},
}

local function setup_gp()
	gp.setup({
		openai_api_key = "dummy",
		image = { disable = true },
		whisper = { disable = true },
		state_dir = vim.fn.stdpath("data") .. "/gp-test/persisted",
		chat_dir = vim.fn.stdpath("data") .. "/gp-test/chats",
		log_file = vim.fn.stdpath("state") .. "/gp-test.log",
		agents = { tool_agent },
	})
end

test("dispatcher facade exposes compatibility aliases", function()
	assert_eq(type(gp.setup), "function", "gp.setup exists")
	for _, alias in ipairs({
		"prepare_payload",
		"create_handler",
		"is_openai_reason_model",
		"is_google_provider",
		"is_other_reason_model",
		"get_attachments_from_message",
		"attach_files_in_message",
	}) do
		assert_eq(type(dispatcher[alias]), "function", "dispatcher." .. alias .. " compatibility")
	end
	assert_eq(type(dispatcher._parse_openai_response), "function", "dispatcher openai parser exposed for tests")
end)

test("dispatcher status timer cleanup is nil-safe and idempotent", function()
	local original_laststatus = vim.o.laststatus
	local original_statusline = vim.o.statusline
	local original_gp_laststatus = vim.g.gp_laststatus
	local original_status_msg = vim.g.status_msg
	local state = {}

	local ok, err = xpcall(function()
		dispatcher_status.print_query_end(state)
		dispatcher_status.show_query_progress(state, "progress before start")
		dispatcher_status.print_query_end(state)
		dispatcher_status.show_query_start(state, "openai")
		dispatcher_status.show_query_start(state, "openai")
		dispatcher_status.print_query_end(state)
		dispatcher_status.print_query_end(state)
	end, debug.traceback)

	if state.refresh_timer and not state.refresh_timer:is_closing() then
		state.refresh_timer:close()
	end
	vim.o.laststatus = original_laststatus
	vim.o.statusline = original_statusline
	vim.g.gp_laststatus = original_gp_laststatus
	vim.g.status_msg = original_status_msg

	assert_true(ok, "status timer cleanup is safe: " .. tostring(err))
	assert_eq(state.refresh_timer, nil, "status timer cleared after repeated cleanup")
end)

test("setup registers exact default command set with tools command", function()
	setup_gp()

	assert_true(gp._setup_called, "setup flag")
	assert_eq(vim.inspect(sorted_gp_commands()), vim.inspect(expected_commands), "exact Gp command snapshot")
	assert_eq(vim.fn.exists(":GpTools"), 2, "native tool command added")
	assert_eq(type(gp.tools), "table", "native tool registry added")
	assert_eq(gp.agents.ChatGPT4o.tools, nil, "default chat agent remains tool-disabled")
	assert_eq(type(gp.agents.ToolAgent.tools), "table", "custom tool agent has tool config")
end)

test("GpTools opens scratch buffer with built-in and enabled tool details", function()
	gp.refresh_state({ chat_agent = "ToolAgent" })
	gp.cmd.Tools()
	local buf = vim.api.nvim_get_current_buf()
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	assert_true(text:match("# Gp Tools"), "tools scratch buffer title")
	assert_true(text:match("agent: ToolAgent"), "tools buffer shows current chat agent")
	assert_true(text:match("enabled: read, write, edit, run"), "tools buffer shows enabled tool list")
	assert_true(text:match("### read"), "tools buffer lists read tool")
	assert_true(text:match("### write"), "tools buffer lists write tool")
	assert_true(text:match("### edit"), "tools buffer lists edit tool")
	assert_true(text:match("### run"), "tools buffer lists run tool")
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("gp facade preserves extracted helper aliases", function()
	assert_eq(type(gp.Prompt), "function", "gp.Prompt compatibility")
	assert_eq(type(gp.Target), "table", "gp.Target compatibility")
	assert_eq(type(gp.BufTarget), "table", "gp.BufTarget compatibility")
	assert_eq(type(gp.resolve_buf_target), "function", "gp.resolve_buf_target compatibility")
	assert_eq(type(gp._toggle_resolve), "function", "gp._toggle_resolve compatibility")
	assert_eq(type(gp.repo_instructions), "function", "gp.repo_instructions compatibility")
	assert_eq(type(gp.not_chat), "function", "gp.not_chat compatibility")
	assert_eq(type(gp.chat_respond), "function", "gp.chat_respond compatibility")
	assert_eq(type(gp.cmd.ChatNew), "function", "gp.cmd.ChatNew compatibility")
	assert_eq(type(gp.cmd.ChatRespond), "function", "gp.cmd.ChatRespond compatibility")
	assert_eq(type(gp.cmd.Context), "function", "gp.cmd.Context compatibility")
	assert_eq(type(gp.cmd.Agent), "function", "gp.cmd.Agent compatibility")
	assert_eq(type(gp.get_chat_agent), "function", "gp.get_chat_agent compatibility")
	assert_eq(type(gp.get_command_agent), "function", "gp.get_command_agent compatibility")

	assert_eq(gp.resolve_buf_target("popup"), gp.BufTarget.popup, "resolve popup target")
	assert_eq(gp.resolve_buf_target({ args = " vsplit " }), gp.BufTarget.vsplit, "resolve trimmed vsplit target")
	assert_eq(gp.resolve_buf_target("unknown"), gp.BufTarget.current, "unknown target falls back to current")
	assert_eq(gp._toggle_resolve("chat"), gp._toggle_kind.chat, "resolve chat toggle")
	assert_eq(gp._toggle_resolve("popup"), gp._toggle_kind.popup, "resolve popup toggle")
	assert_eq(gp._toggle_resolve("context"), gp._toggle_kind.context, "resolve context toggle")
	local original_warning = gp.logger.warning
	gp.logger.warning = function() end
	assert_eq(gp._toggle_resolve("unknown"), gp._toggle_kind.unknown, "unknown toggle falls back to unknown")
	gp.logger.warning = original_warning

	assert_eq(gp.repo_instructions(), "", "repo instructions empty outside git repo with .gp.md")

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".md")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# topic: T", "- file: x", "", "", "" })
	assert_eq(gp.not_chat(buf, vim.api.nvim_buf_get_name(buf)), nil, "valid minimal chat recognized")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "topic: T", "- file: x", "", "", "" })
	assert_eq(gp.not_chat(buf, vim.api.nvim_buf_get_name(buf)), "missing topic header", "invalid chat reason preserved")
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("dispatcher payload characterization preserves core provider behavior", function()
	local string_messages = { { role = "user", content = "hello" } }
	local string_payload = dispatcher.prepare_payload(string_messages, "gpt-test", "openai")
	assert_eq(string_payload.model, "gpt-test", "string model payload model")
	assert_eq(string_payload.stream, true, "string model payload stream")
	assert_true(string_payload.messages == string_messages, "string model payload keeps message table")

	local reason_messages = {
		{ role = "system", content = "sys" },
		{ role = "assistant", content = "<think>hidden</think>\nvisible" },
		{ role = "user", content = "question" },
	}
	local reason_payload = dispatcher.prepare_payload(reason_messages, { model = "o1-mini", temperature = 0.1 }, "openai")
	assert_eq(reason_payload.messages[1].role, "developer", "openai reasoning system role mutated")
	assert_eq(reason_payload.messages[2].content, "visible", "assistant think block stripped")
	assert_true(reason_payload.messages == reason_messages, "openai table payload keeps message table")

	local anthropic_messages = {
		{ role = "system", content = "sys" },
		{ role = "user", content = "hello" },
	}
	local anthropic_payload = dispatcher.prepare_payload(
		anthropic_messages,
		{ model = "claude-test", max_tokens = 100, temperature = 0.2, top_p = 1, stream = false },
		"anthropic"
	)
	assert_eq(anthropic_payload.model, "claude-test", "anthropic model")
	assert_eq(anthropic_payload.system, "sys\n", "anthropic system extracted")
	assert_eq(#anthropic_messages, 1, "anthropic mutates messages by removing system")
	assert_true(anthropic_payload.messages == anthropic_messages, "anthropic payload uses mutated messages")
	assert_eq(anthropic_payload.stream, true, "anthropic stream preserves current or-true behavior")

	local google_messages = {
		{ role = "system", content = "sys" },
		{ role = "user", content = "hello" },
		{ role = "assistant", content = "answer" },
	}
	local google_payload = dispatcher.prepare_payload(
		google_messages,
		{ model = "gemini-test", temperature = 0.3, top_p = 1, top_k = 40, max_tokens = 123, search = "on" },
		"google"
	)
	assert_eq(google_payload.model, "gemini-test", "google model")
	assert_eq(google_payload.system_instruction.parts.text, "sys\n", "google system instruction")
	assert_eq(google_messages[2].role, "model", "google assistant role converted")
	assert_eq(google_messages[1].parts[1].text, "hello", "google user content converted")
	assert_true(google_payload.contents == google_messages, "google payload uses mutated messages")
	assert_true(google_payload.tools and google_payload.tools[1].google_search ~= nil, "google search tool preserved")
end)

test("tool payloads and response parser support OpenAI-compatible tool calls only", function()
	local schemas = gp.tools.openai_schemas(assert(gp.tools.resolve(gp.get_chat_agent("ToolAgent"), "openai")))
	local openai_payload = dispatcher.prepare_payload(
		{ { role = "user", content = "use tools" } },
		{ model = "gpt-test", temperature = 0 },
		"openai",
		{ stream = false, tools = schemas, tool_choice = "auto" }
	)
	assert_eq(openai_payload.stream, false, "tool payload forces non-stream")
	assert_eq(openai_payload.tool_choice, "auto", "tool choice auto")
	assert_eq(openai_payload.tools[1]["function"].name, "read", "read schema injected")

	local anthropic_payload = dispatcher.prepare_payload(
		{ { role = "user", content = "hello" } },
		{ model = "claude-test" },
		"anthropic",
		{ stream = false, tools = schemas, tool_choice = "auto" }
	)
	assert_eq(anthropic_payload.tools, nil, "anthropic does not receive OpenAI tools")
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

test("built-in tools enforce workspace limits confirmation and file edits", function()
	local agent = gp.get_chat_agent("ToolAgent")
	vim.fn.writefile({ "alpha", "beta" }, workspace .. "/sample.txt")

	local read_result = exec_tool(gp, tool_call("r1", "read", [[{"path":"sample.txt"}]]), agent)
	assert_true(read_result.content:match("path: sample.txt"), "read returns path metadata")
	assert_true(read_result.content:match("content:\nalpha\nbeta"), "read returns content")

	vim.fn.writefile({ "abcdef" }, workspace .. "/limited.txt")
	local limited_agent = vim.deepcopy(agent)
	limited_agent.tools.read = { max_bytes = 4, max_lines = 2000 }
	local limited_read = exec_tool(gp, tool_call("r2", "read", [[{"path":"limited.txt"}]]), limited_agent)
	assert_true(limited_read.content:match("bytes: 4"), "read bytes reports returned bytes")
	assert_true(limited_read.content:match("total_bytes: 7"), "read reports total file bytes")
	assert_true(limited_read.content:match("truncated: true"), "read reports truncation")

	local write_result = exec_tool(gp, tool_call("w1", "write", [[{"path":"dir/new.txt","content":"hello"}]]), agent)
	assert_true(write_result.content:match("bytes_written: 5"), "write returns byte summary")
	assert_eq(vim.fn.readfile(workspace .. "/dir/new.txt")[1], "hello", "write creates file and parents")

	local edit_result = exec_tool(gp, tool_call("e1", "edit", [[{"path":"sample.txt","edits":[{"old_text":"alpha","new_text":"ALPHA"},{"old_text":"beta","new_text":"BETA"}]}]]), agent)
	assert_true(edit_result.content:match("edits_applied: 2"), "edit returns edit count")
	assert_eq(table.concat(vim.fn.readfile(workspace .. "/sample.txt"), "\n"), "ALPHA\nBETA", "edit applies replacements")

	local escape = exec_tool(gp, tool_call("bad", "read", [[{"path":"../escape.txt"}]]), agent)
	assert_true(escape.is_error, "workspace escape rejected")
	assert_true(escape.content:match("escapes workspace root"), "workspace escape error returned")

	local invalid = exec_tool(gp, tool_call("badjson", "read", "{"), agent)
	assert_true(invalid.is_error, "invalid JSON args rejected")
	assert_true(invalid.content:match("invalid JSON"), "invalid JSON error returned")

	local deny_agent = vim.deepcopy(agent)
	deny_agent.tools.write.confirm = true
	local denied
	with_stub(vim.ui, "select", function(_, _, cb)
		cb("Deny")
	end, function()
		denied = exec_tool(gp, tool_call("deny", "write", [[{"path":"denied.txt","content":"no"}]]), deny_agent)
	end)
	assert_true(denied.is_error, "denied confirmation returns error")
	assert_true(denied.content:match("denied"), "denial content returned")

	local allow_agent = vim.deepcopy(agent)
	allow_agent.tools.write.confirm = true
	local allowed
	with_stub(vim.ui, "select", function(_, _, cb)
		cb("Run once")
	end, function()
		allowed = exec_tool(gp, tool_call("allow", "write", [[{"path":"allowed.txt","content":"yes"}]]), allow_agent)
	end)
	assert_true(not allowed.is_error, "Run once confirmation allows execution")
	assert_eq(vim.fn.readfile(workspace .. "/allowed.txt")[1], "yes", "confirmed write creates file")

	local run_result = exec_tool(gp, tool_call("run", "run", [[{"cmd":"printf","args":["hi"]}]]), agent)
	assert_true(run_result.content:match("exit_code: 0"), "run returns exit code")
	assert_true(run_result.content:match("stdout:\nhi"), "run returns stdout")

	local printf_path = vim.fn.exepath("printf")
	assert_true(printf_path ~= "", "printf executable exists")
	local run_abs = exec_tool(gp, tool_call("runabs", "run", vim.json.encode({ cmd = printf_path, args = { "ok" } })), agent)
	assert_true(run_abs.content:match("exit_code: 0"), "allowed command basename bypasses confirmation")
	assert_true(run_abs.content:match("stdout:\nok"), "absolute allowed command runs")

	local timeout_agent = vim.deepcopy(agent)
	timeout_agent.tools.run.allowed_commands = { "sleep" }
	local timed = exec_tool(gp, tool_call("timeout", "run", [[{"cmd":"sleep","args":["1"],"timeout_ms":0}]]), timeout_agent)
	assert_true(timed.content:match("timed_out: true"), "timeout_ms zero is clamped and enforced")
end)

test("default confirmation gates write edit and non-allowlisted run", function()
	local agent = gp.get_chat_agent("ToolAgent")
	local default_agent = vim.deepcopy(agent)
	default_agent.tools.write = nil
	default_agent.tools.edit = nil
	default_agent.tools.run = { timeout_ms = 1000, max_output_bytes = 1024 }
	vim.fn.writefile({ "before" }, workspace .. "/confirm-edit.txt")

	local prompts = 0
	with_stub(vim.ui, "select", function(_, _, cb)
		prompts = prompts + 1
		cb("Deny")
	end, function()
		local denied_write = exec_tool(gp, tool_call("dw", "write", [[{"path":"confirm-write.txt","content":"no"}]]), default_agent)
		assert_true(denied_write.is_error, "default write confirmation can deny")
		assert_eq(vim.fn.filereadable(workspace .. "/confirm-write.txt"), 0, "denied write does not create file")

		local denied_edit = exec_tool(gp, tool_call("de", "edit", [[{"path":"confirm-edit.txt","edits":[{"old_text":"before","new_text":"after"}]}]]), default_agent)
		assert_true(denied_edit.is_error, "default edit confirmation can deny")
		assert_eq(vim.fn.readfile(workspace .. "/confirm-edit.txt")[1], "before", "denied edit does not modify file")

		local denied_run = exec_tool(gp, tool_call("dr", "run", [[{"cmd":"printf","args":["no"]}]]), default_agent)
		assert_true(denied_run.is_error, "non-allowlisted run confirmation can deny")
		assert_true(denied_run.content:match("denied"), "denied run reports denial")
	end)
	assert_eq(prompts, 3, "write edit and non-allowlisted run each prompt by default")

	with_stub(vim.ui, "select", function(_, _, cb)
		cb("Run once")
	end, function()
		local allowed_write = exec_tool(gp, tool_call("aw", "write", [[{"path":"confirm-allow.txt","content":"yes"}]]), default_agent)
		assert_true(not allowed_write.is_error, "Run once allows default-confirmed write")
		assert_eq(vim.fn.readfile(workspace .. "/confirm-allow.txt")[1], "yes", "Run once write created file")
	end)
end)

test("workspace validation covers absolute paths cwd symlinks and workspace override", function()
	local agent = gp.get_chat_agent("ToolAgent")
	local outside = vim.fn.tempname()
	vim.fn.mkdir(outside, "p")
	vim.fn.writefile({ "outside content" }, outside .. "/outside.txt")

	local abs_escape = exec_tool(gp, tool_call("abs", "read", vim.json.encode({ path = outside .. "/outside.txt" })), agent)
	assert_true(abs_escape.is_error, "absolute path outside workspace rejected")
	assert_true(abs_escape.content:match("escapes workspace root"), "absolute path escape reports workspace error")

	local cwd_escape = exec_tool(gp, tool_call("cwd", "run", vim.json.encode({ cmd = "printf", args = { "x" }, cwd = outside })), agent)
	assert_true(cwd_escape.is_error, "run cwd outside workspace rejected when workspace_only=true")
	assert_true(cwd_escape.content:match("escapes workspace root"), "run cwd escape reports workspace error")

	local open_agent = vim.deepcopy(agent)
	open_agent.tools.workspace_only = false
	open_agent.tools.run.allowed_commands = { "pwd" }
	local outside_read = exec_tool(gp, tool_call("or", "read", vim.json.encode({ path = outside .. "/outside.txt" })), open_agent)
	assert_true(not outside_read.is_error, "workspace_only=false allows controlled outside read")
	assert_true(outside_read.content:match("outside content"), "outside read returns content")
	local outside_cwd = exec_tool(gp, tool_call("oc", "run", vim.json.encode({ cmd = "pwd", args = {}, cwd = outside })), open_agent)
	assert_true(outside_cwd.content:match("exit_code: 0"), "workspace_only=false allows outside cwd")
	assert_true(outside_cwd.content:match("stdout:\n" .. vim.pesc(vim.fn.fnamemodify(outside, ":p"):gsub("/$", ""))), "outside cwd command ran in requested directory")

	local uv = vim.uv or vim.loop
	local link = workspace .. "/outside-link.txt"
	local ok = pcall(function()
		uv.fs_symlink(outside .. "/outside.txt", link)
	end)
	if ok and vim.fn.filereadable(link) == 1 then
		local symlink_read = exec_tool(gp, tool_call("sl", "read", [[{"path":"outside-link.txt"}]]), agent)
		assert_true(symlink_read.is_error, "symlink to outside workspace rejected")
		local symlink_write = exec_tool(gp, tool_call("sw", "write", [[{"path":"outside-link.txt","content":"bad","overwrite":true}]]), agent)
		assert_true(symlink_write.is_error, "write through existing outside symlink rejected")
	else
		print("skip - symlink escape fixture unsupported")
	end
	vim.fn.delete(outside, "rf")
end)

test("path helpers reject NUL bytes and discover git or cwd workspace roots", function()
	local path_tools = require("gp.tools.path")
	local nul_path = "bad" .. string.char(0) .. "path.txt"
	local resolved, err = path_tools.resolve(nul_path, { workspace_root = workspace }, false)
	assert_eq(resolved, nil, "NUL path does not resolve")
	assert_true(err:match("NUL byte"), "NUL path rejection explains cause")

	local git_parent = vim.fn.tempname()
	local git_root = git_parent .. "/repo"
	vim.fn.mkdir(git_root .. "/.git", "p")
	vim.fn.mkdir(git_root .. "/sub", "p")
	with_cwd(git_root .. "/sub", function()
		assert_eq(path_tools.workspace_root({}), vim.fn.fnamemodify(git_root, ":p"):gsub("/$", ""), "workspace root discovers git root from cwd")
	end)
	vim.fn.delete(git_parent, "rf")

	local plain = vim.fn.tempname()
	vim.fn.mkdir(plain, "p")
	with_cwd(plain, function()
		with_stub(vim.fn, "isdirectory", function(candidate)
			if tostring(candidate):match("/%.git$") then
				return 0
			end
			return 1
		end, function()
			assert_eq(path_tools.workspace_root({}), vim.fn.fnamemodify(plain, ":p"):gsub("/$", ""), "workspace root falls back to cwd when no git root is found")
		end)
	end)
	vim.fn.delete(plain, "rf")
end)

test("confirmation cancel denies and preview describes requested tool", function()
	local agent = gp.get_chat_agent("ToolAgent")
	local default_agent = vim.deepcopy(agent)
	default_agent.tools.write = nil
	local prompt = nil
	local cancelled
	with_stub(vim.ui, "select", function(_, opts, cb)
		prompt = opts.prompt
		cb(nil)
	end, function()
		cancelled = exec_tool(gp, tool_call("cancel", "write", [[{"path":"cancelled.txt","content":"no"}]]), default_agent)
	end)
	assert_true(cancelled.is_error, "nil confirmation callback denies execution")
	assert_true(cancelled.content:match("denied"), "cancelled confirmation reports denial")
	assert_eq(vim.fn.filereadable(workspace .. "/cancelled.txt"), 0, "cancelled write does not create file")
	assert_true(prompt:match("Run tool: write"), "confirmation preview includes tool name")
	assert_true(prompt:match("path: cancelled.txt"), "confirmation preview includes path")
	assert_true(prompt:match("overwrite: false"), "confirmation preview includes overwrite flag")
end)

test("tool formatting and empty batch execution are stable", function()
	local result_block = gp.tools.format_result_block("read", "ok")
	assert_true(result_block:match("📎 tool_result: read"), "result block includes tool name")
	assert_true(result_block:match("```text\nok\n```"), "result block fences text result")
	local done = false
	local results
	gp.tools.execute_calls({}, gp.get_chat_agent("ToolAgent"), { buf = vim.api.nvim_get_current_buf(), provider = "openai" }, function(res)
		results = res
		done = true
	end)
	assert_true(done, "empty execute_calls returns synchronously")
	assert_eq(#results, 0, "empty execute_calls returns empty results")
end)

test("read write edit and run expose focused failure branches", function()
	local agent = gp.get_chat_agent("ToolAgent")
	vim.fn.mkdir(workspace .. "/read-dir", "p")
	local missing = exec_tool(gp, tool_call("missing", "read", [[{"path":"missing.txt"}]]), agent)
	assert_true(missing.is_error, "read missing file returns error")
	assert_true(missing.content:match("file not found"), "read missing file error message")
	local directory = exec_tool(gp, tool_call("dir", "read", [[{"path":"read-dir"}]]), agent)
	assert_true(directory.is_error, "read directory returns error")
	assert_true(directory.content:match("path is not a file"), "read directory error message")
	write_binary(workspace .. "/binary.bin", "a\0b")
	local binary = exec_tool(gp, tool_call("bin", "read", [[{"path":"binary.bin"}]]), agent)
	assert_true(binary.is_error, "read binary file returns error")
	assert_true(binary.content:match("binary files are not supported"), "read binary error message")
	vim.fn.writefile({ "one", "two", "three" }, workspace .. "/lines.txt")
	local line_agent = vim.deepcopy(agent)
	line_agent.tools.read = { max_bytes = 65536, max_lines = 1 }
	local line_limited = exec_tool(gp, tool_call("line", "read", [[{"path":"lines.txt"}]]), line_agent)
	assert_true(line_limited.content:match("truncated: true"), "read line truncation reported")
	assert_true(not line_limited.content:match("two"), "read line truncation omits later lines")

	vim.fn.writefile({ "old" }, workspace .. "/existing.txt")
	local no_overwrite = exec_tool(gp, tool_call("wo", "write", [[{"path":"existing.txt","content":"new"}]]), agent)
	assert_true(no_overwrite.is_error, "write existing file without overwrite returns error")
	local overwrite = exec_tool(gp, tool_call("ow", "write", [[{"path":"existing.txt","content":"new","overwrite":true}]]), agent)
	assert_true(not overwrite.is_error, "write overwrite=true succeeds")
	assert_true(overwrite.content:match("overwritten: true"), "overwrite summary reports overwritten")
	local unknown_field = exec_tool(gp, tool_call("uf", "write", [[{"path":"x.txt","content":"x","extra":true}]]), agent)
	assert_true(unknown_field.is_error, "unknown argument fields rejected")
	assert_true(unknown_field.content:match("unknown field"), "unknown field error returned")
	local wrong_type = exec_tool(gp, tool_call("wt", "write", [[{"path":"x.txt","content":1}]]), agent)
	assert_true(wrong_type.is_error, "invalid argument types rejected")
	assert_true(wrong_type.content:match("arguments.content must be string"), "invalid type error returned")
	local small_write_agent = vim.deepcopy(agent)
	small_write_agent.tools.write = { max_bytes = 2, confirm = false }
	local too_large_write = exec_tool(gp, tool_call("wmax", "write", [[{"path":"too-large.txt","content":"abc"}]]), small_write_agent)
	assert_true(too_large_write.is_error, "write content over max_bytes rejected")
	assert_true(too_large_write.content:match("content exceeds max_bytes: 2"), "write max_bytes error returned")

	vim.fn.writefile({ "abc abc" }, workspace .. "/edit-errors.txt")
	local zero_match = exec_tool(gp, tool_call("ez", "edit", [[{"path":"edit-errors.txt","edits":[{"old_text":"missing","new_text":"x"}]}]]), agent)
	assert_true(zero_match.is_error, "edit zero-match replacement rejected")
	assert_true(zero_match.content:match("matched 0 times"), "zero-match error returned")
	local multi_match = exec_tool(gp, tool_call("em", "edit", [[{"path":"edit-errors.txt","edits":[{"old_text":"abc","new_text":"x"}]}]]), agent)
	assert_true(multi_match.is_error, "edit multi-match replacement rejected")
	assert_true(multi_match.content:match("matched 2 times"), "multi-match error returned")
	local empty_old = exec_tool(gp, tool_call("ee", "edit", [[{"path":"edit-errors.txt","edits":[{"old_text":"","new_text":"x"}]}]]), agent)
	assert_true(empty_old.is_error, "edit empty old_text rejected")
	assert_true(empty_old.content:match("old_text must not be empty"), "empty old_text error returned")
	vim.fn.writefile({ "abcdef" }, workspace .. "/edit-overlap.txt")
	local overlap = exec_tool(gp, tool_call("eo", "edit", [[{"path":"edit-overlap.txt","edits":[{"old_text":"abc","new_text":"x"},{"old_text":"bcd","new_text":"y"}]}]]), agent)
	assert_true(overlap.is_error, "edit overlapping replacements rejected")
	assert_true(overlap.content:match("edits overlap"), "overlap error returned")
	local max_edits_agent = vim.deepcopy(agent)
	max_edits_agent.tools.edit = { max_edits = 1, confirm = false }
	local too_many_edits = exec_tool(gp, tool_call("emax", "edit", [[{"path":"edit-overlap.txt","edits":[{"old_text":"abc","new_text":"x"},{"old_text":"def","new_text":"y"}]}]]), max_edits_agent)
	assert_true(too_many_edits.is_error, "edit over max_edits rejected")
	assert_true(too_many_edits.content:match("too many edits; max_edits is 1"), "edit max_edits error returned")

	local shell_agent = vim.deepcopy(agent)
	shell_agent.tools.run.allowed_commands = { "sh" }
	local shell_reject = exec_tool(gp, tool_call("shell", "run", [[{"cmd":"sh","args":["-c","echo bad"]}]]), shell_agent)
	assert_true(shell_reject.is_error, "run shell -c rejected")
	assert_true(shell_reject.content:match("shell %-c style commands are not supported"), "shell -c rejection message")
	local run_agent = vim.deepcopy(agent)
	run_agent.tools.run.allowed_commands = { "ls", "printf" }
	local nonzero = exec_tool(gp, tool_call("nz", "run", [[{"cmd":"ls","args":["definitely-missing-gp-test-file"]}]]), run_agent)
	assert_true(not nonzero.content:match("exit_code: 0\n"), "run reports non-zero exit code")
	assert_true(nonzero.content:match("stderr:\n") and not nonzero.content:match("stderr:\n%s*$"), "run returns stderr")
	run_agent.tools.run.max_output_bytes = 3
	local truncated = exec_tool(gp, tool_call("tr", "run", [[{"cmd":"printf","args":["abcdef"]}]]), run_agent)
	assert_true(truncated.content:match("stdout_truncated: true"), "run stdout truncation reported")
	assert_true(truncated.content:match("stdout:\nabc"), "run stdout capped content returned")
	local stderr_agent = vim.deepcopy(agent)
	stderr_agent.tools.run.allowed_commands = { "ls" }
	stderr_agent.tools.run.max_output_bytes = 3
	local stderr_truncated = exec_tool(gp, tool_call("terr", "run", [[{"cmd":"ls","args":["definitely-missing-gp-test-file"]}]]), stderr_agent)
	assert_true(stderr_truncated.content:match("stderr_truncated: true"), "run stderr truncation reported")
	local spawn_agent = vim.deepcopy(agent)
	spawn_agent.tools.run.allowed_commands = { "definitely-missing-gp-nvim-command" }
	local spawn_fail = exec_tool(gp, tool_call("spawn", "run", [[{"cmd":"definitely-missing-gp-nvim-command","args":[]}]]), spawn_agent)
	assert_true(spawn_fail.content:match("exit_code: %-1"), "run spawn failure returns exit_code -1")
	assert_true(spawn_fail.content:match("failed to start command"), "run spawn failure returns stderr message")
end)

test("schema validation rejects unknown disabled and malformed tool calls", function()
	local agent = gp.get_chat_agent("ToolAgent")
	local unknown = exec_tool(gp, tool_call("unknown", "unknown_tool", [[{}]]), agent)
	assert_true(unknown.is_error, "unknown tool call rejected")
	assert_true(unknown.content:match("tool is not enabled"), "unknown tool reports not enabled")
	local read_only_agent = vim.deepcopy(agent)
	read_only_agent.tools.enabled = { "read" }
	local disabled = exec_tool(gp, tool_call("disabled", "write", [[{"path":"x.txt","content":"x"}]]), read_only_agent)
	assert_true(disabled.is_error, "disabled built-in tool rejected")
	assert_true(disabled.content:match("tool is not enabled: write"), "disabled tool error returned")
	local missing_required = exec_tool(gp, tool_call("missing", "read", [[{}]]), agent)
	assert_true(missing_required.is_error, "missing required field rejected")
	assert_true(missing_required.content:match("missing required field: path"), "missing required error returned")
	local invalid_array_item = exec_tool(gp, tool_call("badargs", "run", [[{"cmd":"printf","args":[1]}]]), agent)
	assert_true(invalid_array_item.is_error, "invalid array item type rejected")
	assert_true(invalid_array_item.content:match("arguments.args%[1%] must be string"), "array item type error returned")
end)

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
				assert_eq(payload.stream, false, "max-round tool loop forces payload stream false")
				assert_eq(stream, false, "max-round tool loop disables UI streaming")
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

test("ChatRespond tool loop records tool blocks and finalizes", function()
	gp.refresh_state({ chat_agent = "ToolAgent" })
	vim.fn.writefile({ "tool content" }, workspace .. "/tool.txt")
	vim.fn.writefile({ "second content" }, workspace .. "/tool2.txt")
	local calls = 0
	local handler_stub = function(buf)
		return function(_, content)
			local line = gp.helpers.last_content_line(buf)
			vim.api.nvim_buf_set_lines(buf, line, line, false, vim.split(content, "\n", { plain = true }))
		end
	end
	local query_stub = function(buf, provider, payload, _, on_exit, _, stream)
		calls = calls + 1
		assert_eq(provider, "openai", "tool loop provider")
		assert_eq(payload.stream, false, "tool loop forces payload stream false")
		assert_true(payload.tools ~= nil, "tool loop sends schemas")
		assert_eq(stream, false, "tool loop disables UI streaming")
		local qid = "tool-qid-" .. calls
		if calls == 1 then
			gp.tasker.set_query(qid, {
				timestamp = os.time(),
				buf = buf,
				provider = provider,
				payload = payload,
				response = "",
				tool_calls = {
					tool_call("tc1", "read", [[{"path":"tool.txt"}]]),
					tool_call("tc2", "read", [[{"path":"tool2.txt"}]]),
					tool_call("tc_bad", "read", "{"),
				},
				response_message = { role = "assistant", content = nil },
			})
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
			})
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
	assert_true(text:match("final answer"), "final response written")
	assert_true(text:match(gp.config.chat_user_prefix), "chat finalized with user prompt")
	assert_single_blank_before_prompt(buf, "final answer", gp.config.chat_user_prefix, "tool response without trailing newline")
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
	local query_stub = function(buf, provider, payload, _, on_exit, _, stream)
		calls = calls + 1
		assert_eq(payload.stream, false, "tool final response forces payload stream false")
		assert_eq(stream, false, "tool final response disables UI streaming")
		local qid = "tool-newline-qid"
		gp.tasker.set_query(qid, {
			timestamp = os.time(),
			buf = buf,
			provider = provider,
			payload = payload,
			response = "final answer\n",
			tool_calls = {},
			response_message = { role = "assistant", content = "final answer\n" },
		})
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
		return calls == 1 and text:match("final answer") and text:match(gp.config.chat_user_prefix)
	end)
	assert_eq(calls, 1, "tool final response without tool calls performs one provider request")
	assert_single_blank_before_prompt(buf, "final answer", gp.config.chat_user_prefix, "tool response with trailing newline")
	vim.api.nvim_buf_delete(buf, { force = true })
	vim.fn.delete(chat_file)
end)

local failures = {}
for _, case in ipairs(tests) do
	local ok, err = xpcall(case.fn, debug.traceback)
	if ok then
		print("ok - " .. case.name)
	else
		table.insert(failures, "not ok - " .. case.name .. "\n" .. err)
	end
end

vim.fn.delete(workspace, "rf")

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(string.format("tests passed (%d)", #tests))
