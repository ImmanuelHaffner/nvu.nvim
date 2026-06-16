--- mcphub._native.edit.ui_backend — `drive_file` callback driven by mcphub's `EditUI`.
---
--- ## Why this file lives here, not under `lua/nvu/edit/`
---
--- The pure engine in `lua/nvu/edit/` deliberately does not import anything
--- from mcphub. This file is the bridge: it implements the `drive_file`
--- shape documented in `nvu.edit.applier.apply_plan` against mcphub's
--- `EditUI`. Any caller wanting a non-mcphub backend (CLI batch mode, a
--- synthetic test driver, etc.) can write a sibling that conforms to the
--- same call contract.
---
--- ## What we reuse from mcphub
---
--- Only `EditUI` itself — not `EditSession`, `DiffParser`, or
--- `BlockLocator`. Those comprise the SEARCH/REPLACE protocol layer we're
--- replacing. `EditUI` is the reusable piece: open file → apply changes →
--- per-hunk review (when interactive) → write. We feed it pre-resolved
--- `LocatedBlock`s constructed from the applier's `Block[]` request.
---
--- See the spelunking notes in `/memories/parked-sessions/nvu-edit-tool.md`
--- for the load-bearing observations about `EditUI`'s shape: `interactive`
--- propagation, `completed_hunks` snapshot timing, `cleanup()` nils state,
--- `get_summary` is async, `_apply_all_changes` sorts ascending internally.
---
--- @module "mcphub._native.edit.ui_backend"

local M = {}

--- Widen a zero-width-range or empty-replace block by borrowing one
--- neighbouring buffer line, so that the `LocatedBlock` handed to mcphub's
--- `EditUI` has both `found_lines` and `replace_lines` non-empty.
---
--- ## Why this exists
---
--- `EditUI._generate_hunk_blocks` constructs the inputs to `vim.diff` as
--- `table.concat(lines, "\n") .. "\n"`. For an empty list this is `"\n"`,
--- which `vim.diff` interprets as a **single empty line**, not zero lines.
--- That breaks two ways:
---
---   * **Pure deletion** (our `delete_range`, `replace_lines == []`):
---     `vim.diff` reports `new_count = 1` instead of `0`. The hunk is
---     classified as `"change"` instead of `"deletion"`; the "change"
---     branch in `_highlight_hunk_block` then calls `nvim_buf_set_extmark`
---     with an `end_row` past the (now-shorter) buffer, crashing with
---     `E5111: Invalid 'end_row': out of range`.
---
---   * **Pure insertion** (zero-width range, `found_lines == []`):
---     `vim.diff` reports `old_count = 1` instead of `0`. Hunk becomes
---     `"change"` instead of `"addition"`; the highlighted row is off by
---     one. (Doesn't crash, but mishighlights.)
---
--- The principled fix is in mcphub. The pragmatic fix is here: synthesise
--- a non-zero-width pair by borrowing one adjacent buffer line. `vim.diff`
--- then naturally splits the resulting pair into a clean addition or
--- deletion sub-hunk (the borrowed line becomes context), so the user
--- sees correct highlighting and `EditUI`'s apply path produces the
--- byte-identical buffer state.
---
--- ## Borrowing strategy
---
---   * **Pure insert** (`range = { N, N-1 }`, `replace_lines = R`):
---     borrow line `N` if it exists, else line `N-1` (insert-at-EOF case).
---     Widen the range to cover the borrowed line and append/prepend it
---     to `replace_lines` so the net buffer effect is unchanged.
---
---   * **Pure delete** (`range = { S, E }`, `replace_lines = []`):
---     borrow line `E+1` if it exists, else line `S-1` (delete-to-EOF).
---     Widen the range to cover the borrowed line; `replace_lines`
---     becomes `[borrowed]`.
---
---   * **Pure delete of the entire buffer** (`S == 1`, `E == #buf`,
---     `replace_lines = []`): no line to borrow on either side. Returns
---     `nil`; the caller must apply this block via a direct
---     `nvim_buf_set_lines` path instead of going through `EditUI`. (Not
---     reachable from the MVP anchor set in practice — would require a
---     user-issued `delete_range` covering all lines.)
---
--- @param bufnr integer
--- @param block nvu.edit.applier.Block
--- @return nvu.edit.applier.Block?  Widened block, or `nil` for the
---     degenerate whole-file-delete case.
local function widen_for_editui(bufnr, block)
    local s, e = block.range.start_line, block.range.end_line
    local replace_lines = block.replace_lines

    local is_pure_insert = e < s              -- zero-width position
    local is_pure_delete = #replace_lines == 0 and not is_pure_insert

    if not is_pure_insert and not is_pure_delete then
        return block  -- nothing to widen
    end

    local total = vim.api.nvim_buf_line_count(bufnr)

    if is_pure_insert then
        -- Anchor `{N, N-1}` (insert before line N).
        local insert_at = s  -- the line that would shift down
        if insert_at <= total then
            -- Borrow line N forward: range becomes {N, N}, replace becomes [...R, line_N].
            local borrowed = vim.api.nvim_buf_get_lines(bufnr, insert_at - 1, insert_at, false)[1]
            local new_replace = {}
            for _, l in ipairs(replace_lines) do new_replace[#new_replace + 1] = l end
            new_replace[#new_replace + 1] = borrowed
            return {
                block_id      = block.block_id,
                op_index      = block.op_index,
                kind          = block.kind,
                range         = { start_line = insert_at, end_line = insert_at },
                replace_lines = new_replace,
            }
        elseif total >= 1 then
            -- Insert-at-EOF: borrow line `total` backward.
            -- Range becomes {total, total}, replace becomes [line_total, ...R].
            local borrowed = vim.api.nvim_buf_get_lines(bufnr, total - 1, total, false)[1]
            local new_replace = { borrowed }
            for _, l in ipairs(replace_lines) do new_replace[#new_replace + 1] = l end
            return {
                block_id      = block.block_id,
                op_index      = block.op_index,
                kind          = block.kind,
                range         = { start_line = total, end_line = total },
                replace_lines = new_replace,
            }
        else
            -- Empty buffer; nothing to borrow. Fall through to nil-return.
            return nil
        end
    end

    -- is_pure_delete
    if e < total then
        -- Borrow line E+1 forward: range becomes {S, E+1}, replace becomes [line_{E+1}].
        local borrowed = vim.api.nvim_buf_get_lines(bufnr, e, e + 1, false)[1]
        return {
            block_id      = block.block_id,
            op_index      = block.op_index,
            kind          = block.kind,
            range         = { start_line = s, end_line = e + 1 },
            replace_lines = { borrowed },
        }
    elseif s > 1 then
        -- Delete-to-EOF: borrow line S-1 backward.
        -- Range becomes {S-1, E}, replace becomes [line_{S-1}].
        local borrowed = vim.api.nvim_buf_get_lines(bufnr, s - 2, s - 1, false)[1]
        return {
            block_id      = block.block_id,
            op_index      = block.op_index,
            kind          = block.kind,
            range         = { start_line = s - 1, end_line = e },
            replace_lines = { borrowed },
        }
    else
        -- Whole-file delete: S == 1, E == total, nothing to borrow.
        return nil
    end
end

--- Build the `LocatedBlock`-shaped table `EditUI` expects, from one of the
--- applier's `Block`s. `EditUI` needs:
---
---   * `block_id`               — scopes the per-hunk IDs generated by
---                                `_generate_hunk_blocks`.
---   * `search_content` / lines — used by `_generate_block_summary` for the
---                                LLM-facing report. Not load-bearing for
---                                the apply path.
---   * `replace_content` / lines — what gets inserted by `_apply_all_changes`.
---   * `location_result`        — `{ found = true, start_line, end_line,
---                                found_lines, ... }`. `_apply_all_changes`
---                                reads `start_line` / `end_line`;
---                                `_generate_hunk_blocks` reads `found_lines`.
---
--- The other `BlockLocationResult` fields are informational (the SEARCH/
--- REPLACE locator emits them for fuzzy-match feedback). We provide
--- harmless defaults so any field reads don't crash on nil.
---
--- @param bufnr      integer
--- @param block      nvu.edit.applier.Block
--- @return table     LocatedBlock-shaped table (mcphub's types.lua).
local function to_located_block(bufnr, block)
    local start_line, end_line = block.range.start_line, block.range.end_line

    -- `end_line < start_line` would be a zero-width insertion, but the
    -- caller (`drive_file`) has already widened pure inserts and pure
    -- deletes via `widen_for_editui` before calling us. We assert that
    -- the post-widen range is non-zero-width and has non-empty replace
    -- content — anything else would crash `EditUI` downstream.
    assert(end_line >= start_line,
        'to_located_block: zero-width range slipped past widen_for_editui')
    assert(#block.replace_lines > 0,
        'to_located_block: empty replace_lines slipped past widen_for_editui')

    local found_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

    local search_text   = table.concat(found_lines, '\n')
    local replace_lines = block.replace_lines
    local replace_text  = table.concat(replace_lines, '\n')

    return {
        block_id        = block.block_id,
        search_content  = search_text,
        search_lines    = found_lines,
        replace_content = replace_text,
        replace_lines   = replace_lines,
        location_result = {
            found              = true,
            start_line         = start_line,
            end_line           = end_line,
            found_lines        = found_lines,
            -- Informational defaults — EditUI's summary code reads these
            -- but treats them as additive; nil would be fine in practice
            -- but explicit defaults keep the contract obvious.
            overall_score      = 1.0,
            overall_match_type = 'exact',
            confidence         = 100,
            found_content      = search_text,
            line_details       = {},
            search_metadata    = {
                method            = 'exact_scan',
                iterations        = 0,
                search_strategy   = 'auto',
                search_bounds     = { start_line, end_line < start_line and start_line or end_line },
                early_termination = false,
            },
        },
    }
end

--- Walk `EditUI.state.completed_hunks` and aggregate hunk-level statuses up
--- to the block level (`per_block[block_id]`). `EditUI` generates hunk IDs
--- of the form `<block_id>_hunk_<N>`, so we scan by prefix.
---
--- Aggregation rule:
---   * any hunk rejected and any hunk accepted → 'partial'
---   * any hunk rejected, none accepted        → 'rejected'
---   * no hunks (block produced no diff)       → absent (treated as accepted by classify_outcome)
---   * all hunks accepted/skipped              → 'accepted'
---
--- `EditUI` uses status `'skipped'` for hunks that couldn't be navigated
--- (e.g. content already matched). For our purposes that's a successful
--- no-op — group it with `'accepted'`.
---
--- @param completed_hunks table<string, string>
--- @param block_ids       string[]
--- @return table<string, string>
local function aggregate_per_block(completed_hunks, block_ids)
    local per_block = {}
    for _, block_id in ipairs(block_ids) do
        local prefix = block_id .. '_'
        local any_rejected, any_accepted = false, false
        local n = 0
        for hunk_id, status in pairs(completed_hunks) do
            if hunk_id:sub(1, #prefix) == prefix then
                n = n + 1
                if status == 'rejected' then
                    any_rejected = true
                elseif status == 'accepted' or status == 'skipped' then
                    any_accepted = true
                end
            end
        end
        if n == 0 then
            -- absent: classify_outcome treats this as accepted on a completed
            -- file and as cancelled on a cancelled file. Don't set anything.
        elseif any_rejected and any_accepted then
            per_block[block_id] = 'partial'
        elseif any_rejected then
            per_block[block_id] = 'rejected'
        else
            per_block[block_id] = 'accepted'
        end
    end
    return per_block
end

--- Drive one file's edits through `EditUI`. Implements the `drive_file`
--- contract from `nvu.edit.applier.apply_plan`.
---
--- @param request  nvu.edit.applier.FileRequest
--- @param file_cb  fun(outcome: nvu.edit.applier.FileOutcome)
function M.drive_file(request, file_cb)
    local EditUI = require'mcphub.native.neovim.files.edit_file.edit_ui'

    -- Convert applier blocks → EditUI LocatedBlocks. Also keep the parallel
    -- block_id list for outcome aggregation.
    --
    -- Each block is first run through `widen_for_editui` to side-step
    -- mcphub's `_generate_hunk_blocks` bug on zero-width / empty-replace
    -- pairs. See that helper's docstring for the full rationale. The
    -- whole-file-delete degenerate case (helper returns `nil`) is not
    -- yet wired through a direct-apply fallback — it would require a
    -- separate code path that bypasses `EditUI` entirely. Surfacing it
    -- as an error keeps the contract well-defined until we hit it in
    -- practice.
    local located_blocks, block_ids = {}, {}
    for _, b in ipairs(request.blocks) do
        local widened = widen_for_editui(request.bufnr, b)
        if widened == nil then
            return file_cb{
                status        = 'cancelled',
                cancel_reason = string.format(
                    'block %s (op %d): whole-file delete is not supported by the EditUI driver',
                    b.block_id, b.op_index or -1),
                per_block     = {},
            }
        end
        located_blocks[#located_blocks + 1] = to_located_block(request.bufnr, widened)
        block_ids[#block_ids + 1] = b.block_id
    end

    -- Guard against the degenerate "no blocks" case. The applier shouldn't
    -- send us this (planner emits at least one located op per included
    -- file), but a defensive return keeps the contract well-defined.
    if #located_blocks == 0 then
        return file_cb{ status = 'no_changes', per_block = {} }
    end

    -- Origin window for "return-to-origin on complete". The current window
    -- is fine: `EditUI.open_file_in_editor` filters by `buftype == ""` when
    -- picking a target split, so the CodeCompanion chat (buftype = "acwrite")
    -- is structurally excluded — see spelunking notes.
    local origin_winnr = vim.api.nvim_get_current_win()

    -- `EditUI.new` deep-merges over its own DEFAULT_CONFIG, so an empty table
    -- is the correct way to say "use all defaults". mcphub's UIConfig
    -- annotation marks every field as required, which is wrong for this
    -- entry point — silence the diagnostic.
    ---@diagnostic disable-next-line: missing-fields
    local ui = EditUI.new({})

    -- Both completion paths share the same epilogue: snapshot state, fetch
    -- summary (async), cleanup, hand outcome to file_cb. We must read
    -- `ui.state.completed_hunks` BEFORE `ui:cleanup()` because cleanup nils
    -- the state table.
    local function finalise(status, cancel_reason)
        local completed_hunks = vim.deepcopy(ui.state and ui.state.completed_hunks or {})
        local per_block = aggregate_per_block(completed_hunks, block_ids)

        -- `get_summary` is async (it may wait for diagnostics). We disable
        -- diagnostic plumbing here — wiring it up is a later concern. The
        -- summary is still informative without it.
        local summary_config = {
            include_session_summary = true,
            include_final_diff      = false,
            send_diagnostics        = false,
            wait_for_diagnostics    = 0,
        }
        ui:get_summary(summary_config, function(summary_text)
            ui:cleanup()
            file_cb{
                status        = status,
                cancel_reason = cancel_reason,
                per_block     = per_block,
                ui_summary    = summary_text ~= '' and summary_text or nil,
            }
        end)
    end

    ui:start_interactive_editing{
        interactive              = request.interactive ~= false,
        is_replacing_entire_file = false,
        origin_winnr             = origin_winnr,
        file_path                = request.file_path,
        located_blocks           = located_blocks,
        original_content         = request.original_content,
        on_complete = function() finalise('completed', nil) end,
        on_cancel   = function(reason) finalise('cancelled', reason) end,
    }
end

--- Test-only surface. Exposes file-local helpers so specs can exercise the
--- borrowing edge cases (mid-buffer / EOF / whole-file) without needing to
--- stand up `EditUI` itself. Not part of the module's public contract — any
--- caller outside `tests/` reaching into this table is on their own.
M._test = { widen_for_editui = widen_for_editui }

return M
