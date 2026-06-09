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
	assert_eq(type(dispatcher._merge_openai_tool_call_delta), "function", "dispatcher stream tool-call merger exposed for tests")
	assert_eq(type(dispatcher._validate_openai_stream_tool_calls), "function", "dispatcher stream tool-call validator exposed for tests")
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
	assert_true(text:match("stream: true"), "tools buffer shows default-on streaming")
	assert_true(text:match("workspace_only: true"), "tools buffer shows workspace safety")
	assert_true(text:match("max_rounds: 10"), "tools buffer shows max rounds")
	assert_true(text:match("### read"), "tools buffer lists read tool")
	assert_true(text:match("confirm: false"), "tools buffer shows read/write/edit confirmation config")
	assert_true(text:match("max_bytes: 65536"), "tools buffer shows read size limit")
	assert_true(text:match("max_lines: 2000"), "tools buffer shows read line limit")
	assert_true(text:match("### write"), "tools buffer lists write tool")
	assert_true(text:match("max_bytes: 262144"), "tools buffer shows write size limit")
	assert_true(text:match("### edit"), "tools buffer lists edit tool")
	assert_true(text:match("max_edits: 20"), "tools buffer shows edit limit")
	assert_true(text:match("### run"), "tools buffer lists run tool")
	assert_true(text:match("confirm: true"), "tools buffer shows run confirmation config")
	assert_true(text:match("allowed_commands: printf"), "tools buffer shows run allowlist")
	assert_true(text:match("timeout_ms: 1000"), "tools buffer shows run timeout")
	assert_true(text:match("max_output_bytes: 1024"), "tools buffer shows run output limit")
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
	assert_eq(type(gp.cmd.ChatFinder), "function", "gp.cmd.ChatFinder compatibility")
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
	assert_eq(anthropic_payload.stream, false, "anthropic table model stream=false is preserved")

	local anthropic_override_payload = dispatcher.prepare_payload(
		{ { role = "user", content = "hello" } },
		{ model = "claude-test", max_tokens = 100, stream = true },
		"anthropic",
		{ stream = false }
	)
	assert_eq(anthropic_override_payload.stream, false, "anthropic opts stream override wins")

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

