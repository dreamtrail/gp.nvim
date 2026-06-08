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

vim.opt.runtimepath:append(vim.fn.getcwd())

local gp = require("gp")
local dispatcher = require("gp.dispatcher")

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
	"GpVnew",
}

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
end)

test("setup registers the exact default command set without tools", function()
	gp.setup({
		openai_api_key = "dummy",
		image = { disable = true },
		whisper = { disable = true },
		state_dir = vim.fn.stdpath("data") .. "/gp-test/persisted",
		chat_dir = vim.fn.stdpath("data") .. "/gp-test/chats",
		log_file = vim.fn.stdpath("state") .. "/gp-test.log",
	})

	assert_true(gp._setup_called, "setup flag")
	assert_eq(vim.inspect(sorted_gp_commands()), vim.inspect(expected_commands), "exact Gp command snapshot")
	assert_eq(vim.fn.exists(":GpTools"), 0, "native tool command not added in refactor")
	assert_eq(gp.tools, nil, "native tool registry not added in refactor")
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

test("attachment payloads preserve OpenAI Anthropic and Google shapes", function()
	local attachment = vim.fn.tempname() .. ".txt"
	vim.fn.writefile({ "fixture attachment" }, attachment)
	local attachment_ref = "@attach(" .. attachment .. ")"

	local openai_messages = { { role = "user", content = "see " .. attachment_ref } }
	local openai_payload = dispatcher.prepare_payload(openai_messages, { model = "gpt-test" }, "openai")
	assert_eq(type(openai_payload.messages[1].content), "table", "openai attachment content table")
	assert_eq(openai_payload.messages[1].content[1].type, "text", "openai keeps text part")
	assert_eq(openai_payload.messages[1].content[2].type, "image_url", "openai attachment url part")
	assert_true(
		openai_payload.messages[1].content[2].image_url.url:match("^data:text/plain;base64,"),
		"openai attachment includes text/plain data url"
	)

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

test("ChatRespond builds provider payload and writes assistant prompt without live provider", function()
	local original_query = gp.dispatcher.query
	local original_create_handler = gp.dispatcher.create_handler
	local captured = nil
	gp.dispatcher.create_handler = function(_, _, _, _, _, _)
		return function() end
	end
	gp.dispatcher.query = function(buf, provider, payload, handler, on_exit, callback, stream, show_thinking)
		captured = {
			buf = buf,
			provider = provider,
			payload = payload,
			handler = handler,
			on_exit = on_exit,
			callback = callback,
			stream = stream,
			show_thinking = show_thinking,
		}
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

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local found_prompt = false
	for _, line in ipairs(lines) do
		if line == "🤖:[gpt-custom & custom role]" then
			found_prompt = true
		end
	end
	assert_true(found_prompt, "ChatRespond writes assistant prompt with model/custom role label")

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

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(string.format("tests passed (%d)", #tests))
