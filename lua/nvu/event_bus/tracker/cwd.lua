--- nvu.event_bus.tracker.cwd
---
--- Tracks current-working-directory changes and emits a scope-aware fact onto
--- the event bus. Driven by the `DirChanged` autocmd, which fires on the EFFECT
--- of any cwd change regardless of cause (typed `:cd`/`:lcd`/`:tcd`, a mapping,
--- `vim.cmd('lcd ...')`, `:execute 'cd '.dir`, a plugin, or a sourced
--- `.nvim.lua`). This is strictly more reliable than intercepting command-line
--- text, which misses every non-cmdline cause.
---
--- Pure module: imports nothing from CodeCompanion. It only depends on
--- `nvu.event_bus.router` and core Neovim APIs.

local router = require("nvu.event_bus.router")
local util = require("nvu.event_bus.tracker.util")

local M = {}

--- Build the human/LLM-ready fact for a DirChanged event.
--- @param scope string One of "global" | "tabpage" | "window".
--- @param cwd string The new (resolved) directory.
--- @return string
local function format_fact(scope, cwd)
    local p = util.code_span(util.tildify(cwd))
    if scope == "window" then
        local win = vim.api.nvim_get_current_win()
        local tab = vim.api.nvim_get_current_tabpage()
        local tabnr = vim.api.nvim_tabpage_get_number(tab)
        return string.format(
            "CWD changed to %s for window %d (tab %d, handle %d), scope=window", p, win, tabnr, tab)
    elseif scope == "tabpage" then
        local tab = vim.api.nvim_get_current_tabpage()
        local tabnr = vim.api.nvim_tabpage_get_number(tab)
        return string.format("CWD changed to %s for tab %d (handle %d), scope=tabpage", p, tabnr, tab)
    else -- "global"
        return string.format(
            "CWD changed to %s, scope=global (affects all windows without a local cwd)", p)
    end
end

--- Install the DirChanged autocmd into the given augroup.
--- @param augroup integer The augroup id to attach the autocmd to.
function M.attach(augroup)
    vim.api.nvim_create_autocmd("DirChanged", {
        group = augroup,
        pattern = "*",
        desc = "nvu.event_bus: report cwd changes to registered sinks",
        callback = function(args)
            -- args.file is the new directory; v:event carries scope + cwd.
            local ev = vim.v.event or {}
            local scope = ev.scope or "global"
            local cwd = ev.cwd or args.file or vim.fn.getcwd()
            router.emit({ kind = "cwd", text = format_fact(scope, cwd) })
        end,
    })
end

return M
