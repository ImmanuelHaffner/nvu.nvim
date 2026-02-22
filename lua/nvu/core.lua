--- Core utilities
--- @module nvu.core

local M = {}

--- Toggle a boolean option in a table.
--- @param tbl table The table containing the option
--- @param opt string The key of the option to toggle
function M.toggle(tbl, opt)
    tbl[opt] = not tbl[opt]
end

--- Select between two values based on a condition (ternary helper).
--- @param cond boolean The condition to evaluate
--- @param tru any The value to return if `cond` is true
--- @param fals any The value to return if `cond` is false
--- @return any The selected value
function M.select(cond, tru, fals)
    if cond then return tru else return fals end
end

return M
