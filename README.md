# gp.nvim

`gp.nvim` brings AI chat, prompt-driven text/code editing, optional speech-to-text, image generation, and native chat tools to Neovim.

> **Fork status**
> This repository is a maintained fork of `gp.nvim`, continued after upstream development slowed/stopped. User-facing install snippets below point at this fork: `dreamtrail/gp.nvim`.

## Quick start

### Install

Use your preferred plugin manager and call `require("gp").setup(...)` after the plugin is loaded.

```lua
-- lazy.nvim
{
  "dreamtrail/gp.nvim",
  config = function()
    require("gp").setup({
      -- Minimal setup uses OPENAI_API_KEY from your environment.
    })
  end,
}
```

```lua
-- packer.nvim
use({
  "dreamtrail/gp.nvim",
  config = function()
    require("gp").setup({})
  end,
})
```

```vim
" vim-plug
Plug 'dreamtrail/gp.nvim'
```

```lua
require("gp").setup({})
```

### Requirements

Core features require:

- Neovim with Lua support;
- `curl` for provider requests;
- `grep` for chat search/finder.

Optional features:

- `sox` for Whisper speech-to-text commands;
- provider-specific CLIs/files when secrets are resolved by command, such as password managers, Copilot config, or `gcloud` for Vertex.

### Minimal configuration

For OpenAI, set `OPENAI_API_KEY` in your shell and use the default setup:

```lua
require("gp").setup({})
```

Or pass a secret explicitly. Prefer environment variables or command-based secrets over hardcoded keys:

```lua
require("gp").setup({
  openai_api_key = os.getenv("OPENAI_API_KEY"),
})
```

Command secrets run asynchronously and can call password managers:

```lua
require("gp").setup({
  openai_api_key = { "bw", "get", "password", "OPENAI_API_KEY" },
})
```

## Providers and agents

The config supports OpenAI-compatible endpoints plus provider-specific formats for Anthropic, Google/Vertex-style APIs, Copilot, Perplexity, Ollama, Azure-style deployments, and local OpenAI-compatible servers.

Example provider configuration:

```lua
require("gp").setup({
  providers = {
    openai = {
      endpoint = "https://api.openai.com/v1/chat/completions",
      secret = os.getenv("OPENAI_API_KEY"),
    },
    ollama = {
      endpoint = "http://localhost:11434/v1/chat/completions",
    },
    anthropic = {
      endpoint = "https://api.anthropic.com/v1/messages",
      secret = os.getenv("ANTHROPIC_API_KEY"),
    },
    googleai = {
      endpoint = "https://generativelanguage.googleapis.com/v1beta/models/{{model}}:streamGenerateContent?key={{secret}}",
      secret = os.getenv("GOOGLEAI_API_KEY"),
    },
  },
})
```

Agents choose a provider, model, and whether they are available for chat and/or text commands:

```lua
require("gp").setup({
  agents = {
    {
      name = "LocalChat",
      provider = "ollama",
      chat = true,
      command = true,
      model = { model = "llama3" },
      system_prompt = require("gp.defaults").chat_system_prompt,
    },
  },
})
```

See `lua/gp/config.lua` for all defaults and [Usage](docs/USAGE.md) for command behavior.

Default config permalink used by the documentation workflow:

<!-- README_REFERENCE_MARKER_REPLACE_NEXT_LINE -->
https://github.com/dreamtrail/gp.nvim/blob/main/lua/gp/config.lua

## Common commands

| Command | Purpose |
| --- | --- |
| `:GpChatNew` | Open a new markdown chat buffer. |
| `:GpChatToggle` | Toggle the latest chat in a popup/split/tab target. |
| `:GpChatRespond` | Ask the selected chat agent to respond in the current chat. |
| `:GpChatFinder` | Search, preview, open, or delete saved chats. |
| `:GpRewrite` | Replace the current line/range/selection from a prompt. |
| `:GpAppend` / `:GpPrepend` | Insert model output after/before the current line/range/selection. |
| `:GpPopup`, `:GpEnew`, `:GpNew`, `:GpVnew`, `:GpTabnew` | Send prompt output to a popup, new buffer, split, vertical split, or tab. |
| `:GpContext` | Create/open repository-local `.gp.md` instructions. |
| `:GpAgent` / `:GpNextAgent` | Inspect or switch active agents. |
| `:GpTools` | Inspect native chat tool availability and safety settings. |
| `:GpStop` | Stop active gp.nvim jobs. |

Full command docs: [Usage](docs/USAGE.md). Shortcut examples: [Shortcuts](docs/SHORTCUTS.md). Hook/API examples: [Extending](docs/EXTENDING.md).

## Repository instructions with `.gp.md`

Use `:GpContext` to create or edit `.gp.md` at the repository root. Prompt commands such as `:GpRewrite` and `:GpAppend` include that file as repository-local instructions.

Example `.gp.md`:

```md
Use Lua 5.1-compatible Neovim APIs.
Prefer small focused modules.
When writing tests, use the existing headless harness style.
```

## Native chat tools

Native tools let a tool-enabled chat agent ask gp.nvim to read files, write files, edit files, or run commands. Tools are disabled by default and are currently available for OpenAI-compatible tool-calling providers.

Built-in tools:

- `read` — read bounded text files;
- `write` — write text files and create parent directories;
- `edit` — apply exact text replacements atomically;
- `run` — run a command with arguments, without invoking a shell.

Example tool-enabled agent:

```lua
require("gp").setup({
  agents = {
    {
      provider = "openai",
      name = "ChatGPT4oTools",
      chat = true,
      command = false,
      model = { model = "gpt-4o", temperature = 1.0 },
      system_prompt = require("gp.defaults").chat_system_prompt,
      tools = {
        enabled = { "read", "write", "edit", "run" },
        workspace_only = true,
        -- streamed tool-use is on by default; set false for compatibility
        stream = true,
        write = { confirm = true },
        edit = { confirm = true },
        run = {
          -- exact command strings bypass normal run confirmation
          allowed_commands = { "make", "npm", "pytest" },
          -- set false to let allowlisted commands use cwd outside the
          -- workspace without the extra outside-workspace prompt
          workspace_only = true,
        },
      },
    },
  },
})
```

Safety model:

- Tools run only in chat sessions.
- Tools use OpenAI-compatible `tools` / `tool_calls` payloads. Anthropic and Google native tool adapters are deferred until there is a concrete provider-specific need.
- Tool-enabled chats stream tool-use rounds by default; set `tools.stream = false` per agent for compatibility with providers that do not support streamed tool calls.
- `workspace_only = true` is the default. It means **no silent outside-workspace access**:
  - outside-workspace `read`, `write`, and `edit` require explicit per-call confirmation, even if that tool's normal `confirm` option is `false`;
  - outside-workspace `run.cwd` requires explicit per-call confirmation by default, even for allowlisted commands;
  - set `tools.run.workspace_only = false` if trusted allowlisted commands may run with `cwd` outside the workspace without that extra prompt;
  - set top-level `tools.workspace_only = false` only for trusted/local models that may access paths outside the workspace without per-call outside-workspace confirmation.
- `write`, `edit`, and non-allowlisted `run` calls ask for normal confirmation by default.
- `run.allowed_commands` matches exact command strings. `/usr/bin/make` needs an exact `/usr/bin/make` allowlist entry.
- Model-provided `run.timeout_ms` is capped by the configured `tools.run.timeout_ms` maximum.
- Tool call/result blocks are visible in chat files for auditability, but historical markdown tool blocks are not replayed as structured tool messages.

## Detailed documentation

- [Usage](docs/USAGE.md) — commands, native tools, `.gp.md`, scripting.
- [Shortcuts](docs/SHORTCUTS.md) — keymap examples.
- [Extending](docs/EXTENDING.md) — hooks and prompt target API.
- [Troubleshooting](docs/TROUBLESHOOTING.md) — common setup/provider/tool issues.
- [Contributor setup](docs/SETUP.md) — local development setup.
- [Testing](docs/TESTING.md) — validation strategy and headless harness.
- [Architecture](docs/ARCHITECTURE.md) and [Implementation notes](docs/IMPLEMENTATION.md) — maintainer internals.
- [Maintainers guide](docs/MAINTAINERS.md) — fork stewardship and release notes.

## Generated vimdoc

`doc/gp.nvim.txt` is generated from `README.md` by CI. Update README and source docs, then let CI regenerate vimdoc unless a release process explicitly requires local regeneration.
