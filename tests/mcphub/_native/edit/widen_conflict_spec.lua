--- Regression test for the widen-introduced range conflict.
---
--- # The issue this spec pins
---
--- When `ui_backend._test.widen_for_editui` widens a pure-delete-to-EOF
--- block, it borrows the line **before** the deleted range (because there
--- is no line after it). If another op in the same batch targets that
--- borrowed line, the planner's no-conflict invariant — which held over
--- the original (unwidened) ranges — silently breaks at the EditUI seam:
---
---   * Op A: replace_range on line N         (planner range { N, N })
---   * Op B: delete_range on line N+1 (last) (planner range { N+1, N+1 })
---
--- The planner sees no overlap. After widening, op B becomes range
--- `{ N, N+1 }` with `replace_lines = [buf[N]]` — the line op A is
--- already replacing. EditUI's `_apply_all_changes` sorts blocks by
--- `start_line` ascending; with two blocks at `start_line = N`, the
--- stable-sort order is undefined, and in practice op B applies after
--- op A, overwriting A's replacement with the original line A wanted to
--- replace.
---
--- The on-disk result therefore loses op A entirely while reporting
--- `status='applied'` for both ops. This is exactly the silent
--- wrong-location failure mode the apply_edit design set out to
--- eliminate, so it must not ship as-is.
---
--- # Why this spec is currently `pending`
---
--- The fix requires making `widen_for_editui` plan-aware so it can
--- detect a borrowing collision and either (a) pick the other
--- direction, or (b) defer the offending block to a direct-apply
--- bypass that skips EditUI. The test body below asserts the correct
--- post-fix behaviour; flipping `pending` to `it` activates the spec
--- once the fix lands. See the commit message of the fix for the
--- chosen strategy.
---
--- # Why this lives in its own file
---
--- It isn't testing `widen_for_editui` in isolation (that's
--- `tests/mcphub/_native/edit/ui_backend_spec.lua`) and it isn't a
--- general e2e flow (that's `tests/edit/e2e_spec.lua`, which uses the
--- synthetic accept_all driver and so doesn't exercise widening at
--- all). It is specifically about the conflict the widening introduces
--- at the EditUI seam — a category of its own.
---
--- @module "tests.mcphub._native.edit.widen_conflict_spec"

local schema      = require'nvu.edit.schema'
local planner     = require'nvu.edit.planner'
local applier     = require'nvu.edit.applier'
local fingerprint = require'nvu.edit.fingerprint'
local ui_backend  = require'mcphub._native.edit.ui_backend'

--- Same fixture helper as `e2e_spec.lua` — write a tempfile, load into a
--- buffer, compute the baseline fingerprint the same way the engine does.
local function fixture_file(lines, suffix)
    local path = vim.fn.tempname() .. (suffix or '.txt')
    vim.fn.writefile(lines, path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local content = table.concat(buf_lines, '\n')
    if vim.bo[bufnr].endofline then content = content .. '\n' end
    return path, bufnr, fingerprint.compute(content)
end

local function cleanup_fixture(path, bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    os.remove(path)
end

--- Drive the input through schema → planner → applier → ui_backend with
--- `interactive = false`, mirroring `nvu.edit.apply` but bypassing the
--- LLM-facing seal so we can pass `opts.interactive = false`. Returns the
--- response synchronously after waiting on the async on_complete chain.
---
--- EditUI fires `on_complete` via `vim.schedule`, plus `get_summary` is
--- itself async (it waits up to `wait_for_diagnostics` ms). Our ui_backend
--- sets `wait_for_diagnostics = 0`, so the total async budget is one
--- scheduler tick per file. 500 ms is plenty of headroom.
local function run(input)
    local ok, parsed_or_errors = schema.validate(input)
    assert(ok, 'schema validation failed: ' .. vim.inspect(parsed_or_errors))
    local plan, plan_fail = planner.plan(parsed_or_errors)
    assert(plan, 'planner failed: ' .. vim.inspect(plan_fail))

    local response
    applier.apply_plan(plan, { interactive = false }, ui_backend.drive_file,
        function(r) response = r end)
    local ok = vim.wait(500, function() return response ~= nil end, 5)
    assert(ok, 'apply did not complete within 500ms')
    return response
end

describe('widen-introduced range conflict', function()

    pending('preserves a replace on the line a delete-to-EOF borrows', function()
        -- Fixture: 3 lines. Op 1 replaces line 2; op 2 deletes line 3
        -- (the last line). Planner ranges {2,2} and {3,3} — no conflict.
        -- After widening, op 2's range becomes {2, 3} with replace = [line_2],
        -- where line_2 is the original "B" that op 1 is replacing with "B-NEW".
        -- The correct behaviour is for op 1's replacement to survive.
        local path, bufnr, fp = fixture_file({ 'A', 'B', 'C' }, '_widen_conflict.txt')

        local response = run{
            ops = {
                { kind = 'replace_range', path = path, baseline_fingerprint = fp,
                  anchor = { by = 'line_range', start = 2, ['end'] = 2 },
                  content = 'B-NEW' },
                { kind = 'delete_range', path = path, baseline_fingerprint = fp,
                  anchor = { by = 'line_range', start = 3, ['end'] = 3 } },
            },
        }

        -- Both ops reported as applied.
        assert.is.equal('applied', response.status)
        assert.is.equal(2, #response.applied)
        assert.is.equal(0, #response.rejected)
        assert.is.equal(0, #response.failed)

        -- The disk reflects the intended end-state: line 2 is the replacement,
        -- line 3 is gone, file is 2 lines.
        local on_disk = vim.fn.readfile(path)
        assert.is.equal(2,       #on_disk)
        assert.is.equal('A',     on_disk[1])
        assert.is.equal('B-NEW', on_disk[2])

        cleanup_fixture(path, bufnr)
    end,
    [[widen_for_editui borrows backward on delete-to-EOF without checking for
collision with another op's target line, so an adjacent replace can be
silently overwritten by the borrowed original. Fix requires making
widening plan-aware (detect borrowing collisions; pick the opposite
direction or fall back to direct-apply). Flip `pending` to `it` once
the fix lands.]])

end)
