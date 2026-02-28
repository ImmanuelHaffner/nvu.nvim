---LLM formatting utilities
---Formats editor context for consumption by AI assistants (Markdown output).
--- @module "nvu.llm"
--- @see nvu.editor

local M = {}

local editor = require'nvu.editor'
local fmt = string.format

---Format the editor context for LLM consumption
--- @param context nvu.editor.Context The editor context from editor.get_context()
--- @return string Formatted Markdown output
function M.format_context(context)
  local lines = {}

  table.insert(lines, "# Editor Context")
  table.insert(lines, "")

  -- Active buffer and cursor info
  local active_buf_info = editor.get_buffer_info(context.active_buf)
  if active_buf_info then
    table.insert(lines, "## Active Buffer")
    table.insert(lines, fmt("- **File**: `%s`", active_buf_info.relative_path ~= "" and active_buf_info.relative_path or "[No Name]"))
    table.insert(lines, fmt("- **Buffer**: %d", context.active_buf))
    table.insert(lines, fmt("- **Window**: %d (Tab %d)", context.active_win, context.active_tab))
    if active_buf_info.filetype ~= "" then
      table.insert(lines, fmt("- **Filetype**: `%s`", active_buf_info.filetype))
    end
    table.insert(lines, fmt("- **Total Lines**: %d", active_buf_info.line_count))
    table.insert(lines, fmt("- **Modified**: %s", active_buf_info.is_modified and "Yes" or "No"))
    table.insert(lines, "")
  end

  -- Cursor position
  table.insert(lines, "## Cursor Position")
  table.insert(lines, fmt("- **Line**: %d", context.cursor.line))
  table.insert(lines, fmt("- **Column**: %d", context.cursor.column_1based))
  if context.cursor.current_line_content then
    table.insert(lines, fmt("- **Current Line Content**:\n  ```\n  %s\n  ```", context.cursor.current_line_content))
  end
  table.insert(lines, "")

  -- Visible buffers across all tabs
  table.insert(lines, "## Visible Buffers")
  table.insert(lines, "")

  for _, tab in ipairs(context.tabs) do
    local tab_marker = tab.is_active and " (active)" or ""
    table.insert(lines, fmt("### Tab %d%s", tab.tabnr, tab_marker))

    for _, win in ipairs(tab.windows) do
      local win_marker = win.is_active and " **(active window)**" or ""
      local buf = win.buffer
      local buf_name = buf.relative_path ~= "" and buf.relative_path or "[No Name]"

      if buf.buftype == "" or buf.buftype == nil then
        -- Regular file buffer
        table.insert(lines, fmt("- `%s` (buf %d, win %d)%s", buf_name, buf.bufnr, win.winnr, win_marker))
        if buf.filetype ~= "" then
          table.insert(lines, fmt("  - Filetype: `%s`", buf.filetype))
        end
        table.insert(lines, fmt("  - Lines: %d (visible: %d-%d)", buf.line_count, win.topline or 1, win.botline or buf.line_count))
        if buf.is_modified then
          table.insert(lines, "  - **Modified**")
        end
      else
        -- Special buffer (terminal, help, etc.)
        table.insert(lines, fmt("- [%s] `%s` (buf %d, win %d)%s", buf.buftype, buf_name, buf.bufnr, win.winnr, win_marker))
      end
    end
    table.insert(lines, "")
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
