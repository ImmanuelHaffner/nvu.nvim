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
--- @field is_codecompanion_chat? boolean True iff this buffer is a CodeCompanion chat
--- @field codecompanion_chat_id? number|string CodeCompanion chat id (stable across renames)
--- @field codecompanion_chat_title? string CodeCompanion chat title (user-visible; may change)

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
--- @field local_cwd? string Window-local CWD (set via :lcd), if any

--- @class nvu.editor.TabInfo
--- @field handle number Tab handle (stable across the session; pass to nvim_tabpage_* APIs)
--- @field number number User-visible 1-based tab number (from nvim_tabpage_get_number; changes if tabs are reordered)
--- @field is_active boolean Is the active tab
--- @field windows nvu.editor.WindowInfo[] Windows in this tab
--- @field local_cwd? string Tab-local CWD (set via :tcd), if any

--- @class nvu.editor.Context
--- @field tabs nvu.editor.TabInfo[] All tabs
--- @field active_tab number Active tab handle
--- @field active_win number Active window handle
--- @field active_buf number Active buffer number
--- @field cursor nvu.editor.Cursor Cursor position info
--- @field cwd string Global current working directory of the Neovim session

---Detect whether a buffer is a CodeCompanion chat. Uses the public
---`codecompanion.buf_get_chat(bufnr)` API when available; returns identifying
---info that lets the LLM disambiguate "the chat window" from regular buffers.
---Returns `nil, nil, nil` for non-chat buffers (or when codecompanion isn't loaded).
---@param bufnr number
---@return boolean? is_chat, (number|string)? chat_id, string? chat_title
local function get_codecompanion_chat_info(bufnr)
  local ok, codecompanion = pcall(require, 'codecompanion')
  if not ok then return nil, nil, nil end
  local ok2, chat = pcall(codecompanion.buf_get_chat, bufnr)
  if not ok2 or chat == nil then return nil, nil, nil end
  return true, chat.id, chat.title
end

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

  local info = {
    bufnr = bufnr,
    name = name,
    relative_path = relative_path,
    filetype = filetype,
    buftype = buftype,
    line_count = line_count,
    is_modified = vim.bo[bufnr].modified,
    is_readonly = vim.bo[bufnr].readonly,
  }

  -- CodeCompanion chat detection (optional integration; silently skipped if CC isn't loaded).
  -- The chat window has strong "don't displace" semantics; flagging it here lets the LLM
  -- avoid accidentally targeting it for :edit / buffer reuse.
  local is_chat, chat_id, chat_title = get_codecompanion_chat_info(bufnr)
  if is_chat then
    info.is_codecompanion_chat = true
    info.codecompanion_chat_id = chat_id
    info.codecompanion_chat_title = chat_title
  end

  return info
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
    cwd = vim.fn.getcwd(-1, -1),  -- global cwd, independent of window/tab locals
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
    -- vim.fn.haslocaldir/getcwd take a tab *number* (1-based), not a tab *handle*.
    -- nvim_list_tabpages() returns handles, so we must convert.
    local tabnr = vim.api.nvim_tabpage_get_number(tabpage)

    local tab_info = {
      handle = tabpage,
      number = tabnr,
      is_active = tabpage == result.active_tab,
      windows = {},
    }

    -- Tab-local CWD (set via :tcd). haslocaldir(-1, tabnr) is 1 when tab has its own cwd.
    local ok_tcd, has_tcd = pcall(vim.fn.haslocaldir, -1, tabnr)
    if ok_tcd and has_tcd == 1 then
      local ok_cwd, tab_cwd = pcall(vim.fn.getcwd, -1, tabnr)
      if ok_cwd then
        tab_info.local_cwd = tab_cwd
      end
    end

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

          -- Window-local CWD (set via :lcd). haslocaldir(win, tabnr) is 1 when window has its own cwd.
          local ok_lcd, has_lcd = pcall(vim.fn.haslocaldir, win, tabnr)
          if ok_lcd and has_lcd == 1 then
            local ok_cwd, win_cwd = pcall(vim.fn.getcwd, win, tabnr)
            if ok_cwd then
              win_info.local_cwd = win_cwd
            end
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
