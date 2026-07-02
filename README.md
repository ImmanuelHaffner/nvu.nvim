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
- **MCP tools for LLM file editing** - Structured, batch-atomic `neovim__apply_edit` and `neovim__read_with_fingerprint` tools (via mcphub.nvim) that replace brittle SEARCH/REPLACE editing
- **lazy.nvim integration** - Programmatic equivalent of `:Lazy check` for agent-driven plugin-upgrade workflows

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
nvu.lazy       -- lazy.nvim integration
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

### `nvu.lazy`

Programmatic integration with lazy.nvim. Provides a structured, agent-friendly equivalent of the `:Lazy check` UI for use in upgrade workflows.

```lua
local lazy_utils = require'nvu.lazy'

-- Trust mode (default): compare HEAD against origin/<branch> using whatever
-- refs the most recent `git fetch` left behind. Fast (milliseconds), but stale
-- if no fetch has been done recently.
local data = lazy_utils.pending_updates()

-- Fetch mode: run `git fetch --quiet` on every installed plugin first.
-- Uses a bounded-concurrency sliding-window scheduler (default 8 parallel
-- fetches). Typically ~20-30s for a ~80-plugin config (vs. ~3 minutes serial).
-- Per-fetch timeout is configurable (default 30s); failures are recorded in
-- the returned `fetch_errors` field rather than throwing.
local data = lazy_utils.pending_updates({ fetch = true })

-- Tune concurrency, per-fetch timeout, freshness threshold.
local data = lazy_utils.pending_updates({
  fetch = true,
  jobs = 16,
  fetch_timeout_ms = 60000,
  freshness_threshold_seconds = 600,
})

-- Format the structured data as a human/LLM-readable Markdown overview,
-- grouped by direction (forward / backward / diverged).
print(lazy_utils.format_pending_updates(data))
```

#### Direction classification

For each plugin where `HEAD ≠ target`, the function classifies the relationship using `git merge-base --is-ancestor`:

| Direction | Meaning | `:Lazy update` behaviour |
|---|---|---|
| `forward` | `from` is ancestor of `to`. Upstream has commits we don't. | Fast-forward. The routine "update available" case. |
| `backward` | `to` is ancestor of `from`. Local HEAD is ahead of the target. | Would **rewind** local HEAD — typically unpushed local work or a `:Lazy restore` to an old pin. |
| `diverged` | Neither is ancestor of the other. Both have unique commits. | Would force-checkout the target, losing local commits. Needs human resolution. |

The returned data includes all three categories — the agent decides which are actionable. Sort order is `forward → backward → diverged`, descending by commit count within each direction.

#### Returns

```lua
{
  updates = {
    {
      name        = 'nvim-metals',
      dir         = '/home/.../lazy/nvim-metals',
      from        = '7ed47cd',                       -- short SHA (current HEAD)
      from_full   = '7ed47cdabc...',                 -- full SHA
      to          = '4cc98f0',                       -- short SHA (target)
      to_full     = '4cc98f0...',                    -- full SHA
      branch      = 'main',
      count       = 7,                               -- commits in the relevant direction
      direction   = 'forward',                       -- 'forward' | 'backward' | 'diverged'
      log         = {                                -- per-commit, newest first
        { sha = '4cc98f0', subject = 'Adding metals root dir to MetalsInfo' },
        ...
      },
    },
    ...
  },
  fetch_age_seconds = 770 * 3600,                    -- max FETCH_HEAD age, nil if no plugin has been fetched
  stale             = true,                          -- fetch_age_seconds > threshold
  fetch_errors      = {                              -- per-plugin failure map; empty if fetch wasn't run or all succeeded
    -- ['plugin-name'] = 'timeout after 30000ms',
    -- ['other-plugin'] = 'fatal: unable to access ...',
  },
}
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

- **`neovim_context` tool** - A tool the LLM can call to get information about visible buffers, cursor position, active window, and the working directory (including per-tab `:tcd` and per-window `:lcd` overrides)
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
-- Returns: { cwd, active_buf, active_win, active_tab, cursor = {...}, tabs = {...} }
-- Each tab carries { handle, number, is_active, local_cwd?, windows = {...} }
-- Each window carries { winnr, is_active, buffer = {...}, topline, botline, local_cwd? }

-- Get formatted Markdown string
local formatted = ext.get_formatted_context()
-- Returns: "# Editor Context\n\n**CWD**: `...`\n\n## Active Position\n..."

-- Get info about a specific buffer
local info = ext.get_buffer_info(bufnr)
-- Returns: { path, name, filetype, lines, modified, ... }
```

### Dependencies

The CodeCompanion extension requires:
- [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim)

---

## MCP Tools: Structured File Editing

nvu.nvim ships a structured, batch-atomic file-edit engine for LLM-assisted editing, exposed as two MCP tools registered on [mcphub.nvim](https://github.com/ravitemer/mcphub.nvim)'s existing `neovim` native server. They replace the brittle SEARCH/REPLACE protocol with a structured **operation/anchor** model: the LLM submits a batch of edits, each located by an anchor rather than by fuzzy-matched search text.

| Tool | What it does |
|---|---|
| `neovim__apply_edit` | Apply a batch of structured edits (`replace_range` / `insert` / `delete_range`) across one or more files. |
| `neovim__read_with_fingerprint` | Read a file and return its content plus a baseline fingerprint the LLM echoes back on every edit. |

### Why

SEARCH/REPLACE-style tools waste turns and produce silent wrong-location edits. This engine instead:

- **Locates edits with structured anchors** - a `line_range`, a `unique_text` substring (must match uniquely, or return structured candidates), or a `before` / `after` / `between` positional modifier. No fuzzy matching: either an anchor resolves exactly, or the batch is refused with candidates and a hint.
- **Closes the read-then-edit race** - every op carries a `baseline_fingerprint` from `read_with_fingerprint`; if the file changed underneath, the batch is refused (`stale_fingerprint`) instead of clobbering.
- **Is plan-atomic and reviewable** - if any anchor fails to resolve, no buffer is touched. Otherwise you review each hunk interactively (per-hunk accept/reject via mcphub's `EditUI`), and outcomes come back per-op in `applied[]` / `rejected[]`.
- **Operates buffer-first** - both tools work on Neovim buffers (loaded or found), so modified buffers win over disk and saving still fires `BufWritePre` / format-on-save.

### Setup

Register the tools by requiring the mcphub adapter **after** `mcphub.setup{}` has run:

```lua
-- after require('mcphub').setup{ ... }
require'mcphub._native.edit'
```

This calls `mcphub.add_tool('neovim', ...)` for both tools. To use them from a CodeCompanion chat, open a **fresh** chat after registration - CodeCompanion snapshots the MCP tool list at chat-session start.

Because `apply_edit` requires a baseline fingerprint on every op, disable other read paths (`neovim__read_file`) on the mcphub `neovim` server so `read_with_fingerprint` is the canonical read - any other read path is a footgun.

### Direct (non-MCP) use

The engine is pure Lua and client-agnostic; call it without MCP:

```lua
require'nvu.edit'.apply(input, drive_file, on_complete)
```

The MCP tools wrap this with a default `drive_file` that opens the hunk-review UI; other callers can supply any conforming driver.

### Full reference

See [`lua/nvu/edit/README.md`](lua/nvu/edit/README.md) for the complete protocol - anchors, operations, batch ordering, content sources, the response shape, and error recovery. Maintenance and design notes live in [`lua/nvu/edit/AGENTS.md`](lua/nvu/edit/AGENTS.md).

### Dependencies

The MCP tools require:
- [mcphub.nvim](https://github.com/ravitemer/mcphub.nvim)

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
