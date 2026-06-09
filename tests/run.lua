local source = debug.getinfo(1, "S").source
local script = source:sub(1, 1) == "@" and source:sub(2) or "tests/run.lua"
local root = vim.fn.fnamemodify(script, ":p:h:h")
local support = dofile(root .. "/tests/support.lua")

local env = setmetatable({}, {
	__index = function(_, key)
		local value = support[key]
		if value ~= nil then
			return value
		end
		return _G[key]
	end,
	__newindex = _G,
})

for _, spec in ipairs({ "core", "dispatcher", "tools", "chat_tools", "chat_basic", "chat_tool_rounds" }) do
	local chunk = assert(loadfile(root .. "/tests/spec/" .. spec .. ".lua"))
	setfenv(chunk, env)
	chunk()
end

local failures = {}
for _, case in ipairs(support.tests) do
	local ok, err = xpcall(case.fn, debug.traceback)
	if ok then
		print("ok - " .. case.name)
	else
		table.insert(failures, "not ok - " .. case.name .. "\n" .. err)
	end
end

vim.fn.delete(support.workspace, "rf")

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(string.format("tests passed (%d)", #support.tests))
