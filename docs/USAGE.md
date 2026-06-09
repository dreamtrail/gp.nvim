# Usage

## Chat commands

#### `:GpChatNew` <!-- {doc=:GpChatNew}  -->

Open a fresh chat in the current window. It can be either empty or include the visual selection or specified range as context. This command also supports subcommands for layout specification:

- `:GpChatNew vsplit` Open a fresh chat in a vertical split window.
- `:GpChatNew split` Open a fresh chat in a horizontal split window.
- `:GpChatNew tabnew` Open a fresh chat in a new tab.
- `:GpChatNew popup` Open a fresh chat in a popup window.

#### `:GpChatPaste` <!-- {doc=:GpChatPaste}  -->

Paste the selection or specified range into the latest chat, simplifying the addition of code from multiple files into a single chat buffer. This command also supports subcommands for layout specification:

- `:GpChatPaste vsplit` Paste into the latest chat in a vertical split window.
- `:GpChatPaste split` Paste into the latest chat in a horizontal split window.
- `:GpChatPaste tabnew` Paste into the latest chat in a new tab.
- `:GpChatPaste popup` Paste into the latest chat in a popup window.

#### `:GpChatToggle` <!-- {doc=:GpChatToggle}  -->

Open chat in a toggleable popup window, showing the last active chat or a fresh one with selection or a range as a context. This command also supports subcommands for layout specification:

- `:GpChatToggle vsplit` Toggle chat in a vertical split window.
- `:GpChatToggle split` Toggle chat in a horizontal split window.
- `:GpChatToggle tabnew` Toggle chat in a new tab.
- `:GpChatToggle popup` Toggle chat in a popup window.

#### `:GpChatFinder` <!-- {doc=:GpChatFinder}  -->

Open a dialog to search through chats.

#### `:GpChatRespond` <!-- {doc=:GpChatRespond}  -->

Request a new GPT response for the current chat. Usin`:GpChatRespond N` request a new GPT response with only the last N messages as context, using everything from the end up to the Nth instance of `🗨:..` (N=1 is like asking a question in a new chat).

#### `:GpChatDelete` <!-- {doc=:GpChatDelete}  -->

Delete the current chat. By default requires confirmation before delete, which can be disabled in config using `chat_confirm_delete = false,`.

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
- Tool call/result blocks are visible in chat files for auditability, but old blocks are not replayed as structured tool messages.
- `@command(...)` remains human prompt preprocessing and is separate from native tools.

## Text/Code commands

#### `:GpRewrite`<!-- {doc=:GpRewrite}  -->

Opens a dialog for entering a prompt. After providing prompt instructions into the dialog, the generated response replaces the current line in normal/insert mode, selected lines in visual mode, or the specified range (e.g., `:%GpRewrite` applies the rewrite to the entire buffer).

`:GpRewrite {prompt}` Executes directly with specified `{prompt}` instructions, bypassing the dialog. Suitable for mapping repetitive tasks to keyboard shortcuts or for automation using headless Neovim via terminal or shell scripts.

#### `:GpAppend` <!-- {doc=:GpAppend}  -->

Similar to `:GpRewrite`, but the answer is added after the current line, visual selection, or range.

#### `:GpPrepend` <!-- {doc=:GpPrepend}  -->

Similar to `:GpRewrite`, but the answer is added before the current line, visual selection, or range.

#### `:GpEnew` <!-- {doc=:GpEnew}  -->

Similar to `:GpRewrite`, but the answer is added into a new buffer in the current window.

#### `:GpNew` <!-- {doc=:GpNew}  -->

Similar to `:GpRewrite`, but the answer is added into a new horizontal split window.

#### `:GpVnew` <!-- {doc=:GpVnew}  -->

Similar to `:GpRewrite`, but the answer is added into a new vertical split window.

#### `:GpTabnew` <!-- {doc=:GpTabnew}  -->

Similar to `:GpRewrite`, but the answer is added into a new tab.

#### `:GpPopup` <!-- {doc=:GpPopup}  -->

Similar to `:GpRewrite`, but the answer is added into a pop-up window.

#### `:GpImplement` <!-- {doc=:GpImplement}  -->

Example hook command to develop code from comments in a visual selection or specified range.

#### `:GpContext`<!-- {doc=:GpContext}  -->

Provides custom context per repository:

- opens `.gp.md` file for a given repository in a toggable window.
- appends selection/range to the context file when used in visual/range mode.
- also supports subcommands for layout specification:

  - `:GpContext vsplit` Open `.gp.md` in a vertical split window.
  - `:GpContext split` Open `.gp.md` in a horizontal split window.
  - `:GpContext tabnew` Open `.gp.md` in a new tab.
  - `:GpContext popup` Open `.gp.md` in a popup window.

- refer to [Custom Instructions](#custom-instructions) for more details.

## Speech commands

#### `:GpWhisper` {lang?} <!-- {doc=:GpWhisper}  -->

Transcription replaces the current line, visual selection or range in the current buffer. Use your mouth to ask a question in a chat buffer instead of writing it by hand, dictate some comments for the code, notes or even your next novel..

For the rest of the whisper commands, the transcription is used as an editable prompt for the equivalent non whisper command - `GpWhisperRewrite` dictates instructions for `GpRewrite` etc.

You can override the default language by setting {lang} with the 2 letter
shortname of your language (e.g. "en" for English, "fr" for French etc).

#### `:GpWhisperRewrite` <!-- {doc=:GpWhisperRewrite}  -->

Similar to `:GpRewrite`, but the prompt instruction dialog uses transcribed spoken instructions.

#### `:GpWhisperAppend` <!-- {doc=:GpWhisperAppend}  -->

Similar to `:GpAppend`, but the prompt instruction dialog uses transcribed spoken instructions for adding content after the current line, visual selection, or range.

#### `:GpWhisperPrepend` <!-- {doc=:GpWhisperPrepend}  -->

Similar to `:GpPrepend`, but the prompt instruction dialog uses transcribed spoken instructions for adding content before the current line, selection, or range.

#### `:GpWhisperEnew` <!-- {doc=:GpWhisperEnew}  -->

Similar to `:GpEnew`, but the prompt instruction dialog uses transcribed spoken instructions for opening content in a new buffer within the current window.

#### `:GpWhisperNew` <!-- {doc=:GpWhisperNew}  -->

Similar to `:GpNew`, but the prompt instruction dialog uses transcribed spoken instructions for opening content in a new horizontal split window.

#### `:GpWhisperVnew` <!-- {doc=:GpWhisperVnew}  -->

Similar to `:GpVnew`, but the prompt instruction dialog uses transcribed spoken instructions for opening content in a new vertical split window.

#### `:GpWhisperTabnew` <!-- {doc=:GpWhisperTabnew}  -->

Similar to `:GpTabnew`, but the prompt instruction dialog uses transcribed spoken instructions for opening content in a new tab.

#### `:GpWhisperPopup` <!-- {doc=:GpWhisperPopup}  -->

Similar to `:GpPopup`, but the prompt instruction dialog uses transcribed spoken instructions for displaying content in a pop-up window.

## Agent commands

#### `:GpNextAgent` <!-- {doc=:GpNextAgent}  -->

Cycles between available agents based on the current buffer (chat agents if current buffer is a chat and command agents otherwise). The agent setting is persisted on disk across Neovim instances.

#### `:GpAgent` <!-- {doc=:GpAgent}  -->

Displays currently used agents for chat and command instructions.

#### `:GpAgent XY` <!-- {doc=:GpAgent-XY}  -->

Choose a new agent based on its name, listing options based on the current buffer (chat agents if current buffer is a chat and command agents otherwise). The agent setting is persisted on disk across Neovim instances.

## Image commands

#### `:GpImage` <!-- {doc=:GpImage}  -->

Opens a dialog for entering a prompt describing wanted images. When the generation is done it opens dialog for storing the image to the disk.

#### `:GpImageAgent` <!-- {doc=:GpImageAgent}  -->

Displays currently used image agent (configuration).

#### `:GpImageAgent XY` <!-- {doc=:GpImageAgent-XY}  -->

Choose a new "image agent" based on its name. In the context of images, agent is basically a configuration for model, image size, quality and so on. The agent setting is persisted on disk across Neovim instances.

## Other commands

#### `:GpStop` <!-- {doc=:GpStop}  -->

Stops all currently running responses and jobs.

#### `:GpTools` <!-- {doc=:GpTools}  -->

Opens a scratch buffer listing built-in native tools, their schemas, and which tools are enabled for the current chat agent.

#### `:GpInspectPlugin` <!-- {doc=:GpInspectPlugin}  -->

Inspects the GPT prompt plugin object in a new scratch buffer.

## GpDone autocommand

Commands like `GpRewrite`, `GpAppend` etc. run asynchronously and generate event `GpDone`, so you can define autocmd (like auto formating) to run when gp finishes:

```lua
    vim.api.nvim_create_autocmd({ "User" }, {
        pattern = {"GpDone"},
        callback = function(event)
            print("event fired:\n", vim.inspect(event))
            -- local b = event.buf
            -- DO something
        end,
    })
```

## Custom instructions

By calling `:GpContext` you can make `.gp.md` markdown file in a root of a repository. Commands such as `:GpRewrite`, `:GpAppend` etc. will respect instructions provided in this file (works better with gpt4, gpt 3.5 doesn't always listen to system commands). For example:

```md
Use ‎C++17.
Use Testify library when writing Go tests.
Use Early return/Guard Clauses pattern to avoid excessive nesting.
...
```

Here is [another example](https://github.com/Robitx/gp.nvim/blob/main/.gp.md).

## Scripting

`GpDone` event + `.gp.md` custom instructions provide a possibility to run gp.nvim using headless (neo)vim from terminal or shell script. So you can let gp run edits accross many files if you put it in a loop.

`test` file:

```
1
2
3
4
5
```

`.gp.md` file:

````
If user says hello, please respond with:

```
Ahoy there!
```
````

calling gp.nvim from terminal/script:

- register autocommand to save and quit nvim when Gp is done
- second jumps to occurrence of something I want to rewrite/append/prepend to (in this case number `3`)
- selecting the line
- calling gp.nvim acction

```
$ nvim --headless -c "autocmd User GpDone wq" -c "/3" -c "normal V" -c "GpAppend hello there"  test
```

resulting `test` file:

```
1
2
3
Ahoy there!
4
5
```
