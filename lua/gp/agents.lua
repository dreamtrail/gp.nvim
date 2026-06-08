--------------------------------------------------------------------------------
-- Agent selection and lookup helpers.
--------------------------------------------------------------------------------

local M = {}

M.setup = function(gp)
	gp.agent_completion = function()
		local buf = vim.api.nvim_get_current_buf()
		local file_name = vim.api.nvim_buf_get_name(buf)
		if gp.not_chat(buf, file_name) == nil then
			return gp._chat_agents
		end
		return gp._command_agents
	end

	gp.cmd.Agent = function(params)
		local agent_name = string.gsub(params.args, "^%s*(.-)%s*$", "%1")
		if agent_name == "" then
			gp.logger.info(" Chat agent: " .. gp._state.chat_agent .. "  |  Command agent: " .. gp._state.command_agent)
			return
		end

		if not gp.agents[agent_name] then
			gp.logger.warning("Unknown agent: " .. agent_name)
			return
		end

		local buf = vim.api.nvim_get_current_buf()
		local file_name = vim.api.nvim_buf_get_name(buf)
		local is_chat = gp.not_chat(buf, file_name) == nil
		if is_chat and gp.agents[agent_name].chat then
			gp.refresh_state({ chat_agent = agent_name })
			gp.logger.info("Chat agent: " .. gp._state.chat_agent)
		elseif gp.agents[agent_name].command then
			gp.refresh_state({ command_agent = agent_name })
			gp.logger.info("Command agent: " .. gp._state.command_agent)
		else
			gp.logger.warning(agent_name .. " is not a valid agent for current buffer")
			gp.refresh_state()
		end
	end

	gp.cmd.NextAgent = function()
		local buf = vim.api.nvim_get_current_buf()
		local file_name = vim.api.nvim_buf_get_name(buf)
		local is_chat = gp.not_chat(buf, file_name) == nil
		local current_agent, agent_list

		if is_chat then
			current_agent = gp._state.chat_agent
			agent_list = gp._chat_agents
		else
			current_agent = gp._state.command_agent
			agent_list = gp._command_agents
		end

		local set_agent = function(agent_name)
			if is_chat then
				gp.refresh_state({ chat_agent = agent_name })
				gp.logger.info("Chat agent: " .. gp._state.chat_agent)
			else
				gp.refresh_state({ command_agent = agent_name })
				gp.logger.info("Command agent: " .. gp._state.command_agent)
			end
		end

		for i, agent_name in ipairs(agent_list) do
			if agent_name == current_agent then
				set_agent(agent_list[i % #agent_list + 1])
				return
			end
		end
		set_agent(agent_list[1])
	end

	---@param name string | nil
	---@return table | nil # { cmd_prefix, name, model, system_prompt, provider}
	gp.get_command_agent = function(name)
		name = name or gp._state.command_agent
		if gp.agents[name] == nil then
			gp.logger.warning("Command Agent " .. name .. " not found, using " .. gp._state.command_agent)
			name = gp._state.command_agent
		end
		local template = gp.config.command_prompt_prefix_template
		local cmd_prefix = gp.render.template(template, { ["{{agent}}"] = name })
		local model = gp.agents[name].model
		local system_prompt = gp.agents[name].system_prompt
		local provider = gp.agents[name].provider
		gp.logger.debug("getting command agent: " .. name)
		return {
			cmd_prefix = cmd_prefix,
			name = name,
			model = model,
			system_prompt = system_prompt,
			provider = provider,
		}
	end

	---@param name string | nil
	---@return table # { cmd_prefix, name, model, system_prompt, provider }
	gp.get_chat_agent = function(name)
		name = name or gp._state.chat_agent
		if gp.agents[name] == nil then
			gp.logger.warning("Chat Agent " .. name .. " not found, using " .. gp._state.chat_agent)
			name = gp._state.chat_agent
		end
		local template = gp.config.command_prompt_prefix_template
		local cmd_prefix = gp.render.template(template, { ["{{agent}}"] = name })
		local model = gp.agents[name].model
		local system_prompt = gp.agents[name].system_prompt
		local provider = gp.agents[name].provider
		local stream = gp.agents[name].stream
		gp.logger.debug("getting chat agent: " .. name)
		return {
			cmd_prefix = cmd_prefix,
			name = name,
			model = model,
			system_prompt = system_prompt,
			provider = provider,
			stream = stream,
		}
	end
end

return M
