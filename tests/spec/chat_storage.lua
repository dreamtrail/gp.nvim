local storage = require("gp.chat.storage")

local function with_temp_chat_dir(fn)
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local old_chat_dir = gp.config.chat_dir
	gp.config.chat_dir = vim.fn.resolve(dir)
	local ok, err = xpcall(function()
		fn(gp.config.chat_dir)
	end, debug.traceback)
	gp.config.chat_dir = old_chat_dir
	vim.fn.delete(dir, "rf")
	if not ok then
		error(err, 0)
	end
end

local function chat_text(topic, basename)
	return table.concat({
		"# " .. topic,
		"- file: " .. basename,
		"- provider: openai",
		"- model: gpt-test",
		"---",
		"",
		gp.config.chat_user_prefix .. "hello " .. topic,
	}, "\n")
end

local function write_chat(path, topic)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	write_binary(path, chat_text(topic, vim.fn.fnamemodify(path, ":t")))
end

test("chat storage builds canonical year month paths", function()
	local path, parent, basename = storage.timestamp_path("/tmp/gp/chats", "2026-07-06.14-23-01.123")
	assert_eq(path, "/tmp/gp/chats/2026/07/2026-07-06.14-23-01.123.md", "timestamp path")
	assert_eq(parent, "/tmp/gp/chats/2026/07", "timestamp parent")
	assert_eq(basename, "2026-07-06.14-23-01.123.md", "timestamp basename")
	assert_true(storage.is_timestamp_chat_basename("2026-07-06.14-23-01.md"), "legacy no-ms timestamp accepted")
	assert_eq(storage.canonical_relative_path("2026/07/2026-07-06.14-23-01.123.md"), "2026/07/2026-07-06.14-23-01.123.md", "canonical relative path")
	assert_eq(storage.canonical_relative_path("2026/08/2026-07-06.14-23-01.123.md"), nil, "canonical relative month must match filename")
end)

test("ChatNew creates chats in canonical year month layout", function()
	with_temp_chat_dir(function(dir)
		with_stub(gp.logger, "now", function()
			return "2026-07-06.14-23-01.123"
		end, function()
			local buf = gp.new_chat({ args = "", range = 0, line1 = 1, line2 = 1 }, false)
			local name = vim.api.nvim_buf_get_name(buf)
			assert_eq(name, dir .. "/2026/07/2026-07-06.14-23-01.123.md", "new chat path")
			assert_true(vim.fn.isdirectory(dir .. "/2026/07") == 1, "new chat parent exists")
			vim.api.nvim_buf_delete(buf, { force = true })
		end)
	end)
end)

test("canonical listing and search ignore flat legacy chats", function()
	with_temp_chat_dir(function(dir)
		local nested = dir .. "/2026/07/2026-07-06.14-23-01.123.md"
		local flat = dir .. "/2026-07-06.15-00-00.123.md"
		write_chat(nested, "Nested Topic")
		write_chat(flat, "Flat Topic")

		local chats = storage.list_canonical_chats(dir)
		assert_eq(#chats, 1, "only nested canonical chat listed")
		assert_eq(chats[1].relative, "2026/07/2026-07-06.14-23-01.123.md", "nested relative path preserved")

		local results = storage.search_canonical_chats(dir, "Flat")
		assert_eq(#results, 0, "custom search ignores flat legacy chats")
		results = storage.search_canonical_chats(dir, "Nested")
		assert_true(#results > 0, "custom search finds nested canonical chats")
		for _, result in ipairs(results) do
			assert_eq(result.path, nested, "search result preserves absolute nested path")
		end
	end)
end)

test("finder collection uses default fast path and canonical-only search", function()
	with_temp_chat_dir(function(dir)
		local nested = dir .. "/2026/07/2026-07-06.14-23-01.123.md"
		local flat = dir .. "/2026-07-06.15-00-00.123.md"
		write_chat(nested, "Default Topic")
		write_chat(flat, "Flat Topic")

		with_stub(gp.tasker, "grep_directory", function()
			error("finder default path must not call grep_directory")
		end, function()
			local collected = gp._chat_finder_collect(dir, gp.config.chat_finder_pattern, gp.config.chat_finder_pattern)
			assert_eq(#collected.files, 1, "default finder lists only canonical chats")
			assert_eq(collected.files[1], nested, "default finder stores absolute nested path")
			assert_true(collected.picker_lines[1]:match("2026/07/2026%-07%-06"), "default finder displays relative nested path")
		end)

		local collected = gp._chat_finder_collect(dir, "Flat", gp.config.chat_finder_pattern)
		assert_eq(#collected.files, 0, "finder custom search excludes flat chats")
		collected = gp._chat_finder_collect(dir, "Default", gp.config.chat_finder_pattern)
		assert_true(#collected.files > 0, "finder custom search includes canonical chats")
	end)
end)

test("default finder query detection covers empty whitespace and configured pattern", function()
	assert_true(storage.is_default_finder_query("", "topic "), "empty query is default")
	assert_true(storage.is_default_finder_query("   ", "topic "), "whitespace query is default")
	assert_true(storage.is_default_finder_query(" topic ", "topic "), "trimmed configured pattern is default")
	assert_eq(storage.is_default_finder_query("topic extra", "topic "), false, "custom query is not default")
end)

test("custom search with no canonical chats returns no results", function()
	with_temp_chat_dir(function(dir)
		local results = storage.search_canonical_chats(dir, "anything")
		assert_eq(#results, 0, "empty canonical search returns no results")
	end)
end)

test("migration dry-run and apply move only chat-shaped flat timestamp files", function()
	with_temp_chat_dir(function(dir)
		local ms = dir .. "/2026-07-06.14-23-01.123.md"
		local no_ms = dir .. "/2026-07-07.14-23-01.md"
		local non_chat = dir .. "/2026-07-08.14-23-01.123.md"
		local non_timestamp = dir .. "/notes.md"
		local conflict_source = dir .. "/2026-07-09.14-23-01.123.md"
		local conflict_target = dir .. "/2026/07/2026-07-09.14-23-01.123.md"
		write_chat(ms, "Millisecond Topic")
		write_chat(no_ms, "No Millisecond Topic")
		write_binary(non_chat, "# Not a gp chat\nno file header\n")
		write_binary(non_timestamp, chat_text("Notes", "notes.md"))
		write_chat(conflict_source, "Conflict Source")
		write_chat(conflict_target, "Conflict Target")

		local plan = storage.plan_flat_migration(dir)
		local summary = storage.summarize_plan(plan)
		assert_eq(summary.move, 2, "dry-run plans movable chat-shaped timestamp files")
		assert_eq(summary.non_chat, 1, "dry-run skips timestamp non-chat markdown")
		assert_eq(summary.non_timestamp, 1, "dry-run skips non-timestamp markdown")
		assert_eq(summary.conflict, 1, "dry-run detects target conflicts")

		local result = storage.apply_flat_migration(dir, plan)
		assert_eq(#result.moved, 2, "apply moves eligible chats")
		assert_true(vim.fn.filereadable(dir .. "/2026/07/2026-07-06.14-23-01.123.md") == 1, "ms chat migrated")
		assert_true(vim.fn.filereadable(dir .. "/2026/07/2026-07-07.14-23-01.md") == 1, "no-ms chat migrated")
		assert_true(vim.fn.filereadable(non_chat) == 1, "non-chat file remains flat")
		assert_true(vim.fn.filereadable(conflict_source) == 1, "conflict source remains flat")

		local chats = storage.list_canonical_chats(dir)
		local found_no_ms = false
		for _, chat in ipairs(chats) do
			if chat.relative == "2026/07/2026-07-07.14-23-01.md" then
				found_no_ms = true
			end
		end
		assert_true(found_no_ms, "migrated no-ms chat appears in canonical listing")

		local second = storage.apply_flat_migration(dir, storage.plan_flat_migration(dir))
		assert_eq(#second.moved, 0, "migration is idempotent")
	end)
end)

test("ChatMigrate dry-run is default and makes no changes", function()
	with_temp_chat_dir(function(dir)
		local source = dir .. "/2026-07-06.14-23-01.123.md"
		local target = dir .. "/2026/07/2026-07-06.14-23-01.123.md"
		write_chat(source, "Dry Run Topic")
		with_stub(vim.ui, "input", function()
			error("dry-run must not ask for confirmation")
		end, function()
			with_stub(vim, "notify", function() end, function()
				gp.cmd.ChatMigrate({ args = "" })
			end)
		end)
		assert_true(vim.fn.filereadable(source) == 1, "dry-run leaves source in place")
		assert_true(vim.fn.filereadable(target) == 0, "dry-run does not create target")
	end)
end)

test("ChatMigrate invalid args make no changes", function()
	with_temp_chat_dir(function(dir)
		local source = dir .. "/2026-07-06.14-23-01.123.md"
		write_chat(source, "Invalid Arg Topic")
		local warnings = 0
		with_stub(gp.logger, "warning", function()
			warnings = warnings + 1
		end, function()
			with_stub(vim, "notify", function() end, function()
				gp.cmd.ChatMigrate({ args = "bad" })
			end)
		end)
		assert_eq(warnings, 1, "invalid migration arg warns")
		assert_true(vim.fn.filereadable(source) == 1, "invalid arg leaves source in place")
		assert_true(vim.fn.filereadable(dir .. "/2026/07/2026-07-06.14-23-01.123.md") == 0, "invalid arg does not migrate")
	end)
end)

test("ChatMigrate apply cancellation makes no changes", function()
	with_temp_chat_dir(function(dir)
		local source = dir .. "/2026-07-06.14-23-01.123.md"
		local target = dir .. "/2026/07/2026-07-06.14-23-01.123.md"
		write_chat(source, "Cancel Topic")
		with_stub(vim.ui, "input", function(_, callback)
			callback("n")
		end, function()
			with_stub(vim, "notify", function() end, function()
				gp.cmd.ChatMigrate({ args = "apply" })
			end)
		end)
		assert_true(vim.fn.filereadable(source) == 1, "cancel leaves source in place")
		assert_true(vim.fn.filereadable(target) == 0, "cancel does not migrate")
	end)
end)

test("ChatMigrate apply confirms moves and updates last_chat", function()
	with_temp_chat_dir(function(dir)
		local source = dir .. "/2026-07-06.14-23-01.123.md"
		local target = dir .. "/2026/07/2026-07-06.14-23-01.123.md"
		write_chat(source, "Last Chat Topic")
		gp.refresh_state({ last_chat = source })
		with_stub(vim.ui, "input", function(_, callback)
			callback("y")
		end, function()
			with_stub(vim, "notify", function() end, function()
				gp.cmd.ChatMigrate({ args = "apply" })
			end)
		end)
		assert_true(vim.fn.filereadable(target) == 1, "apply moved source")
		assert_eq(gp._state.last_chat, target, "apply updates last_chat when moved")
	end)
end)

test("usage docs warn to close legacy chat buffers before migration", function()
	local file = assert(io.open("docs/USAGE.md", "r"))
	local content = file:read("*a")
	file:close()
	assert_true(content:find("close legacy chat buffers before applying migration", 1, true), "usage docs warn about legacy buffers")
end)
