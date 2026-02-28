---Editor context utilities
---Provides information about visible buffers, windows, tabs, and cursor position.
--- @module "nvu.editor"
--- @see nvu.llm For formatting utilities

local M = {}

--- @class nvu.editor.BufferInfo
--- @field bufnr number Buffer number
--- @field name string Full path
--- @field relative_path string Path relative to cwd
--- @field filetype string Filetype
--- @field buftype string Buffer type (empty for normal files)
--- @field line_count number Total lines
--- @field is_modified boolean Has unsaved changes
--- @field is_readonly boolean Is read-only

--- @class nvu.editor.Cursor
--- @field line number 1-based line number
--- @field column number 0-based column number
--- @field column_1based number 1-based column number
--- @field current_line_content? string Content of the current line

--- @class nvu.editor.WindowInfo
--- @field winnr number Window handle
--- @field is_active boolean Is the active window
--- @field buffer nvu.editor.BufferInfo Buffer info
--- @field width number Window width
--- @field height number Window height
--- @field topline? number First visible line
--- @field botline? number Last visible line

--- @class nvu.editor.TabInfo
--- @field tabnr number Tab handle
--- @field is_active boolean Is the active tab
--- @field windows nvu.editor.WindowInfo[] Windows in this tab

--- @class nvu.editor.Context
--- @field tabs nvu.editor.TabInfo[] All tabs
--- @field active_tab number Active tab handle
--- @field active_win number Active window handle
--- @field active_buf number Active buffer number
--- @field cursor nvu.editor.Cursor Cursor position info

---Get information about a buffer
--- @param bufnr number The buffer number
--- @return nvu.editor.BufferInfo|nil Buffer info or nil if invalid
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
--- @param opts? { winnr?: number, bufnr?: number } Optional window/buffer context
--- @return table { tabs: table[], active_tab: number, active_win: number, active_buf: number, cursor: table }
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

return M
