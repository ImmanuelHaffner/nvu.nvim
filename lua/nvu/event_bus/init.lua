--- nvu.event_bus
---
--- A dependency-free feedback bus that turns silent editor state changes into
--- structured events delivered to registered sinks. Trackers detect changes
--- (e.g. cwd via `DirChanged`) and phrase them; sinks consume the finished
--- events. The bus knows nothing about any particular consumer — CodeCompanion
--- integration lives in a separate CC extension that registers itself as a sink.
---
--- Public surface:
---   * `M.router`               — the sink registry (`register_sink`, `emit`, ...).
---   * `M.setup(opts)`          — install trackers; idempotent (safe to re-run).
---
--- This module and everything under `nvu.event_bus.*` import nothing from
--- CodeCompanion.

local M = {}

--- The shared router instance. Consumers register sinks here.
M.router = require("nvu.event_bus.router")

--- Augroup id, created on first `setup()`. Cleared and recreated on re-setup so
--- the bus is safe to configure more than once (e.g. during live development).
--- @type integer?
local augroup

--- All available trackers, keyed by name. Each exposes `attach(augroup)`.
local TRACKERS = {
    cwd = require("nvu.event_bus.tracker.cwd"),
}

--- Install the event bus.
--- @param opts? { trackers?: string[] } `trackers` selects which trackers to
---        attach by name; defaults to all. Unknown names are ignored with a warn.
function M.setup(opts)
    opts = opts or {}

    -- Recreating the augroup with the same name clears any previously installed
    -- autocmds, making setup idempotent.
    augroup = vim.api.nvim_create_augroup("nvu.event_bus", { clear = true })

    local selected = opts.trackers
    if selected == nil then
        selected = vim.tbl_keys(TRACKERS)
    end

    for _, name in ipairs(selected) do
        local tracker = TRACKERS[name]
        if tracker then
            tracker.attach(augroup)
        else
            vim.notify("nvu.event_bus: unknown tracker '" .. tostring(name) .. "'", vim.log.levels.WARN)
        end
    end

    return M
end

return M
