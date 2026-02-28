--- Highlight group utilities
--- @module "nvu.highlight"

local M = {}

--- @class nvu.HighlightGroup
--- @field bg string Background color
--- @field fg string Foreground color
--- @field sp string Special color (for underlines)
--- @field bold boolean
--- @field italic boolean
--- @field inverse boolean
--- @field underline boolean
--- @field undercurl boolean
--- @field underdouble boolean
--- @field underdotted boolean
--- @field underdashed boolean
--- @field strikethrough boolean

--- Gets the attributes of a highlight group.
--- @param name string The highlight group name
--- @return nvu.HighlightGroup|nil The highlight attributes, or nil if group doesn't exist
function M.get(name)
    if vim.fn.hlexists(name) ~= 1 then
        return nil
    end
    local syn_id = vim.fn.synIDtrans(vim.fn.hlID(name))

    return {
        bg = vim.fn.synIDattr(syn_id, 'bg'),
        fg = vim.fn.synIDattr(syn_id, 'fg'),
        sp = vim.fn.synIDattr(syn_id, 'sp'),
        bold = vim.fn.synIDattr(syn_id, 'bold') == 1,
        italic = vim.fn.synIDattr(syn_id, 'italic') == 1,
        inverse = vim.fn.synIDattr(syn_id, 'inverse') == 1,
        underline = vim.fn.synIDattr(syn_id, 'underline') == 1,
        undercurl = vim.fn.synIDattr(syn_id, 'undercurl') == 1,
        underdouble = vim.fn.synIDattr(syn_id, 'underdouble') == 1,
        underdotted = vim.fn.synIDattr(syn_id, 'underdotted') == 1,
        underdashed = vim.fn.synIDattr(syn_id, 'underdashed') == 1,
        strikethrough = vim.fn.synIDattr(syn_id, 'strikethrough') == 1,
    }
end

return M
