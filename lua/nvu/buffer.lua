--- Buffer and window utilities
--- @module "nvu.buffer"

local M = {}

--- Checks whether the current buffer is empty (has no filename).
--- @return boolean `true` if the buffer has no filename
function M.is_empty()
    return vim.fn.empty(vim.fn.expand('%:t')) == 1
end

--- Checks if the current window width is greater than a given number of columns.
--- @param cols number The number of columns to compare against (compared to half the window width)
--- @return boolean `true` if half the window width is greater than `cols`
function M.has_width_gt(cols)
    return vim.fn.winwidth(0) / 2 > cols
end

--- Gets the current visual selection as a string.
--- @return string The selected text, with lines joined by newlines
function M.get_visual_selection()
    local start_row, start_col = unpack(vim.api.nvim_buf_get_mark(0, '<'))
    local end_row, end_col = unpack(vim.api.nvim_buf_get_mark(0, '>'))
    local lines = vim.api.nvim_buf_get_text(0, start_row - 1, start_col, end_row - 1, end_col + 1, {})
    return table.concat(lines, '\n')
end

--- Searches for the current visual selection.
--- @param forward boolean If true, search forward; otherwise search backward
function M.search_visual_selection(forward)
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local selection = M.get_visual_selection()
    local escaped = vim.fn.escape(selection, '/\\')
    if forward then
        pcall(function() vim.cmd('/\\V' .. escaped) end)
    else
        pcall(function() vim.cmd('?\\V' .. escaped) end)
    end
    vim.api.nvim_win_set_cursor(0, cursor_pos)
end

--- Checks whether any visible buffer satisfies a predicate.
--- Iterates through all buffers visible in windows across all tabpages.
--- @param pred fun(bufid: number): boolean A predicate function
--- @return boolean `true` if any visible buffer satisfies `pred`
function M.any_visible(pred)
    local tabpages = vim.api.nvim_list_tabpages()
    for _, tabid in ipairs(tabpages) do
        local windows = vim.api.nvim_tabpage_list_wins(tabid)
        for _, winid in ipairs(windows) do
            local bufid = vim.api.nvim_win_get_buf(winid)
            if pred(bufid) then return true end
        end
    end
    return false
end

--- Toggles the quickfix window.
--- @return boolean `true` if quickfix was opened, `false` if it was closed
function M.toggle_quickfix()
    local curr_tab = vim.api.nvim_get_current_tabpage()
    local wins = vim.api.nvim_tabpage_list_wins(curr_tab)
    for _, winid in ipairs(wins) do
        local win_info = vim.fn.getwininfo(winid)[1]
        if win_info['quickfix'] == 1 then
            vim.cmd.cclose()
            return false
        end
    end
    vim.cmd.copen()
    return true
end

return M
