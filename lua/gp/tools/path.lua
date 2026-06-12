--------------------------------------------------------------------------------
-- Workspace/path helpers for native tools.
--------------------------------------------------------------------------------

local M = {}

local uv = vim.uv or vim.loop

local function has_nul(value)
	return type(value) == "string" and value:find("%z") ~= nil
end

local function normalize_absolute(path)
	return vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
end

local function is_within(root, path)
	root = normalize_absolute(root)
	path = normalize_absolute(path)
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function find_git_root_from_dir(dir)
	dir = normalize_absolute(dir)
	for _ = 0, 1000 do
		if vim.fn.isdirectory(dir .. "/.git") == 1 then
			return dir
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
	return ""
end

---@param opts table | nil
---@return string
M.workspace_root = function(opts)
	opts = opts or {}
	if opts.workspace_root and opts.workspace_root ~= "" then
		return normalize_absolute(vim.fn.expand(opts.workspace_root))
	end

	local cwd = vim.fn.getcwd()
	local git_root = find_git_root_from_dir(cwd)
	if git_root ~= "" then
		return git_root
	end
	return normalize_absolute(cwd)
end

---@param path string
---@param opts table | nil
---@param for_new boolean | nil
---@return table | nil info
---@return string | nil error
M.inspect = function(path, opts, for_new)
	opts = opts or {}
	if type(path) ~= "string" or path == "" then
		return nil, "path must be a non-empty string"
	end
	if has_nul(path) then
		return nil, "path contains NUL byte"
	end

	local root = M.workspace_root(opts)
	local expanded = vim.fn.expand(path)
	local absolute
	if expanded:sub(1, 1) == "/" or expanded:match("^%a:[/\\]") then
		absolute = normalize_absolute(expanded)
	else
		absolute = normalize_absolute(root .. "/" .. expanded)
	end
	local outside = not is_within(root, absolute)

	if for_new then
		local real_target = uv.fs_realpath(absolute)
		if real_target then
			real_target = normalize_absolute(real_target)
			outside = outside or not is_within(root, real_target)
			return { root = root, requested = path, absolute = absolute, resolved = real_target, outside = outside }, nil
		end
		local parent = vim.fn.fnamemodify(absolute, ":h")
		local existing_parent = parent
		while vim.fn.isdirectory(existing_parent) == 0 do
			local next_parent = vim.fn.fnamemodify(existing_parent, ":h")
			if next_parent == existing_parent then
				break
			end
			existing_parent = next_parent
		end
		local real_parent = uv.fs_realpath(existing_parent)
		if real_parent then
			real_parent = normalize_absolute(real_parent)
			outside = outside or not is_within(root, real_parent)
		end
		return {
			root = root,
			requested = path,
			absolute = absolute,
			resolved = absolute,
			real_parent = real_parent,
			outside = outside,
		}, nil
	end

	local real = uv.fs_realpath(absolute)
	if real then
		real = normalize_absolute(real)
		outside = outside or not is_within(root, real)
		return { root = root, requested = path, absolute = absolute, resolved = real, outside = outside }, nil
	end

	return { root = root, requested = path, absolute = absolute, resolved = absolute, outside = outside }, nil
end

---@param path string
---@param opts table | nil
---@param for_new boolean | nil
---@return string | nil absolute_path
---@return string | nil error
M.resolve = function(path, opts, for_new)
	opts = opts or {}
	local info, err = M.inspect(path, opts, for_new)
	if not info then
		return nil, err
	end
	local workspace_only = opts.workspace_only ~= false
	if workspace_only and info.outside then
		if for_new and info.real_parent and not is_within(info.root, info.real_parent) then
			return nil, "path parent escapes workspace root: " .. path
		end
		return nil, "path escapes workspace root: " .. path
	end
	return info.resolved, nil
end

M.is_within = is_within

return M
