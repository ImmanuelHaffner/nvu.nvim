--- CodeCompanion Extension: MCP Tool Output Size Guard
---
--- Wraps mcphub.nvim's single output-handler factory so that any MCP tool
--- whose response text exceeds a configurable budget has its payload
--- spilled to a tempfile.  The in-chat output is replaced with a short
--- summary, the path, and usage hints (`rg`, `jq`, `head`).
---
--- This catches the entire surface area in one shot: DevPortal, Slack,
--- JIRA, Confluence, Drive, Glean, GitHub, PagerDuty, TestMan, platform,
--- the local Neovim MCP — every server hooked up via mcphub.nvim flows
--- through the same `create_output_handlers().success` callback.
---
--- Why a monkey-patch and not a fork:
--- the user maintains a temporary fork of mcphub already; layering yet
--- another patch into it would couple this defensive layer to upstream
--- bumps.  Patching in `setup()` lives entirely inside our owned code.
---
--- Idempotency: the original `create_output_handlers` is stashed on the
--- module once, so re-running `setup()` (e.g. `:Lazy reload`) does not
--- stack wrappers.
---
--- @module codecompanion._extensions.mcp_size_guard

local spill = require'nvu.spill'

--- @class CodeCompanion.Extension.MCPSizeGuard
local Extension = {}

--- @class CodeCompanion.Extension.MCPSizeGuard.Opts
--- @field max_bytes? integer  Spill threshold in bytes (default: nvu.spill.DEFAULT_MAX_BYTES).
--- @field max_lines? integer  Spill threshold in lines (default: nvu.spill.DEFAULT_MAX_LINES).
--- @field max_tokens? integer Spill threshold in estimated tokens (default: 20000).  Set to false to disable token-based spilling.
--- @field token_counter? fun(s: string): integer  Custom token counter.  Defaults to CodeCompanion's heuristic estimator.
--- @field skip? string[]      Tool display-names whose output should never be spilled.
--- @field gc? boolean|{ max_age_hours?: integer, period_minutes?: integer }  GC config.  `true` (default) runs a startup sweep + hourly timer with 24 h retention; `false` disables GC; a table overrides the defaults.

--- Default token budget — 20 k tokens is the comfortable upper bound for a
--- single tool invocation given typical chat context budgets.  Anything past
--- that is large enough to deserve disk-spilling and on-demand `rg`/`jq`
--- inspection rather than going inline.  The byte/line defaults in
--- `nvu.spill` are derived from this figure (~5 bytes/token, ~10 lines per
--- 100 tokens) so the three budgets stay in the same ballpark.
local DEFAULT_MAX_TOKENS = 20000

--- Cached so we don't double-wrap on repeat setup() calls.
--- @type table<string, boolean>
local SKIP = {}

--- The currently installed GC timer handle (nil if GC is disabled).
--- This is the SOLE owner of the timer lifecycle for this extension.
--- @type nvu.spill.GCHandle|nil
local GC_HANDLE = nil

--- Resolve a token counter, preferring the user's, falling back to
--- CodeCompanion's pure-Lua heuristic.  Returns nil if neither is available
--- (token-based spilling is then silently disabled).
--- @param user_counter fun(s: string): integer|nil
--- @return (fun(s: string): integer)|nil
local function resolve_token_counter(user_counter)
    if type(user_counter) == 'function' then return user_counter end
    local ok, tokens_util = pcall(require, 'codecompanion.utils.tokens')
    if ok and type(tokens_util.calculate) == 'function' then
        return function(s) return tokens_util.calculate(s) end
    end
    return nil
end

--- Build the `success` wrapper that mutates `result.text` in place when
--- it's too large, then delegates to the original handler.
--- @param original_success fun(self: any, stdout: table|nil, meta: any)
--- @param display_name string  Tool name (used as the spill filename label).
--- @param spill_opts table     Pre-resolved opts table passed to `nvu.spill.maybe_spill`.
--- @return fun(self: any, stdout: table|nil, meta: any)
local function make_success_wrapper(original_success, display_name, spill_opts)
    return function(self, stdout, meta)
        if SKIP[display_name] then
            return original_success(self, stdout, meta)
        end
        -- mcphub uses stdout[#stdout] as the "current" result.  Mutating
        -- result.text in place is correct because the original handler
        -- formats it into both to_llm and to_user — keeping them in sync
        -- without re-implementing the markdown wrapping.
        local result = stdout and stdout[#stdout]
        if type(result) == 'table' and type(result.text) == 'string' then
            -- Per-call opts inherit from the resolved defaults but override `label`.
            local call_opts = vim.tbl_extend('force', spill_opts, { label = display_name })
            local replacement, _, spilled = spill.maybe_spill(result.text, call_opts)
            if spilled then
                result.text = replacement
            end
        end
        return original_success(self, stdout, meta)
    end
end

--- Install (or refresh) the monkey-patch on mcphub's output-handler factory.
--- @param spill_opts table  Pre-resolved opts table passed to `nvu.spill.maybe_spill`.
--- @return boolean ok True if the patch was installed.
local function install_patch(spill_opts)
    local ok, mcp_core = pcall(require, 'mcphub.extensions.codecompanion.core')
    if not ok then
        vim.notify(
            'mcp_size_guard: mcphub.extensions.codecompanion.core not loadable; patch NOT installed',
            vim.log.levels.WARN,
            { title = 'CodeCompanion' })
        return false
    end

    -- Stash the original once so re-running setup() doesn't stack wrappers.
    if not mcp_core._mcp_size_guard_original then
        mcp_core._mcp_size_guard_original = mcp_core.create_output_handlers
    end
    local original = mcp_core._mcp_size_guard_original

    --- @diagnostic disable-next-line: duplicate-set-field
    mcp_core.create_output_handlers = function(display_name, has_function_calling, factory_opts)
        local handlers = original(display_name, has_function_calling, factory_opts)
        handlers.success = make_success_wrapper(handlers.success, display_name, spill_opts)
        return handlers
    end
    return true
end

--- Configure GC according to `opts.gc`.
---
--- Behaviour matrix:
---   • opts.gc == false           → no startup sweep, no periodic timer.
---   • opts.gc == nil or true     → startup sweep (deferred) + hourly timer
---                                  with 24 h retention.
---   • opts.gc == { … }           → same as `true` but with overrides for
---                                  `max_age_hours` / `period_minutes`.
---
--- ALWAYS stops a previously installed timer first, regardless of the new
--- mode.  This unifies the "toggle off" and "reconfigure" cases — there is
--- exactly one place where the timer lifecycle is managed, and the rest of
--- the function only decides whether (and how) to start a fresh one.
---
--- @param gc_opts boolean|table|nil
local function configure_gc(gc_opts)
    -- 1. Always stop any previously installed timer.
    if GC_HANDLE then
        GC_HANDLE.stop()
        GC_HANDLE = nil
    end

    -- 2. Bail if GC is disabled.
    if gc_opts == false then return end

    -- 3. Start fresh.
    local cfg = type(gc_opts) == 'table' and gc_opts or {}
    vim.defer_fn(function() pcall(spill.gc, cfg) end, 3000)  -- one-shot startup sweep
    GC_HANDLE = spill.start_periodic_gc(cfg)
end

--- Set up the extension.  Called by CodeCompanion via the extensions config.
--- @param opts? CodeCompanion.Extension.MCPSizeGuard.Opts
function Extension.setup(opts)
    opts = opts or {}

    -- Refresh the skip-set every setup() in case the user changes it.
    SKIP = {}
    for _, name in ipairs(opts.skip or {}) do SKIP[name] = true end

    -- Resolve the token counter once at setup-time; if max_tokens is
    -- explicitly false the counter is omitted entirely (disabling token
    -- check), otherwise we default to CodeCompanion's heuristic estimator
    -- and a 20k token budget.
    local max_tokens = opts.max_tokens
    local token_counter = nil
    if max_tokens ~= false then
        token_counter = resolve_token_counter(opts.token_counter)
        if max_tokens == nil then max_tokens = DEFAULT_MAX_TOKENS end
    else
        max_tokens = nil
    end

    -- Pre-build the opts table that every wrapped success() handler will use.
    local spill_opts = {
        max_bytes = opts.max_bytes,
        max_lines = opts.max_lines,
        max_tokens = max_tokens,
        token_counter = token_counter,
    }

    install_patch(spill_opts)
    configure_gc(opts.gc)
end

--- Functions accessible via `codecompanion.extensions.mcp_size_guard`.
Extension.exports = {
    --- Bypass the guard for a specific tool by display name.
    --- @param tool_name string
    skip = function(tool_name) SKIP[tool_name] = true end,

    --- Re-enable the guard for a previously skipped tool.
    --- @param tool_name string
    unskip = function(tool_name) SKIP[tool_name] = nil end,

    --- Underlying spill helper (also reachable via `require'nvu.spill'`).
    spill = spill,
}

return Extension
