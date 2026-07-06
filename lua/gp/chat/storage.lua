--------------------------------------------------------------------------------
-- Chat storage layout and migration helpers.
--------------------------------------------------------------------------------

local M = {}

local timestamp_pattern = "^%d%d%d%d%-%d%d%-%d%d%.%d%d%-%d%d%-%d%d%.%d%d%d%.md$"
local timestamp_legacy_pattern = "^%d%d%d%d%-%d%d%-%d%d%.%d%d%-%d%d%-%d%d%.md$"

local trim = function(value)
	return (value or ""):gsub("^%s*(.-)%s*$", "%1")
end

local slash = function(path)
	return (path or ""):gsub("\\", "/")
end

M.is_timestamp_chat_basename = function(name)
	name = name or ""
	return name:match(timestamp_pattern) ~= nil or name:match(timestamp_legacy_pattern) ~= nil
end

local timestamp_parts = function(name)
	if not M.is_timestamp_chat_basename(name) then
		return nil, nil
	end
	return name:match("^(%d%d%d%d)%-(%d%d)-")
end

M.timestamp_path = function(chat_dir, timestamp)
	local basename = timestamp or ""
	if not basename:match("%.md$") then
		basename = basename .. ".md"
	end
	local year, month = timestamp_parts(basename)
	if not year then
		return nil, nil, nil
	end
	local parent = chat_dir:gsub("/$", "") .. "/" .. year .. "/" .. month
	return parent .. "/" .. basename, parent, basename
end

M.canonical_relative_path = function(path_or_relative)
	local path = slash(path_or_relative)
	local rel = path:match("(%d%d%d%d/%d%d/[^/]+%.md)$")
	if not rel then
		return nil
	end
	local year, month, basename = rel:match("^(%d%d%d%d)/(%d%d)/([^/]+%.md)$")
	local by, bm = timestamp_parts(basename)
	if by == year and bm == month then
		return rel
	end
	return nil
end

M.is_default_finder_query = function(query, default_pattern)
	local q = trim(query)
	return q == "" or q == trim(default_pattern)
end

M.read_topic = function(path)
	local file = io.open(path, "r")
	if not file then
		return ""
	end
	local line = file:read("*l") or ""
	file:close()
	return line
end

M.looks_like_chat_file = function(path)
	local file = io.open(path, "r")
	if not file then
		return false
	end
	local first = file:read("*l") or ""
	if not first:match("^# ") then
		file:close()
		return false
	end
	local header_found = false
	for _ = 2, 10 do
		local line = file:read("*l")
		if not line then
			break
		end
		if line:match("^- file: ") then
			header_found = true
			break
		end
	end
	file:close()
	return header_found
end

M.list_canonical_chats = function(chat_dir)
	local root = chat_dir:gsub("/$", "")
	local chats = {}
	if vim.fn.isdirectory(root) == 0 then
		return chats
	end

	for _, year in ipairs(vim.fn.readdir(root)) do
		local year_dir = root .. "/" .. year
		if year:match("^%d%d%d%d$") and vim.fn.isdirectory(year_dir) == 1 then
			for _, month in ipairs(vim.fn.readdir(year_dir)) do
				local month_dir = year_dir .. "/" .. month
				if month:match("^%d%d$") and vim.fn.isdirectory(month_dir) == 1 then
					for _, name in ipairs(vim.fn.readdir(month_dir)) do
						local rel = year .. "/" .. month .. "/" .. name
						if M.canonical_relative_path(rel) then
							local path = month_dir .. "/" .. name
							if vim.fn.filereadable(path) == 1 then
								table.insert(chats, {
									path = path,
									relative = rel,
									basename = name,
									topic = M.read_topic(path),
								})
							end
						end
					end
				end
			end
		end
	end

	table.sort(chats, function(a, b)
		return a.relative > b.relative
	end)
	return chats
end

local query_words = function(query)
	local words = {}
	for word in trim(query):gmatch("%S+") do
		table.insert(words, word:lower())
	end
	return words
end

local line_matches = function(line, words)
	local lower = line:lower()
	local pos = 1
	for _, word in ipairs(words) do
		local start_pos, end_pos = lower:find(word, pos, true)
		if not start_pos then
			return false
		end
		pos = end_pos + 1
	end
	return true
end

M.search_canonical_chats = function(chat_dir, query)
	local words = query_words(query)
	local results = {}
	if #words == 0 then
		return results, ""
	end

	for _, chat in ipairs(M.list_canonical_chats(chat_dir)) do
		local lnum = 0
		local file = io.open(chat.path, "r")
		if file then
			for line in file:lines() do
				lnum = lnum + 1
				if line_matches(line, words) then
					table.insert(results, {
						path = chat.path,
						relative = chat.relative,
						file = chat.relative,
						lnum = lnum,
						line = line,
					})
				end
			end
			file:close()
		end
	end

	table.sort(results, function(a, b)
		if a.relative == b.relative then
			return a.lnum < b.lnum
		end
		return a.relative > b.relative
	end)
	return results, trim(query):gsub("%s+", ".*"):gsub("^%W*(.-)%W*$", "%1")
end

M.plan_flat_migration = function(chat_dir)
	local root = chat_dir:gsub("/$", "")
	local plan = {}
	if vim.fn.isdirectory(root) == 0 then
		return plan
	end

	for _, name in ipairs(vim.fn.readdir(root)) do
		local source = root .. "/" .. name
		if vim.fn.isdirectory(source) == 0 then
			local item = { source = source, basename = name }
			if name == "last.md" or not name:match("%.md$") then
				item.status = "non_timestamp"
				item.reason = "not a timestamp chat"
			elseif not M.is_timestamp_chat_basename(name) then
				item.status = "non_timestamp"
				item.reason = "not a timestamp chat"
			elseif not M.looks_like_chat_file(source) then
				item.status = "non_chat"
				item.reason = "timestamp markdown is not a gp chat"
			else
				local target, parent = M.timestamp_path(root, name)
				item.target = target
				item.parent = parent
				if vim.fn.filereadable(target) == 1 or vim.fn.isdirectory(target) == 1 then
					item.status = "conflict"
					item.reason = "target exists"
				else
					item.status = "move"
					item.reason = "ready"
				end
			end
			table.insert(plan, item)
		end
	end

	table.sort(plan, function(a, b)
		return a.basename > b.basename
	end)
	return plan
end

M.summarize_plan = function(plan)
	local summary = { move = 0, non_chat = 0, non_timestamp = 0, conflict = 0, error = 0, skipped = 0 }
	for _, item in ipairs(plan or {}) do
		local status = item.status or "error"
		summary[status] = (summary[status] or 0) + 1
		if status ~= "move" then
			summary.skipped = summary.skipped + 1
		end
	end
	return summary
end

M.apply_flat_migration = function(chat_dir, plan)
	local result = { moved = {}, skipped = {}, errors = {} }
	for _, item in ipairs(plan or {}) do
		if item.status ~= "move" then
			table.insert(result.skipped, item)
		elseif vim.fn.filereadable(item.target) == 1 or vim.fn.isdirectory(item.target) == 1 then
			local conflict = vim.deepcopy(item)
			conflict.status = "conflict"
			conflict.reason = "target exists"
			table.insert(result.skipped, conflict)
		else
			vim.fn.mkdir(item.parent, "p")
			local ok, err = os.rename(item.source, item.target)
			if ok then
				table.insert(result.moved, item)
			else
				local failed = vim.deepcopy(item)
				failed.status = "error"
				failed.reason = err or "rename failed"
				table.insert(result.errors, failed)
			end
		end
	end
	return result
end

return M
