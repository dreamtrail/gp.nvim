--------------------------------------------------------------------------------
-- Native tool registry and execution orchestration.
--------------------------------------------------------------------------------

local builtin = require("gp.tools.builtin")
local path = require("gp.tools.path")

local M = {
	builtins = builtin.specs,
	defaults = builtin.defaults,
}

local function list_contains(list, value)
	for _, item in ipairs(list or {}) do
		if item == value then
			return true
		end
	end
	return false
end

local function merge_config(agent_tools)
	local config = vim.deepcopy(agent_tools or {})
	config.workspace_only = config.workspace_only ~= false
	config.stream = config.stream ~= false
	config.max_rounds = config.max_rounds or 10
	for name, defaults in pairs(M.defaults) do
		config[name] = vim.tbl_extend("force", vim.deepcopy(defaults), config[name] or {})
	end
	return config
end

local function is_openai_compatible_provider(provider)
	provider = provider or "openai"
	if provider == "anthropic" then
		return false
	end
	if provider:match("^google") or provider:match("^vertex") then
		return false
	end
	return true
end

local function enabled_list(agent)
	if not agent or type(agent.tools) ~= "table" then
		return nil
	end
	if type(agent.tools.enabled) ~= "table" then
		return nil
	end
	return agent.tools.enabled
end

local function type_name(value)
	if type(value) == "table" then
		local islist = vim.islist or vim.tbl_islist
		if islist then
			return islist(value) and "array" or "object"
		end
		local max = 0
		local count = 0
		for k, _ in pairs(value) do
			count = count + 1
			if type(k) ~= "number" then
				return "object"
			end
			max = math.max(max, k)
		end
		if count > 0 and max == count then
			return "array"
		end
		return "object"
	end
	return type(value)
end

local function validate_schema(schema, value, label)
	local expected = schema.type
	if expected and type_name(value) ~= expected then
		return label .. " must be " .. expected .. ", got " .. type_name(value)
	end
	if expected == "object" then
		local props = schema.properties or {}
		if schema.additionalProperties == false then
			for k, _ in pairs(value) do
				if props[k] == nil then
					return label .. " has unknown field: " .. tostring(k)
				end
			end
		end
		for _, required in ipairs(schema.required or {}) do
			if value[required] == nil then
				return label .. " missing required field: " .. required
			end
		end
		for k, prop_schema in pairs(props) do
			if value[k] ~= nil then
				local err = validate_schema(prop_schema, value[k], label .. "." .. k)
				if err then
					return err
				end
			end
		end
	elseif expected == "array" then
		for i, item in ipairs(value) do
			local err = validate_schema(schema.items or {}, item, label .. "[" .. i .. "]")
			if err then
				return err
			end
		end
	end
	return nil
end

local function tool_preview(name, args, config)
	local lines = {
		"Run tool: " .. name,
		"workspace_only: " .. tostring(config.workspace_only ~= false),
	}
	if name == "write" or name == "edit" or name == "read" then
		table.insert(lines, "path: " .. tostring(args.path))
	end
	if name == "write" then
		table.insert(lines, "bytes: " .. tostring(type(args.content) == "string" and #args.content or 0))
		table.insert(lines, "overwrite: " .. tostring(args.overwrite == true))
	end
	if name == "edit" then
		table.insert(lines, "edits: " .. tostring(type(args.edits) == "table" and #args.edits or 0))
	end
	if name == "run" then
		table.insert(lines, "cmd: " .. tostring(args.cmd))
		table.insert(lines, "args: " .. vim.inspect(args.args or {}))
		table.insert(lines, "cwd: " .. tostring(args.cwd or path.workspace_root(config)))
	end
	return table.concat(lines, "\n")
end

local function needs_confirmation(spec, args, config)
	if spec.bypass_confirm and spec.bypass_confirm(args, config) then
		return false
	end
	local per_tool = config[spec.name] or {}
	if per_tool.confirm == false then
		return false
	end
	if per_tool.confirm == true then
		return true
	end
	return spec.name ~= "read"
end

local function confirm(spec, args, config, callback)
	if not needs_confirmation(spec, args, config) then
		callback(true)
		return
	end
	vim.ui.select({ "Run once", "Deny" }, {
		prompt = tool_preview(spec.name, args, config),
	}, function(choice)
		callback(choice == "Run once")
	end)
end

M.supports_provider = is_openai_compatible_provider

---@param agent table | nil
---@param provider string | nil
---@return table | nil
---@return string | nil
M.resolve = function(agent, provider)
	local enabled = enabled_list(agent)
	if not enabled then
		return nil, "tools disabled"
	end
	if not is_openai_compatible_provider(provider or agent.provider) then
		return nil, "native tools are only supported for OpenAI-compatible providers in this MVP"
	end
	local config = merge_config(agent.tools)
	local resolved = {
		enabled = {},
		config = config,
		max_rounds = config.max_rounds,
		stream = config.stream,
	}
	for _, name in ipairs(enabled) do
		if M.builtins[name] then
			table.insert(resolved.enabled, name)
		end
	end
	if #resolved.enabled == 0 then
		return nil, "no valid built-in tools enabled"
	end
	return resolved, nil
end

M.openai_schemas = function(resolved)
	local schemas = {}
	for _, name in ipairs(resolved.enabled or {}) do
		local spec = M.builtins[name]
		if spec then
			table.insert(schemas, {
				type = "function",
				["function"] = {
					name = spec.name,
					description = spec.description,
					parameters = spec.parameters,
				},
			})
		end
	end
	return schemas
end

M.format_call_block = function(name, args)
	return table.concat({
		"",
		"🔧 tool_call: " .. name,
		"```json",
		vim.json.encode(args or {}),
		"```",
	}, "\n")
end

M.format_result_block = function(name, result)
	return table.concat({
		"",
		"📎 tool_result: " .. name,
		"```text",
		result or "",
		"```",
	}, "\n")
end

local function decode_arguments(call)
	local fn = call and call["function"] or {}
	local raw = fn.arguments or "{}"
	if raw == "" then
		raw = "{}"
	end
	local ok, args = pcall(vim.json.decode, raw)
	if not ok or type(args) ~= "table" then
		return nil, "invalid JSON arguments: " .. tostring(args)
	end
	return args, nil
end

M.execute_call = function(call, agent, ctx, callback)
	local name = call and call["function"] and call["function"].name or ""
	local result = {
		id = call and call.id or "",
		name = name,
		args = nil,
		content = nil,
		is_error = false,
	}

	local resolved, err = M.resolve(agent, ctx.provider)
	if not resolved then
		result.content = "ERROR: " .. err
		result.is_error = true
		callback(result)
		return
	end
	if not list_contains(resolved.enabled, name) then
		result.content = "ERROR: tool is not enabled: " .. tostring(name)
		result.is_error = true
		callback(result)
		return
	end
	local spec = M.builtins[name]
	if not spec then
		result.content = "ERROR: unknown tool: " .. tostring(name)
		result.is_error = true
		callback(result)
		return
	end

	local args
	args, err = decode_arguments(call)
	result.args = args or {}
	if not args then
		result.content = "ERROR: " .. err
		result.is_error = true
		callback(result)
		return
	end
	err = validate_schema(spec.parameters, args, "arguments")
	if err then
		result.content = "ERROR: " .. err
		result.is_error = true
		callback(result)
		return
	end

	confirm(spec, args, resolved.config, function(allowed)
		if not allowed then
			result.content = "ERROR: tool execution denied by user"
			result.is_error = true
			callback(result)
			return
		end
		local exec_ctx = {
			buf = ctx.buf,
			provider = ctx.provider,
			config = resolved.config,
		}
		spec.handler(args, exec_ctx, function(content, handler_err)
			if handler_err then
				result.content = "ERROR: " .. handler_err
				result.is_error = true
			else
				result.content = content or ""
			end
			callback(result)
		end)
	end)
end

M.execute_calls = function(calls, agent, ctx, callback)
	local results = {}
	local index = 1
	local function next_call()
		if index > #calls then
			callback(results)
			return
		end
		M.execute_call(calls[index], agent, ctx, function(result)
			table.insert(results, result)
			index = index + 1
			next_call()
		end)
	end
	next_call()
end

M.setup = function(gp)
	gp.tools = M
	gp.cmd.Tools = function()
		local buf = vim.api.nvim_create_buf(true, true)
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
		local lines = { "# Gp Tools", "" }
		local agent = gp.get_chat_agent()
		local resolved = nil
		local reason = nil
		if agent then
			resolved, reason = M.resolve(agent, agent.provider)
		end
		table.insert(lines, "## Current chat agent")
		table.insert(lines, "")
		table.insert(lines, "- agent: " .. (agent and agent.name or "none"))
		if resolved then
			table.insert(lines, "- enabled: " .. table.concat(resolved.enabled, ", "))
			table.insert(lines, "- stream: " .. tostring(resolved.stream ~= false))
			table.insert(lines, "- workspace_only: " .. tostring(resolved.config.workspace_only ~= false))
		else
			table.insert(lines, "- enabled: none")
			table.insert(lines, "- reason: " .. tostring(reason or "tools disabled"))
		end
		table.insert(lines, "")
		table.insert(lines, "## Built-in tools")
		for _, name in ipairs({ "read", "write", "edit", "run" }) do
			local spec = M.builtins[name]
			table.insert(lines, "")
			table.insert(lines, "### " .. spec.name)
			table.insert(lines, "")
			table.insert(lines, spec.description)
			table.insert(lines, "")
			table.insert(lines, "```json")
			table.insert(lines, vim.json.encode(spec.parameters))
			table.insert(lines, "```")
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end
end

return M
