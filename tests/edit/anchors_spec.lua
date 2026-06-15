--- Tests for nvu.edit.anchors.*.
---
--- Run headless:
---   nvim --headless --noplugin -u NONE \
---     -c "set rtp+=$PWD" -c "luafile tests/runner.lua" -c "qall!"
---
--- Or one file at a time:
---   :lua require'tests.runner'.run_file('tests/edit/anchors_spec.lua')

local fr           = require'nvu.edit.file_record'
local line_range   = require'nvu.edit.anchors.line_range'
local schema       = require'nvu.edit.schema'

--- Build a parsed `line_range` anchor with the schema's key shape.
--- The schema uses `['end']` because `end` is a reserved word.
local function lr(s, e) return { by = 'line_range', start = s, ['end'] = e } end

describe('nvu.edit.anchors.line_range', function()

    describe('happy path: in-bounds anchors resolve to themselves', function()
        local rec = fr.from_content('t', 'a\nb\nc\nd\ne\n')  -- 5 lines

        it('single-line at the start of file', function()
            local range, fail = line_range.resolve(lr(1, 1), rec)
            assert.is_nil(fail)
            assert.are.same({ start_line = 1, end_line = 1 }, range)
        end)

        it('single-line in the middle', function()
            local range, fail = line_range.resolve(lr(3, 3), rec)
            assert.is_nil(fail)
            assert.are.same({ start_line = 3, end_line = 3 }, range)
        end)

        it('single-line at the last line', function()
            local range, fail = line_range.resolve(lr(5, 5), rec)
            assert.is_nil(fail)
            assert.are.same({ start_line = 5, end_line = 5 }, range)
        end)

        it('multi-line range', function()
            local range, fail = line_range.resolve(lr(2, 4), rec)
            assert.is_nil(fail)
            assert.are.same({ start_line = 2, end_line = 4 }, range)
        end)

        it('whole-file range (1..n_lines)', function()
            local range, fail = line_range.resolve(lr(1, 5), rec)
            assert.is_nil(fail)
            assert.are.same({ start_line = 1, end_line = 5 }, range)
        end)
    end)

    describe('single-line file', function()
        local rec = fr.from_content('t', 'only')  -- 1 line, no trailing newline

        it('line 1 resolves', function()
            local range, fail = line_range.resolve(lr(1, 1), rec)
            assert.is_nil(fail)
            assert.are.same({ start_line = 1, end_line = 1 }, range)
        end)

        it('line 2 is out of bounds', function()
            local range, fail = line_range.resolve(lr(2, 2), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
            assert.are.same({ start_line = 1, end_line = 1 }, fail.available_range)
        end)
    end)

    describe('out-of-bounds: anchor_not_found', function()
        local rec = fr.from_content('t', 'a\nb\nc\n')  -- 3 lines

        it('start past EOF', function()
            local range, fail = line_range.resolve(lr(4, 4), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
            assert.are.same({ start_line = 1, end_line = 3 }, fail.available_range)
            assert.is_truthy(fail.hint:find('out of bounds', 1, true))
            assert.is_truthy(fail.hint:find('3 line', 1, true))
        end)

        it('end past EOF (start in bounds)', function()
            local range, fail = line_range.resolve(lr(2, 10), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
            assert.are.same({ start_line = 1, end_line = 3 }, fail.available_range)
        end)

        it('echoes the anchor back unchanged on failure', function()
            local anchor = lr(99, 100)
            local _, fail = line_range.resolve(anchor, rec)
            assert.are.same(anchor, fail.anchor)
        end)

        it('hint points at neovim__read_with_snapshot for re-reading', function()
            local _, fail = line_range.resolve(lr(99, 99), rec)
            assert.is_truthy(fail.hint:find('neovim__read_with_snapshot', 1, true))
        end)
    end)

    describe('empty file', function()
        local rec = fr.from_content('t', '')  -- 0 lines

        it('any line_range fails with available_range zero', function()
            local range, fail = line_range.resolve(lr(1, 1), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
            assert.are.same({ start_line = 0, end_line = 0 }, fail.available_range)
            assert.is_truthy(fail.hint:find('zero lines', 1, true))
        end)

        it('hint suggests neovim__write_file for creating content', function()
            local _, fail = line_range.resolve(lr(1, 1), rec)
            assert.is_truthy(fail.hint:find('neovim__write_file', 1, true))
        end)
    end)

    describe('invariant assertions (planner-bug catches)', function()
        local rec = fr.from_content('t', 'a\nb\n')

        it('rejects a non-table anchor', function()
            local ok = pcall(line_range.resolve, 'not-a-table', rec)
            assert.is_falsy(ok)
        end)

        it('rejects an anchor whose `by` is not "line_range"', function()
            local ok = pcall(line_range.resolve, { by = 'unique_text', text = 'x' }, rec)
            assert.is_falsy(ok)
        end)

        it('rejects an anchor with start < 1 (schema-bypass)', function()
            local ok = pcall(line_range.resolve, lr(0, 0), rec)
            assert.is_falsy(ok)
        end)

        it('rejects an anchor with end < start (schema-bypass)', function()
            local ok = pcall(line_range.resolve, lr(3, 2), rec)
            assert.is_falsy(ok)
        end)

        it('rejects a non-FileRecord record', function()
            local ok = pcall(line_range.resolve, lr(1, 1), { not_a = 'record' })
            assert.is_falsy(ok)
        end)
    end)

    describe('integration with FileRecord helpers', function()
        -- The whole point of resolving a line_range is to feed the result
        -- to FileRecord.byte_range / line_text. Verify the contract.
        local rec = fr.from_content('t', 'alpha\nbeta\ngamma\n')

        it('resolved range round-trips through line_text', function()
            local range = assert(line_range.resolve(lr(2, 2), rec))
            assert.is.equal('beta', fr.line_text(rec, range.start_line, range.end_line))
        end)

        it('multi-line resolved range round-trips through line_text', function()
            local range = assert(line_range.resolve(lr(1, 3), rec))
            assert.is.equal('alpha\nbeta\ngamma', fr.line_text(rec, range.start_line, range.end_line))
        end)
    end)
end)
