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

local M = {}

--- Replace a leading $HOME with `~`. Unlike `nvu.path.shorten_absolute`, this
--- does NOT truncate intermediate directories: a cwd fact must be a path the
--- LLM can act on verbatim, so we keep it whole.
--- @param path string
--- @return string
local function tildify(path)
    local home = os.getenv("HOME")
    if home and home ~= "" and path:sub(1, #home) == home then
        return "~" .. path:sub(#home + 1)
    end
    return path
end

--- Wrap a path as a Markdown inline-code span, sizing the fence so any
--- backticks inside the path are preserved literally. On Unix a filename may
--- contain any byte except NUL and `/`, so a backtick is a legal path byte; a
--- fixed single-backtick fence would break the span. The fence is one backtick
--- longer than the longest run inside the path, padded per the CommonMark rule
--- when the content begins or ends with a backtick.
--- @param path string
--- @return string
local function code_span(path)
    local longest = 0
    for run in path:gmatch("`+") do
        if #run > longest then longest = #run end
    end
    local fence = string.rep("`", longest + 1)
    local pad = (path:find("^`") or path:find("`$")) and " " or ""
    return fence .. pad .. path .. pad .. fence
end

--- Build the human/LLM-ready fact for a DirChanged event.
--- @param scope string One of "global" | "tabpage" | "window".
--- @param cwd string The new (resolved) directory.
--- @return string
local function format_fact(scope, cwd)
    local p = code_span(tildify(cwd))
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
