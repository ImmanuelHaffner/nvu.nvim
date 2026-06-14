--- nvu.edit.file_record — canonical in-memory representation of a file
--- being read by the planner.
---
--- A FileRecord is the input shape every anchor resolver expects:
---
---   {
---     path    = "lua/foo.lua",
---     content = "<raw bytes as a single Lua string>",
---     offsets = { 1, 42, 117, ... },  -- 1-based; offsets[i] = first byte of line i
---   }
---
--- The string is canonical (multi-line `unique_text` matches need cross-line
--- scanning); offsets give O(1) line→byte slicing and O(log n) byte→line
--- translation.
---
--- @module "nvu.edit.file_record"

local M = {}

--- A canonical file record.
--- @class nvu.edit.FileRecord
--- @field path    string                 Absolute or relative path the planner was asked to resolve.
--- @field content string                 Raw bytes of the file as a single Lua string.
--- @field offsets integer[]              1-based; offsets[i] = first byte of line i. Always has at least { 1 }.
--- @field n_lines integer                Number of lines in `content`. Derived from `#offsets`.

--- Build the line-start offsets array for a string.
---
--- Convention: `offsets[i]` is the byte position (1-based) where line `i`
--- begins. The line-terminator `\n` is considered to belong to the line it
--- terminates, NOT to start a new (phantom) line. Consequently:
---
---   ""              → {}             (0 lines)
---   "\n"            → {1}            (1 empty line)
---   "foo"           → {1}            (1 line, no trailing newline)
---   "foo\n"         → {1}            (1 line, trailing newline conventional)
---   "foo\nbar"      → {1, 5}         (2 lines, last unterminated)
---   "foo\nbar\n"    → {1, 5}         (2 lines, both terminated)
---   "foo\n\n"       → {1, 5}         (2 lines, second empty)
---
--- The `pos = i + 1` step at the bottom of the loop may push `pos` one past
--- `#content` when the last byte of the file is a `\n`. Lua's `string.find`
--- treats `init > #s` as a guaranteed no-match (returns nil), so this is safe
--- and the loop terminates naturally on the next iteration.
---
--- @param content string
--- @return integer[]
function M.build_offsets(content)
    if content == '' then return {} end
    local offsets = { 1 }
    local pos = 1
    local n = #content
    while true do
        local i = content:find('\n', pos, true)
        if not i then break end
        -- A '\n' at the very last byte terminates the line it sits on; it
        -- does NOT open a new (phantom) line. Only register the next-line
        -- offset if there's actually content after the newline.
        if i < n then
            table.insert(offsets, i + 1)
        end
        pos = i + 1
    end
    return offsets
end

--- Read a file and build a canonical record.
---
--- Uses `io.open` for the raw byte read. We deliberately avoid
--- `vim.fn.readfile`, which allocates one interned Lua string per line and
--- benchmarks ~70× slower than the raw read for large files.
---
--- @param path string
--- @return nvu.edit.FileRecord|nil record  On success.
--- @return string|nil err                  On failure, the I/O error message.
function M.read(path)
    local f, ferr = io.open(path, 'rb')
    if not f then
        return nil, string.format('cannot open %q: %s', path, ferr or 'unknown error')
    end
    local content, rerr = f:read('*a')
    f:close()
    if not content then
        return nil, string.format('cannot read %q: %s', path, rerr or 'unknown error')
    end
    return M.from_content(path, content), nil
end

--- Build a record from a path and an already-loaded content string.
--- Useful for tests and for buffer-sourced content where I/O has happened
--- elsewhere.
---
--- @param path string
--- @param content string
--- @return nvu.edit.FileRecord
function M.from_content(path, content)
    local offsets = M.build_offsets(content)
    return {
        path    = path,
        content = content,
        offsets = offsets,
        n_lines = #offsets,
    }
end

--------------------------------------------------------------------------------
-- Query helpers
--------------------------------------------------------------------------------

--- Return the byte range `[lo, hi]` (inclusive, 1-based) covering lines
--- `start_line .. end_line` (inclusive). The terminating newline of `end_line`
--- is NOT included in `hi`; the byte at `hi` is the last non-newline byte of
--- the range. The caller can slice with `record.content:sub(lo, hi)`.
---
--- @param record  nvu.edit.FileRecord
--- @param start_line integer 1-based.
--- @param end_line   integer 1-based, inclusive, must be >= start_line.
--- @return integer lo
--- @return integer hi
function M.byte_range(record, start_line, end_line)
    assert(start_line >= 1 and start_line <= record.n_lines,
        string.format('start_line %d out of range [1, %d]', start_line, record.n_lines))
    assert(end_line >= start_line and end_line <= record.n_lines,
        string.format('end_line %d out of [start_line=%d, n_lines=%d]',
            end_line, start_line, record.n_lines))

    local lo = record.offsets[start_line]
    local hi
    if end_line == record.n_lines then
        hi = #record.content
        -- Trim a trailing '\n' so the returned bytes are the line content
        -- alone. If the file is empty or just a single '\n', this is a no-op.
        if record.content:sub(hi, hi) == '\n' then hi = hi - 1 end
    else
        -- offsets[end_line + 1] is the first byte of the next line, i.e. the
        -- byte just after the '\n' that terminates end_line. So our `hi` is
        -- two less: skip the '\n' and the off-by-one for "first byte of next".
        hi = record.offsets[end_line + 1] - 2
    end
    return lo, hi
end

--- Return the text of lines `start_line .. end_line` (1-based, inclusive)
--- as a single string, without a trailing newline.
---
--- @param record nvu.edit.FileRecord
--- @param start_line integer
--- @param end_line   integer
--- @return string
function M.line_text(record, start_line, end_line)
    local lo, hi = M.byte_range(record, start_line, end_line)
    if hi < lo then return '' end  -- empty trailing line
    return record.content:sub(lo, hi)
end

--- Translate a byte offset into `record.content` to the 1-based line number
--- it belongs to. Binary search over `offsets`; O(log n_lines).
---
--- A byte at the start of line k returns k. A byte in the middle of line k
--- also returns k. The '\n' character at the end of line k belongs to line k.
---
--- @param record nvu.edit.FileRecord
--- @param byte_offset integer 1-based byte position into `record.content`.
--- @return integer line_number
function M.byte_to_line(record, byte_offset)
    local lo, hi = 1, record.n_lines
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if record.offsets[mid] <= byte_offset then lo = mid else hi = mid - 1 end
    end
    return lo
end

return M
