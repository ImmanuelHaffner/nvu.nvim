--- Telescope utility functions
--- @module nvu.telescope.utils
local M = {}

--- Computes layout dimensions by calling Telescope's layout strategy directly.
--- @param layout_strategy? string Override layout strategy (default: from telescope config)
--- @return table { results_width: number, preview_width: number, prompt_width: number }
function M.get_layout_dimensions(layout_strategy)
    local layout_strategies = require('telescope.pickers.layout_strategies')
    local config = require('telescope.config').values

    layout_strategy = layout_strategy or config.layout_strategy or 'horizontal'

    -- Minimal picker object required by layout strategies
    local mock_picker = {
        layout_strategy = layout_strategy,
        layout_config = config.layout_config,
        previewer = true,
        window = { border = true, borderchars = config.borderchars },
        preview_title = '',
        results_title = '',
        prompt_title = '',
    }

    local max_columns = vim.o.columns
    local max_lines = vim.o.lines - vim.o.cmdheight
    if vim.o.laststatus ~= 0 then
        max_lines = max_lines - 1
    end

    local strategy_fn = layout_strategies[layout_strategy]
    if not strategy_fn then
        -- Fallback if strategy not found
        return { results_width = 80, preview_width = 80, prompt_width = 80 }
    end

    local layout = strategy_fn(mock_picker, max_columns, max_lines, config.layout_config)

    return {
        results_width = layout.results and layout.results.width or 80,
        preview_width = layout.preview and layout.preview.width or 0,
        prompt_width = layout.prompt and layout.prompt.width or 80,
    }
end

--- Calculates the results pane width using Telescope's layout strategy.
--- @param layout_strategy? string Override layout strategy (default: from telescope config)
--- @return number The calculated results width in columns
function M.get_results_width(layout_strategy)
    return M.get_layout_dimensions(layout_strategy).results_width
end

--- Calculates the preview pane width using Telescope's layout strategy.
--- @param layout_strategy? string Override layout strategy (default: from telescope config)
--- @return number The calculated preview width in columns
function M.get_preview_width(layout_strategy)
    return M.get_layout_dimensions(layout_strategy).preview_width
end

--- Extracts a file path from various telescope entry types.
--- Handles string entries, buffer entries (from builtin.buffers), and standard telescope entries.
--- @param entry string|table The telescope entry
--- @return string The extracted path, or '[No Name]' if none found
function M.get_path_from_entry(entry)
    if type(entry) == 'string' then
        if entry ~= '' then
            return entry
        end
    elseif type(entry) == 'table' then
        -- Handle buffer entries from builtin.buffers (have bufnr, flag, info fields)
        if entry.info and entry.info.name then
            return entry.info.name
        end
        -- Handle standard telescope entries
        local has_from_entry, from_entry = pcall(require, 'telescope.from_entry')
        if has_from_entry then
            local path = from_entry.path(entry, false, false)
            if path then return path end
        end
    end
    return '[No Name]'
end

return M
