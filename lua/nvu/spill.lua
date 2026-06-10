--- Spill large strings to disk and return a small summary placeholder.
---
--- The motivating use case is MCP tool outputs in CodeCompanion: any call
--- whose stringified response exceeds a byte/line budget can blow the LLM
--- context window in a single shot.  Spilling the payload to a tempfile and
--- returning a short pointer with usage hints lets the agent inspect the
--- data on demand via `rg`/`jq`/`head` without flooding the chat.
---
--- Pure data helper — no Neovim UI dependencies; safe to call from any
--- context (autocmd, plugin handler, async callback, etc.).
---
--- @module nvu.spill

local M = {}

--- The spill directory.  Hard-coded to live under Neovim's standard cache
--- path (`$XDG_CACHE_HOME/nvim` on Linux); users who want to relocate
--- everything can do so via Neovim's normal cache-dir configuration.
--- Exposed for tests and for the rare diagnostic that wants to inspect or
--- list the dir directly; do not pass it back in as an option.
--- @type string
M.DIR = vim.fn.stdpath('cache') .. '/nvu-spill'

--- Default byte budget — text larger than this is spilled.
--- Sized for an acceptable inline payload of ~20 k tokens, at the middle
--- of the typical 3-6 bytes/token band (so ~5 bytes/token → ~96 KB).
--- @type integer
M.DEFAULT_MAX_BYTES = 96 * 1024

--- Default line budget — text with more lines than this is spilled.
--- Catches small-byte-but-many-line payloads (sparse logs, CSV dumps).
--- Sized so a typical ~20 k-token structured payload doesn't trip on
--- lines alone (~10 lines per 100 tokens for code/JSON).
--- @type integer
M.DEFAULT_MAX_LINES = 2000

--- Default token budget — text estimated above this many tokens is spilled.
--- Disabled by default (nil) so callers without a token counter aren't surprised
--- by an estimator being run unnecessarily.  Set both `max_tokens` and
--- `token_counter` in `opts` to enable token-based spilling.
--- @type integer|nil
M.DEFAULT_MAX_TOKENS = nil

--- Sanitize a label into a filesystem-safe slug.
--- @param label string|nil
--- @return string slug Sanitised, max 80 chars.  Returns `"output"` if label is nil/empty.
local function slugify(label)
    if not label or label == '' then return 'output' end
    return (label:gsub('[^%w_%-]+', '_')):sub(1, 80)
end

--- Detect the format of `text` by inspecting the first non-whitespace character.
--- Cheap heuristic; deliberately conservative — when in doubt, treat as text.
--- The `[^%s]` class explicitly demands a non-whitespace character so
--- whitespace-only or empty inputs cleanly fall through to the `text`
--- default (rather than relying on the greedy backoff of `(.)`).
--- @param text string
--- @return "json"|"xml"|"text"
local function detect_format(text)
    local first = text:match('^%s*([^%s])')
    if first == '{' or first == '[' then return 'json' end
    if first == '<' then return 'xml' end
    return 'text'
end

--- File extension to use for a given detected format.
local FORMAT_EXT = { json = 'json', xml = 'xml', text = 'txt' }

--- Cheap newline counter.  Returns the count of `\n` bytes plus 1 (i.e. number of lines).
--- @param s string
--- @return integer
local function count_lines(s)
    if s == '' then return 0 end
    local _, n = s:gsub('\n', '\n')
    return n + 1
end

--- Build a one-line structural preview suitable for the spill summary.
--- - JSON: top-level keys (when the payload parses as an object).
--- - Text/XML: the first non-empty line, truncated to 200 chars.
--- Returns an empty string when no useful preview can be derived.
--- @param text string
--- @param format "json"|"xml"|"text"
--- @return string
local function structure_hint(text, format)
    if format == 'json' then
        local ok, decoded = pcall(vim.json.decode, text)
        if ok and type(decoded) == 'table' then
            local keys = {}
            for k in pairs(decoded) do
                if type(k) == 'string' then table.insert(keys, k) end
                if #keys >= 12 then break end
            end
            if #keys > 0 then
                table.sort(keys)
                return '\nTop-level JSON keys: `' .. table.concat(keys, '`, `') .. '`'
            end
            -- Array or empty object: fall through to first-line preview.
        end
    end
    -- Plain-text / XML / non-object JSON: first non-empty line.
    local first_line = text:match('^%s*([^\n]+)')
    if not first_line or first_line == '' then return '' end
    if #first_line > 200 then first_line = first_line:sub(1, 200) .. '…' end
    return '\nFirst line: `' .. first_line .. '`'
end

--- Build the format-appropriate inspection hints for the summary message.
--- @param format "json"|"xml"|"text"
--- @param path string
--- @return string
local function inspection_hints(format, path)
    if format == 'json' then
        return string.format([[
To inspect it, prefer ONE of:
  • `jq '<filter>' %s`          — JSON projection (recommended)
  • `rg <pattern> %s`           — content search
  • `head -c 2000 %s`           — peek at the start]], path, path, path)
    end
    if format == 'xml' then
        return string.format([[
To inspect it, prefer ONE of:
  • `rg <pattern> %s`           — content search
  • `xmllint --xpath '<expr>' %s`  — XML projection (if installed)
  • `head -c 2000 %s`           — peek at the start]], path, path, path)
    end
    -- Plain text / logs / CSV / markdown
    return string.format([[
To inspect it, prefer ONE of:
  • `rg <pattern> %s`           — content search
  • `head -n 50 %s`             — first 50 lines
  • `tail -n 50 %s`             — last 50 lines
  • `wc -l %s`                  — line count]], path, path, path, path)
end

--- Estimate the token count of `text`.
--- Uses `opts.token_counter` if supplied; otherwise returns nil.
--- Token counting is intentionally pluggable — `nvu.spill` has no hard
--- dependency on CodeCompanion or any tokenizer library.  Call-sites that
--- want token-aware budgeting (e.g. the mcp_size_guard extension) inject
--- their own counter.
--- @param text string
--- @param opts? { token_counter?: fun(s: string): integer }
--- @return integer|nil tokens nil if no counter is configured.
function M.estimate_tokens(text, opts)
    local counter = opts and opts.token_counter
    if type(counter) ~= 'function' then return nil end
    local ok, n = pcall(counter, text)
    if not ok or type(n) ~= 'number' then return nil end
    return math.floor(n)
end

--- Decide whether `text` exceeds the configured budget.
--- The text is considered too large if it exceeds ANY of the configured
--- budgets (bytes, lines, tokens).  Token check is only performed when both
--- `max_tokens` and `token_counter` are supplied (or available as defaults).
--- @param text string|nil
--- @param opts? { max_bytes?: integer, max_lines?: integer, max_tokens?: integer, token_counter?: fun(s: string): integer }
--- @return boolean too_large
--- @return string|nil reason  Which budget tripped ("bytes" | "lines" | "tokens"), nil if not too large.
function M.too_large(text, opts)
    if not text or text == '' then return false, nil end
    opts = opts or {}
    if #text > (opts.max_bytes or M.DEFAULT_MAX_BYTES) then return true, 'bytes' end
    if count_lines(text) > (opts.max_lines or M.DEFAULT_MAX_LINES) then return true, 'lines' end
    local max_tokens = opts.max_tokens or M.DEFAULT_MAX_TOKENS
    if max_tokens and opts.token_counter then
        local n = M.estimate_tokens(text, opts)
        if n and n > max_tokens then return true, 'tokens' end
    end
    return false, nil
end

--- Write `text` to a unique file in the spill dir and return its absolute path.
--- The directory is created if it doesn't exist.  The file extension is
--- chosen based on a content sniff (json → `.json`, xml → `.xml`, else
--- `.txt`) so editors/tools pick up syntax automatically.
--- @param text string
--- @param opts? { label?: string }
--- @return string|nil path   Absolute file path on success, nil on failure.
--- @return string|nil err    Error message on failure.
--- @return string|nil format Detected format ("json"|"xml"|"text"), nil on failure.
function M.write(text, opts)
    opts = opts or {}
    vim.fn.mkdir(M.DIR, 'p')
    local ts = os.date('%Y%m%d-%H%M%S')
    local rand = string.format('%04x', math.random(0, 0xffff))
    local format = detect_format(text)
    local path = string.format('%s/%s-%s-%s.%s',
        M.DIR, slugify(opts.label), ts, rand, FORMAT_EXT[format])
    local fd, err = io.open(path, 'w')
    if not fd then return nil, err, nil end
    fd:write(text)
    fd:close()
    return path, nil, format
end

--- Build the summary string that takes the place of `text` in the chat.
--- Includes a token estimate when `opts.token_counter` is supplied.
--- Picks format-appropriate inspection hints (`jq` for JSON, `xmllint`
--- for XML, `rg`/`head`/`tail` for plain text).
--- @param text string The original (large) payload.
--- @param path string The path it was written to.
--- @param opts? { token_counter?: fun(s: string): integer, format?: "json"|"xml"|"text" }
--- @return string
function M.summarize(text, path, opts)
    opts = opts or {}
    local n_bytes = #text
    local n_lines = count_lines(text)
    local n_tokens = M.estimate_tokens(text, opts)
    local size_str
    if n_tokens then
        size_str = string.format('%d bytes, %d lines, ≈%d tokens', n_bytes, n_lines, n_tokens)
    else
        size_str = string.format('%d bytes, %d lines', n_bytes, n_lines)
    end
    local format = opts.format or detect_format(text)
    local struct_hint = structure_hint(text, format)
    local hints = inspection_hints(format, path)
    return string.format([[⚠ Tool output was %s — too large for the chat context.
The full response was written to: `%s` (detected format: `%s`)%s

%s
DO NOT `cat` the whole file into the chat.]],
        size_str, path, format, struct_hint, hints)
end

--- Spill `text` to disk and return a replacement summary string.
--- If the file write fails, returns a truncated inline preview instead so
--- the caller never blows the context window with the full payload.
--- @param text string
--- @param opts? { label?: string, max_bytes?: integer, max_lines?: integer, max_tokens?: integer, token_counter?: fun(s: string): integer }
--- @return string replacement Short text suitable to inject in place of `text`.
--- @return string|nil path    Path the payload was written to (nil if the write failed).
function M.spill(text, opts)
    opts = opts or {}
    local path, err, format = M.write(text, opts)
    if not path then
        local cap = opts.max_bytes or M.DEFAULT_MAX_BYTES
        return string.format(
            '⚠ Tool output (%d bytes) too large for chat AND spill-to-disk failed (%s).\n'
            .. 'Truncated to first %d bytes:\n\n%s\n…[truncated]',
            #text, tostring(err), cap, text:sub(1, cap)), nil
    end
    -- Propagate the detected format to the summary so we don't sniff twice.
    local summary_opts = vim.tbl_extend('force', opts, { format = format })
    return M.summarize(text, path, summary_opts), path
end

--- Convenience: spill `text` only if it exceeds the budget.  Returns the
--- original text unchanged when it fits.  This is the one-call entry point
--- most call-sites want.
--- @param text string|nil
--- @param opts? { label?: string, max_bytes?: integer, max_lines?: integer, max_tokens?: integer, token_counter?: fun(s: string): integer }
--- @return string text       Either the original text or the summary placeholder.
--- @return string|nil path   Path it was written to, or nil if it wasn't spilled.
--- @return boolean spilled   True iff the text was actually spilled.
--- @return string|nil reason Which budget tripped ("bytes" | "lines" | "tokens"), nil if not spilled.
function M.maybe_spill(text, opts)
    if not text then return '', nil, false, nil end
    local big, reason = M.too_large(text, opts)
    if not big then return text, nil, false, nil end
    local replacement, path = M.spill(text, opts)
    return replacement, path, true, reason
end

----------------------------------------------------------------------------
-- Garbage collection.
--
-- Spilled files are ephemeral debugging artifacts: by the time a tool
-- response is more than a few hours old, the underlying state it describes
-- (CI run, JIRA issue, doc revision, …) is usually stale anyway.  We
-- aggressively age them out rather than letting the dir grow unbounded.
----------------------------------------------------------------------------

--- Default age cap for `gc()`.  Anything older than this is deleted.
--- @type integer
M.DEFAULT_GC_MAX_AGE_HOURS = 24

--- Default period for the optional background timer.
--- @type integer
M.DEFAULT_GC_PERIOD_MINUTES = 60

--- Pattern matching files this module writes:
---   <slug>-YYYYMMDD-HHMMSS-XXXX.<ext>
--- Used by `gc()` to avoid touching unrelated files a user may have placed
--- in the spill dir.
local SPILL_FILE_PATTERN = '^.+%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-[%da-f]+%.[a-z]+$'

--- Internal: stat helper that returns size + mtime (seconds) or nil/nil.
local function file_stat(path)
    local st = vim.uv.fs_stat(path)
    if not st then return nil, nil end
    return st.size, st.mtime and st.mtime.sec or nil
end

--- Sweep the spill dir, deleting files older than `max_age_hours`.
---
--- Only files matching this module's own naming pattern are considered;
--- foreign files are left untouched.  Individual `unlink` failures are
--- silently skipped (file may be open elsewhere, permission denied, etc.).
---
--- Safe to call from any context.  Synchronous; the dir is small enough
--- that this typically completes in well under a millisecond.
---
--- @param opts? { max_age_hours?: integer }
--- @return { scanned: integer, deleted: integer, freed_bytes: integer, kept_bytes: integer }
function M.gc(opts)
    opts = opts or {}
    local max_age_hours = opts.max_age_hours or M.DEFAULT_GC_MAX_AGE_HOURS
    local age_cutoff = os.time() - (max_age_hours * 3600)

    local stats = { scanned = 0, deleted = 0, freed_bytes = 0, kept_bytes = 0 }
    local handle = vim.uv.fs_scandir(M.DIR)
    if not handle then return stats end

    while true do
        local name, t = vim.uv.fs_scandir_next(handle)
        if not name then break end
        if t == 'file' and name:match(SPILL_FILE_PATTERN) then
            stats.scanned = stats.scanned + 1
            local path = M.DIR .. '/' .. name
            local size, mtime = file_stat(path)
            if size and mtime then
                if mtime < age_cutoff then
                    if vim.uv.fs_unlink(path) then
                        stats.deleted = stats.deleted + 1
                        stats.freed_bytes = stats.freed_bytes + size
                    end
                else
                    stats.kept_bytes = stats.kept_bytes + size
                end
            end
        end
    end
    return stats
end

--- @class nvu.spill.GCHandle
--- @field stop fun() Stop the periodic timer (idempotent).

--- Start a background timer that calls `gc()` every `period_minutes`.
---
--- **Not idempotent** — each call creates a new timer.  The caller owns
--- the lifecycle: stash the returned handle and `handle.stop()` it before
--- starting another, or two timers will run concurrently.  This is by
--- design; tracking the active timer is the caller's concern (typically
--- the integration that decides *when* to (re)configure GC).
---
--- The timer fires on libuv's thread; the GC call is wrapped in
--- `vim.schedule()` + `pcall()` so it always runs through Neovim's event
--- loop and never panics the timer.
---
--- @param opts? { max_age_hours?: integer, period_minutes?: integer }
--- @return nvu.spill.GCHandle handle Stop the timer via `handle.stop()`.
function M.start_periodic_gc(opts)
    opts = opts or {}
    local period_minutes = opts.period_minutes or M.DEFAULT_GC_PERIOD_MINUTES
    local period_ms = period_minutes * 60 * 1000

    local timer = vim.uv.new_timer()
    if not timer then
        -- Timer creation failed (extremely unlikely).  Return a no-op
        -- handle so the caller's code-paths are uniform.
        return { stop = function() end }
    end

    -- The callback runs on libuv's thread; defer all Lua work into
    -- vim.schedule so it goes through Neovim's main loop.  Wrap in pcall
    -- so a future bug doesn't kill the timer.
    timer:start(period_ms, period_ms, function()
        vim.schedule(function() pcall(M.gc, opts) end)
    end)

    -- The handle owns the only reference back to `timer`.  The closure
    -- below also captures a boolean so .stop() is idempotent at the
    -- handle level (calling it twice is harmless).
    local stopped = false
    return {
        timer = timer,  -- exposed so callers like our extension can introspect
        stop = function()
            if stopped then return end
            stopped = true
            pcall(timer.stop, timer)
            pcall(timer.close, timer)
        end,
    }
end

return M
