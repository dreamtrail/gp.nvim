# Architecture

This repository is a maintained fork of `gp.nvim`, continued after upstream development slowed/stopped. The plugin is a Lua-only Neovim plugin that keeps runtime dependencies small: Neovim, `curl`, `grep`, and optional audio tooling for Whisper.

## Repository layout

```text
.
├── README.md              # User-facing documentation
├── doc/gp.nvim.txt        # Generated vimdoc (from README via CI)
├── lua/gp/                # Plugin implementation
│   ├── init.lua           # Public facade, setup, prompt commands, chat finder
│   ├── agents.lua         # Agent selection, lookup, and command handlers
│   ├── chat.lua           # Chat buffer lifecycle and chat file commands
│   ├── chat/respond.lua   # Chat parsing and response orchestration
│   ├── context.lua        # Repository `.gp.md` context command/helpers
│   ├── config.lua         # Default user configuration, providers, agents, hooks
│   ├── defaults.lua       # Default system prompts and chat templates
│   ├── dispatcher.lua     # Dispatcher facade, provider setup, curl query path
│   ├── dispatcher/        # Provider payload, attachment, status, handler helpers
│   ├── ui/                # Shared toggle and buffer opening helpers
│   ├── tasker.lua         # Async process/query tracking
│   ├── vault.lua          # Secret storage and token refresh helpers
│   ├── helper.lua         # Neovim/file utility functions
│   ├── render.lua         # Templates, selections, popup rendering
│   ├── imager.lua         # Image generation commands
│   ├── whisper.lua        # Speech-to-text commands
│   ├── logger.lua         # Logging with sensitive-data controls
│   ├── spinner.lua        # Simple progress spinner
│   ├── deprecator.lua     # Deprecated option checks
│   └── health.lua         # `:checkhealth gp`
└── .github/workflows/     # Documentation and release automation
```

## Main modules

### `lua/gp/init.lua`

`init.lua` is the public entry point returned by `require("gp")`. It remains the stable facade for setup, command registration, prompt targets, chat finder, and compatibility aliases such as `gp.Prompt`, `gp.Target`, `gp.cmd.*`, and agent getters.

Important responsibilities:

- merge default and user configuration;
- initialize `logger`, `vault`, `dispatcher`, `imager`, and `whisper`;
- validate and index configured agents;
- register commands with the configured prefix, usually `Gp`;
- keep existing hook-facing aliases stable while delegating chat, context, UI, and agent behavior to smaller modules;
- translate prompt command/range/selection input into provider messages;
- call `dispatcher.query()` and write prompt responses back into buffers.

### `lua/gp/config.lua`

`config.lua` is the canonical default configuration. It defines default providers, agents, prompt templates, chat settings, UI styling, Whisper settings, image settings, and example hooks. The README configuration block is synchronized from this file by CI.

### Chat, context, and UI modules

The chat lifecycle is split out of the facade:

- `lua/gp/chat.lua` owns chat detection, chat buffer preparation, chat creation/toggle/paste/delete commands, and chat buffer autocommands.
- `lua/gp/chat/respond.lua` parses markdown chat transcripts, builds messages, expands human-authored `@command(...)` prompt snippets, dispatches provider requests, and appends follow-up prompts/topic updates.
- `lua/gp/context.lua` owns `.gp.md` repository instructions and the `GpContext` command.
- `lua/gp/ui/toggle.lua` owns shared popup/chat/context toggle state.
- `lua/gp/ui/buffer.lua` owns buffer target resolution and opening files in current windows, popups, splits, vertical splits, and tabs.

These modules attach functions back onto the main `gp` table to preserve compatibility for hooks and user configuration.

### `lua/gp/dispatcher.lua`

`dispatcher.lua` is a facade for provider setup and query execution. Provider-specific request payloads and response buffer handlers live in dispatcher submodules. It supports OpenAI-compatible providers plus provider-specific formats for Anthropic and Google/Vertex-style APIs.

Dispatcher submodules:

- `dispatcher/reasoning.lua` classifies reasoning models/providers;
- `dispatcher/attachments.lua` expands `@attach(path)` markers;
- `dispatcher/payload.lua` prepares provider-specific payloads while preserving existing message mutation behavior;
- `dispatcher/status.lua` manages statusline progress;
- `dispatcher/handler.lua` writes streamed/buffered responses into buffers.

### `lua/gp/tasker.lua`

`tasker.lua` runs external processes through libuv, tracks running handles by buffer, stores recent query metadata, and provides stop/cancel behavior for active requests.

### `lua/gp/vault.lua`

`vault.lua` keeps secrets out of the public config tables after setup. Secrets may be configured directly as strings or resolved asynchronously from shell commands. It also contains bearer-token refresh helpers for Copilot and Vertex workflows.

## Runtime flow

A normal session follows this path:

1. User config calls `require("gp").setup(conf)`.
2. `init.lua` deep-copies defaults from `config.lua` and merges user options.
3. Secret-like fields are moved into `vault` and removed from public config tables.
4. `dispatcher.setup()` merges provider definitions and prepares the query cache directory.
5. `imager.setup()` and `whisper.setup()` register optional feature commands unless disabled.
6. `init.lua` registers hook commands and built-in commands such as `GpChatNew`, `GpChatRespond`, `GpRewrite`, and `GpPopup`.
7. A user command builds chat or prompt messages from the current buffer, range, selection, arguments, and optional `.gp.md` repository instructions.
8. `dispatcher.prepare_payload()` converts those messages into the target provider's request format.
9. `dispatcher.query()` starts a `curl` process through `tasker.run()`.
10. Streaming or buffered response data is parsed by dispatcher handlers and written back into Neovim buffers.
11. Completion callbacks run cleanup, selection adjustment, and the `User GpDone` autocommand where applicable.

## Data and state

The plugin stores runtime data under Neovim standard paths by default:

- persisted state: `stdpath("data")/gp/persisted`;
- query cache: `stdpath("cache")/gp/query`;
- logs: `stdpath("log")/gp.nvim.log`;
- chats: `stdpath("data")/gp/chats` via `chat_dir`;
- Whisper recordings and image files use their configured `store_dir` values.

Prompt command outputs are written to the current buffer, new buffers, splits, tabs, or popups rather than a configured output directory.

Repository-local instructions are read from `.gp.md` at the Git root when present.

## Documentation generation

`doc/gp.nvim.txt` is generated from `README.md` by `.github/workflows/docgen.yml` using `panvimdoc`. Do not hand-edit generated vimdoc unless there is no viable alternative; update README/source docs instead and let CI regenerate vimdoc.
