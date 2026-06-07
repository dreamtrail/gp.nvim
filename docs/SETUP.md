# Contributor Setup

This guide is for working on this maintained fork locally. For end-user plugin configuration, see `README.md`.

## Requirements

Required for the core plugin:

- Neovim with Lua support;
- `curl` for provider API calls;
- `grep` for chat finder/search behavior;
- Git for repository-local context discovery and normal development.

Optional features:

- `sox` for Whisper speech-to-text support and `:checkhealth gp` Whisper checks;
- `arecord` or `ffmpeg` for alternative recording backends when configured;
- provider-specific CLIs or files when secrets are resolved by shell command, for example password managers, Copilot config files, or `gcloud` for Vertex bearer refresh.

Do not install dependencies globally as part of routine repository work. This project intentionally has no committed package manager manifest or formal dependency install step.

## Local loading in Neovim

For development, load the checkout directly with your plugin manager or by adjusting `runtimepath`.

Example minimal manual load from inside this repository:

```sh
nvim --cmd "set rtp+=."
```

Then in Neovim:

```vim
:lua require("gp").setup({})
:checkhealth gp
```

For a plugin-manager based setup, point the manager at your local checkout and keep the same basic setup call:

```lua
require("gp").setup({
  -- Prefer environment variables or secret commands over hardcoded keys.
})
```

## Provider configuration

At least one usable provider/agent combination is needed for live model calls. Defaults are defined in `lua/gp/config.lua` and documented in `README.md`.

Common development patterns:

- OpenAI-compatible API: set `OPENAI_API_KEY` or pass `openai_api_key`/provider `secret`.
- Local Ollama or LM Studio: enable the local provider and use the configured local endpoint.
- Anthropic, Google, Perplexity, Azure, Copilot, or Vertex-style providers: enable and configure the matching provider block and agent.

Secrets may be direct strings or command arrays. Prefer environment variables or password-manager commands. Do not commit `.env` files, keys, tokens, or logs containing secrets.

## Repository context file

Commands such as `GpRewrite`, `GpAppend`, and related prompt targets read optional repository instructions from `.gp.md` at the Git root. Use `:GpContext` to create/open that file during manual testing.

## Documentation workflow

User docs live in `README.md`. Maintainer/contributor docs live in `docs/`.

Generated vimdoc lives at `doc/gp.nvim.txt`. It is produced from README by `.github/workflows/docgen.yml` with `panvimdoc`. Avoid hand-editing generated vimdoc; update README and source docs instead.

## Current test setup

No formal test suite or test runner configuration is currently present in this repository. See `docs/TESTING.md` for recommended validation steps before committing changes.
