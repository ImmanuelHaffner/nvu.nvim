--- CodeCompanion Extension: Event Bus
---
--- Bridges `nvu.event_bus` into CodeCompanion. On setup it starts the bus
--- (installing the cwd tracker and friends) and registers a SINK that injects
--- each emitted event into the message stack of every live chat as a
--- system-role message.
---
--- Why eager injection (not accumulate-and-flush):
---   * `Chat:add_message` only appends to the in-memory `self.messages` table.
---     There is no network/token cost until that chat next submits, so emitting
---     immediately is effectively free.
---   * The event is physically appended once per chat, giving exactly-once
---     semantics structurally — no per-chat "what has this chat already seen"
---     ledger is needed.
---   * `CodeCompanionChatSubmitted` fires AFTER the payload is built, so it is
---     too late for a flush-on-submit hook without monkey-patching CC internals.
---     Eager injection sidesteps that entirely.
---
--- This is the ONLY file in nvu.nvim that depends on CodeCompanion. All CC
--- modules are resolved at call-time (inside the sink) so live reloads of CC or
--- of `nvu.event_bus.*` are picked up without restarting Neovim.

--- @class CodeCompanion.Extension.EventBus
local Extension = {}

--- Inject a single event into every live chat as a system message. The `## system`
--- header seen in the chat buffer is a buffer-rendering artifact derived from the
--- message `role`; because we use `add_message` (the LLM-facing stack) and not
--- `add_buf_message` (the visible buffer), no header is rendered and we must NOT
--- compose one. The content is the bare fact; the role carries its meaning.
--- @param event nvu.event_bus.Event
local function fan_out_to_chats(event)
    local cc = require("codecompanion")
    local SYSTEM_ROLE = require("codecompanion.config").constants.SYSTEM_ROLE

    local chats = cc.buf_get_chat() -- no arg → list of all live chats
    if type(chats) ~= "table" then return end

    for _, entry in ipairs(chats) do
        local chat = entry.chat
        if chat and chat.bufnr and vim.api.nvim_buf_is_loaded(chat.bufnr) then
            chat:add_message({ role = SYSTEM_ROLE, content = event.text })
        end
    end
end

--- The registered sink. Kept on the module so re-running `setup` can unregister
--- the previous one and avoid duplicate fan-out (idempotent setup).
--- @type fun(event: nvu.event_bus.Event)?
local current_sink

---Setup the extension.
--- @param opts? { trackers?: string[] } Forwarded to `nvu.event_bus.setup`.
function Extension.setup(opts)
    opts = opts or {}

    local event_bus = require("nvu.event_bus")

    -- Start (or restart) the bus with the requested trackers.
    event_bus.setup({ trackers = opts.trackers })

    -- Replace any previously registered sink so repeated setup() calls don't
    -- stack duplicate fan-out callbacks.
    if current_sink then
        event_bus.router.unregister_sink(current_sink)
    end
    current_sink = fan_out_to_chats
    event_bus.router.register_sink(current_sink)
end

-- Exported for tests / introspection. Resolved at call-time for reload safety.
Extension.exports = {
    --- Manually fan an event out to all live chats (bypasses the bus).
    --- @param event nvu.event_bus.Event
    fan_out = function(event) return fan_out_to_chats(event) end,
}

return Extension
