--- nvu.event_bus.router
---
--- A tiny, dependency-free event bus. Trackers emit finished, structured events
--- via `emit()`; consumers register `sinks` via `register_sink()`. The router is
--- deliberately ignorant of event semantics: it never inspects `event.text` and
--- holds no per-kind logic. Adding a new tracker or sink requires no change here.
---
--- This module imports NOTHING from CodeCompanion (or any other consumer). The
--- CC fan-out lives in `lua/codecompanion/_extensions/event_bus/` and registers
--- itself as a sink. Other consumers (logging, statusline, ...) can do the same.

--- @class nvu.event_bus.Event
--- @field kind string A short machine tag for the event class (e.g. "cwd").
--- @field text string Human/LLM-ready prose describing what happened. Opaque here.

local M = {}

--- Registered sink callbacks. Each receives a single `nvu.event_bus.Event`.
--- @type table<function, true>
local sinks = setmetatable({}, { __mode = "k" })

--- Register a sink. Idempotent per function identity.
--- @param fn fun(event: nvu.event_bus.Event) Called for every emitted event.
--- @return fun() unregister A function that removes this sink when called.
function M.register_sink(fn)
    assert(type(fn) == "function", "register_sink expects a function")
    sinks[fn] = true
    return function() sinks[fn] = nil end
end

--- Remove a previously registered sink (no-op if absent).
--- @param fn fun(event: nvu.event_bus.Event)
function M.unregister_sink(fn)
    sinks[fn] = nil
end

--- Emit an event to every registered sink. Each sink is called inside `pcall`
--- so one misbehaving sink cannot break delivery to the others, nor can it
--- propagate an error back into the tracker that emitted the event.
--- @param event nvu.event_bus.Event
function M.emit(event)
    assert(type(event) == "table", "emit expects an event table")
    assert(type(event.kind) == "string" and event.kind ~= "", "event.kind must be a non-empty string")
    assert(type(event.text) == "string" and event.text ~= "", "event.text must be a non-empty string")
    for fn in pairs(sinks) do
        local ok, err = pcall(fn, event)
        if not ok then
            vim.schedule(function()
                vim.notify("nvu.event_bus: sink error: " .. tostring(err), vim.log.levels.WARN)
            end)
        end
    end
end

--- Remove all sinks. Primarily for tests / teardown.
function M.clear_sinks()
    sinks = setmetatable({}, { __mode = "k" })
end

return M
