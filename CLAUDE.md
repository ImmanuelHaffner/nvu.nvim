# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**nvu.nvim** (Neovim Utilities) is a personal utility library for Neovim plugin and configuration development. It provides reusable modules for common tasks like path manipulation, buffer handling, environment detection, and integrations with Telescope and CodeCompanion.

This library is used by our main Neovim configuration at `~/Documents/dotfiles/neovimrc/`.

## Project Structure

```
.
├── README.md                           # User documentation and API reference
├── CLAUDE.md                           # This file
└── lua/
    ├── nvu/                            # Core utility modules
    │   ├── init.lua                    # Main entry point, re-exports all modules
    │   ├── core.lua                    # Toggle, select, resolve helpers
    │   ├── string.lua                  # String manipulation (trim, split, starts/ends_with)
    │   ├── path.lua                    # Path manipulation and smart shortening
    │   ├── buffer.lua                  # Buffer/window utilities, visual selection
    │   ├── env.lua                     # Environment detection (SSH, headless, etc.)
    │   ├── highlight.lua               # Query highlight group attributes
    │   ├── editor.lua                  # Editor context (buffers, cursor, windows)
    │   └── telescope/                  # Telescope integration
    │       ├── init.lua                # Re-exports telescope submodules
    │       ├── utils.lua               # Layout dimension helpers
    │       ├── entry_makers.lua        # Custom entry makers with path shortening
    │       └── previewers.lua          # Custom previewers (buffer, git commit)
    ├── telescope/_extensions/          # Telescope extension
    │   └── adaptive_pickers.lua        # Enhanced pickers with dynamic path shortening
    └── codecompanion/_extensions/      # CodeCompanion extensions
        └── editor_context/
            └── init.lua                # Registers #editor variable and editor_context tool
```

## Key Conventions

### Lua Style
- Maximum line width: 120 columns
- Use `require'module'` syntax (single quotes, no parentheses for simple requires)
- Prefer `vim.api.*` methods over legacy Vimscript
- Use LuaDoc annotations (`---@param`, `---@return`, `---@class`)
- Modules return a table `M` with public functions

### Module Pattern
Each module follows this pattern:
```lua
--- Module description
--- @module nvu.modulename

local M = {}

---Function description
---@param arg type Description
---@return type Description
function M.function_name(arg)
    -- implementation
end

return M
```

### Extension Pattern

#### Telescope Extensions
Located in `lua/telescope/_extensions/`. Follow Telescope's extension API:
```lua
return require('telescope').register_extension{
    setup = function(ext_config, config) end,
    exports = { picker_name = picker_function },
}
```

#### CodeCompanion Extensions
Located in `lua/codecompanion/_extensions/`. Follow CodeCompanion's extension API:
```lua
local Extension = {}

function Extension.setup(opts)
    local cc_config = require("codecompanion.config")
    -- Register tools and variables into cc_config.strategies.chat
end

Extension.exports = {
    -- Functions accessible via codecompanion.extensions.<name>
}

return Extension
```

## Module Descriptions

### `nvu.editor`
Provides editor context information for AI assistants. Used by the CodeCompanion extension.

Key functions:
- `get_buffer_info(bufnr)` - Get detailed info about a buffer
- `get_context(opts)` - Get full editor context (tabs, windows, buffers, cursor)
- `format_context(context)` - Format context as Markdown for LLM consumption
- `get_formatted_context(opts)` - Convenience wrapper combining the above

### `nvu.path`
Smart path shortening that progressively abbreviates directory names to fit a target length.

Key functions:
- `shorten(path, max_len)` - Shorten path by abbreviating directories
- `shorten_absolute(path, max_len)` - Shorten with `~` for home directory
- `shorten_relative(path, max_len)` - Shorten relative to cwd

### `nvu.telescope`
Enhanced Telescope integration with adaptive path display.

The `adaptive_pickers` extension wraps built-in pickers to:
- Dynamically shorten paths based on results window width
- Add file icons via nvim-web-devicons
- Enhance git commit display with colored columns
- Use delta for git commit previews

## CodeCompanion Extension: editor_context

The `editor_context` extension (`lua/codecompanion/_extensions/editor_context/init.lua`) provides:

### Tool: `editor_context`
A tool the LLM can call to get information about the current editor state:
- Active buffer (file path, filetype, line count, modified status)
- Cursor position (line, column, current line content)
- All visible buffers across tabs and windows
- Visible line ranges for each window

### Variable: `#editor`
A variable users can type in chat to include editor context in their message.

### Usage in Neovim Config
```lua
require('codecompanion').setup{
    extensions = {
        editor_context = {
            callback = 'codecompanion._extensions.editor_context',
            opts = {
                require_approval_before = false,
            },
        },
    },
}
```

### Exported Functions
The extension exports functions accessible via `codecompanion.extensions.editor_context`:
- `get_context(opts)` - Get raw editor context data
- `get_formatted_context(opts)` - Get formatted Markdown string
- `get_buffer_info(bufnr)` - Get info about a specific buffer

## Development

### Testing Changes
Since this is a lazy.nvim managed plugin, changes take effect after restarting Neovim or reloading the module:
```lua
-- Force reload a module
package.loaded['nvu.editor'] = nil
local editor = require'nvu.editor'
```

### Related Repository
The main Neovim configuration that uses this library is at:
```
~/Documents/dotfiles/neovimrc/
```

When adding new utilities, consider whether they belong here (reusable) or in the config repo (specific to that setup).

## Important Notes

- This library targets **Neovim 0.11+**
- Telescope integration requires telescope.nvim and nvim-web-devicons
- CodeCompanion integration requires codecompanion.nvim
- Git commit previews require delta to be installed
