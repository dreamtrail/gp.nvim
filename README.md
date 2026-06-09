<!-- panvimdoc-ignore-start -->

<a href="https://github.com/Robitx/gp.nvim/blob/main/LICENSE"><img alt="GitHub" src="https://img.shields.io/github/license/robitx/gp.nvim"></a>
<a href="https://github.com/Robitx/gp.nvim/stargazers"><img alt="GitHub Repo stars" src="https://img.shields.io/github/stars/Robitx/gp.nvim"></a>
<a href="https://github.com/Robitx/gp.nvim/issues"><img alt="GitHub closed issues" src="https://img.shields.io/github/issues-closed/Robitx/gp.nvim"></a>
<a href="https://github.com/Robitx/gp.nvim/pulls"><img alt="GitHub closed pull requests" src="https://img.shields.io/github/issues-pr-closed/Robitx/gp.nvim?label=PRs"></a>
<a href="https://github.com/Robitx/gp.nvim/graphs/contributors"><img alt="GitHub contributors" src="https://img.shields.io/github/contributors-anon/Robitx/gp.nvim"></a>
<a href="https://github.com/search?q=%2F%5E%5B%5Cs%5D*require%5C%28%5B%27%22%5Dgp%5B%27%22%5D%5C%29%5C.setup%2F+language%3ALua&type=code&p=1"><img alt="Static Badge" src="https://img.shields.io/badge/Use%20in%20the%20Wild-8A2BE2"></a>
<a href="https://discord.gg/dYyHmyNpv7"><img alt="Discord" src="https://img.shields.io/discord/1200485978725433484?label=Discord"></a>


# Gp.nvim (GPT prompt) Neovim AI plugin

<!-- panvimdoc-ignore-end -->

<br>

> **Fork status**
> This repository is a maintained fork of `gp.nvim`, continued after upstream development slowed/stopped.

**ChatGPT like sessions, Instructable text/code operations, Speech to text and Image generation in your favorite editor.**

<p align="left">
<img src="https://github.com/Robitx/gp.nvim/assets/8431097/cb288094-2308-42d6-9060-4eb21b3ba74c" width="49%">
<img src="https://github.com/Robitx/gp.nvim/assets/8431097/c538f0a2-4667-444e-8671-13f8ea261be1" width="49%">
</p>

### Youtube demos

- [5-min-demo](https://www.youtube.com/watch?v=X-cT7s47PLo) (December 2023)
- [older-5-min-demo](https://www.youtube.com/watch?v=wPDcBnQgNCc) (screen capture, no sound)

# Goals and Features

The goal is to extend Neovim with the **power of GPT models in a simple unobtrusive extensible way.**  
Trying to keep things as native as possible - reusing and integrating well with the natural features of (Neo)vim.

- **Streaming responses**
  - no spinner wheel and waiting for the full answer
  - response generation can be canceled half way through
  - properly working undo (response can be undone with a single `u`)
- **Infinitely extensible** via hook functions specified as part of the config
  - hooks have access to everything in the plugin and are automatically registered as commands
  - see [5. Configuration](#5-configuration) and [Extend functionality](#extend-functionality) sections for details
- **Minimum dependencies** (`neovim`, `curl`, `grep` and optionally `sox`)
  - zero dependencies on other lua plugins to minimize chance of breakage
- **ChatGPT like sessions**
  - just good old neovim buffers formated as markdown with autosave and few buffer bound shortcuts
  - last chat also quickly accessible via toggable popup window
  - chat finder - management popup for searching, previewing, deleting and opening chat sessions
- **Instructable text/code operations**
  - templating mechanism to combine user instructions, selections etc into the gpt query
  - multimodal - same command works for normal/insert mode, with selection or a range
  - many possible output targets - rewrite, prepend, append, new buffer, popup
  - non interactive command mode available for common repetitive tasks implementable as simple hooks  
    (explain something in a popup window, write unit tests for selected code into a new buffer,  
    finish selected code based on comments in it, etc.)
  - custom instructions per repository with `.gp.md` file  
    (instruct gpt to generate code using certain libs, packages, conventions and so on)
- **Speech to text support**
  - a mouth is 2-4x faster than fingers when it comes to outputting words - use it where it makes sense  
    (dicating comments and notes, asking gpt questions, giving instructions for code operations, ..)
- **Image generation**
  - be even less tempted to open the browser with the ability to generate images directly from Neovim

# Maintainer / contributor docs

This README focuses on user-facing setup and usage. Contributor and maintainer notes for this fork live in:

- [Architecture](docs/ARCHITECTURE.md)
- [Implementation notes](docs/IMPLEMENTATION.md)
- [Contributor setup](docs/SETUP.md)
- [Testing and validation](docs/TESTING.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Maintainers guide](docs/MAINTAINERS.md)

# Install

## 1. Install the plugin

Snippets for your preferred package manager:

```lua
-- lazy.nvim
{
    "robitx/gp.nvim",
    config = function()
        local conf = {
            -- For customization, refer to Install > Configuration in the Documentation/Readme
        }
        require("gp").setup(conf)

        -- Setup shortcuts here (see Usage > Shortcuts in the Documentation/Readme)
    end,
}
```

```lua
-- packer.nvim
use({
    "robitx/gp.nvim",
    config = function()
        local conf = {
            -- For customization, refer to Install > Configuration in the Documentation/Readme
        }
        require("gp").setup(conf)

        -- Setup shortcuts here (see Usage > Shortcuts in the Documentation/Readme)
    end,
})
```

```lua
-- vim-plug
Plug 'robitx/gp.nvim'

local conf = {
    -- For customization, refer to Install > Configuration in the Documentation/Readme
}
require("gp").setup(conf)

-- Setup shortcuts here (see Usage > Shortcuts in the Documentation/Readme)
```
## 2. OpenAI API key

Make sure you have OpenAI API key. [Get one here](https://platform.openai.com/account/api-keys) and use it in the [4. Configuration](#4-configuration). Also consider setting up [usage limits](https://platform.openai.com/account/billing/limits) so you won't get suprised at the end of the month.

The OpenAI API key can be passed to the plugin in multiple ways:

| Method                    | Example                                                        | Security Level      |
| ------------------------- | -------------------------------------------------------------- | ------------------- |
| hardcoded string          | `openai_api_key: "sk-...",`                                    | Low                 |
| default env var           | set `OPENAI_API_KEY` environment variable in shell config      | Medium              |
| custom env var            | `openai_api_key = os.getenv("CUSTOM_ENV_NAME"),`               | Medium              |
| read from file            | `openai_api_key = { "cat", "path_to_api_key" },`               | Medium-High         |
| password manager          | `openai_api_key = { "bw", "get", "password", "OAI_API_KEY" },` | High                |

If `openai_api_key` is a table, Gp runs it asynchronously to avoid blocking Neovim (password managers can take a second or two).

## 3. Multiple providers
The following LLM providers are currently supported besides OpenAI:

- [Ollama](https://github.com/ollama/ollama) for local/offline open-source models. The plugin assumes you have the Ollama service up and running with configured models available (the default Ollama agent uses Llama3).
- [GitHub Copilot](https://github.com/settings/copilot) with a Copilot license ([zbirenbaum/copilot.lua](https://github.com/zbirenbaum/copilot.lua) or [github/copilot.vim](https://github.com/github/copilot.vim) for autocomplete). You can access the underlying GPT-4 model without paying anything extra (essentially unlimited GPT-4 access).
- [Perplexity.ai](https://www.perplexity.ai/pro) Pro users have $5/month free API credits available (the default PPLX agent uses Mixtral-8x7b).
- [Anthropic](https://www.anthropic.com/api) to access Claude models, which currently outperform GPT-4 in some benchmarks.
- [Google Gemini](https://ai.google.dev/) with a quite generous free range but some geo-restrictions (EU).
- Any other "OpenAI chat/completions" compatible endpoint (Azure, LM Studio, etc.)

Below is an example of the relevant configuration part enabling some of these. The `secret` field has the same capabilities as `openai_api_key` (which is still supported for compatibility).

```lua
	providers = {
		openai = {
			endpoint = "https://api.openai.com/v1/chat/completions",
			secret = os.getenv("OPENAI_API_KEY"),
		},

		-- azure = {...},

		copilot = {
			endpoint = "https://api.githubcopilot.com/chat/completions",
			secret = {
				"bash",
				"-c",
				"cat ~/.config/github-copilot/hosts.json | sed -e 's/.*oauth_token...//;s/\".*//'",
			},
		},

		pplx = {
			endpoint = "https://api.perplexity.ai/chat/completions",
			secret = os.getenv("PPLX_API_KEY"),
		},

		ollama = {
			endpoint = "http://localhost:11434/v1/chat/completions",
		},

		googleai = {
			endpoint = "https://generativelanguage.googleapis.com/v1beta/models/{{model}}:streamGenerateContent?key={{secret}}",
			secret = os.getenv("GOOGLEAI_API_KEY"),
		},

		anthropic = {
			endpoint = "https://api.anthropic.com/v1/messages",
			secret = os.getenv("ANTHROPIC_API_KEY"),
		},
	},
```

Each of these providers has some agents preconfigured. Below is an example of how to disable predefined ChatGPT3-5 agent and create a custom one. If the `provider` field is missing, OpenAI is assumed for backward compatibility.

```lua
	agents = {
		{
			name = "ChatGPT3-5",
			disable = true,
		},
		{
			name = "MyCustomAgent",
			provider = "copilot",
			chat = true,
			command = true,
			model = { model = "gpt-4-turbo" },
			system_prompt = "Answer any query with just: Sure thing..",
		},
	},

```


## 4. Dependencies

The core plugin only needs `curl` installed to make calls to OpenAI API and `grep` for ChatFinder. So Linux, BSD and Mac OS should be covered.

Voice commands (`:GpWhisper*`) depend on `SoX` (Sound eXchange) to handle audio recording and processing:

- Mac OS: `brew install sox`
- Ubuntu/Debian: `apt-get install sox libsox-fmt-mp3`
- Arch Linux: `pacman -S sox`
- Redhat/CentOS: `yum install sox`
- NixOS: `nix-env -i sox`

## 5. Configuration

Below is a linked snippet with the default values, but I suggest starting with minimal config possible (just `openai_api_key` if you don't have `OPENAI_API_KEY` env set up). Defaults change over time to improve things, options might get deprecated and so on - it's better to change only things where the default doesn't fit your needs.

<!-- README_REFERENCE_MARKER_REPLACE_NEXT_LINE -->
https://github.com/Robitx/gp.nvim/blob/a88225e90f22acdbc943079f8fa5912e8c101db8/lua/gp/config.lua#L10-L607

# Usage

Full command documentation lives in [Usage](docs/USAGE.md). Shortcut examples live in [Shortcuts](docs/SHORTCUTS.md), and hook/API extension examples live in [Extending gp.nvim](docs/EXTENDING.md).

## Native chat tools

Tool-enabled chat agents can use OpenAI-compatible native function/tool calling. Tools are disabled unless an agent opts in with `tools.enabled`.

Built-in tools:

- `read` — read bounded text files;
- `write` — write text files, creating parent directories;
- `edit` — apply exact text replacements atomically;
- `run` — run a command with arguments, without invoking a shell.

Example tool-enabled agent:

```lua
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
        -- read runs automatically by default
        write = { confirm = true },
        edit = { confirm = true },
        run = {
            -- allowed commands bypass confirmation; all others ask first.
            -- Path commands like /usr/bin/make need exact allowlist entries.
            allowed_commands = { "make", "npm", "pytest" },
        },
    },
}
```

Safety notes:

- Tools work in chat sessions only for the MVP.
- Tools currently use OpenAI-compatible tool-calling payloads; Anthropic/Google native tool formats are not implemented yet.
- Tool-enabled chats stream OpenAI-compatible tool-use rounds by default; set `tools.stream = false` per agent to use the previous non-streaming path.
- During streamed tool-call rounds, tool-call argument chunks are collected without being shown as assistant text; final no-tool assistant responses stream into the chat.
- If a tool-enabled agent uses a provider without native tool support, gp.nvim warns once and falls back to a normal non-streaming chat request without tool schemas.
- `workspace_only = true` is the default; set it to `false` only for trusted/local models.
- `write`, `edit`, and non-allowlisted `run` calls ask for confirmation by default.
- `run.allowed_commands` matches exact command strings; bare commands like `make` can be allowlisted by name, while path commands like `/usr/bin/make` bypass confirmation only when that exact path is allowlisted.
- Model-provided `run.timeout_ms` is capped by the configured `tools.run.timeout_ms` maximum.
- `:GpTools` shows the effective safety config for the current chat agent, including confirmation, allowlist, size, timeout, and workspace settings.
- Tool call/result blocks are visible in chat files for auditability, but old blocks are intentionally not replayed as structured tool messages. Replaying editable markdown as provider-native tool output is deferred until a safer opt-in format with provenance/versioning exists.
- `@command(...)` remains human prompt preprocessing and is separate from native tools.

For the full command reference, including chat, text/code, speech, agent, image, and scripting commands, see [Usage](docs/USAGE.md).

# Shortcuts

See [Shortcuts](docs/SHORTCUTS.md) for native `vim.keymap.set` and which-key examples.

# Extend functionality

See [Extending gp.nvim](docs/EXTENDING.md) for hook examples and the `Prompt`/`Target` extension API.
