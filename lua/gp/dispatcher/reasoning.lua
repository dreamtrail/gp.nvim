--------------------------------------------------------------------------------
-- Provider/model classification helpers for dispatcher.
--------------------------------------------------------------------------------

local M = {}

---@param model string
---@return boolean
M.is_openai_reason_model = function(model)
	return model:match("^o%d+%p?") ~= nil or model:match("^openai/o%d+%p?") ~= nil
end

M.is_google_provider = function(provider)
	return provider:match("^google") ~= nil or provider:match("^vertex") ~= nil
end

---@param model string
---@return integer | nil
M.is_other_reason_model = function(model)
	model = model:lower()
	return model:find("deepseek")
		or model:find("qwen") -- qwen is a reason model
		or model:find("k2") -- k2 is a reason model
		or model:find("grok%-") -- grok is a reason model
		or model:find("glm%-") -- glm-4.5 is a reason model
		or model:find("gpt%-oss") -- gpt-oss is a reason model
end

return M
