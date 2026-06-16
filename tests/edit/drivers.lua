--- Synthetic `drive_file` implementations for applier specs.
---
--- The real driver — `mcphub._native.edit.ui_backend.drive_file` — depends on
--- mcphub's `EditUI` and is callback-driven through `vim.schedule`, making
--- it awkward for unit tests of the applier. The applier's `drive_file`
--- contract (see `nvu.edit.applier.apply_plan`) is small enough that we can
--- supply minimal synthetic implementations here:
---
---   * `accept_all` — applies every block to the buffer, writes the file,
---     and reports every block as `'accepted'`. Mirrors the headless
---     `interactive = false` path of `EditUI`.
---
---   * (Future: `reject_all`, `partial`, `cancel_at`, etc. Deferred until
---     we need reject-path coverage.)
---
--- These drivers are **non-interactive** by construction: they apply blocks
--- synchronously inside their request handler, then invoke `file_cb` via
--- `vim.schedule` so that the applier's sequencing — which assumes the
--- callback fires from a scheduled context — sees the same timing it
--- gets from the production driver.
---
--- @module "tests.edit.drivers"

local M = {}

--- Apply a list of blocks to a buffer in bottom-up order. Within a single
--- file, applying ranges from highest `start_line` to lowest means earlier
--- blocks' line numbers are unaffected by later mutations — no offset
--- bookkeeping needed.
---
--- @param bufnr  integer
--- @param blocks nvu.edit.applier.Block[]
local function apply_blocks(bufnr, blocks)
    -- Sort a shallow copy descending by start_line. For zero-width insertions
    -- (end_line < start_line), `start_line` is still the insertion point —
    -- ordering by it works the same way.
    local ordered = {}
    for i, b in ipairs(blocks) do ordered[i] = b end
    table.sort(ordered, function(a, b)
        return a.range.start_line > b.range.start_line
    end)
    for _, b in ipairs(ordered) do
        local s, e = b.range.start_line, b.range.end_line
        local start_0, end_excl
        if e < s then
            -- Zero-width position { s, s-1 }: insert at line s.
            start_0, end_excl = s - 1, s - 1
        else
            start_0, end_excl = s - 1, e
        end
        vim.api.nvim_buf_set_lines(bufnr, start_0, end_excl, false, b.replace_lines)
    end
end

--- Accept-all synthetic driver. Conforms to the `drive_file` contract from
--- `nvu.edit.applier.apply_plan`.
---
--- Applies every block in the request's buffer, writes the file, and reports
--- `status = 'completed'` with `per_block[block_id] = 'accepted'` for every
--- block. Errors during apply/write surface as `status = 'cancelled'` with
--- `cancel_reason` carrying the message — that path is unlikely in practice
--- (the planner has already validated the buffer and ranges) but it keeps
--- the contract well-defined.
---
--- @param request nvu.edit.applier.FileRequest
--- @param file_cb fun(outcome: nvu.edit.applier.FileOutcome)
function M.accept_all(request, file_cb)
    local ok, err = pcall(function()
        apply_blocks(request.bufnr, request.blocks)
        -- Mirror EditUI:write_if_modified — write only if modified.
        if vim.bo[request.bufnr].modified then
            vim.api.nvim_buf_call(request.bufnr, function()
                vim.cmd.write{ args = { request.file_path }, mods = { silent = true } }
            end)
        end
    end)

    local per_block = {}
    if ok then
        for _, b in ipairs(request.blocks) do per_block[b.block_id] = 'accepted' end
    end

    -- Schedule the callback so the applier's sequencing sees the same
    -- "fires under vim.schedule" timing as the production driver.
    vim.schedule(function()
        if ok then
            file_cb{
                status     = 'completed',
                per_block  = per_block,
                ui_summary = string.format('accept_all: applied %d block(s) to %s',
                    #request.blocks, request.file_path),
            }
        else
            file_cb{
                status        = 'cancelled',
                cancel_reason = 'accept_all driver failed: ' .. tostring(err),
                per_block     = {},
            }
        end
    end)
end

return M
