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

local function count_occurrences(text, needle)
	local count = 0
	local pos = 1
	while true do
		local start_pos, end_pos = text:find(needle, pos, true)
		if not start_pos then
			return count
		end
		count = count + 1
		pos = end_pos + 1
	end
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
	"GpChatMigrate",
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


return {
	tests = tests,
	test = test,
	assert_eq = assert_eq,
	assert_true = assert_true,
	sorted_gp_commands = sorted_gp_commands,
	tool_call = tool_call,
	exec_tool = exec_tool,
	with_stub = with_stub,
	with_stubs = with_stubs,
	write_binary = write_binary,
	with_cwd = with_cwd,
	assert_single_blank_before_prompt = assert_single_blank_before_prompt,
	count_occurrences = count_occurrences,
	workspace = workspace,
	gp = gp,
	dispatcher = dispatcher,
	dispatcher_status = dispatcher_status,
	expected_commands = expected_commands,
	tool_agent = tool_agent,
	setup_gp = setup_gp,
}
