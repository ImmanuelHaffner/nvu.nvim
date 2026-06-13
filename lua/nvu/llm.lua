---LLM formatting utilities
---Formats editor context for consumption by AI assistants (Markdown output).
--- @module "nvu.llm"
--- @see nvu.editor

local M = {}

local editor = require'nvu.editor'
local fmt = string.format

---Compare two paths for equality after `vim.fs.normalize` normalisation.
---Handles trailing slashes, `~`, env vars, `.`/`..`, and Windows path separators.
---@param a string|nil
---@param b string|nil
---@return boolean
local function paths_equal(a, b)
  if a == nil or b == nil then return false end
  return vim.fs.normalize(a) == vim.fs.normalize(b)
end

---Compute the effective parent cwd for a tab: tab-local if set, otherwise global.
---@param context nvu.editor.Context
---@param tab nvu.editor.TabInfo
---@return string
local function effective_parent_cwd(context, tab)
  return tab.local_cwd or context.cwd
end

---Format the current cursor-line content for display.
---Empty / whitespace-only lines render as italic `*(empty)*`.
---Lines containing backticks fall back to a four-backtick fenced block:
---  - CommonMark requires the closing fence to have at least as many backticks
---    as the opening, so a four-backtick fence can safely contain content with
---    up to three consecutive backticks (e.g. a line from a Markdown file).
---  - This also matches CodeCompanion's wrapper convention (it wraps tool output
---    in four-backtick blocks for the same reason), so a three-backtick fence
---    inside would interact awkwardly with the outer wrapper.
---All other lines render inline as backtick-quoted code.
---@param content string|nil
---@return string
local function format_current_line(content)
  if content == nil or content:match("^%s*$") then
    return "*(empty)*"
  end
  if content:find("`", 1, true) then
    return "\n  ````\n  " .. content .. "\n  ````"
  end
  return "`" .. content .. "`"
end

---Build the metadata sub-line for a window entry: filetype, [buftype], line count,
---visible range — joined by commas, skipping empty parts.
---Note: "modified" / "active" / "CodeCompanion chat" labels are handled by
---`buffer_suffix` and appear on the header line instead.
---@param win nvu.editor.WindowInfo
---@return string
local function window_metadata(win)
  local buf = win.buffer
  local parts = {}

  if buf.filetype and buf.filetype ~= "" then
    table.insert(parts, "`" .. buf.filetype .. "`")
  end
  if buf.buftype and buf.buftype ~= "" then
    table.insert(parts, "[" .. buf.buftype .. "]")
  end
  table.insert(parts, fmt("%d %s", buf.line_count, buf.line_count == 1 and "line" or "lines"))

  local top, bot = win.topline, win.botline
  if top and bot and not (top == 1 and bot == buf.line_count) then
    table.insert(parts, fmt("visible %d–%d", top, bot))
  end

  return table.concat(parts, ", ")
end

---Build the suffix that goes after a buffer's name/handles: active marker plus
---any "kind" labels (currently just CodeCompanion chat). Multiple labels are joined
---with `, ` after a single leading ` — `.
---@param buf nvu.editor.BufferInfo
---@param is_active boolean
---@return string
local function buffer_suffix(buf, is_active)
  local labels = {}
  if is_active then table.insert(labels, "**active**") end
  if buf.is_codecompanion_chat then table.insert(labels, "**CodeCompanion chat**") end
  if buf.is_modified then table.insert(labels, "**modified**") end
  if #labels == 0 then return "" end
  return " — " .. table.concat(labels, ", ")
end

---Emit a window entry (two lines: header + metadata sub-line) plus an optional
---`:lcd` line when the window has a window-local CWD that differs from `effective_cwd`.
---@param win nvu.editor.WindowInfo
---@param effective_cwd string Parent cwd to compare window-local cwd against
---@param lines string[] Output accumulator (mutated)
local function format_window(win, effective_cwd, lines)
  local buf = win.buffer
  local buf_name = (buf.relative_path ~= "" and buf.relative_path) or "[No Name]"

  table.insert(lines, fmt("- `%s` (buf %d, win %d)%s",
    buf_name, buf.bufnr, win.winnr, buffer_suffix(buf, win.is_active)))
  table.insert(lines, "  - " .. window_metadata(win))

  if win.local_cwd and not paths_equal(win.local_cwd, effective_cwd) then
    table.insert(lines, fmt("  - **Window-local CWD** (`:lcd`): `%s`", win.local_cwd))
  end
end

---Format the editor context for LLM consumption.
---@param context nvu.editor.Context The editor context from editor.get_context()
---@return string Formatted Markdown output
function M.format_context(context)
  local lines = {}

  -- Header + global CWD (no H2 wrapper for a one-line field).
  table.insert(lines, "# Editor Context")
  table.insert(lines, "")
  if context.cwd then
    table.insert(lines, fmt("**CWD**: `%s`", context.cwd))
    table.insert(lines, "")
  end

  -- Active position: merges what used to be `## Active Buffer` + `## Cursor Position`,
  -- so the file the cursor is in is stated in the same section as the cursor itself.
  local active_buf_info = editor.get_buffer_info(context.active_buf)
  if active_buf_info then
    -- Locate the active window's tab to print the user-visible tab number alongside the handle.
    local active_tab_number
    for _, tab in ipairs(context.tabs) do
      if tab.handle == context.active_tab then
        active_tab_number = tab.number
        break
      end
    end

    local name = (active_buf_info.relative_path ~= "" and active_buf_info.relative_path) or "[No Name]"
    -- Reuse the per-window suffix builder so labels are consistent across sections.
    -- The active buffer is by definition the active window's buffer, so pass is_active = false
    local suffix = buffer_suffix(active_buf_info, false)

    table.insert(lines, "## Active Position")
    table.insert(lines, fmt("- **File**: `%s` (buf %d)%s", name, context.active_buf, suffix))
    if active_buf_info.filetype and active_buf_info.filetype ~= "" then
      table.insert(lines, fmt("- **Filetype**: `%s`", active_buf_info.filetype))
    end
    table.insert(lines, fmt("- **Lines**: %d", active_buf_info.line_count))
    if active_tab_number then
      table.insert(lines, fmt("- **Location**: tab %d (handle %d), window %d",
        active_tab_number, context.active_tab, context.active_win))
    else
      table.insert(lines, fmt("- **Location**: tab handle %d, window %d",
        context.active_tab, context.active_win))
    end
    table.insert(lines, fmt("- **Cursor**: line %d, column %d",
      context.cursor.line, context.cursor.column_1based))
    table.insert(lines, "  - **Current line**: " .. format_current_line(context.cursor.current_line_content))
    table.insert(lines, "")
  end

  -- Tabs & windows. Renamed from "Visible Buffers" because the section enumerates
  -- windows within tabs (and a buffer can legitimately appear in multiple windows).
  table.insert(lines, "## Tabs & Windows")
  table.insert(lines, "")

  for i, tab in ipairs(context.tabs) do
    if i > 1 then
      table.insert(lines, "")  -- single blank line between tabs
    end

    local tab_marker = tab.is_active and ", active" or ""
    table.insert(lines, fmt("### Tab %d (handle %d%s)", tab.number, tab.handle, tab_marker))

    -- Tab-local CWD only when it differs from global (otherwise it's noise).
    if tab.local_cwd and not paths_equal(tab.local_cwd, context.cwd) then
      table.insert(lines, fmt("- **Tab-local CWD** (`:tcd`): `%s`", tab.local_cwd))
    end

    local effective_cwd = effective_parent_cwd(context, tab)
    for _, win in ipairs(tab.windows) do
      format_window(win, effective_cwd, lines)
    end
  end

  return table.concat(lines, "\n")
end

---Get formatted editor context string
--- @param opts? { winnr?: number, bufnr?: number } Optional window/buffer context
--- @return string Formatted editor context
function M.get_formatted_context(opts)
  local context = editor.get_context(opts)
  return M.format_context(context)
end

return M
