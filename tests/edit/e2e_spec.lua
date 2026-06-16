--- End-to-end tests for `nvu.edit.apply(input, drive_file, on_complete)`.
---
--- Exercises the full pipeline: schema → planner → applier → drive_file. We
--- use the synthetic `tests.edit.drivers.accept_all` driver, which mirrors
--- the headless `interactive = false` behaviour of mcphub's `EditUI` without
--- the UI dependency. Reject-path tests are deferred until we have a
--- synthetic reject driver.
---
--- Fingerprints are real (no bypass) — these tests construct the fingerprint
--- from the file content they wrote, the same way the LLM constructs it
--- from a `neovim__read_with_fingerprint` response. That makes them genuine
--- end-to-end smoke tests of the production seal `nvu.edit.apply`.
---
--- @module "tests.edit.e2e_spec"

local edit        = require'nvu.edit'
local fingerprint = require'nvu.edit.fingerprint'
local drivers     = require'tests.edit.drivers'

--- Wait for the async `on_complete` callback. Returns the response.
---
--- The accept_all driver is synchronous-with-`vim.schedule` (no I/O beyond
--- `:write`), so completion should occur in sub-millisecond wall time per
--- file. 100ms is tight enough to scream if a regression accidentally pulls
--- in an async waiter (e.g. EditUI's 500ms-default diagnostic settle), but
--- still ~1000× the realistic budget.
local function await_apply(input)
    local response
    edit.apply(input, drivers.accept_all, function(r) response = r end)
    local ok = vim.wait(100, function() return response ~= nil end, 1)
    assert(ok, 'edit.apply did not complete within 100ms')
    return response
end

--- Write `lines` to a tempfile, load it into a buffer (mirrors the
--- buffer-first read path used by `read_with_fingerprint`), and return
--- `(path, bufnr, fingerprint)`.
local function fixture_file(lines, suffix)
    local path = vim.fn.tempname() .. (suffix or '.txt')
    vim.fn.writefile(lines, path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    -- Match the engine's content normalisation:
    -- nvim_buf_get_lines joined by '\n', plus trailing '\n' iff endofline.
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local content = table.concat(buf_lines, '\n')
    if vim.bo[bufnr].endofline then content = content .. '\n' end
    return path, bufnr, fingerprint.compute(content)
end

--- Tear down a fixture: delete the buffer and remove the file. Safe under
--- the test runner's per-spec isolation; this prevents stale buffers from
--- the previous spec affecting the next.
local function cleanup_fixture(path, bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    os.remove(path)
end

describe('nvu.edit.apply end-to-end (accept_all driver)', function()
    it('applies a single replace_range and writes to disk', function()
        local path, bufnr, fp = fixture_file{ 'alpha', 'beta', 'gamma' }
        local response = await_apply{
            ops = {
                {
                    kind = 'replace_range',
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = { by = 'line_range', start = 2, ['end'] = 2 },
                    content = 'BETA',
                },
            },
        }
        assert(response.status == 'applied',
            'expected status=applied, got ' .. tostring(response.status))
        assert(#response.applied == 1, 'expected 1 applied entry')
        assert(#response.rejected == 0, 'expected 0 rejected')
        assert(#response.failed == 0, 'expected 0 failed')

        local on_disk = vim.fn.readfile(path)
        assert.is.equal('alpha',  on_disk[1])
        assert.is.equal('BETA',   on_disk[2])
        assert.is.equal('gamma',  on_disk[3])

        cleanup_fixture(path, bufnr)
    end)

    it('applies replace + insert + delete in one batch', function()
        local path, bufnr, fp = fixture_file{ 'one', 'two', 'three', 'four' }
        local response = await_apply{
            ops = {
                { kind = 'replace_range', path = path, baseline_fingerprint = fp,
                  anchor = { by = 'line_range', start = 2, ['end'] = 2 },
                  content = 'TWO-a\nTWO-b' },
                { kind = 'insert', path = path, baseline_fingerprint = fp,
                  anchor = { by = 'before',
                             of = { by = 'line_range', start = 4, ['end'] = 4 } },
                  content = 'INSERTED' },
                { kind = 'delete_range', path = path, baseline_fingerprint = fp,
                  anchor = { by = 'line_range', start = 1, ['end'] = 1 } },
            },
        }
        assert.is.equal('applied', response.status)
        assert.is.equal(3, #response.applied)

        local on_disk = vim.fn.readfile(path)
        -- Expected after all three: ["TWO-a", "TWO-b", "three", "INSERTED", "four"]
        assert.is.equal('TWO-a',    on_disk[1])
        assert.is.equal('TWO-b',    on_disk[2])
        assert.is.equal('three',    on_disk[3])
        assert.is.equal('INSERTED', on_disk[4])
        assert.is.equal('four',     on_disk[5])
        assert.is.equal(5,          #on_disk)

        cleanup_fixture(path, bufnr)
    end)

    it('returns failed[] with schema_invalid for malformed input', function()
        local response = await_apply{
            ops = {
                -- Missing baseline_fingerprint → schema rejects.
                { kind = 'replace_range', path = '/tmp/nonexistent',
                  anchor = { by = 'line_range', start = 1, ['end'] = 1 },
                  content = 'x' },
            },
        }
        assert.is.equal('failed', response.status)
        assert(#response.failed >= 1, 'expected at least one failed entry')
        local entry = response.failed[1]
        assert.is.equal('schema_invalid', entry.reason)
    end)

    it('returns failed[] with stale_fingerprint when the file mutated', function()
        local path, bufnr, fp = fixture_file{ 'live', 'content' }
        -- Mutate the buffer behind the LLM's back.
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'mutated', 'content' })

        local response = await_apply{
            ops = {
                { kind = 'replace_range', path = path, baseline_fingerprint = fp,
                  anchor = { by = 'line_range', start = 1, ['end'] = 1 },
                  content = 'never_applied' },
            },
        }
        assert.is.equal('failed', response.status)
        assert.is.equal(1, #response.failed)
        local entry = response.failed[1]
        assert.is.equal('stale_fingerprint', entry.reason)
        assert(entry.live_fingerprint  ~= nil, 'stale failure should carry live_fingerprint')
        assert(entry.live_content      ~= nil, 'stale failure should carry live_content')

        cleanup_fixture(path, bufnr)
    end)

    it('sequences ops across two files, both applied', function()
        local path_a, buf_a, fp_a = fixture_file({ 'A1', 'A2' }, '_a.txt')
        local path_b, buf_b, fp_b = fixture_file({ 'B1', 'B2' }, '_b.txt')
        local response = await_apply{
            ops = {
                { kind = 'replace_range', path = path_a, baseline_fingerprint = fp_a,
                  anchor = { by = 'line_range', start = 1, ['end'] = 1 },
                  content = 'A1-edited' },
                { kind = 'replace_range', path = path_b, baseline_fingerprint = fp_b,
                  anchor = { by = 'line_range', start = 2, ['end'] = 2 },
                  content = 'B2-edited' },
            },
        }
        assert.is.equal('applied', response.status)
        assert.is.equal(2, #response.applied)

        local on_disk_a = vim.fn.readfile(path_a)
        assert.is.equal('A1-edited', on_disk_a[1])
        assert.is.equal('A2',        on_disk_a[2])
        local on_disk_b = vim.fn.readfile(path_b)
        assert.is.equal('B1',        on_disk_b[1])
        assert.is.equal('B2-edited', on_disk_b[2])

        cleanup_fixture(path_a, buf_a)
        cleanup_fixture(path_b, buf_b)
    end)
end)
