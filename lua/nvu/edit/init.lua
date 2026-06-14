--- nvu.edit — structured, batch-atomic file-edit engine.
---
--- The pure engine behind the MCP tool `neovim__apply_edit`. Deliberately
--- client-agnostic: no mcphub, no LLM, no MCP, no UI imports. Inputs are
--- typed Lua tables; outputs are typed Lua tables. The mcphub adapter at
--- `lua/mcphub/_native/edit/init.lua` is the only file that bridges this
--- engine to the MCP world.
---
--- @module "nvu.edit"

local schema = require'nvu.edit.schema'

local M = {}

--- Render a list of schema errors as `failed[]` entries in the canonical
--- response shape. Each error becomes one entry with `reason = "schema_invalid"`
--- and the structured field details promoted to top-level keys.
local function errors_to_failed(errors)
    local failed = {}
    for _, e in ipairs(errors) do
        table.insert(failed, {
            op_index = e.op_index ~= nil and e.op_index or vim.NIL,
            reason   = 'schema_invalid',
            path     = e.path,
            sub_reason = e.reason,       -- the schema's own taxonomy (missing_field, wrong_type, …)
            message  = e.message,
            hint     = e.hint,
            expected = e.expected,
            got      = e.got,
        })
    end
    return failed
end

--- Apply a batch of edit operations.
---
--- @param input table The decoded request body (raw, untyped — validation happens here).
--- @return table response The structured response object.
function M.apply(input)
    -- Phase 1: schema validation. On failure we return immediately with one
    -- `failed[]` entry per error, each carrying a hint describing the discrete
    -- next move the caller should make.
    local ok, parsed_or_errors = schema.validate(input)
    if not ok then
        return {
            status  = 'failed',
            summary = schema.format_error_summary(parsed_or_errors),
            applied = {},
            rejected = {},
            failed  = errors_to_failed(parsed_or_errors),
            files   = {},
            warnings = {},
        }
    end

    -- Phase 2+ (planner, applier, preview) are not yet implemented. Schema
    -- validation succeeded and we have a typed parsed request, so the failure
    -- shape carries `op_index` correctly even though we cannot yet act on it.
    local parsed = parsed_or_errors
    local failed = {}
    for i = 1, #parsed.ops do
        table.insert(failed, {
            op_index = i - 1,
            reason   = 'not_implemented',
            message  = 'edit engine is not yet implemented past schema validation',
            hint     = 'the request shape is valid; execution backends '
                .. '(planner, applier, preview) will be wired up in later work',
        })
    end

    return {
        status   = 'failed',
        summary  = string.format(
            'schema valid (%d op(s)); engine not yet implemented past schema validation',
            #parsed.ops),
        applied  = {},
        rejected = {},
        failed   = failed,
        files    = {},
        warnings = parsed.warnings,
    }
end

return M
