# Architecture

This repository is a maintained fork of `gp.nvim`, continued after upstream development slowed/stopped. The plugin is a Lua-only Neovim plugin that keeps runtime dependencies small: Neovim, `curl`, `grep`, and optional audio tooling for Whisper.

## Repository layout

```text
.
├── README.md              # User-facing documentation
├── doc/gp.nvim.txt        # Generated vimdoc (from README via CI)
├── lua/gp/                # Plugin implementation
│   ├── init.lua           # Main module, setup, commands, chat/prompt flows
│   ├── config.lua         # Default user configuration, providers, agents, hooks
│   ├── defaults.lua       # Default system prompts and chat templates
│   ├── dispatcher.lua     # Provider payloads, curl requests, response handlers
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

`init.lua` is the public entry point returned by `require("gp")`. It wires the other modules together, owns `setup(opts)`, registers default commands and hook commands, manages chat buffers, and implements prompt targets such as rewrite, append, popup, and new buffers.

Important responsibilities:

- merge default and user configuration;
- initialize `logger`, `vault`, `dispatcher`, `imager`, and `whisper`;
- validate and index configured agents;
- register commands with the configured prefix, usually `Gp`;
- prepare chat markdown buffers and repository context buffers;
- translate command/range/selection input into provider messages;
- call `dispatcher.query()` and write responses back into buffers.

### `lua/gp/config.lua`

`config.lua` is the canonical default configuration. It defines default providers, agents, prompt templates, chat settings, UI styling, Whisper settings, image settings, and example hooks. The README configuration block is synchronized from this file by CI.

### `lua/gp/dispatcher.lua`

`dispatcher.lua` prepares provider-specific request payloads and handles responses. It supports OpenAI-compatible providers plus provider-specific formats for Anthropic and Google/Vertex-style APIs. It also handles model-specific reasoning behavior and attachment expansion for `@attach(path)` markers.

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
