--- nvu.edit.snapshot — content-hash tokens for the read-then-edit race guard.
---
--- A snapshot token is the LLM's receipt that it has read a file and is
--- planning edits against a specific revision of its content. Every op
--- in `apply_edit` carries a `snapshot` field pointing at a token
--- previously issued by `neovim__read_with_snapshot`; the planner
--- rehashes the live file at apply time and refuses the batch on
--- mismatch (`stale_snapshot`). This is what closes the inter-batch
--- race: between the LLM's read and its subsequent edit, the file may
--- have been mutated by the user or another tool, and anchors planned
--- against the stale content would otherwise land at the wrong location
--- silently.
---
--- ## Format
---
--- A bare 7-character lowercase-hex string — the first 7 hex characters
--- of `vim.fn.sha256(content)`. Example: `a3f9d2c`.
---
---   * 7 hex chars = 28 bits ≈ 268M values. The token is compared
---     **pairwise per file per batch** (not searched across a
---     population), so the relevant collision probability is
---     ~1 / 2²⁸ ≈ 3.7×10⁻⁹ per comparison. The failure mode if a
---     collision did occur is "we accept a stale snapshot and apply
---     edits anchored against shifted content" — the same failure mode
---     `apply_edit` has today without snapshots, so the collision cost
---     is bounded by the pre-existing baseline.
---   * The LLM treats it as opaque: do not parse, do not regenerate.
---     Pass it through verbatim from `neovim__read_with_snapshot` into
---     `apply_edit`.
---
--- ## Hash primitive
---
--- `vim.fn.sha256`, built into Neovim. We are not defending against
--- adversaries — only detecting honest mutation — so cryptographic
--- strength is irrelevant; uniform-length hex output and zero
--- dependencies are what we want.
---
--- ## Input to the hash
---
--- The buffer-normalised content from `FileRecord.content` —
--- `nvim_buf_get_lines` joined with `\n`, plus a trailing `\n` iff
--- `vim.bo[bufnr].endofline`. This is the same byte sequence both
--- `read_with_snapshot` (token emission) and the planner
--- (`stale_snapshot` validation) feed into the hash, so the comparison
--- is meaningful as long as the buffer hasn't changed. See
--- `file_record.lua` for the EOL-normalisation routine.
---
--- @module "nvu.edit.snapshot"

local M = {}

--- Number of hex characters in a snapshot token. See module doc for
--- the collision-math rationale.
M.HASH_LEN = 7

--- Compute the snapshot token for some content.
---
--- @param content string  The buffer-normalised file content.
--- @return string         A 7-character lowercase-hex token.
function M.compute(content)
    assert(type(content) == 'string', 'snapshot.compute: content must be a string, got: ' .. type(content))
    return vim.fn.sha256(content):sub(1, M.HASH_LEN)
end

--- Test whether a token matches some content's current snapshot.
---
--- Used by the planner to detect `stale_snapshot` — the per-op
--- `snapshot` field from the request is compared against the live
--- buffer's content via this function.
---
--- @param token   string
--- @param content string
--- @return boolean
function M.matches(token, content)
    if type(token) ~= 'string' then return false end
    return M.compute(content) == token
end

--- Validate that a string has the shape of a snapshot token: exactly
--- `HASH_LEN` lowercase-hex characters.
---
--- Used by input validation (and by tests) to give a clear error
--- before the planner tries to compare a malformed token. `vim.fn.sha256`
--- emits lowercase hex, so we don't accept uppercase: any token that
--- could have come from `compute()` is lowercase by construction.
---
--- @param token any
--- @return boolean
function M.is_valid_format(token)
    if type(token) ~= 'string' then return false end
    if #token ~= M.HASH_LEN then return false end
    return token:match('^[0-9a-f]+$') ~= nil
end

return M
