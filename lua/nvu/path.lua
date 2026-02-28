--- Path utilities
--- @module "nvu.path"

local M = {}

local string_utils = require'nvu.string'

--- Extracts the basename (filename) from a path.
--- @param path string The file path
--- @return string|nil The basename, or nil if path is empty
function M.basename(path)
    return string.match(path, '/([^/]+)$')
end

--- Shortens a path to fit within a maximum length.
--- Progressively shortens directory names from left to right until the path fits.
--- @param path? string The path to shorten
--- @param max_len number The maximum length
--- @return string? The shortened path
function M.shorten(path, max_len)
    if path == nil or path == '' or path == '/' then return path end

    local len = path:len()
    local fields = string_utils.split(path, '/')

    local SHORTEN_SYMBOL = '…'

    -- Shorten fields until path is short enough
    for idx, field in ipairs(fields) do
        if len <= max_len then break end
        if idx == #fields then break end -- don't shorten last field

        local short_field = field:sub(1, 1) .. SHORTEN_SYMBOL
        local saved = field:len() - (short_field:len() - 2) -- subtract 2 for unicode char
        len = len - saved
        fields[idx] = short_field
    end

    -- Reconstruct path
    local s, _ = path:find('/', 1)
    local starts_with_sep = s == 1
    local short_path = starts_with_sep and '/' or ''
    short_path = short_path .. fields[1]
    for idx = 2, #fields do
        short_path = short_path .. '/' .. fields[idx]
    end
    return short_path
end

--- Shortens an absolute path, replacing $HOME with ~.
--- @param path? string The absolute path to shorten
--- @param max_len number The maximum length
--- @return string? The shortened path
function M.shorten_absolute(path, max_len)
    if path == nil or path == '' then return path end
    local home_dir = os.getenv('HOME') or ''
    local s, e = path:find(home_dir, 1, true)
    if s == 1 then
        return '~' .. M.shorten(path:sub(e + 1, -1), max_len - 1)
    else
        return M.shorten(path, max_len)
    end
end

--- Shortens a path relative to the current working directory.
--- @param path? string The path to shorten
--- @param max_len number The maximum length
--- @return string? The shortened path
function M.shorten_relative(path, max_len)
    if path == nil or path == '' then return path end
    local cwd = vim.fn.getcwd() .. '/'
    local s, e = path:find(cwd, 1, true)
    if s == 1 then
        local rel_path = path:sub(e + 1, -1)
        return M.shorten(rel_path, max_len)
    elseif path:sub(1, 1) == '~' then
        return M.shorten(path:sub(3, -1), max_len)
    elseif path:sub(1, 1) == '/' then
        return M.shorten_absolute(path, max_len)
    else
        return M.shorten(path, max_len)
    end
end

return M
