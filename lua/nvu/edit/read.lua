--- nvu.edit.read — the engine behind `neovim__read_with_fingerprint`.
---
--- One function — `M.read_with_fingerprint(path)` — that buffer-loads
--- a file (via `FileRecord.read`, the same buffer-first pipeline the
--- planner uses), computes a baseline fingerprint over its content
--- (via `nvu.edit.fingerprint`), and returns both. The LLM then
--- carries the fingerprint verbatim on every `apply_edit` op against
--- that file (in the op's `baseline_fingerprint` field); the planner
--- re-computes and refuses the batch on mismatch.
---
--- ## Why this exists
---
--- Without fingerprints, an LLM that read a file at t0 and called
--- `apply_edit` at t2 against anchors planned against t0's content
--- has no way to detect that the file mutated at t1. Anchors may
--- resolve to the wrong location silently. With required fingerprints,
--- the planner detects the drift and aborts with `stale_fingerprint`.
---
--- This is the **only** read path the LLM has — the legacy
--- `neovim__read_file` is removed from the LLM-facing surface (by
--- user-side mcphub config) so every edit is anchored against a known
--- baseline. There is no bypass.
---
--- ## What it returns
---
--- Success:
---   { status = 'ok',
---     path                 = '<absolute path>',
---     content              = '<raw bytes>',
---     baseline_fingerprint = 'a3f9d2c',
---     n_lines              = N }
---
--- Failure:
---   { status   = 'failed',
---     summary  = 'cannot read file',
---     failed   = { { reason = 'io_error', path, message, hint } } }
---
--- The failure shape mirrors `apply_edit`'s `failed[]` entries so the
--- LLM sees a uniform error structure across both tools.
---
--- @module "nvu.edit.read"

local file_record = require'nvu.edit.file_record'
local fingerprint = require'nvu.edit.fingerprint'
local schema      = require'nvu.edit.schema'

local M = {}

--- Build the failure response for an I/O error.
---
--- @param raw_path string  The path as the LLM provided it (not the absolutised form).
--- @param message  string  The error message from FileRecord.read.
--- @return table response
local function io_failure(raw_path, message)
    return {
        status  = 'failed',
        summary = string.format('cannot read %q', raw_path),
        failed  = { {
            reason  = schema.ERROR_REASONS.io_error,
            path    = raw_path,
            message = message,
            hint    = 'verify the path exists and is readable; '
                   .. 'use neovim__write_file to create new files.',
        } },
    }
end

--- Read a file and return its content plus a baseline fingerprint.
---
--- Reads via `FileRecord.read`, which is buffer-first: if the path is
--- open in a Neovim buffer (loaded), that buffer's content is the
--- source of truth (including unsaved changes); otherwise the file is
--- loaded into a fresh buffer. EOL normalisation is captured on the
--- record. The fingerprint is computed over the same byte sequence
--- the planner will re-compute at apply time, so comparison is
--- meaningful as long as the buffer hasn't changed.
---
--- @param path string  The file path. Will be absolutised via `:p`.
--- @return table response  Always a complete response, success or failure.
function M.read_with_fingerprint(path)
    -- Input validation. Path-shape errors return as `failed[]` entries
    -- matching apply_edit's error format.
    if type(path) ~= 'string' then
        return {
            status  = 'failed',
            summary = 'invalid `path` argument',
            failed  = { {
                reason  = schema.ERROR_REASONS.wrong_type,
                path    = '',
                message = 'path must be a string, got: ' .. type(path),
                hint    = 'pass the file path as a string',
            } },
        }
    end
    if path == '' then
        return {
            status  = 'failed',
            summary = 'empty `path` argument',
            failed  = { {
                reason  = schema.ERROR_REASONS.missing_field,
                path    = '',
                message = 'path must not be empty',
                hint    = 'pass a non-empty file path',
            } },
        }
    end

    local rec, err = file_record.read(path)
    if not rec then
        return io_failure(path, err or 'file_record.read returned nil with no error')
    end

    return {
        status               = 'ok',
        path                 = rec.path,            -- absolutised by FileRecord
        content              = rec.content,
        baseline_fingerprint = fingerprint.compute(rec.content),
        n_lines              = rec.n_lines,
    }
end

return M
