# Extend functionality

You can extend/override the plugin functionality with your own, by putting functions into `config.hooks`.
Hooks have access to everything (see `InspectPlugin` example in defaults) and are
automatically registered as commands (`GpInspectPlugin`).

Here are some more examples:

- `:GpUnitTests`

  ````lua
  -- example of adding command which writes unit tests for the selected code
  UnitTests = function(gp, params)
      local template = "I have the following code from {{filename}}:\n\n"
          .. "```{{filetype}}\n{{selection}}\n```\n\n"
          .. "Please respond by writing table driven unit tests for the code above."
      local agent = gp.get_command_agent()
      gp.Prompt(params, gp.Target.vnew, agent, template)
  end,
  ````

- `:GpExplain`

  ````lua
  -- example of adding command which explains the selected code
  Explain = function(gp, params)
      local template = "I have the following code from {{filename}}:\n\n"
          .. "```{{filetype}}\n{{selection}}\n```\n\n"
          .. "Please respond by explaining the code above."
      local agent = gp.get_chat_agent()
      gp.Prompt(params, gp.Target.popup, agent, template)
  end,
  ````

- `:GpCodeReview`

  ````lua
  -- example of usig enew as a function specifying type for the new buffer
  CodeReview = function(gp, params)
      local template = "I have the following code from {{filename}}:\n\n"
          .. "```{{filetype}}\n{{selection}}\n```\n\n"
          .. "Please analyze for code smells and suggest improvements."
      local agent = gp.get_chat_agent()
      gp.Prompt(params, gp.Target.enew("markdown"), agent, template)
  end,
  ````

- `:GpTranslator`

  ```lua
  -- example of adding command which opens new chat dedicated for translation
  Translator = function(gp, params)
      local chat_system_prompt = "You are a Translator, please translate between English and Chinese."
      gp.cmd.ChatNew(params, chat_system_prompt)

      -- -- you can also create a chat with a specific fixed agent like this:
      -- local agent = gp.get_chat_agent("ChatGPT4o")
      -- gp.cmd.ChatNew(params, chat_system_prompt, agent)
  end,
  ```

- `:GpBufferChatNew`

  ```lua
  -- example of making :%GpChatNew a dedicated command which
  -- opens new chat with the entire current buffer as a context
  BufferChatNew = function(gp, _)
      -- call GpChatNew command in range mode on whole buffer
      vim.api.nvim_command("%" .. gp.config.cmd_prefix .. "ChatNew")
  end,
  ```

The raw plugin text editing method `Prompt` has following signature:
```lua
---@param params table  # vim command parameters such as range, args, etc.
---@param target integer | function | table  # where to put the response
---@param agent table  # obtained from get_command_agent or get_chat_agent
---@param template string  # template with model instructions
---@param prompt string | nil  # nil for non interactive commads
---@param whisper string | nil  # predefined input (e.g. obtained from Whisper)
---@param callback function | nil  # callback(response) after completing the prompt
Prompt(params, target, agent, template, prompt, whisper, callback)
```

- `params` is a [table passed to neovim user commands](https://neovim.io/doc/user/lua-guide.html#lua-guide-commands-create), `Prompt` currently uses:

  - `range, line1, line2` to work with [ranges](https://neovim.io/doc/user/usr_10.html#10.3)
  - `args` so instructions can be passed directly after command (`:GpRewrite something something`)

  ```lua
  params = {
        args = "",
        bang = false,
        count = -1,
        fargs = {},
        line1 = 1352,
        line2 = 1352,
        mods = "",
        name = "GpChatNew",
        range = 0,
        reg = "",
        smods = {
              browse = false,
              confirm = false,
              emsg_silent = false,
              hide = false,
              horizontal = false,
              keepalt = false,
              keepjumps = false,
              keepmarks = false,
              keeppatterns = false,
              lockmarks = false,
              noautocmd = false,
              noswapfile = false,
              sandbox = false,
              silent = false,
              split = "",
              tab = -1,
              unsilent = false,
              verbose = -1,
              vertical = false
        }
  }
  ```

- `target` specifying where to direct GPT response

  - enew/new/vnew/tabnew can be used as a function so you can pass in a filetype
    for the new buffer (`enew/enew()/enew("markdown")/..`)

  ```lua
  M.Target = {
      rewrite = 0, -- for replacing the selection, range or the current line
      append = 1, -- for appending after the selection, range or the current line
      prepend = 2, -- for prepending before the selection, range or the current line
      popup = 3, -- for writing into the popup window

      -- for writing into a new buffer
      ---@param filetype nil | string # nil = same as the original buffer
      ---@return table # a table with type=4 and filetype=filetype
      enew = function(filetype)
          return { type = 4, filetype = filetype }
      end,

      --- for creating a new horizontal split
      ---@param filetype nil | string # nil = same as the original buffer
      ---@return table # a table with type=5 and filetype=filetype
      new = function(filetype)
          return { type = 5, filetype = filetype }
      end,

      --- for creating a new vertical split
      ---@param filetype nil | string # nil = same as the original buffer
      ---@return table # a table with type=6 and filetype=filetype
      vnew = function(filetype)
          return { type = 6, filetype = filetype }
      end,

      --- for creating a new tab
      ---@param filetype nil | string # nil = same as the original buffer
      ---@return table # a table with type=7 and filetype=filetype
      tabnew = function(filetype)
          return { type = 7, filetype = filetype }
      end,
  }
  ```


- `agent` table obtainable via `get_command_agent` and `get_chat_agent` methods which have following signature:
  ```lua
  ---@param name string | nil
  ---@return table # { cmd_prefix, name, model, system_prompt, provider }
  get_command_agent(name)
  ```

- `template`

  - template of the user message send to gpt
  - string can include variables below:

    | name            | Description                       |
    | --------------- | --------------------------------- |
    | `{{filetype}}`  | filetype of the current buffer    |
    | `{{selection}}` | last or currently selected text   |
    | `{{command}}`   | instructions provided by the user |

- `prompt`
  - string used similarly as bash/zsh prompt in terminal, when plugin asks for user command to gpt.
  - if `nil`, user is not asked to provide input (for specific predefined commands - document this, explain that, write tests ..)
  - simple `🤖 ~ ` might be used or you could use different msg to convey info about the method which is called  
    (`🤖 rewrite ~`, `🤖 popup ~`, `🤖 enew ~`, `🤖 inline ~`, etc.)
- `whisper`
  - optional string serving as a default for input prompt (for example generated from speech by Whisper)
- `callback`
  - optional callback function allowing post processing logic on the prompt response  
    (for example letting the model to generate commit message and using the callback to make actual commit)
