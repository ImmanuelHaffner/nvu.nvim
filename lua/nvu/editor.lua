--- Editor context utilities
--- Provides information about visible buffers, active buffer, and cursor position.
--- @module nvu.editor

local M = {}

local fmt = string.format

---Get information about a buffer
---@param bufnr number The buffer number
---@return table|nil Buffer info or nil if invalid
function M.get_buffer_info(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype
  local buftype = vim.bo[bufnr].buftype
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- Get relative path if possible
  local cwd = vim.fn.getcwd()
  local relative_path = name
  if name ~= "" then
    relative_path = vim.fs.relpath(cwd, name) or name
  end

  return {
    bufnr = bufnr,
    name = name,
    relative_path = relative_path,
    filetype = filetype,
    buftype = buftype,
    line_count = line_count,
    is_modified = vim.bo[bufnr].modified,
    is_readonly = vim.bo[bufnr].readonly,
  }
end

---Get all visible buffers across all tabs and windows
---@param opts? { winnr?: number, bufnr?: number } Optional window/buffer context
---@return table { tabs: table[], active_tab: number, active_win: number, active_buf: number, cursor: table }
function M.get_context(opts)
  opts = opts or {}

  -- Use provided context or fall back to current window/buffer
  local active_win = opts.winnr or vim.api.nvim_get_current_win()
  local active_buf = opts.bufnr or vim.api.nvim_get_current_buf()

  -- Validate that the source window/buffer still exist
  if not vim.api.nvim_win_is_valid(active_win) then
    active_win = vim.api.nvim_get_current_win()
  end
  if not vim.api.nvim_buf_is_valid(active_buf) then
    active_buf = vim.api.nvim_get_current_buf()
  end

  local result = {
    tabs = {},
    active_tab = vim.api.nvim_win_get_tabpage(active_win),
    active_win = active_win,
    active_buf = active_buf,
    cursor = {},
  }

  -- Get cursor position in active buffer
  local cursor_pos = vim.api.nvim_win_get_cursor(active_win)
  result.cursor = {
    line = cursor_pos[1],           -- 1-based line number
    column = cursor_pos[2],         -- 0-based column number
    column_1based = cursor_pos[2] + 1,  -- 1-based column for display
  }

  -- Get the current line content for context
  local current_line = vim.api.nvim_buf_get_lines(result.active_buf, cursor_pos[1] - 1, cursor_pos[1], false)
  if #current_line > 0 then
    result.cursor.current_line_content = current_line[1]
  end

  -- Iterate through all tabs
  local tabpages = vim.api.nvim_list_tabpages()
  for _, tabpage in ipairs(tabpages) do
    local tab_info = {
      tabnr = tabpage,
      is_active = tabpage == result.active_tab,
      windows = {},
    }

    -- Get all windows in this tab (excluding floating windows)
    local wins = vim.api.nvim_tabpage_list_wins(tabpage)
    for _, win in ipairs(wins) do
      local win_config = vim.api.nvim_win_get_config(win)
      local is_floating = win_config.relative ~= nil and win_config.relative ~= ""
      if vim.api.nvim_win_is_valid(win) and not is_floating then
        local bufnr = vim.api.nvim_win_get_buf(win)
        local buf_info = M.get_buffer_info(bufnr)

        if buf_info then
          local win_info = {
            winnr = win,
            is_active = win == result.active_win,
            buffer = buf_info,
          }

          -- Get window dimensions
          win_info.width = vim.api.nvim_win_get_width(win)
          win_info.height = vim.api.nvim_win_get_height(win)

          -- Get visible line range in this window
          local win_info_dict = vim.fn.getwininfo(win)[1]
          if win_info_dict then
            win_info.topline = win_info_dict.topline
            win_info.botline = win_info_dict.botline
          end

          table.insert(tab_info.windows, win_info)
        end
      end
    end

    table.insert(result.tabs, tab_info)
  end

  return result
end

---Format the editor context for LLM consumption
---@param context table The editor context from get_context()
---@return string Formatted output
function M.format_context(context)
  local lines = {}

  table.insert(lines, "# Editor Context")
  table.insert(lines, "")

  -- Active buffer and cursor info
  local active_buf_info = M.get_buffer_info(context.active_buf)
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
---@param opts? { winnr?: number, bufnr?: number } Optional window/buffer context
---@return string Formatted editor context
function M.get_formatted_context(opts)
  local context = M.get_context(opts)
  return M.format_context(context)
end

return M
