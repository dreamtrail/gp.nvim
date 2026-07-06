# Testing and Validation

This repository includes a minimal headless Neovim characterization test harness invoked by `scripts/test.sh`. `tests/run.lua` is the runner, `tests/support.lua` provides shared fixtures/helpers, and grouped specs live under `tests/spec/`. The harness currently covers plugin loading/setup, command registration, public compatibility aliases, chat storage/migration behavior, representative dispatcher payload behavior, chat tool-loop orchestration, and native tool safety paths.

It is not a comprehensive unit/integration test suite. Use the checks below to validate changes according to their scope, and add focused characterization coverage when changing core behavior.

## Documentation-only changes

For docs-only changes, validate that the expected files and links are correct and that no code/generated files changed accidentally.

```sh
git status --short
git diff --stat
git diff -- README.md docs/
```

Check README/docs links to local files:

```sh
python3 - <<'PY'
from pathlib import Path
import re
files = [Path('README.md'), *Path('docs').glob('*.md')]
missing = []
for file in files:
    text = file.read_text()
    for link in re.findall(r'\[[^\]]+\]\(([^)#]+)', text):
        if re.match(r'^[a-z]+:', link) or link.startswith('#'):
            continue
        target = (file.parent / link).resolve() if not link.startswith('/') else Path(link)
        if not target.exists():
            missing.append(f'{file}: {link}')
if missing:
    raise SystemExit('Missing local markdown links:\n' + '\n'.join(missing))
print('local markdown links OK')
PY
```

For README rewrites, also search for removed or stale section names and old behavior descriptions relevant to the change.

## Headless characterization tests

Run the committed headless test harness for Lua source changes:

```sh
./scripts/test.sh
```

The script uses temporary XDG directories and a dummy API key, then runs `tests/run.lua` in a clean headless Neovim session. The runner loads grouped spec files from `tests/spec/`.

## Lua load/syntax smoke checks

When Lua source changes, perform at least a load smoke check in Neovim. Keep secrets out of the environment unless a provider call is intentionally being tested.

```sh
nvim --headless --clean -u NONE -i NONE --cmd "set rtp+=." \
  -c "lua require('gp')" \
  -c "qa"
```

If setup behavior changed, also smoke setup with a local/minimal config and temporary XDG directories:

```sh
TMPDIR="$(mktemp -d)"
XDG_DATA_HOME="$TMPDIR/data" XDG_CACHE_HOME="$TMPDIR/cache" XDG_STATE_HOME="$TMPDIR/state" \
OPENAI_API_KEY=dummy \
nvim --headless --clean -u NONE -i NONE --cmd "set rtp+=." \
  -c "lua require('gp').setup({ openai_api_key = 'dummy', image = { disable = true }, whisper = { disable = true } })" \
  -c "qa"
rm -rf "$TMPDIR"
```

Adjust provider disabling/enabling for the behavior under test.

## Health check

Run health checks interactively when possible:

```vim
:checkhealth gp
```

Expected checks include whether:

- `require('gp')` succeeds;
- `require('gp').setup()` has been called;
- `curl` is installed;
- Whisper dependencies/config are usable if Whisper is enabled;
- deprecated config options are reported.

## Command smoke tests

For UI/command changes, test the affected command paths in a disposable Neovim session and scratch files.

Suggested smoke paths:

- `:GpInspectPlugin` opens plugin state without exposing secrets in normal logs;
- `:GpContext` creates/opens `.gp.md` at the Git root;
- `:GpChatNew`, `:GpChatToggle`, and `:GpChatDelete` handle chat files as expected;
- `:GpChatFinder` lists/searches only `chat_dir/YYYY/MM/*.md` chats and ignores root-level legacy chats;
- `:GpChatMigrate` dry-runs by default and `:GpChatMigrate apply` confirms before moving legacy flat chats;
- `:GpAgent` and `:GpNextAgent` switch among valid agents;
- one prompt target such as `:GpPopup` or `:GpEnew` works with a configured provider.

Avoid live provider calls unless you intend to spend API credits and have configured a safe test prompt.

## Core refactor validation

For behavior-preserving architecture refactors, check stable facade behavior:

- `require("gp")` and `require("gp.dispatcher")` still load;
- existing commands are still registered after setup;
- compatibility aliases such as `gp.Prompt`, `gp.Target`, `gp.cmd.ChatNew`, `gp.cmd.ChatFinder`, `gp.get_chat_agent`, `dispatcher.prepare_payload`, and `dispatcher.create_handler` still exist;
- representative payload tests still pass, including current in-place message mutation behavior for Anthropic/Google/OpenAI reasoning payloads.

## Native tool validation

For native tool changes, run the headless harness and add provider-free coverage where possible:

```sh
./scripts/test.sh
```

The committed tests should cover:

- exact `Gp*` command snapshots, including `GpTools` and `GpChatMigrate`;
- default agents remaining tool-disabled;
- OpenAI-compatible payloads receiving native tool schemas only when tools are enabled;
- Anthropic/Google payloads not receiving OpenAI tool schemas;
- non-stream OpenAI response parsing for final content, one tool call, and multiple tool calls;
- streamed OpenAI-compatible tool-call delta merging and invalid argument detection;
- chat tool-loop orchestration with a mocked dispatcher, including default streaming and `tools.stream = false` opt-out;
- unsupported native-tool provider fallback to non-streaming requests without OpenAI tool schemas;
- visible tool call/result blocks in chat buffers;
- built-in `read`, `write`, `edit`, and `run` behavior in temporary workspaces;
- confirmation allow/deny paths by stubbing `vim.ui.select`;
- outside-workspace confirmation for `read`, `write`, `edit`, and default `run.cwd` when `workspace_only=true`;
- `tools.run.workspace_only=false` allowing allowlisted commands to use outside `cwd` without the extra outside-workspace prompt.

Manual validation for trusted local setups:

1. Configure a tool-enabled chat agent with `tools.enabled = { "read", "write", "edit", "run" }`.
2. Use `:GpTools` to inspect enabled tools.
3. In a disposable repository, ask the model to read a small file, edit a copy, and run an allowlisted harmless command.
4. Verify tool call/result blocks are visible in the chat transcript.
5. Use `:GpStop` while a long `run` command is active to verify cancellation where supported.

Avoid live remote-provider tests with sensitive files unless you explicitly intend to send those file contents to the provider.

## Provider-specific validation

Provider changes should be validated with the provider they affect:

- OpenAI-compatible providers: check payload shape, streaming/non-streaming behavior, streamed `delta.tool_calls`, native tool schemas/tool calls when enabled, and auth header handling.
- Anthropic: check `system`, `messages`, optional `thinking`, and attachment handling.
- Google/Vertex: check `contents`, `parts`, `system_instruction`, search/thinking options, and bearer refresh if applicable.
- Copilot: check secret extraction and bearer refresh paths without logging tokens.
- Local providers such as Ollama/LM Studio: check endpoint availability and model names.

## Before committing

Before committing, confirm:

```sh
git status --short
git diff --stat
```

Only intended files should be changed. Do not commit cache files, generated files not required by the plan, local chat data, secrets, logs, or build artifacts.
