--- nvu.edit — structured, batch-atomic file-edit engine.
---
--- The pure engine behind the MCP tool `neovim__apply_edit`. Deliberately
--- client-agnostic: no mcphub, no LLM, no MCP, no UI imports. Inputs are
--- typed Lua tables; outputs are typed Lua tables. The mcphub adapter at
--- `lua/mcphub/_native/edit/init.lua` is the only file that bridges this
--- engine to the MCP world.
---
--- @module "nvu.edit"

local M = {}

--- Apply a batch of edit operations.
---
--- Input is the validated request body (the same shape an MCP client sends
--- as the tool argument, modulo any MCP wrapping). Output is the structured
--- response object — `status`, `summary`, `applied[]`, `rejected[]`,
--- `failed[]`, `files[]`, `warnings[]`.
---
--- This implementation is a stub. Every call returns a single `failed[]`
--- entry with reason `"not_implemented"` and status `"failed"`. Real op
--- dispatch will be filled in as the engine is built out.
---
--- @param input table The decoded request body. Eventually expected to
---                    contain `ops`, optional `contents`, `dry_run`,
---                    `description`. The stub only inspects `#input.ops`
---                    for the summary string.
--- @return table response The structured response object.
function M.apply(input)
    local op_count = (type(input) == 'table' and type(input.ops) == 'table') and #input.ops or 0

    return {
        status = 'failed',
        summary = string.format('not implemented (received %d op(s))', op_count),
        applied = {},
        rejected = {},
        failed = {
            {
                op_index = vim.NIL,
                reason = 'not_implemented',
                hint = 'neovim__apply_edit is wired but the engine is a stub.',
            },
        },
        files = {},
        warnings = {},
    }
end

return M
