--- String utilities
--- @module nvu.string

local M = {}

--- Checks if a string starts with a given prefix.
--- @param str string The string to check
--- @param prefix string The prefix to look for
--- @return boolean `true` if `str` starts with `prefix`
function M.starts_with(str, prefix)
    return prefix == '' or str:sub(1, #prefix) == prefix
end

--- Checks if a string ends with a given suffix.
--- @param str string The string to check
--- @param suffix string The suffix to look for
--- @return boolean `true` if `str` ends with `suffix`
function M.ends_with(str, suffix)
    return suffix == '' or str:sub(-#suffix) == suffix
end

--- Removes leading and trailing whitespace from a string.
--- @param str string The string to trim
--- @return string The trimmed string
function M.trim(str)
    return str:match'^%s*(.-)%s*$'
end

--- Splits a string by a separator.
--- @param str string The string to split
--- @param sep? string The separator pattern (defaults to whitespace)
--- @return string[] An array of substrings
function M.split(str, sep)
    if sep == nil then
        sep = '%s'
    end
    local fields = {}
    for field in string.gmatch(str, '([^' .. sep .. ']+)') do
        table.insert(fields, field)
    end
    return fields
end

return M
