# nvu.nvim

**N**eo**v**im **U**tilities

A collection of utility functions for Neovim plugin and configuration development.

## Features

- **Core utilities** - Toggle, select, and resolve helpers
- **String utilities** - Common string operations (trim, split, starts/ends with)
- **Path utilities** - Path manipulation and smart shortening
- **Buffer utilities** - Buffer/window helpers and visual selection
- **Environment detection** - Detect SSH, headless, client-server connections
- **Highlight utilities** - Query highlight group attributes
- **Telescope integration** - Enhanced entry makers, previewers, and adaptive pickers extension
- **CodeCompanion integration** - Editor context tool and variable for LLM-assisted editing

## Installation

### Lazy.nvim

```lua
{
    'ImmanuelHaffner/nvu.nvim',
    lazy = true,  -- Load on demand
}
```

### packer.nvim

```lua
use 'ImmanuelHaffner/nvu.nvim'
```

## Usage

```lua
local nvu = require'nvu'

-- Access submodules
nvu.core       -- Core utilities
nvu.string     -- String utilities
nvu.path       -- Path utilities
nvu.buffer     -- Buffer utilities
nvu.env        -- Environment detection
nvu.highlight  -- Highlight utilities
nvu.telescope  -- Telescope utilities
```

## API Reference

### `nvu.core`

Core utility functions.

```lua
local core = require'nvu.core'

-- Toggle a boolean option in a table
core.toggle(tbl, 'option_name')

-- Ternary select helper
local result = core.select(condition, true_value, false_value)

-- Resolve a value (calls it if it's a function)
local value = core.resolve(val_or_func)
```

### `nvu.string`

String manipulation utilities.

```lua
local str = require'nvu.string'

-- Check prefix/suffix
str.starts_with('hello world', 'hello')  --> true
str.ends_with('hello world', 'world')    --> true

-- Trim whitespace
str.trim('  hello  ')  --> 'hello'

-- Split string
str.split('a,b,c', ',')  --> {'a', 'b', 'c'}
```

### `nvu.path`

Path manipulation and shortening utilities.

```lua
local path = require'nvu.path'

-- Get basename
path.basename('/home/user/file.lua')  --> 'file.lua'

-- Shorten path to fit max length (shortens directories progressively)
path.shorten('/home/user/projects/myproject/src/file.lua', 30)
--> '/h…/u…/p…/m…/src/file.lua'

-- Shorten absolute path (replaces $HOME with ~)
path.shorten_absolute('/home/user/projects/file.lua', 25)
--> '~/p…/file.lua'

-- Shorten relative to cwd
path.shorten_relative('/current/working/dir/src/file.lua', 20)
--> 's…/file.lua'
```

### `nvu.buffer`

Buffer and window utilities.

```lua
local buffer = require'nvu.buffer'

-- Check if current buffer is empty (no filename)
buffer.is_empty()

-- Check if window width is greater than N columns
buffer.has_width_gt(80)

-- Get visual selection as string
local selection = buffer.get_visual_selection()

-- Search for visual selection
buffer.search_visual_selection(true)   -- forward
buffer.search_visual_selection(false)  -- backward

-- Check if any visible buffer satisfies predicate
buffer.any_visible(function(bufid)
    return vim.bo[bufid].filetype == 'lua'
end)

-- Toggle quickfix window
local opened = buffer.toggle_quickfix()
```

### `nvu.env`

Environment detection utilities.

```lua
local env = require'nvu.env'

-- Check if running locally (not remote)
env.is_local()

-- Check if connected via SSH
env.is_ssh()

-- Check if connected via TCP client-server
env.is_client_server()

-- Check if UI is connected to headless server
env.is_headless()

-- Check if tree-sitter CLI is available
env.has_treesitter_cli()
```

### `nvu.highlight`

Highlight group utilities.

```lua
local highlight = require'nvu.highlight'

-- Get highlight group attributes
local hl = highlight.get('Normal')
-- Returns: { bg, fg, sp, bold, italic, underline, ... }
```

### `nvu.telescope`

Telescope integration utilities. Requires [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim).

```lua
local telescope = require'nvu.telescope'

-- Submodules
telescope.utils         -- Layout dimension helpers
telescope.entry_makers  -- Custom entry makers
telescope.previewers    -- Custom previewers
```

#### Telescope Utils

```lua
local utils = require'nvu.telescope.utils'

-- Get layout dimensions from current Telescope config
local dims = utils.get_layout_dimensions()
-- Returns: { results_width, preview_width, prompt_width }

-- Get specific widths
local results_width = utils.get_results_width()
local preview_width = utils.get_preview_width()

-- Extract path from telescope entry (handles various entry types)
local path = utils.get_path_from_entry(entry)
```

#### Telescope Entry Makers

```lua
local entry_makers = require'nvu.telescope.entry_makers'

-- File entry maker with icons and adaptive path shortening
local maker = entry_makers.file{ max_len = 60 }

-- Git commit entry maker with colored columns
local maker = entry_makers.git_commit{
    hash_width = 10,
    author_width = 20,
    date_width = 10,
}
```

#### Telescope Previewers

```lua
local previewers = require'nvu.telescope.previewers'

-- Buffer previewer (handles unnamed buffers and terminals)
local previewer = previewers.buffer{
    title = 'Preview',
    max_title_len = 100,
}

-- Git commit previewer using delta
local previewer = previewers.git_commit{
    include_file = true,  -- Scope to current file
}
```

---

## CodeCompanion Extension: Editor Context

nvu.nvim includes a CodeCompanion extension that provides the LLM with context about your current editor state. It registers both a **tool** and a **variable**.

### Features

- **`neovim_context` tool** - A tool the LLM can call to get information about visible buffers, cursor position, and active window
- **`#neovim_context` variable** - A variable users can type in chat to include editor context in their message

### What It Provides

The extension gives the LLM access to:

- **Active buffer** - File path, filetype, line count, modified status
- **Cursor position** - Line number, column, and content of the current line
- **Visible buffers** - All buffers visible across tabs and windows with their visible line ranges
- **Window/tab structure** - Which window and tab is currently active

### Setup

```lua
require('codecompanion').setup{
    extensions = {
        editor_context = {
            callback = 'codecompanion._extensions.editor_context',
            opts = {
                -- Set to true to require user approval before the tool runs
                require_approval_before = false,
            },
        },
    },
}
```

### Usage

#### Using the `#neovim_context` Variable

Type `#neovim_context` in your chat message to include the current editor context:

```
#neovim_context Explain what this file does
```

The variable expands to a formatted Markdown block containing all visible buffers, cursor position, and active buffer information.

#### Using the `neovim_context` Tool

The LLM can call the `neovim_context` tool automatically when it needs to understand your current editing context. The tool is designed to be lightweight and is called when:

- You ask about "this file", "current buffer", or "what I'm looking at"
- The LLM needs cursor position for targeted edits
- You're asking about something visible in your editor
- The LLM is unsure which file you're referring to

### Exported Functions

The extension exports functions accessible via `require('codecompanion').extensions.editor_context`:

```lua
local ext = require('codecompanion').extensions.editor_context

-- Get raw editor context data
local context = ext.get_context()
-- Returns: { active = {...}, cursor = {...}, tabs = {...} }

-- Get formatted Markdown string
local formatted = ext.get_formatted_context()
-- Returns: "# Editor Context\n\n## Active Buffer\n..."

-- Get info about a specific buffer
local info = ext.get_buffer_info(bufnr)
-- Returns: { path, name, filetype, lines, modified, ... }
```

### Dependencies

The CodeCompanion extension requires:
- [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim)

---

## Telescope Extension: Adaptive Pickers

nvu.nvim includes a Telescope extension that enhances built-in pickers with:

- Dynamic path shortening based on window size
- File icons via nvim-web-devicons
- Enhanced git commit display with colored columns
- Delta integration for git commit previews
- Custom prompt prefixes

### Setup

```lua
require('telescope').setup{
    extensions = {
        adaptive_pickers = {
            -- Path shortening (number or function)
            max_path_len = function()
                return require'nvu.telescope.utils'.get_results_width() - 5
            end,

            -- Title shortening for preview window
            max_title_len = function()
                return require'nvu.telescope.utils'.get_preview_width() - 4
            end,

            -- Git commit display widths
            git = {
                hash_width = 10,
                author_width = 20,
                date_width = 10,
            },

            -- Enable/disable specific pickers
            pickers = {
                find_files = true,
                git_files = true,
                buffers = true,
                git_commits = true,
                git_bcommits = true,
                git_bcommits_range = true,
            },

            -- Custom prompt prefixes
            prompt_prefixes = {
                find_files = '󰱼 ',  -- alternatives: 󰱽 󰮗 󰈞 󰱼 🔍
                git_files = '  ',
                git_branches = ' ',
                git_commits = ' ',  -- alternatives:    
                git_bcommits = '  ',
                git_bcommits_range = '  ',
                buffers = ' ',
                live_grep = ' ',
            },
        },
    },
}

-- Load the extension
require('telescope').load_extension('adaptive_pickers')
```

### Dependencies

The Telescope extension requires:
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) (for file icons)
- [delta](https://github.com/dandavison/delta) (optional, for git commit previews)

## License

MIT
