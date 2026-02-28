--- Telescope entry maker utilities
--- @module "nvu.telescope.entry_makers"
local M = {}

local core = require'nvu.core'
local utils = require'nvu.telescope.utils'
local path_utils = require'nvu.path'

--- Creates an entry maker for file entries with icon and adaptive path shortening.
--- @param opts? table Options: { max_len = number }
--- @return function Entry maker function
function M.file(opts)
    opts = opts or {}

    local telescope_utils = require'telescope.utils'
    local entry_display = require'telescope.pickers.entry_display'
    local devicons = require'nvim-web-devicons'

    return function(entry)
        local max_len = core.resolve(opts.max_len) or 60
        local path = utils.get_path_from_entry(entry)

        local filename = telescope_utils.path_tail(path) or '[No Name]'
        local display_path = path_utils.shorten_relative(path, max_len)
        local glyph, hl_group = devicons.get_icon(filename)

        local display_formatter = entry_display.create{
            separator = ' ',
            items = {
                { width = 1 },         -- Icon
                { remaining = true },  -- Path
            },
        }

        local display_func = function()
            return display_formatter{
                { glyph or '', hl_group or 'Normal' },
                { display_path },
            }
        end

        return {
            value = entry,
            ordinal = path,
            display = display_func,
            filename = filename,
            path = path,
        }
    end
end

--- Creates an entry maker for git commit entries with colored columns.
--- Expected input format: "%H %an %ad %s" with --date=short
--- @param opts? table Options: { hash_width = number, author_width = number, date_width = number }
--- @return function Entry maker function
function M.git_commit(opts)
    opts = opts or {}
    local hash_width = opts.hash_width or 10
    local author_width = opts.author_width or 20
    local date_width = opts.date_width or 10

    local entry_display = require'telescope.pickers.entry_display'

    return function(entry)
        local commit_hash, author, date, message = entry:match('^(%S+) (.-) (%d%d%d%d%-%d%d%-%d%d) (.+)$')

        if not commit_hash or not author or not date or not message then
            return nil  -- Skip malformed entries
        end

        local formatter = entry_display.create{
            separator = ' ',
            items = {
                { width = hash_width },    -- Commit hash
                { width = author_width },  -- Author
                { width = date_width },    -- Date
                { width = 1 },             -- Separator
                { remaining = true },      -- Commit message
            },
        }

        local display = function()
            return formatter{
                { commit_hash:sub(1, hash_width), 'TelescopePreviewLink' },
                { author, 'TelescopeResultsNumber' },
                { date, 'TelescopeResultsIdentifier' },
                { '│' },
                { message },
            }
        end

        return {
            value = commit_hash,
            ordinal = entry,
            display = display,
        }
    end
end

return M
