--- Tests for nvu.edit.file_record.
---
--- Run headless:
---   nvim --headless --noplugin -u NONE \
---     -c "set rtp+=$PWD" -c "luafile tests/runner.lua" -c "qall!"

local fr = require'nvu.edit.file_record'

describe('nvu.edit.file_record', function()

    describe('build_offsets — line-counting edge cases', function()
        it('an empty file has zero lines', function()
            assert.are.same({}, fr.build_offsets(''))
        end)

        it('a single newline is one empty line, not two', function()
            -- The terminator belongs to the line it terminates; a file
            -- consisting of one '\n' is "one empty line," not "an empty
            -- line followed by another empty line."
            assert.are.same({ 1 }, fr.build_offsets('\n'))
        end)

        it('a single line with no trailing newline has one line', function()
            assert.are.same({ 1 }, fr.build_offsets('foo'))
        end)

        it('a single line with a trailing newline has one line, not two', function()
            -- The POSIX-conventional "file ends with newline" case: the
            -- trailing '\n' terminates line 1, it does not begin a phantom
            -- line 2.
            assert.are.same({ 1 }, fr.build_offsets('foo\n'))
        end)

        it('two lines without a trailing newline', function()
            assert.are.same({ 1, 5 }, fr.build_offsets('foo\nbar'))
        end)

        it('two lines with a trailing newline (no phantom 3rd line)', function()
            assert.are.same({ 1, 5 }, fr.build_offsets('foo\nbar\n'))
        end)

        it('preserves empty lines in the middle', function()
            assert.are.same({ 1, 5, 6 }, fr.build_offsets('foo\n\nbar'))
        end)

        it('preserves an empty trailing line but does not double-count it', function()
            -- Two terminated lines; the second is empty.
            assert.are.same({ 1, 5 }, fr.build_offsets('foo\n\n'))
        end)
    end)

    describe('from_content', function()
        it('packages content + offsets + n_lines into a record', function()
            local rec = fr.from_content('test.lua', 'foo\nbar')
            assert.is.equal('test.lua', rec.path)
            assert.is.equal('foo\nbar', rec.content)
            assert.are.same({ 1, 5 }, rec.offsets)
            assert.is.equal(2, rec.n_lines)
        end)

        it('produces n_lines=0 for an empty file', function()
            local rec = fr.from_content('empty', '')
            assert.is.equal(0, rec.n_lines)
            assert.are.same({}, rec.offsets)
        end)
    end)

    describe('byte_range — slicing single lines', function()
        local rec = fr.from_content('t', 'foo\nbar\nqux')

        it('line 1', function()
            local lo, hi = fr.byte_range(rec, 1, 1)
            assert.is.equal(1, lo)
            assert.is.equal(3, hi)
        end)

        it('middle line', function()
            local lo, hi = fr.byte_range(rec, 2, 2)
            assert.is.equal(5, lo)
            assert.is.equal(7, hi)
        end)

        it('last line', function()
            local lo, hi = fr.byte_range(rec, 3, 3)
            assert.is.equal(9, lo)
            assert.is.equal(11, hi)
        end)
    end)

    describe('byte_range — multi-line ranges', function()
        local rec = fr.from_content('t', 'foo\nbar\nqux')

        it('lines 1..2', function()
            local lo, hi = fr.byte_range(rec, 1, 2)
            assert.is.equal(1, lo)
            assert.is.equal(7, hi)
            assert.is.equal('foo\nbar', rec.content:sub(lo, hi))
        end)

        it('lines 2..3 (range ends at last line)', function()
            local lo, hi = fr.byte_range(rec, 2, 3)
            assert.is.equal(5, lo)
            assert.is.equal(11, hi)
            assert.is.equal('bar\nqux', rec.content:sub(lo, hi))
        end)

        it('whole file', function()
            local lo, hi = fr.byte_range(rec, 1, 3)
            assert.is.equal(1, lo)
            assert.is.equal(11, hi)
            assert.is.equal('foo\nbar\nqux', rec.content:sub(lo, hi))
        end)
    end)

    describe('byte_range — trailing-newline handling', function()
        it('strips the trailing newline when the last line is the last one in the range', function()
            local rec = fr.from_content('t', 'foo\nbar\n')
            -- File has 2 lines (last terminated). Slicing the last line
            -- should return "bar" (not "bar\n").
            local lo, hi = fr.byte_range(rec, 2, 2)
            assert.is.equal('bar', rec.content:sub(lo, hi))
        end)

        it('still returns the inter-line newline when slicing multiple lines', function()
            local rec = fr.from_content('t', 'foo\nbar\n')
            local lo, hi = fr.byte_range(rec, 1, 2)
            assert.is.equal('foo\nbar', rec.content:sub(lo, hi))
        end)
    end)

    describe('line_text', function()
        local rec = fr.from_content('t', 'foo\nbar\nqux')

        it('returns single-line text without trailing newline', function()
            assert.is.equal('foo', fr.line_text(rec, 1, 1))
            assert.is.equal('bar', fr.line_text(rec, 2, 2))
            assert.is.equal('qux', fr.line_text(rec, 3, 3))
        end)

        it('returns multi-line text with inner newlines preserved', function()
            assert.is.equal('foo\nbar', fr.line_text(rec, 1, 2))
            assert.is.equal('foo\nbar\nqux', fr.line_text(rec, 1, 3))
        end)

        it('returns an empty string for an empty line', function()
            local rec_blank = fr.from_content('t', 'foo\n\nbar')
            assert.is.equal('', fr.line_text(rec_blank, 2, 2))
        end)
    end)

    describe('byte_to_line', function()
        local rec = fr.from_content('t', 'foo\nbar\nqux')
        -- offsets = {1, 5, 9}; #content = 11
        -- bytes 1..4: line 1 (4 is the '\n')
        -- bytes 5..8: line 2 (8 is the '\n')
        -- bytes 9..11: line 3

        it('byte at line start returns that line', function()
            assert.is.equal(1, fr.byte_to_line(rec, 1))
            assert.is.equal(2, fr.byte_to_line(rec, 5))
            assert.is.equal(3, fr.byte_to_line(rec, 9))
        end)

        it('byte mid-line returns that line', function()
            assert.is.equal(1, fr.byte_to_line(rec, 2))  -- 'o' of 'foo'
            assert.is.equal(2, fr.byte_to_line(rec, 6))  -- 'a' of 'bar'
            assert.is.equal(3, fr.byte_to_line(rec, 10)) -- 'u' of 'qux'
        end)

        it('the terminating newline belongs to the line it terminates', function()
            assert.is.equal(1, fr.byte_to_line(rec, 4))  -- '\n' after 'foo'
            assert.is.equal(2, fr.byte_to_line(rec, 8))  -- '\n' after 'bar'
        end)

        it('the last byte of the file returns the last line', function()
            assert.is.equal(3, fr.byte_to_line(rec, 11))
        end)
    end)

    describe('read — file I/O', function()
        it('reads an existing file and produces a record', function()
            local tmp = vim.fn.tempname()
            local f = assert(io.open(tmp, 'wb'), 'failed to open tempfile for write')
            f:write('line1\nline2\n')
            f:close()

            local rec, err = fr.read(tmp)
            assert.is_nil(err)
            assert.is.equal(tmp, rec.path)
            assert.is.equal('line1\nline2\n', rec.content)
            assert.is.equal(2, rec.n_lines)

            vim.fn.delete(tmp)
        end)

        it('returns nil + error message when the file does not exist', function()
            local rec, err = fr.read('/nonexistent/path/that/should/not/exist')
            assert.is_nil(rec)
            assert.is_string(err)
            assert.is_truthy(err:find('cannot open', 1, true))
        end)
    end)
end)
