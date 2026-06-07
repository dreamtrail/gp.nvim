# Troubleshooting

## `require('gp').setup()` has not been called

Symptom:

- `:checkhealth gp` reports setup was not called;
- commands are missing or not initialized as expected.

Fix:

```lua
require("gp").setup({})
```

Place setup in your plugin manager config or Neovim config after the plugin is on `runtimepath`.

## `curl` is missing

Symptom:

- `:checkhealth gp` reports `curl` is not installed;
- provider calls fail before contacting the API.

Fix: install `curl` with your system package manager. The plugin uses `curl` for chat/completion, transcription, and image requests.

## `grep` is missing

Symptom:

- `:checkhealth gp` reports `grep` is not installed;
- chat finder/search behavior may not work.

Fix: install `grep` with your system package manager.

## Whisper or speech commands fail

Symptoms:

- `:GpWhisper` reports `sox is not installed`;
- recording popup opens but transcription fails;
- `:checkhealth gp` reports missing audio tooling.

Fixes:

- install `sox`;
- verify your microphone works outside Neovim;
- configure `whisper.rec_cmd` if the default recording command is wrong for your platform;
- ensure an OpenAI API key is available because Whisper transcription uses OpenAI's audio endpoint.

Disable Whisper if you do not use it:

```lua
require("gp").setup({
  whisper = { disable = true },
})
```

## Missing or unresolved secrets

Symptoms:

- logs or notifications mention a vault secret not found;
- provider call exits with an auth error;
- a command-based secret works in the shell but not in Neovim.

Fixes:

- prefer environment variables such as `OPENAI_API_KEY` for simple setups;
- test command-based secrets outside Neovim first;
- ensure commands used for secrets are available in Neovim's environment;
- avoid trailing prompts or interactive secret commands;
- do not enable `log_sensitive` unless debugging locally and protecting logs.

## Provider authentication failures

Symptoms:

- HTTP 401/403-like provider errors;
- model call starts but response contains an authentication or permission message.

Fixes:

- verify the provider `endpoint`, `secret`, and enabled agent provider name match;
- confirm the selected model is available for the account/key;
- for OpenAI-compatible local providers, use a dummy secret only if the server accepts it;
- check provider-specific environment variables in `lua/gp/config.lua`.

## Copilot bearer refresh issues

Symptoms:

- Copilot provider works initially then fails after token expiry;
- token refresh logs warnings.

Fixes:

- confirm Copilot is enabled and authenticated in the external Copilot tooling you use;
- verify the configured secret command can read the expected Copilot config file;
- avoid logging or sharing bearer token output.

## Vertex bearer refresh issues

Symptoms:

- Vertex requests fail after token expiry;
- refresh command logs empty token or command failure.

Fixes:

- ensure the configured Vertex secret command is valid, commonly a `gcloud auth print-access-token` style command;
- verify `gcloud` is authenticated outside Neovim;
- ensure Neovim inherits the same PATH and account context.

## Chat file does not look like a chat

Symptom:

- `GpChatRespond` reports that the current file does not look like a chat file.

Likely causes:

- the buffer is too short to be parsed as a chat;
- the first line no longer starts with the topic header (`# `);
- the `- file: ...` header from the chat template was removed.

Fixes:

- create chats with `:GpChatNew` instead of by hand;
- preserve the topic and file headers from the configured chat template;
- if `---` is missing, fix that separately; it produces a parsing error rather than this warning.

## `.gp.md` context is not used

Symptoms:

- repository instructions seem ignored;
- `:GpContext` reports that you are not in a Git repository.

Fixes:

- run commands from a file inside a Git working tree;
- create/open the context file with `:GpContext`;
- ensure the file is named exactly `.gp.md` at the Git root.

## Generated vimdoc is stale

Symptom:

- `doc/gp.nvim.txt` does not reflect README changes.

Explanation:

`doc/gp.nvim.txt` is generated from `README.md` by `.github/workflows/docgen.yml`. For normal documentation changes, update README and docs files, then let CI regenerate vimdoc. Do not hand-edit generated vimdoc unless a release/process explicitly requires it.

## Inspecting plugin state and logs

Useful commands:

```vim
:GpInspectPlugin
:GpInspectLog
:checkhealth gp
```

Be careful when enabling sensitive logging. Logs can contain prompts, provider responses, and optionally secrets if `log_sensitive` is enabled.
