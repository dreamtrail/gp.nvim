test("built-in tools enforce workspace limits confirmation and file edits", function()
	local agent = gp.get_chat_agent("ToolAgent")
	vim.fn.writefile({ "alpha", "beta" }, workspace .. "/sample.txt")

	local read_result = exec_tool(gp, tool_call("r1", "read", [[{"path":"sample.txt"}]]), agent)
	assert_true(read_result.content:match("path: sample.txt"), "read returns path metadata")
	assert_true(read_result.content:match("content:\nalpha\nbeta"), "read returns content")

	vim.fn.writefile({ "abcdef" }, workspace .. "/limited.txt")
	local limited_agent = vim.deepcopy(agent)
	limited_agent.tools.read = { max_bytes = 4, max_lines = 2000 }
	local limited_read = exec_tool(gp, tool_call("r2", "read", [[{"path":"limited.txt"}]]), limited_agent)
	assert_true(limited_read.content:match("bytes: 4"), "read bytes reports returned bytes")
	assert_true(limited_read.content:match("total_bytes: 7"), "read reports total file bytes")
	assert_true(limited_read.content:match("truncated: true"), "read reports truncation")
	assert_true(limited_read.content:match("max_bytes: 4"), "read reports byte limit for truncated content")
	assert_true(limited_read.content:match("max_lines: 2000"), "read reports line limit")

	local write_result = exec_tool(gp, tool_call("w1", "write", [[{"path":"dir/new.txt","content":"hello"}]]), agent)
	assert_true(write_result.content:match("bytes_written: 5"), "write returns byte summary")
	assert_eq(vim.fn.readfile(workspace .. "/dir/new.txt")[1], "hello", "write creates file and parents")

	local edit_result = exec_tool(gp, tool_call("e1", "edit", [[{"path":"sample.txt","edits":[{"old_text":"alpha","new_text":"ALPHA"},{"old_text":"beta","new_text":"BETA"}]}]]), agent)
	assert_true(edit_result.content:match("edits_applied: 2"), "edit returns edit count")
	assert_eq(table.concat(vim.fn.readfile(workspace .. "/sample.txt"), "\n"), "ALPHA\nBETA", "edit applies replacements")

	local escape = exec_tool(gp, tool_call("bad", "read", [[{"path":"../escape.txt"}]]), agent)
	assert_true(escape.is_error, "workspace escape rejected")
	assert_true(escape.content:match("escapes workspace root"), "workspace escape error returned")

	local invalid = exec_tool(gp, tool_call("badjson", "read", "{"), agent)
	assert_true(invalid.is_error, "invalid JSON args rejected")
	assert_true(invalid.content:match("invalid JSON"), "invalid JSON error returned")

	local deny_agent = vim.deepcopy(agent)
	deny_agent.tools.write.confirm = true
	local denied
	with_stub(vim.ui, "select", function(_, _, cb)
		cb("Deny")
	end, function()
		denied = exec_tool(gp, tool_call("deny", "write", [[{"path":"denied.txt","content":"no"}]]), deny_agent)
	end)
	assert_true(denied.is_error, "denied confirmation returns error")
	assert_true(denied.content:match("denied"), "denial content returned")

	local allow_agent = vim.deepcopy(agent)
	allow_agent.tools.write.confirm = true
	local allowed
	with_stub(vim.ui, "select", function(_, _, cb)
		cb("Run once")
	end, function()
		allowed = exec_tool(gp, tool_call("allow", "write", [[{"path":"allowed.txt","content":"yes"}]]), allow_agent)
	end)
	assert_true(not allowed.is_error, "Run once confirmation allows execution")
	assert_eq(vim.fn.readfile(workspace .. "/allowed.txt")[1], "yes", "confirmed write creates file")

	local run_result = exec_tool(gp, tool_call("run", "run", [[{"cmd":"printf","args":["hi"]}]]), agent)
	assert_true(run_result.content:match("exit_code: 0"), "run returns exit code")
	assert_true(run_result.content:match("stdout:\nhi"), "run returns stdout")

	local printf_path = vim.fn.exepath("printf")
	assert_true(printf_path ~= "", "printf executable exists")
	local denied_abs
	with_stub(vim.ui, "select", function(_, _, cb)
		cb("Deny")
	end, function()
		denied_abs = exec_tool(gp, tool_call("runabsdeny", "run", vim.json.encode({ cmd = printf_path, args = { "blocked" } })), agent)
	end)
	assert_true(denied_abs.is_error, "absolute command with bare allowlist still requires confirmation")
	local exact_path_agent = vim.deepcopy(agent)
	exact_path_agent.tools.run.allowed_commands = { printf_path }
	local run_abs = exec_tool(gp, tool_call("runabs", "run", vim.json.encode({ cmd = printf_path, args = { "ok" } })), exact_path_agent)
	assert_true(run_abs.content:match("exit_code: 0"), "exact absolute allowlist bypasses confirmation")
	assert_true(run_abs.content:match("stdout:\nok"), "absolute allowed command runs")

	local process = require("gp.tools.process")
	local captured_timeout = nil
	local clamp_agent = vim.deepcopy(agent)
	clamp_agent.tools.run.timeout_ms = 123
	clamp_agent.tools.run.allowed_commands = { "printf" }
	with_stub(process, "run", function(opts, callback)
		captured_timeout = opts.timeout_ms
		callback({ exit_code = 0, timed_out = false, stdout = "", stderr = "", stdout_truncated = false, stderr_truncated = false })
	end, function()
		local clamped = exec_tool(gp, tool_call("clamp", "run", [[{"cmd":"printf","args":["x"],"timeout_ms":9999}]]), clamp_agent)
		assert_true(not clamped.is_error, "clamped timeout command succeeds")
	end)
	assert_eq(captured_timeout, 123, "model timeout_ms is clamped to configured maximum")

	local malformed_timeout = nil
	local malformed_agent = vim.deepcopy(agent)
	malformed_agent.tools.run.timeout_ms = "not-a-number"
	malformed_agent.tools.run.allowed_commands = { "printf" }
	with_stub(process, "run", function(opts, callback)
		malformed_timeout = opts.timeout_ms
		callback({ exit_code = 0, timed_out = false, stdout = "", stderr = "", stdout_truncated = false, stderr_truncated = false })
	end, function()
		local fallback = exec_tool(gp, tool_call("malformed-timeout", "run", [[{"cmd":"printf","args":["x"]}]]), malformed_agent)
		assert_true(not fallback.is_error, "malformed configured timeout falls back without error")
	end)
	assert_eq(malformed_timeout, 30000, "malformed configured timeout_ms falls back to default maximum")

	local timeout_agent = vim.deepcopy(agent)
	timeout_agent.tools.run.allowed_commands = { "sleep" }
	local timed = exec_tool(gp, tool_call("timeout", "run", [[{"cmd":"sleep","args":["1"],"timeout_ms":0}]]), timeout_agent)
	assert_true(timed.content:match("timed_out: true"), "timeout_ms zero is clamped and enforced")
end)

test("default confirmation gates write edit and non-allowlisted run", function()
	local agent = gp.get_chat_agent("ToolAgent")
	local default_agent = vim.deepcopy(agent)
	default_agent.tools.write = nil
	default_agent.tools.edit = nil
	default_agent.tools.run = { timeout_ms = 1000, max_output_bytes = 1024 }
	vim.fn.writefile({ "before" }, workspace .. "/confirm-edit.txt")

	local prompts = 0
	with_stub(vim.ui, "select", function(_, _, cb)
		prompts = prompts + 1
		cb("Deny")
	end, function()
		local denied_write = exec_tool(gp, tool_call("dw", "write", [[{"path":"confirm-write.txt","content":"no"}]]), default_agent)
		assert_true(denied_write.is_error, "default write confirmation can deny")
		assert_eq(vim.fn.filereadable(workspace .. "/confirm-write.txt"), 0, "denied write does not create file")

		local denied_edit = exec_tool(gp, tool_call("de", "edit", [[{"path":"confirm-edit.txt","edits":[{"old_text":"before","new_text":"after"}]}]]), default_agent)
		assert_true(denied_edit.is_error, "default edit confirmation can deny")
		assert_eq(vim.fn.readfile(workspace .. "/confirm-edit.txt")[1], "before", "denied edit does not modify file")

		local denied_run = exec_tool(gp, tool_call("dr", "run", [[{"cmd":"printf","args":["no"]}]]), default_agent)
		assert_true(denied_run.is_error, "non-allowlisted run confirmation can deny")
		assert_true(denied_run.content:match("denied"), "denied run reports denial")
	end)
	assert_eq(prompts, 3, "write edit and non-allowlisted run each prompt by default")

	with_stub(vim.ui, "select", function(_, _, cb)
		cb("Run once")
	end, function()
		local allowed_write = exec_tool(gp, tool_call("aw", "write", [[{"path":"confirm-allow.txt","content":"yes"}]]), default_agent)
		assert_true(not allowed_write.is_error, "Run once allows default-confirmed write")
		assert_eq(vim.fn.readfile(workspace .. "/confirm-allow.txt")[1], "yes", "Run once write created file")
	end)
end)

test("workspace validation covers absolute paths cwd symlinks and workspace override", function()
	local agent = gp.get_chat_agent("ToolAgent")
	local outside = vim.fn.tempname()
	vim.fn.mkdir(outside, "p")
	vim.fn.writefile({ "outside content" }, outside .. "/outside.txt")

	local abs_escape = exec_tool(gp, tool_call("abs", "read", vim.json.encode({ path = outside .. "/outside.txt" })), agent)
	assert_true(abs_escape.is_error, "absolute path outside workspace rejected")
	assert_true(abs_escape.content:match("escapes workspace root"), "absolute path escape reports workspace error")

	local cwd_escape = exec_tool(gp, tool_call("cwd", "run", vim.json.encode({ cmd = "printf", args = { "x" }, cwd = outside })), agent)
	assert_true(cwd_escape.is_error, "run cwd outside workspace rejected when workspace_only=true")
	assert_true(cwd_escape.content:match("escapes workspace root"), "run cwd escape reports workspace error")

	local open_agent = vim.deepcopy(agent)
	open_agent.tools.workspace_only = false
	open_agent.tools.run.allowed_commands = { "pwd" }
	local outside_read = exec_tool(gp, tool_call("or", "read", vim.json.encode({ path = outside .. "/outside.txt" })), open_agent)
	assert_true(not outside_read.is_error, "workspace_only=false allows controlled outside read")
	assert_true(outside_read.content:match("outside content"), "outside read returns content")
	local outside_cwd = exec_tool(gp, tool_call("oc", "run", vim.json.encode({ cmd = "pwd", args = {}, cwd = outside })), open_agent)
	assert_true(outside_cwd.content:match("exit_code: 0"), "workspace_only=false allows outside cwd")
	assert_true(outside_cwd.content:match("stdout:\n" .. vim.pesc(vim.fn.fnamemodify(outside, ":p"):gsub("/$", ""))), "outside cwd command ran in requested directory")

	local uv = vim.uv or vim.loop
	local link = workspace .. "/outside-link.txt"
	local ok = pcall(function()
		uv.fs_symlink(outside .. "/outside.txt", link)
	end)
	if ok and vim.fn.filereadable(link) == 1 then
		local symlink_read = exec_tool(gp, tool_call("sl", "read", [[{"path":"outside-link.txt"}]]), agent)
		assert_true(symlink_read.is_error, "symlink to outside workspace rejected")
		local symlink_write = exec_tool(gp, tool_call("sw", "write", [[{"path":"outside-link.txt","content":"bad","overwrite":true}]]), agent)
		assert_true(symlink_write.is_error, "write through existing outside symlink rejected")
	else
		print("skip - symlink escape fixture unsupported")
	end
	vim.fn.delete(outside, "rf")
end)

test("write and edit revalidate target paths before atomic rename", function()
	local agent = gp.get_chat_agent("ToolAgent")
	local path_tools = require("gp.tools.path")
	local original_resolve = path_tools.resolve
	local write_calls = 0
	local denied_write
	with_stub(path_tools, "resolve", function(requested, opts, for_new)
		write_calls = write_calls + 1
		if write_calls == 1 then
			return workspace .. "/revalidate-write.txt", nil
		end
		assert_eq(requested, "revalidate-write.txt", "write revalidates original requested path")
		assert_eq(for_new, true, "write revalidates as new/write target")
		return nil, "path escapes workspace root: revalidate-write.txt"
	end, function()
		denied_write = exec_tool(gp, tool_call("wrv", "write", [[{"path":"revalidate-write.txt","content":"blocked"}]]), agent)
	end)
	assert_true(denied_write.is_error, "write revalidation failure rejects rename")
	assert_true(denied_write.content:match("target path revalidation failed"), "write revalidation error is visible")
	assert_eq(vim.fn.filereadable(workspace .. "/revalidate-write.txt"), 0, "write revalidation failure does not create target")

	vim.fn.writefile({ "before" }, workspace .. "/revalidate-edit.txt")
	local edit_calls = 0
	local denied_edit
	with_stub(path_tools, "resolve", function(requested, opts, for_new)
		edit_calls = edit_calls + 1
		if edit_calls == 1 then
			return original_resolve(requested, opts, for_new)
		end
		assert_eq(requested, "revalidate-edit.txt", "edit revalidates original requested path")
		assert_eq(for_new, false, "edit revalidates existing target")
		return nil, "path escapes workspace root: revalidate-edit.txt"
	end, function()
		denied_edit = exec_tool(gp, tool_call("erv", "edit", [[{"path":"revalidate-edit.txt","edits":[{"old_text":"before","new_text":"after"}]}]]), agent)
	end)
	assert_true(denied_edit.is_error, "edit revalidation failure rejects rename")
	assert_true(denied_edit.content:match("target path revalidation failed"), "edit revalidation error is visible")
	assert_eq(vim.fn.readfile(workspace .. "/revalidate-edit.txt")[1], "before", "edit revalidation failure preserves target")
end)

test("path helpers reject NUL bytes and discover git or cwd workspace roots", function()
	local path_tools = require("gp.tools.path")
	local nul_path = "bad" .. string.char(0) .. "path.txt"
	local resolved, err = path_tools.resolve(nul_path, { workspace_root = workspace }, false)
	assert_eq(resolved, nil, "NUL path does not resolve")
	assert_true(err:match("NUL byte"), "NUL path rejection explains cause")

	local git_parent = vim.fn.tempname()
	local git_root = git_parent .. "/repo"
	vim.fn.mkdir(git_root .. "/.git", "p")
	vim.fn.mkdir(git_root .. "/sub", "p")
	with_cwd(git_root .. "/sub", function()
		assert_eq(path_tools.workspace_root({}), vim.fn.fnamemodify(git_root, ":p"):gsub("/$", ""), "workspace root discovers git root from cwd")
	end)
	vim.fn.delete(git_parent, "rf")

	local plain = vim.fn.tempname()
	vim.fn.mkdir(plain, "p")
	with_cwd(plain, function()
		with_stub(vim.fn, "isdirectory", function(candidate)
			if tostring(candidate):match("/%.git$") then
				return 0
			end
			return 1
		end, function()
			assert_eq(path_tools.workspace_root({}), vim.fn.fnamemodify(plain, ":p"):gsub("/$", ""), "workspace root falls back to cwd when no git root is found")
		end)
	end)
	vim.fn.delete(plain, "rf")
end)

test("confirmation cancel denies and preview describes requested tool", function()
	local agent = gp.get_chat_agent("ToolAgent")
	local default_agent = vim.deepcopy(agent)
	default_agent.tools.write = nil
	local prompt = nil
	local cancelled
	with_stub(vim.ui, "select", function(_, opts, cb)
		prompt = opts.prompt
		cb(nil)
	end, function()
		cancelled = exec_tool(gp, tool_call("cancel", "write", [[{"path":"cancelled.txt","content":"no"}]]), default_agent)
	end)
	assert_true(cancelled.is_error, "nil confirmation callback denies execution")
	assert_true(cancelled.content:match("denied"), "cancelled confirmation reports denial")
	assert_eq(vim.fn.filereadable(workspace .. "/cancelled.txt"), 0, "cancelled write does not create file")
	assert_true(prompt:match("Run tool: write"), "confirmation preview includes tool name")
	assert_true(prompt:match("path: cancelled.txt"), "confirmation preview includes path")
	assert_true(prompt:match("overwrite: false"), "confirmation preview includes overwrite flag")
end)

test("tool formatting and empty batch execution are stable", function()
	local result_block = gp.tools.format_result_block("read", "ok")
	assert_true(result_block:match("📎 tool_result: read"), "result block includes tool name")
	assert_true(result_block:match("```text\nok\n```"), "result block fences text result")
	local done = false
	local results
	gp.tools.execute_calls({}, gp.get_chat_agent("ToolAgent"), { buf = vim.api.nvim_get_current_buf(), provider = "openai" }, function(res)
		results = res
		done = true
	end)
	assert_true(done, "empty execute_calls returns synchronously")
	assert_eq(#results, 0, "empty execute_calls returns empty results")
end)

test("read write edit and run expose focused failure branches", function()
	local agent = gp.get_chat_agent("ToolAgent")
	vim.fn.mkdir(workspace .. "/read-dir", "p")
	local missing = exec_tool(gp, tool_call("missing", "read", [[{"path":"missing.txt"}]]), agent)
	assert_true(missing.is_error, "read missing file returns error")
	assert_true(missing.content:match("file not found"), "read missing file error message")
	local directory = exec_tool(gp, tool_call("dir", "read", [[{"path":"read-dir"}]]), agent)
	assert_true(directory.is_error, "read directory returns error")
	assert_true(directory.content:match("path is not a file"), "read directory error message")
	write_binary(workspace .. "/binary.bin", "a\0b")
	local binary = exec_tool(gp, tool_call("bin", "read", [[{"path":"binary.bin"}]]), agent)
	assert_true(binary.is_error, "read binary file returns error")
	assert_true(binary.content:match("binary files are not supported"), "read binary error message")
	vim.fn.writefile({ "one", "two", "three" }, workspace .. "/lines.txt")
	local line_agent = vim.deepcopy(agent)
	line_agent.tools.read = { max_bytes = 65536, max_lines = 1 }
	local line_limited = exec_tool(gp, tool_call("line", "read", [[{"path":"lines.txt"}]]), line_agent)
	assert_true(line_limited.content:match("truncated: true"), "read line truncation reported")
	assert_true(not line_limited.content:match("two"), "read line truncation omits later lines")

	vim.fn.writefile({ "old" }, workspace .. "/existing.txt")
	local no_overwrite = exec_tool(gp, tool_call("wo", "write", [[{"path":"existing.txt","content":"new"}]]), agent)
	assert_true(no_overwrite.is_error, "write existing file without overwrite returns error")
	local overwrite = exec_tool(gp, tool_call("ow", "write", [[{"path":"existing.txt","content":"new","overwrite":true}]]), agent)
	assert_true(not overwrite.is_error, "write overwrite=true succeeds")
	assert_true(overwrite.content:match("overwritten: true"), "overwrite summary reports overwritten")
	local unknown_field = exec_tool(gp, tool_call("uf", "write", [[{"path":"x.txt","content":"x","extra":true}]]), agent)
	assert_true(unknown_field.is_error, "unknown argument fields rejected")
	assert_true(unknown_field.content:match("unknown field"), "unknown field error returned")
	local wrong_type = exec_tool(gp, tool_call("wt", "write", [[{"path":"x.txt","content":1}]]), agent)
	assert_true(wrong_type.is_error, "invalid argument types rejected")
	assert_true(wrong_type.content:match("arguments.content must be string"), "invalid type error returned")
	local small_write_agent = vim.deepcopy(agent)
	small_write_agent.tools.write = { max_bytes = 2, confirm = false }
	local too_large_write = exec_tool(gp, tool_call("wmax", "write", [[{"path":"too-large.txt","content":"abc"}]]), small_write_agent)
	assert_true(too_large_write.is_error, "write content over max_bytes rejected")
	assert_true(too_large_write.content:match("content exceeds max_bytes: 3 > 2"), "write max_bytes error includes content size and limit")

	vim.fn.writefile({ "abc abc" }, workspace .. "/edit-errors.txt")
	local zero_match = exec_tool(gp, tool_call("ez", "edit", [[{"path":"edit-errors.txt","edits":[{"old_text":"missing","new_text":"x"}]}]]), agent)
	assert_true(zero_match.is_error, "edit zero-match replacement rejected")
	assert_true(zero_match.content:match("matched 0 times"), "zero-match error returned")
	local multi_match = exec_tool(gp, tool_call("em", "edit", [[{"path":"edit-errors.txt","edits":[{"old_text":"abc","new_text":"x"}]}]]), agent)
	assert_true(multi_match.is_error, "edit multi-match replacement rejected")
	assert_true(multi_match.content:match("matched 2 times"), "multi-match error returned")
	local empty_old = exec_tool(gp, tool_call("ee", "edit", [[{"path":"edit-errors.txt","edits":[{"old_text":"","new_text":"x"}]}]]), agent)
	assert_true(empty_old.is_error, "edit empty old_text rejected")
	assert_true(empty_old.content:match("old_text must not be empty"), "empty old_text error returned")
	vim.fn.writefile({ "abcdef" }, workspace .. "/edit-overlap.txt")
	local overlap = exec_tool(gp, tool_call("eo", "edit", [[{"path":"edit-overlap.txt","edits":[{"old_text":"abc","new_text":"x"},{"old_text":"bcd","new_text":"y"}]}]]), agent)
	assert_true(overlap.is_error, "edit overlapping replacements rejected")
	assert_true(overlap.content:match("edits overlap"), "overlap error returned")
	local max_edits_agent = vim.deepcopy(agent)
	max_edits_agent.tools.edit = { max_edits = 1, confirm = false }
	local too_many_edits = exec_tool(gp, tool_call("emax", "edit", [[{"path":"edit-overlap.txt","edits":[{"old_text":"abc","new_text":"x"},{"old_text":"def","new_text":"y"}]}]]), max_edits_agent)
	assert_true(too_many_edits.is_error, "edit over max_edits rejected")
	assert_true(too_many_edits.content:match("too many edits: 2 > max_edits 1"), "edit max_edits error includes requested count and limit")
	local small_edit_agent = vim.deepcopy(agent)
	small_edit_agent.tools.edit = { max_bytes = 2, confirm = false }
	local too_large_edit = exec_tool(gp, tool_call("efmax", "edit", [[{"path":"edit-overlap.txt","edits":[{"old_text":"abc","new_text":"x"}]}]]), small_edit_agent)
	assert_true(too_large_edit.is_error, "edit over max_bytes rejected")
	assert_true(too_large_edit.content:match("file exceeds max_bytes: 7 > 2"), "edit max_bytes error includes file size and limit")

	local shell_agent = vim.deepcopy(agent)
	shell_agent.tools.run.allowed_commands = { "sh" }
	local shell_reject = exec_tool(gp, tool_call("shell", "run", [[{"cmd":"sh","args":["-c","echo bad"]}]]), shell_agent)
	assert_true(shell_reject.is_error, "run shell -c rejected")
	assert_true(shell_reject.content:match("shell %-c style commands are not supported"), "shell -c rejection message")
	local run_agent = vim.deepcopy(agent)
	run_agent.tools.run.allowed_commands = { "ls", "printf" }
	local nonzero = exec_tool(gp, tool_call("nz", "run", [[{"cmd":"ls","args":["definitely-missing-gp-test-file"]}]]), run_agent)
	assert_true(not nonzero.content:match("exit_code: 0\n"), "run reports non-zero exit code")
	assert_true(nonzero.content:match("stderr:\n") and not nonzero.content:match("stderr:\n%s*$"), "run returns stderr")
	run_agent.tools.run.max_output_bytes = 3
	local truncated = exec_tool(gp, tool_call("tr", "run", [[{"cmd":"printf","args":["abcdef"]}]]), run_agent)
	assert_true(truncated.content:match("stdout_truncated: true"), "run stdout truncation reported")
	assert_true(truncated.content:match("stdout:\nabc"), "run stdout capped content returned")
	local stderr_agent = vim.deepcopy(agent)
	stderr_agent.tools.run.allowed_commands = { "ls" }
	stderr_agent.tools.run.max_output_bytes = 3
	local stderr_truncated = exec_tool(gp, tool_call("terr", "run", [[{"cmd":"ls","args":["definitely-missing-gp-test-file"]}]]), stderr_agent)
	assert_true(stderr_truncated.content:match("stderr_truncated: true"), "run stderr truncation reported")
	local spawn_agent = vim.deepcopy(agent)
	spawn_agent.tools.run.allowed_commands = { "definitely-missing-gp-nvim-command" }
	local spawn_fail = exec_tool(gp, tool_call("spawn", "run", [[{"cmd":"definitely-missing-gp-nvim-command","args":[]}]]), spawn_agent)
	assert_true(spawn_fail.content:match("exit_code: %-1"), "run spawn failure returns exit_code -1")
	assert_true(spawn_fail.content:match("failed to start command"), "run spawn failure returns stderr message")
end)

test("schema validation rejects unknown disabled and malformed tool calls", function()
	local agent = gp.get_chat_agent("ToolAgent")
	local unknown = exec_tool(gp, tool_call("unknown", "unknown_tool", [[{}]]), agent)
	assert_true(unknown.is_error, "unknown tool call rejected")
	assert_true(unknown.content:match("tool is not enabled"), "unknown tool reports not enabled")
	local read_only_agent = vim.deepcopy(agent)
	read_only_agent.tools.enabled = { "read" }
	local disabled = exec_tool(gp, tool_call("disabled", "write", [[{"path":"x.txt","content":"x"}]]), read_only_agent)
	assert_true(disabled.is_error, "disabled built-in tool rejected")
	assert_true(disabled.content:match("tool is not enabled: write"), "disabled tool error returned")
	local missing_required = exec_tool(gp, tool_call("missing", "read", [[{}]]), agent)
	assert_true(missing_required.is_error, "missing required field rejected")
	assert_true(missing_required.content:match("missing required field: path"), "missing required error returned")
	local invalid_array_item = exec_tool(gp, tool_call("badargs", "run", [[{"cmd":"printf","args":[1]}]]), agent)
	assert_true(invalid_array_item.is_error, "invalid array item type rejected")
	assert_true(invalid_array_item.content:match("arguments.args%[1%] must be string"), "array item type error returned")
end)

