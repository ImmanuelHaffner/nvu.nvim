--- nvu.edit.anchors.modifier — resolver for positional modifier anchors.
---
--- Modifiers wrap a base anchor (`line_range`, `unique_text`, ...) and
--- transform its resolved range into a **zero-width position**. They are
--- consumed by `insert` ops — `replace_range` and `delete_range` need
--- ranges, not positions, and the schema rejects modifier-wrapped
--- anchors on those op kinds.
---
--- ## The three modifiers
---
--- Given a base anchor that resolves to lines `[S..E]` (inclusive):
---
--- | Modifier             | Resolved range        | Semantics                                |
--- |----------------------|-----------------------|------------------------------------------|
--- | `before`             | `{S,  S - 1}`         | insert above line S (push S down)        |
--- | `after`              | `{E + 1, E}`          | insert below line E (push later down)    |
--- | `inside`, at "start" | `{S + 1, S}`          | insert *after* the opening line          |
--- | `inside`, at "end"   | `{E, E - 1}`          | insert *before* the closing line         |
---
--- ## The zero-width convention
---
--- A range with `end_line = start_line - 1` is a **zero-width position**:
--- nothing is replaced; new content is inserted at `start_line` and
--- existing content from `start_line` onward shifts down. This maps
--- directly to `nvim_buf_set_lines(bufnr, start_0, start_0, false, lines)`
--- (start and end indices equal — pure insertion).
---
--- ## `inside` on `line_range`
---
--- `line_range` has no syntactic interior — there is no "opening line"
--- and "closing line" the way a function or a block has. We resolve
--- `inside` on `line_range` to the inner edges anyway, by the same
--- formula as any other base: `at: start` → `{S + 1, S}`, `at: end` →
--- `{E, E - 1}`. The redundancy is deliberate (see plan doc §M2): it
--- keeps `inside` uniformly available across base anchors, and authors
--- who want true block-interior semantics can use the treesitter anchor
--- (v2).
---
--- ## Multi-range bases (`occurrence: "all"`)
---
--- The schema allows `before`/`after`/`inside` to wrap a `unique_text`
--- with `occurrence: "all"`, but the semantics of "insert before every
--- match" are not part of MVP — `insert` ops resolve to a single
--- position. If the base resolver returns the multi-range shape
--- `{ranges = {...}}`, this resolver fails with an invariant assertion.
--- (Real-world demand for multi-position inserts can lift this later;
--- the failure mode for now is "schema accepts, planner refuses".)
---
--- @module "nvu.edit.anchors.modifier"

local line_range_anchor  = require'nvu.edit.anchors.line_range'
local unique_text_anchor = require'nvu.edit.anchors.unique_text'

local M = {}

--- Dispatch a base anchor to the right resolver.
---
--- This is a small private dispatcher; the planner-side public dispatch
--- will live in `nvu.edit.anchors` (or `anchors/init.lua`) once it
--- exists. Until then, having the table here keeps the modifier module
--- self-contained.
---
--- @param base_anchor table
--- @param record nvu.edit.FileRecord
--- @return nvu.edit.ResolvedRange|{ranges: nvu.edit.ResolvedRange[]}|nil
--- @return nvu.edit.AnchorFailure|nil
local function resolve_base(base_anchor, record)
    local by = base_anchor.by
    if by == 'line_range'  then return line_range_anchor.resolve(base_anchor, record)  end
    if by == 'unique_text' then return unique_text_anchor.resolve(base_anchor, record) end
    -- v2 kinds (treesitter, lsp_symbol) are rejected at the schema layer
    -- with `unsupported_anchor_kind`, so we should never see them here.
    error(string.format('modifier.resolve_base: unknown base anchor kind %q', tostring(by)))
end

--- Compute the resolved zero-width position for a modifier applied to a
--- base range.
---
--- @param by string                   'before' | 'after' | 'inside'
--- @param at string|nil               'start' | 'end' (required iff by == 'inside')
--- @param base nvu.edit.ResolvedRange
--- @return nvu.edit.ResolvedRange
local function apply_modifier(by, at, base)
    local S, E = base.start_line, base.end_line
    if by == 'before' then
        return { start_line = S, end_line = S - 1 }
    elseif by == 'after' then
        return { start_line = E + 1, end_line = E }
    elseif by == 'inside' then
        if at == 'start' then
            return { start_line = S + 1, end_line = S }
        elseif at == 'end' then
            return { start_line = E, end_line = E - 1 }
        else
            error('modifier.apply_modifier: inside requires at = "start" or "end", got: ' .. tostring(at))
        end
    else
        error('modifier.apply_modifier: unknown modifier `by`: ' .. tostring(by))
    end
end

--- Resolve a positional-modifier anchor against a file record.
---
--- Returns the same shape as `line_range.resolve`: a single resolved
--- zero-width position on success, or a structured failure on error.
--- Errors from the base resolver are propagated transparently — the
--- caller (planner) sees the failure for the base, with the modifier
--- context preserved in the `anchor` echo-back.
---
--- @param anchor table                Validated parsed modifier anchor.
--- @param record nvu.edit.FileRecord
--- @return nvu.edit.ResolvedRange|nil
--- @return nvu.edit.AnchorFailure|nil
function M.resolve(anchor, record)
    assert(type(anchor) == 'table', 'resolve: anchor must be a table')
    local by = anchor.by
    assert(by == 'before' or by == 'after' or by == 'inside',
        'resolve: anchor.by must be a modifier kind (before/after/inside), got: ' .. tostring(by))
    assert(type(anchor.of) == 'table', 'resolve: anchor.of must be a table (the wrapped base anchor)')
    if by == 'inside' then
        assert(anchor.at == 'start' or anchor.at == 'end',
            'resolve: inside requires at = "start" or "end", got: ' .. tostring(anchor.at))
    end
    assert(type(record) == 'table' and type(record.n_lines) == 'number',
        'resolve: record must be a FileRecord (n_lines required)')

    local result, fail = resolve_base(anchor.of, record)
    if fail ~= nil then
        -- Propagate the base failure, but rewrite `anchor` to echo back
        -- the full modifier-wrapped form so the LLM sees its actual
        -- input shape (not just the unwrapped base).
        fail.anchor = anchor
        return nil, fail
    end

    -- The modifier expects a single resolved range, not a multi-range
    -- `{ranges=...}` from occurrence: "all". The schema permits this
    -- combination syntactically; we refuse semantically.
    assert(result.start_line ~= nil and result.end_line ~= nil,
        'modifier wrapping a multi-range base (occurrence: "all") is not supported in MVP — '
        .. 'inserting at multiple positions in one op is undefined. Emit one op per intended position.')

    return apply_modifier(by, anchor.at, result), nil
end

return M
