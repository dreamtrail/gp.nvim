-- Gp (GPT prompt) lua plugin for Neovim
-- https://github.com/Robitx/gp.nvim/

--------------------------------------------------------------------------------
-- Module structure
--------------------------------------------------------------------------------
local config = require("gp.config")

local M = {
	_Name = "Gp", -- plugin name
	_state = {}, -- table of state variables
	agents = {}, -- table of agents
	cmd = {}, -- default command functions
	config = {}, -- config variables
	hooks = {}, -- user defined command functions
	defaults = require("gp.defaults"), -- some useful defaults
	deprecator = require("gp.deprecator"), -- handle deprecated options
	dispatcher = require("gp.dispatcher"), -- handle communication with LLM providers
	helpers = require("gp.helper"), -- helper functions
	imager = require("gp.imager"), -- image generation module
	logger = require("gp.logger"), -- logger module
	render = require("gp.render"), -- render module
	spinner = require("gp.spinner"), -- spinner module
	tasker = require("gp.tasker"), -- tasker module
	vault = require("gp.vault"), -- handles secrets
	whisper = require("gp.whisper"), -- whisper module
}

--------------------------------------------------------------------------------
-- Extracted module wiring
--------------------------------------------------------------------------------
require("gp.ui.toggle").setup(M)
require("gp.ui.buffer").setup(M)
require("gp.chat").setup(M)
require("gp.agents").setup(M)
require("gp.context").setup(M)
require("gp.chat.respond").setup(M)
require("gp.tools").setup(M)

-- setup function
M._setup_called = false
---@param opts GpConfig? # table with options
M.setup = function(opts)
	M._setup_called = true

	math.randomseed(os.time())

	-- make sure opts is a table
	opts = opts or {}
	if type(opts) ~= "table" then
		M.logger.error(string.format("setup() expects table, but got %s:\n%s", type(opts), vim.inspect(opts)))
		opts = {}
	end

	-- reset M.config
	M.config = vim.deepcopy(config)

	local curl_params = opts.curl_params or M.config.curl_params
	local cmd_prefix = opts.cmd_prefix or M.config.cmd_prefix
	local state_dir = opts.state_dir or M.config.state_dir
	local openai_api_key = opts.openai_api_key or M.config.openai_api_key

	M.logger.setup(opts.log_file or M.config.log_file, opts.log_sensitive)

	M.vault.setup({ state_dir = state_dir, curl_params = curl_params })

	M.vault.add_secret("openai_api_key", openai_api_key)
	M.config.openai_api_key = nil
	opts.openai_api_key = nil

	M.dispatcher.setup({ providers = opts.providers, curl_params = curl_params })
	M.config.providers = nil
	opts.providers = nil

	local image_opts = opts.image or {}
	image_opts.state_dir = state_dir
	image_opts.cmd_prefix = cmd_prefix
	image_opts.secret = image_opts.secret or openai_api_key
	M.imager.setup(image_opts)
	M.config.image = nil
	opts.image = nil

	local whisper_opts = opts.whisper or {}
	whisper_opts.style_popup_border = opts.style_popup_border or M.config.style_popup_border
	whisper_opts.curl_params = curl_params
	whisper_opts.cmd_prefix = cmd_prefix
	M.whisper.setup(whisper_opts)
	M.config.whisper = nil
	opts.whisper = nil

	-- merge nested tables
	local mergeTables = { "hooks", "agents" }
	for _, tbl in ipairs(mergeTables) do
		M[tbl] = M[tbl] or {}
		---@diagnostic disable-next-line
		for k, v in pairs(M.config[tbl]) do
			if tbl == "hooks" then
				M[tbl][k] = v
			elseif tbl == "agents" then
				---@diagnostic disable-next-line
				M[tbl][v.name] = v
			end
		end
		M.config[tbl] = nil

		opts[tbl] = opts[tbl] or {}
		for k, v in pairs(opts[tbl]) do
			if tbl == "hooks" then
				M[tbl][k] = v
			elseif tbl == "agents" then
				M[tbl][v.name] = v
			end
		end
		opts[tbl] = nil
	end

	for k, v in pairs(opts) do
		if M.deprecator.is_valid(k, v) then
			M.config[k] = v
		end
	end
	M.deprecator.report()

	-- make sure _dirs exists
	for k, v in pairs(M.config) do
		if k:match("_dir$") and type(v) == "string" then
			M.config[k] = M.helpers.prepare_dir(v, k)
		end
	end

	-- remove invalid agents
	for name, agent in pairs(M.agents) do
		if type(agent) ~= "table" or agent.disable then
			M.agents[name] = nil
		elseif not agent.model then
			M.logger.warning(
				"Agent "
					.. name
					.. " is missing model\n"
					.. "If you want to disable an agent, use: { name = '"
					.. name
					.. "', disable = true },"
			)
			M.agents[name] = nil
		end
	end

	-- prepare agent completions
	M._chat_agents = {}
	M._command_agents = {}
	for name, agent in pairs(M.agents) do
		M.agents[name].provider = M.agents[name].provider or "openai"

		if M.dispatcher.providers[M.agents[name].provider] then
			if agent.command then
				table.insert(M._command_agents, name)
			end
			if agent.chat then
				table.insert(M._chat_agents, name)
			end
		else
			M.agents[name] = nil
		end
	end
	table.sort(M._chat_agents)
	table.sort(M._command_agents)

	M.refresh_state()

	if M.config.default_command_agent then
		M.refresh_state({ command_agent = M.config.default_command_agent })
	end

	if M.config.default_chat_agent then
		M.refresh_state({ chat_agent = M.config.default_chat_agent })
	end

	-- register user commands
	for hook, _ in pairs(M.hooks) do
		M.helpers.create_user_command(M.config.cmd_prefix .. hook, function(params)
			if M.hooks[hook] ~= nil then
				M.refresh_state()
				M.logger.debug("running hook: " .. hook)
				return M.hooks[hook](M, params)
			end
			M.logger.error("The hook '" .. hook .. "' does not exist.")
		end)
	end

	local completions = {
		ChatNew = { "popup", "split", "vsplit", "tabnew" },
		ChatPaste = { "popup", "split", "vsplit", "tabnew" },
		ChatToggle = { "popup", "split", "vsplit", "tabnew" },
		ChatMigrate = { "dry-run", "apply" },
		Context = { "popup", "split", "vsplit", "tabnew" },
		Agent = M.agent_completion,
	}

	-- register default commands
	for cmd, _ in pairs(M.cmd) do
		if M.hooks[cmd] == nil then
			M.helpers.create_user_command(M.config.cmd_prefix .. cmd, function(params)
				M.logger.debug("running command: " .. cmd)
				M.refresh_state()
				M.cmd[cmd](params)
			end, completions[cmd])
		end
	end

	M.buf_handler()

	if vim.fn.executable("curl") == 0 then
		M.logger.error("curl is not installed, run :checkhealth gp")
	end

	M.logger.debug("setup finished")
end

--------------------------------------------------------------------------------
-- Extracted facade extensions
--------------------------------------------------------------------------------
require("gp.state").setup(M)
require("gp.prompt").setup(M)
require("gp.chat.finder").setup(M)
require("gp.chat.migration").setup(M)

return M
