# Implementation Notes

This document explains the main implementation seams for maintainers of this fork. It describes the current code; it is not a public API guarantee.

## Setup and configuration

The public entry point is `require("gp").setup(opts)` in `lua/gp/init.lua`. `init.lua` acts as a facade: extracted modules attach compatibility functions back onto the main `gp` table, so existing hooks can continue to call `gp.Prompt`, `gp.Target`, `gp.cmd.ChatNew`, `gp.get_chat_agent`, and related helpers.

Setup performs these steps:

1. reset `M.config` from `lua/gp/config.lua`;
2. initialize logging;
3. initialize the vault and register `openai_api_key`;
4. initialize the dispatcher with provider config;
5. initialize image and Whisper modules;
6. merge default and user-defined `hooks` and `agents`;
7. apply remaining config options through the deprecator;
8. prepare configured directories;
9. validate providers and agents;
10. refresh persisted state;
11. register commands and buffer handlers.

Nested config tables are handled deliberately: `hooks` and `agents` are merged by name, while provider secrets are moved into `vault` before provider tables are exposed through dispatcher state.

## Command registration

Commands are registered with `helpers.create_user_command()` from facade-owned setup logic.

There are three command groups:

- built-in commands from `M.cmd` in `lua/gp/init.lua`;
- user hooks from `config.hooks`, registered under the same command prefix;
- optional feature commands from `imager.lua` and `whisper.lua`.

The default command prefix is `Gp`, so `ChatNew` becomes `:GpChatNew`. User hooks can override built-in command names because built-ins are skipped when a hook with the same name exists.

`M.prepare_commands()` in `lua/gp/init.lua` generates the text/code prompt commands from `M.Target`, including:

- `GpRewrite`
- `GpAppend`
- `GpPrepend`
- `GpPopup`
- `GpEnew`
- `GpNew`
- `GpVnew`
- `GpTabnew`

When Whisper is enabled, matching `GpWhisper*` variants are added.

## Chat buffers

Chats are regular markdown files in the configured chat directory. Chat templates come from `lua/gp/defaults.lua` and contain a header section before the first `---` separator.

Important chat behavior is split across smaller modules:

- `lua/gp/chat.lua`: `new_chat()` creates the markdown file and opens it in the requested target; `prep_chat()` sets markdown options and buffer-local shortcuts; `ChatDelete` deletes the active chat after optional confirmation.
- `lua/gp/chat/respond.lua`: `chat_respond()` parses markdown messages into `{ role, content }` records, expands `@command(...)`, orchestrates normal provider calls, and runs the native tool loop for tool-enabled OpenAI-compatible chat agents.
- `lua/gp/init.lua`: `ChatFinder` searches existing chat files and previews matches.

The extracted modules attach these functions to the same `M` table used by `require("gp")`, preserving existing public aliases.

Chat parsing depends on configured user and assistant prefixes. Header fields may override the agent model/provider/role for that chat.

## Native chat tools

Native tools are opt-in per chat agent through `agent.tools.enabled`. Default agents do not enable tools. The MVP is chat-only and uses OpenAI-compatible `tools` / `tool_calls` / `role = "tool"` message shapes; Anthropic and Google native tool formats are intentionally not implemented yet.

Main modules:

- `lua/gp/tools.lua`: registry, schema export, `:GpTools`, confirmation policy, and sequential execution of multiple tool calls.
- `lua/gp/tools/builtin.lua`: built-in `read`, `write`, `edit`, and `run` implementations.
- `lua/gp/tools/path.lua`: workspace root resolution and path containment checks.
- `lua/gp/tools/process.lua`: bounded libuv process execution for `run`.

A tool-enabled chat response follows this loop:

1. `chat_respond()` parses the chat as usual and writes the assistant prefix.
2. If the current chat agent has `tools.enabled` and the provider is OpenAI-compatible, it builds a non-streaming payload with tool schemas.
3. Dispatcher parses non-streaming responses into `response_message`, `tool_calls`, and `finish_reason` fields on the tasker query record.
4. If tool calls exist, `chat_respond()` records visible tool-call blocks, executes each call in order, records visible tool-result blocks, appends structured `role = "tool"` messages internally, and sends the next non-streaming request.
5. If no tool calls exist, the final assistant response is written and normal chat finalization runs.

Safety defaults:

- `read` is read-only and can run without confirmation.
- `write`, `edit`, and non-allowlisted `run` calls require `vim.ui.select()` confirmation by default.
- `run.allowed_commands` bypasses confirmation for trusted commands.
- `workspace_only = true` is the default; trusted/local agents may set it to `false`.
- `write` and `edit` use atomic temporary-file writes plus rename when possible.
- `run` does not invoke a shell; it uses `cmd` plus `args`, output caps, and a timeout.

Tool call/result blocks are deliberately human-readable transcript text. The MVP does not parse historical blocks back into structured tool messages.

## Prompt targets

Text/code commands use `M.Prompt(params, target, agent, template, prompt, whisper, callback)`.

The target controls where model output is written:

- `rewrite`: replace the current line/range/selection;
- `append`: insert after the current line/range/selection;
- `prepend`: insert before the current line/range/selection;
- `popup`: render into an ephemeral popup buffer;
- `enew`, `new`, `vnew`, `tabnew`: render into a new buffer/window/tab.

`M.Prompt()` normalizes indentation from the selected lines, expands templates with filetype/filename/selection/command values, optionally prepends repository instructions from `.gp.md`, and then creates a dispatcher handler for the selected output target.

## Provider dispatch

`lua/gp/dispatcher.lua` is responsible for provider-facing setup and query execution, while submodules own focused helper logic.

Key paths:

- `D.setup(opts)` merges configured providers with defaults and registers provider secrets with `vault`;
- `D.prepare_payload(messages, model, provider, opts)` is a compatibility alias to `lua/gp/dispatcher/payload.lua` and converts internal messages into the target provider format; `opts` can inject OpenAI-compatible tool schemas and force non-streaming requests;
- `D.query(...)` resolves provider secrets and delegates to the internal `query` function;
- `D.create_handler(...)` is a compatibility alias to `lua/gp/dispatcher/handler.lua` and creates buffer writers for streaming and buffered responses.

Dispatcher helper modules:

- `dispatcher/reasoning.lua`: model/provider classification helpers;
- `dispatcher/attachments.lua`: `@attach(path)` parsing and inline attachment conversion;
- `dispatcher/payload.lua`: provider-specific payload conversion;
- `dispatcher/status.lua`: statusline progress updates;
- `dispatcher/handler.lua`: response insertion into buffers.

Provider-specific behavior includes:

- OpenAI-compatible payloads with `messages` and optional native `tools` / `tool_choice`;
- Anthropic payloads with top-level `system`, `messages`, and optional `thinking`;
- Google/Vertex-style payloads with `contents`, `parts`, `system_instruction`, and safety settings;
- OpenAI reasoning models using `developer` instead of `system` for the leading role;
- stripping leading `<think>...</think>` blocks from assistant history;
- file/image attachment expansion for `@attach(path)` in user messages.

Network calls are made through `curl`, not through a Lua HTTP dependency.

## Vault and secrets

`lua/gp/vault.lua` keeps secret values in a private table. Public config tables should not retain raw API keys after setup.

Secrets can be:

- direct strings;
- command arrays such as `{ "bw", "get", "password", "OPENAI_API_KEY" }`;
- omitted for providers that do not need authentication or use dummy local secrets.

`resolve_secret()` runs command-based secrets asynchronously. The vault also manages bearer refresh flows for Copilot and Vertex.

Do not log secrets unless `log_sensitive` is explicitly enabled for debugging, and avoid adding documentation examples that encourage committing keys.

## Async task management

`lua/gp/tasker.lua` wraps libuv process spawning.

It tracks:

- running process handles;
- process IDs;
- the buffer associated with a request;
- recent query metadata used by response handlers and inspection commands.

`GpStop` calls `tasker.stop()` to terminate tracked jobs. `is_busy(buf)` prevents starting multiple Gp processes for the same buffer.

## Whisper

`lua/gp/whisper.lua` records audio and sends it to OpenAI's transcription endpoint.

Expected tooling:

- `sox` is required by the current health check and transcription path;
- `arecord` or `ffmpeg` may be selected as recording backends depending on configuration/platform;
- `curl` is used for the transcription request.

Whisper commands feed transcribed text into the corresponding prompt command variants.

## Image generation

`lua/gp/imager.lua` registers image commands independently of text providers.

- `GpImageAgent` selects the configured image agent.
- `GpImage` prompts for or accepts an image prompt, calls OpenAI image generation, downloads the resulting image URL, and opens/saves it.

Image secrets are stored in `vault` under `imager_secret`.

## Generated docs

The README configuration snippet is bounded by `README_REFERENCE_MARKER_START` and `README_REFERENCE_MARKER_END` in `lua/gp/config.lua`. CI uses that range to update `README.md`, then uses `panvimdoc` to regenerate `doc/gp.nvim.txt`.
