--- Tests for nvu.edit.read.
---
--- Run headless:
---   nvim --headless --noplugin -u NONE \
---     -c "set rtp+=$PWD" -c "luafile tests/runner.lua" -c "qall!"

local edit_read   = require'nvu.edit.read'
local fingerprint = require'nvu.edit.fingerprint'
local schema      = require'nvu.edit.schema'

--- Write a fresh tempfile and return its absolute path.
local function write_tempfile(content)
    local tmp = vim.fn.tempname()
    local f = assert(io.open(tmp, 'wb'), 'tempfile open failed')
    f:write(content)
    f:close()
    return vim.fn.fnamemodify(tmp, ':p')
end

--- Wipe the buffer attached to `path` and delete the file.
local function cleanup(path)
    local bufnr = vim.fn.bufnr(path)
    if bufnr > 0 then pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) end
    vim.fn.delete(path)
end

describe('nvu.edit.read.read_with_fingerprint', function()

    describe('success path', function()
        it('returns status=ok with content, baseline_fingerprint, n_lines, absolute path', function()
            local tmp = write_tempfile('alpha\nbeta\ngamma\n')
            local r = edit_read.read_with_fingerprint(tmp)
            assert.is.equal('ok', r.status)
            assert.is.equal(tmp, r.path)
            assert.is.equal('alpha\nbeta\ngamma\n', r.content)
            assert.is.equal(3, r.n_lines)
            assert.is_truthy(fingerprint.is_valid_format(r.baseline_fingerprint))
            cleanup(tmp)
        end)

        it('baseline_fingerprint is the same one fingerprint.compute would produce', function()
            local tmp = write_tempfile('exact\n')
            local r = edit_read.read_with_fingerprint(tmp)
            assert.is.equal(fingerprint.compute(r.content), r.baseline_fingerprint)
            cleanup(tmp)
        end)

        it('handles empty files', function()
            -- Neovim has no "zero-line buffer" — an empty file loads as
            -- one empty line. With endofline=true (the default), the
            -- normalised content is a single '\n'. The fingerprint
            -- mechanism works either way; what matters is that read and
            -- re-compute use the same routine.
            local tmp = write_tempfile('')
            local r = edit_read.read_with_fingerprint(tmp)
            assert.is.equal('ok', r.status)
            assert.is.equal('\n', r.content)
            assert.is.equal(1, r.n_lines)
            assert.is_truthy(fingerprint.is_valid_format(r.baseline_fingerprint))
            cleanup(tmp)
        end)

        it('handles single-line file without trailing newline', function()
            local tmp = write_tempfile('one')
            local r = edit_read.read_with_fingerprint(tmp)
            assert.is.equal('ok', r.status)
            -- Buffer-loaded reads through Neovim's normal pipeline. Whether
            -- the trailing newline is added or not depends on 'endofline'
            -- detection; we just assert the fingerprint is well-formed.
            assert.is_truthy(fingerprint.is_valid_format(r.baseline_fingerprint))
            cleanup(tmp)
        end)

        it('normalises relative-form paths to absolute in the response', function()
            local abs = write_tempfile('x\n')
            local rel = vim.fn.fnamemodify(abs, ':~')
            local r = edit_read.read_with_fingerprint(rel)
            assert.is.equal('ok', r.status)
            assert.is.equal(abs, r.path)
            cleanup(abs)
        end)

        it('two reads of the same unchanged file produce the same fingerprint', function()
            local tmp = write_tempfile('stable\n')
            local r1 = edit_read.read_with_fingerprint(tmp)
            local r2 = edit_read.read_with_fingerprint(tmp)
            assert.is.equal(r1.baseline_fingerprint, r2.baseline_fingerprint)
            cleanup(tmp)
        end)

        it('reflects buffer content when a modified buffer holds unsaved changes', function()
            -- The whole point of buffer-first reads: the LLM must see what
            -- the user sees, not what's on disk.
            local tmp = write_tempfile('disk_content\n')
            local bufnr = vim.fn.bufadd(tmp)
            vim.fn.bufload(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'buffer_content' })

            local r = edit_read.read_with_fingerprint(tmp)
            assert.is.equal('ok', r.status)
            -- The content we see is the buffer's, not the disk's.
            assert.is.equal('buffer_content\n', r.content)
            -- And the fingerprint reflects that content.
            assert.is.equal(fingerprint.compute('buffer_content\n'), r.baseline_fingerprint)
            cleanup(tmp)
        end)
    end)

    describe('failure shape', function()
        it('missing file → status=failed with single io_error', function()
            local r = edit_read.read_with_fingerprint('/nonexistent/never/exists')
            assert.is.equal('failed', r.status)
            assert.is.equal(1, #r.failed)
            assert.is.equal(schema.ERROR_REASONS.io_error, r.failed[1].reason)
            assert.is.equal('/nonexistent/never/exists', r.failed[1].path)
            assert.is_string(r.failed[1].message)
            assert.is_string(r.failed[1].hint)
        end)

        it('hint mentions neovim__write_file for file creation', function()
            local r = edit_read.read_with_fingerprint('/nonexistent/path')
            assert.is_truthy(r.failed[1].hint:find('neovim__write_file', 1, true))
        end)

        it('directory path → io_error', function()
            local r = edit_read.read_with_fingerprint('/tmp')
            assert.is.equal('failed', r.status)
            assert.is.equal(schema.ERROR_REASONS.io_error, r.failed[1].reason)
        end)

        it('empty path → missing_field failure', function()
            local r = edit_read.read_with_fingerprint('')
            assert.is.equal('failed', r.status)
            assert.is.equal(schema.ERROR_REASONS.missing_field, r.failed[1].reason)
        end)

        it('non-string path → wrong_type failure', function()
            local r = edit_read.read_with_fingerprint(42)
            assert.is.equal('failed', r.status)
            assert.is.equal(schema.ERROR_REASONS.wrong_type, r.failed[1].reason)
        end)

        it('nil path → wrong_type failure', function()
            local r = edit_read.read_with_fingerprint(nil)
            assert.is.equal('failed', r.status)
            assert.is.equal(schema.ERROR_REASONS.wrong_type, r.failed[1].reason)
        end)

        it('failure response always carries a non-empty summary', function()
            local r = edit_read.read_with_fingerprint('/nonexistent/q')
            assert.is_string(r.summary)
            assert.is_truthy(#r.summary > 0)
        end)
    end)

    describe('response shape uniformity', function()
        it('success response carries no `failed` field (just status, path, content, baseline_fingerprint, n_lines)', function()
            local tmp = write_tempfile('x\n')
            local r = edit_read.read_with_fingerprint(tmp)
            assert.is_nil(r.failed)
            assert.is_nil(r.summary)
            cleanup(tmp)
        end)

        it('failure response carries no content/baseline_fingerprint/n_lines', function()
            local r = edit_read.read_with_fingerprint('/nonexistent')
            assert.is_nil(r.content)
            assert.is_nil(r.baseline_fingerprint)
            assert.is_nil(r.n_lines)
        end)
    end)
end)
