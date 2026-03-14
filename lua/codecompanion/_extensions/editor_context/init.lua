--- CodeCompanion Extension: Neovim Context
--- Provides the LLM with context about visible buffers, active buffer, and cursor position.
--- Registers both a tool (neovim_context) and an editor context item (#neovim_context).

local editor = require'nvu.editor'
local llm = require'nvu.llm'

local fmt = string.format

--- @class CodeCompanion.Extension.EditorContext
local Extension = {}

--- System prompt for the neovim_context tool
local TOOL_SYSTEM_PROMPT = [[Use the neovim_context tool to understand what the user is currently looking at or working on in Neovim. This tool is lightweight and cheap to call. When in doubt, call it.

The tool provides:
- The active buffer (file) and its properties (path, filetype, line count, modified status)
- The exact cursor position (line and column) and the content of the current line
- All visible buffers across tabs and windows with their visible line ranges

IMPORTANT: The editor context changes between user messages. The user may have switched files, moved the cursor, or opened new buffers since your last request. If multiple turns have passed, consider refreshing the context.

Call this tool when:
- The user asks about "this file", "current buffer", or "what I'm looking at"
- You need to know the cursor position to make targeted edits
- You need to understand the user's current editing context
- The user's question implies they want you to act on something visible in their editor
- You're unsure which file or location the user is referring to
- Several conversation turns have passed since you last checked the context]]

--- Tool schema for the neovim_context tool
local TOOL_SCHEMA = {
    type = "function",
    ["function"] = {
        name = "neovim_context",
        description = [[Get information about the current editor state in Neovim. This tool provides:
        - The currently active buffer (file being edited) and its properties
        - The exact cursor position (line and column) in the active buffer
        - The content of the current line where the cursor is located
        - A list of all visible buffers across all tabs and windows
        - Which window and tab is currently active
        - Visible line ranges for each window

        Use this tool when you need to understand what the user is currently looking at or working on, or when you need to know the cursor position for making targeted edits.]],
        parameters = {
            type = "object",
            properties = {
                -- Placeholder parameter to satisfy APIs that require non-empty properties
                -- (e.g., Databricks/Bedrock). This parameter is ignored by the tool.
                _placeholder = {
                    type = "string",
                    description = "Unused placeholder parameter. Can be omitted or set to any value.",
                },
            },
            required = {},
        },
    },
}

---Execute the editor context tool
--- @param buffer_context? table The buffer context from CodeCompanion chat
--- @return { status: "success"|"error", data: string }
local function execute_tool(buffer_context)
    local ok, context = pcall(editor.get_context, buffer_context)
    if not ok then
        return {
            status = "error",
            data = fmt("Error getting editor context: %s", tostring(context)),
        }
    end

    local ok2, formatted = pcall(llm.format_context, context)
    if not ok2 then
        return {
            status = "error",
            data = fmt("Error formatting editor context: %s", tostring(formatted)),
        }
    end

    return {
        status = "success",
        data = formatted,
    }
end

---Create the tool definition
--- @param opts table Extension options
--- @return fun(): table Tool factory function (v19 requires callback to be a function)
local function create_tool(opts)
    local log = require("codecompanion.utils.log")

    return function()
        return {
            name = "neovim_context",
            system_prompt = TOOL_SYSTEM_PROMPT,
            cmds = {
                ---Execute the editor context command (v19 signature)
                --- @param self table Tool instance with access to chat context
                --- @param action table The arguments from the LLM's tool call
                --- @param opts_arg { input?: any, output_cb?: fun(msg: table) } Options with input and async callback
                --- @return { status: "success"|"error", data: string }
                function(self, action, opts_arg)
                    -- Get buffer_context from chat (the window/buffer that was active when chat opened)
                    local buffer_context = self.chat and self.chat.buffer_context
                    return execute_tool(buffer_context)
                end,
            },
            schema = TOOL_SCHEMA,
            handlers = {
                --- @param tools CodeCompanion.Tools The tool object
                --- @return nil
                on_exit = function(tools)
                    log:trace("[Neovim Context Tool] on_exit handler executed")
                end,
            },
            output = {
                ---The message which is shared with the user when asking for their approval
                --- @param self CodeCompanion.Tools.Tool
                --- @param tools CodeCompanion.Tools
                --- @return nil|string
                prompt = function(self, tools)
                    return "Get neovim context (visible buffers, cursor position)?"
                end,

                ---v19 output handler signature: (self, stdout, meta)
                --- @param self table
                --- @param stdout table The output from the command
                --- @param meta { cmd: table, tools: CodeCompanion.Tools } Metadata
                success = function(self, stdout, meta)
                    local chat = meta.tools.chat
                    local output = vim.iter(stdout):flatten():join("\n")

                    local llm_output = fmt("<neovimContext>\n%s\n</neovimContext>", output)
                    -- Show full output to user with a summary first line (used as fold text)
                    local user_output = fmt("Retrieved neovim context\n%s", output)

                    chat:add_tool_output(self, llm_output, user_output)
                end,

                ---v19 output handler signature: (self, stderr, meta)
                --- @param self table
                --- @param stderr table The error output from the command
                --- @param meta { cmd: table, tools: CodeCompanion.Tools } Metadata
                error = function(self, stderr, meta)
                    local chat = meta.tools.chat
                    local errors = vim.iter(stderr):flatten():join("\n")
                    log:debug("[Neovim Context Tool] Error output: %s", errors)

                    chat:add_tool_output(self, errors)
                end,

                ---Rejection message back to the LLM
                --- @param self table
                --- @param tools CodeCompanion.Tools
                --- @param cmd table
                --- @param reject_opts table
                --- @return nil
                rejected = function(self, tools, cmd, reject_opts)
                    local message = "The user rejected the neovim context tool"
                    if tools.chat then
                        tools.chat:add_tool_output(self, message)
                    end
                end,
            },
        }
    end
end

---Setup the extension
--- @param opts table Configuration options
function Extension.setup(opts)
    opts = opts or {}

    local cc_config = require("codecompanion.config")

    -- Register the neovim_context tool (v19: callback must be a function that returns the tool table)
    cc_config.config.interactions.chat.tools["neovim_context"] = {
        callback = create_tool(opts),
        description = "Get information about visible buffers, active buffer, and cursor position",
        opts = {
            require_approval_before = opts.require_approval_before or false,
        },
    }

    -- Register the #neovim_context editor context item (v19: `variables` renamed to `editor_context`)
    local editor_context_config = cc_config.config.interactions.chat.editor_context
        or cc_config.config.interactions.chat.variables  -- fallback for older CC versions
    if editor_context_config then
        editor_context_config["neovim_context"] = {
            callback = function(self)
                local buffer_context = self.Chat and self.Chat.buffer_context
                return llm.get_formatted_context(buffer_context)
            end,
            description = "Get information about visible buffers, active buffer, and cursor position",
            opts = {
                contains_code = false,
            },
        }
    end
end

-- Exported functions accessible via codecompanion.extensions.editor_context
Extension.exports = {
    ---Get the raw editor context data
    --- @param opts? { winnr?: number, bufnr?: number }
    --- @return table
    get_context = editor.get_context,

    ---Get formatted editor context string
    --- @param opts? { winnr?: number, bufnr?: number }
    --- @return string
    get_formatted_context = llm.get_formatted_context,

    ---Get buffer info
    --- @param bufnr number
    --- @return table|nil
    get_buffer_info = editor.get_buffer_info,
}

return Extension
