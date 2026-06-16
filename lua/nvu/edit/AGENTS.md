# `nvu.edit` — maintainer's guide

This file is for people changing the code. For *using* the protocol —
input shapes, response shapes, error reasons — see [`README.md`](README.md).

The goal here is to explain **why the code is shaped this way** so a
maintainer can edit it without re-deriving the design from first principles.

## Contents

- [Architecture and module boundaries](#architecture-and-module-boundaries)
- [Indexing conventions](#indexing-conventions)
- [Locked design decisions](#locked-design-decisions)
- [Module-by-module orientation](#module-by-module-orientation)
- [Test layout](#test-layout)
- [Footguns](#footguns)
- [Deferred work](#deferred-work)

## Architecture and module boundaries

Two source trees, with a strict one-way dependency:

```
lua/nvu/edit/             ← pure engine. No mcphub, no MCP, no UI.
                            Only imports from itself and from vim.*.

lua/mcphub/_native/edit/  ← mcphub bridge. The only files allowed to
                            require mcphub.* and reach into EditUI.
                            Imports from nvu.edit downward.
```

The boundary is **grep-enforceable**:

```
grep -rn "require.*mcphub" lua/nvu/   # MUST be empty
grep -rn "require.*mcphub" tests/edit/ # MUST be empty (comments OK)
```

Test layout mirrors this:

```
tests/edit/                       ← tests for lua/nvu/edit/*
tests/mcphub/_native/edit/        ← tests for lua/mcphub/_native/edit/*
```

If you add a test that requires mcphub, it goes in `tests/mcphub/_native/edit/`,
period. Putting it under `tests/edit/` breaks the boundary check; the runner
won't notice but the grep will.

The reason for the split: the engine is the project's reusable asset. The
mcphub bridge is one consumer; there could be others (a CLI driver, a
Telescope picker, a programmatic batch caller). Keeping the engine free of
mcphub imports means swapping the consumer doesn't require touching the
engine.

## Indexing conventions

These trip up everyone, including future-you. Pin them in mind before
editing anything in `applier.lua`, `anchors/*.lua`, or `ui_backend.lua`.

| Quantity                          | Convention                                           |
| --------------------------------- | ---------------------------------------------------- |
| `op_index` (Lua and wire)         | 1-based **everywhere** in the response: matches the position of the op in the input `ops[]` array, counting from 1. The internal `parsed_ops[op_index]` table-lookup is therefore direct, no translation. |
| JSON-Pointer-style `path` strings inside `schema_invalid` errors | 0-based. `"ops[0].anchor.text"` refers to the first op. Matches RFC 6901. Built in `validate_op` as `string.format('ops[%d]', op_index - 1)`. |
| Line ranges in the engine         | 1-based inclusive everywhere.                        |
| Line ranges at `nvim_buf_set_lines` boundary | 0-based, end-exclusive. `start_0 = start_line - 1; end_excl = end_line`. |
| Zero-width position (insert)      | `{ start_line = N, end_line = N - 1 }`.              |
| Diagnostic positions in `vim.diagnostic.Diagnostic` | 0-based.                          |
| Diagnostic positions in the response | 1-based. Translation in `collect_diagnostics`.    |
| Severity in `vim.diagnostic`      | Integer enum (`ERROR=1, WARN=2, INFO=3, HINT=4`).    |
| Severity in the response          | Lowercase string. `SEVERITY_NAME` table in `ui_backend.lua`. |

The historical motivation for "JSON is 0-based" was the JSON Pointer
spec. We bend that here: `op_index` as a structured field is much more
useful to LLMs as a 1-based position (matches how they count
naturally) than as a 0-based offset. The 0-based form is preserved
only inside the JSON Pointer path strings, which the LLM reads as
location hints rather than indexing into.

The zero-width-position convention (`{N, N-1}`) is deliberate. It encodes
"insert before line N" as a regular range that:
- can pass through the same code as non-degenerate ranges,
- naturally maps to `nvim_buf_set_lines(N-1, N-1, ...)` (start == end == N-1),
- distinguishes from a single-line range `{N, N}` which selects line N for replacement.

## Locked design decisions

These are settled. Reopening any of them needs an explicit reason that
wasn't available at the time. The rationale is recorded here so a
reopening can be honest about what's changing.

### Implementation in `nvu.nvim`, not a mcphub fork

We extend mcphub via its `add_tool("neovim", …)` API. Why not fork:
forking inherits maintenance burden for the rest of mcphub; the
add_tool surface is exactly the extension point we need.

### LLM-facing namespace `neovim__*`

`neovim__apply_edit` is sibling to mcphub's existing
`neovim__edit_file`. Clean parallel for the migration: roll out
`apply_edit`, validate, deprecate `edit_file` in user-side config.

### Batch-of-ops, not stream-of-ops

A single `apply_edit` call carries a list of operations. Batch atomicity
is implicit within a file; across files it is best-effort (see README's
*Limitations* section). The LLM benefits from grouping related edits in
one call because the response describes the whole set coherently.

### JSON wire format + `contents` labelled-sidecar

Bulk multi-line content moves to top-level `contents: { [label]: string }`
with ops referencing via `content_ref`. Inline `content` is for short
strings. The sidecar keeps op bodies scannable when content is long;
inline is cheaper when it's short.

### No fuzzy anchor matching

`unique_text` requires exact substring match. On zero or many matches,
we return structured candidates and refuse. This is a deliberate choice
over the SEARCH/REPLACE approach of "guess the closest match" — the
guess produces silent wrong-location edits, which is exactly what this
tool exists to eliminate.

### `unique_text` defaults to must-be-unique

Without `occurrence: "all"`, more than one match is `anchor_ambiguous`,
not "use the first one". `occurrence: "all"` is allowed only on
`delete_range`; everything else is rejected at validation time with
`occurrence_all_disallowed`. The check inspects both `anchor.occurrence`
(for `replace_range`) and `anchor.of.occurrence` (for modifier-wrapped
`insert`) so the schema covers both reachable shapes. The semantics of
broadcasting one piece of content or one zero-width position across
multiple match sites are ambiguous, and the resolver would either pick
silently or crash; the schema-level refusal preempts both.

### Baseline fingerprint is mandatory

Every op carries `baseline_fingerprint`. The LLM cannot bypass it.
`nvu.edit.apply(input, drive_file, on_complete)` takes no opts table,
so the production path can never thread `bypass_fingerprint = true`.
Tests bypass via `tests/edit/helpers.lua` wrappers that call
`schema.validate` / `planner.plan` directly with opts; the LLM-facing
entry point has no analogue.

### Fingerprint format: 7-char lowercase-hex prefix of SHA-256

No version prefix. The tool's schema is initialised atomically per
session, so cross-version mixing is structurally impossible. Format
regex: `^[0-9a-f]{7}$`.

### Buffer-first I/O

Reads come from the loaded buffer if one exists, regardless of
modified state. Disk content is a fallback. Writes go through
`:write` (mcphub's `EditUI` does the actual write), which triggers
`BufWritePre` autocmds and any format-on-save hooks. Our code never
touches the filesystem directly.

### EOL normalisation

Hashing and reading both use: `nvim_buf_get_lines` joined with `\n`,
plus a trailing `\n` iff `vim.bo[bufnr].endofline`. Identical recipe
at read time, baseline-validation time, and any future re-hash so
fingerprints compare meaningfully.

### Single LLM-facing entry point, structurally sealed

`nvu.edit.apply(input, drive_file, on_complete)` is the only function
the MCP handler calls. The `drive_file` and `on_complete` parameters
are continuations, not configuration — they cannot be expressed in
the JSON schema, so the LLM has no way to inject them or anything
config-like. Internal entry points (`schema.validate`, `planner.plan`,
`applier.apply_plan`) accept opts; the seal is at `M.apply`.

### `EditUI` reuse, not reimplementation

mcphub's `EditUI` already provides hunk-by-hunk review with
`./,/n/p/ga/gr` keybindings. We feed it pre-resolved `LocatedBlock`
shapes and bypass its `DiffParser` / `BlockLocator` (which implement
the SEARCH/REPLACE protocol we replace). This costs ~150 lines of
adapter code (`ui_backend.lua`) and saves rewriting the whole review
UI.

### Sequential per-file driving

`EditUI` installs global keymaps for the duration of a review;
running two instances simultaneously would have them fight. The
applier drives one file at a time. This also makes cross-file
atomicity inherently impossible — surfaced honestly in the response.

### Top-level `description` field was removed

The schema briefly accepted a top-level `description` string. Nothing
ever read it. We removed it. If we later want batch-level intent in
the response, adding it back as a pass-through is one commit. Don't
re-add it speculatively.

## Module-by-module orientation

### `lua/nvu/edit/`

**`init.lua`** — engine entry. `M.apply(input, drive_file, on_complete)`
is the sealed LLM-facing entry point. Wires schema → planner → applier.
Schema failures fire `on_complete` synchronously; planner and applier
results arrive via `vim.schedule`.

**`schema.lua`** — hand-rolled validator. ~900 lines, no external
validator dependency. Public surface: `M.validate(input, opts)`,
`M.ERROR_REASONS`, `M.WARNING_REASONS`, `M.format_error_summary`. Each
validation produces structured errors with `op_index`, `path` (JSON
Pointer), `reason`, `message`, `hint`, `expected`, `got`.

**`planner.lua`** — turns parsed ops into a `Plan`. Resolves anchors,
validates fingerprints, detects pre-widen range conflicts within a
file. Output is `{ records, located_ops, warnings }`.

**`anchors/init.lua`** — dispatcher. Calls into the appropriate
resolver based on `anchor.by`.

**`anchors/line_range.lua`** — trivial: validates bounds against the
file's line count, returns `{ start_line, end_line }`.

**`anchors/unique_text.lua`** — scan-based. Walks the file content
looking for the verbatim text. Caps at 3 candidates with early exit at
hit #4. Reports `total_matches` as an integer up to 3 or the string
`">3"`.

**`anchors/modifier.lua`** — wraps a base resolver. Translates
`before`/`after`/`inside` into zero-width positions on the inner range.
Rejects modifier-of-modifier at validation time.

**`file_record.lua`** — canonical "file as we see it" representation.
Buffer-first read; computes content normalisation and the fingerprint
the same way every time.

**`fingerprint.lua`** — SHA-256-based content-derived identifiers.
`M.compute(content) → "abc1234"`. Stateless.

**`read.lua`** — engine behind `neovim__read_with_fingerprint`. Loads
a file into a buffer, normalises content, computes fingerprint.

**`applier.lua`** — sequences files, drives one at a time via the
caller-supplied `drive_file`, classifies per-block outcomes into
`applied[]` / `rejected[]` / `failed[]`. Knows nothing about mcphub.

### `lua/mcphub/_native/edit/`

**`init.lua`** — MCP tool registration via `mcphub.add_tool`. Declares
the JSON schema for `neovim__apply_edit` and `neovim__read_with_fingerprint`.
Calls `nvu.edit.apply` for apply, `nvu.edit.read` for read.

**`ui_backend.lua`** — the `drive_file` implementation backed by mcphub's
`EditUI`. Contains:
- `widen_for_editui` — adapts zero-width / empty-replace blocks to
  EditUI's shape (which doesn't model them natively) by borrowing one
  neighbouring buffer line.
- `effective_range_after_widen` — pure prediction of the post-widen range.
- `detect_widen_collisions` — refuses batches where widening would
  produce overlaps that the planner couldn't have seen. Surfaces as
  `precondition_failed` with `range_conflict` failures.
- `collect_diagnostics` — translates `vim.diagnostic.Diagnostic` to our
  `Diagnostic` shape.
- `resolve_lsp_wait_ms` — per-LSP timeout table; max across attached
  clients; 0 when no LSP.
- `drive_file` — the orchestrator. Refuses early on collisions,
  otherwise widens, instantiates `EditUI`, snapshots state before
  cleanup, builds the `FileOutcome`.

## Test layout

| Directory                          | What it covers                                                |
| ---------------------------------- | ------------------------------------------------------------- |
| `tests/edit/`                      | Pure engine. No mcphub imports.                               |
| `tests/edit/helpers.lua`           | `schema.validate` / `planner.plan` wrappers with `bypass_fingerprint = true`. |
| `tests/edit/drivers.lua`           | Synthetic `drive_file` implementations: `accept_all`, `reject_all`, `make_selective`, `cancel_at`. |
| `tests/edit/e2e_spec.lua`          | End-to-end through `nvu.edit.apply` with `accept_all`.        |
| `tests/edit/applier_spec.lua`      | Applier outcome shapes via synthetic drivers.                 |
| `tests/edit/fingerprint_enforcement_spec.lua` | Direct calls to `schema.validate` / `planner.plan` *without* bypass — exercises the strict path. |
| `tests/edit/*_spec.lua`            | One spec per engine module.                                   |
| `tests/mcphub/_native/edit/`       | Bridge layer. May import mcphub.                              |
| `tests/mcphub/_native/edit/ui_backend_spec.lua` | Unit tests for the bridge helpers.                |
| `tests/mcphub/_native/edit/widen_conflict_spec.lua` | Regression test for the post-widen collision class. |
| `tests/runner.lua`                 | Internal busted-compatible runner. Supports `pending`.        |

The synthetic drivers test the **applier's reaction** to outcome
shapes, not mcphub's *production* of those outcomes. mcphub's
contract adherence on the reject path is verified by manual real-EditUI
smokes, not unit tests.

To add a regression test for a bug fix:

1. Write the spec asserting correct (post-fix) behaviour.
2. If the fix isn't in yet, mark with `pending('name', body, 'reason')`
   instead of `it('name', body)`. The runner shows it as PEND in
   yellow, doesn't run the body, doesn't count toward fail.
3. When the fix lands, flip `pending` to `it`.

To run a single spec:

```
nvim --headless --noplugin -u NONE \
  -c "set rtp+=$PWD" \
  -c "lua require'tests.runner'.run_file('tests/edit/schema_spec.lua')" \
  -c "qall!"
```

To run the whole suite:

```
nvim --headless --noplugin -u NONE \
  -c "set rtp+=$PWD" \
  -c "lua require'tests.runner'.run_dir('tests')" \
  -c "qall!"
```

Specs that drive `EditUI` (e.g. `widen_conflict_spec.lua`'s positive
control) include an `ensure_mcphub_on_rtp()` preamble that locates
mcphub via lazy.nvim's data directory.

## Footguns

These are real traps that have bitten us. Read before editing.

### Lua `ipairs` stops at the first `nil`

We compute "effective ranges per block" as an array `ranges[i]`, where
some entries are `nil` (e.g. for blocks that widening would refuse).
Iterating `for i, r in ipairs(ranges)` stops at the **first** nil
entry, skipping subsequent ones. Always use a numeric loop
(`for i = 1, #blocks`) when the array might be sparse. This bug was
caught by a regression test before commit.

### `ui.state` is nilled by `ui:cleanup()`

mcphub's `EditUI:cleanup` sets `self.state = nil`. Anything that reads
`ui.state.completed_hunks`, `ui.state.bufnr`, etc. must do so **before**
calling cleanup. Snapshot what you need; then cleanup.

### `EditUI.open_file_in_editor` and the CodeCompanion chat window

`open_file_in_editor` filters target windows by `buftype == ""`. The
CodeCompanion chat buffer has `buftype == "acwrite"`, so it's
structurally excluded from being displaced. Confirmed by reading
mcphub's source. Don't refactor this assumption away without
re-verifying.

### Zero-width range mapping

`{ start_line = N, end_line = N - 1 }` is a position, not a backwards
range. Code that treats it as an invalid range (e.g. asserting `e >= s`)
will crash on insert ops. Validate the position-vs-range distinction
explicitly: `e < s` is "zero-width position at line s"; `e >= s` is
"non-degenerate range".

### `nvim_buf_set_lines` is 0-based, end-exclusive

The single most common indexing bug in this code base would be passing
1-based-inclusive ranges to `nvim_buf_set_lines` directly. Always
translate at the boundary:

```lua
local start_0  = block.range.start_line - 1
local end_excl = block.range.end_line     -- not end_line + 1, because end_line is inclusive 1-based,
                                          -- so the 0-based end-exclusive is just end_line.
```

For zero-width inserts: `start_0 == end_excl == N - 1`.

### `vim.diff` interprets `"\n"` as one empty line, not zero lines

mcphub's `_generate_hunk_blocks` calls `vim.diff(table.concat(lines, "\n") .. "\n", ...)`.
For empty `lines`, this yields `"\n"`, which `vim.diff` reads as a
single empty line. That breaks both pure-delete (vim.diff reports
`new_count=1`) and pure-insert (reports `old_count=1`).

This is why `widen_for_editui` exists: we never hand mcphub a
zero-width or empty-replace `LocatedBlock`. The widening helper is
load-bearing, not an optimisation.

### Post-widen range conflicts

Widening can introduce range conflicts the planner couldn't see in
the pre-widen shapes. `detect_widen_collisions` runs at the bridge
*before* any widening, refusing the batch with `precondition_failed`
when collisions exist. This is correctness-critical: without it, a
delete-to-EOF adjacent to a replace silently loses the replace.

### Diagnostic wait is per-LSP, not flat

`resolve_lsp_wait_ms` picks the max across all attached LSP clients.
A buffer with both `tsserver` (1000 ms) and `metals` (5000 ms) waits
5000 ms. Tuning the table down for a single LSP can leave another
LSP under-served on shared buffers.

### Real LSP-attached LSPs vs none-attached

`resolve_lsp_wait_ms({})` returns 0 (no LSP, no wait). This is what
makes headless test runs fast — no LSPs attach to scratch buffers in
`-u NONE` mode. Don't refactor the empty-clients case away without
preserving this property; otherwise the suite slows by ~1s per
file-edit test.

## Deferred work

Things intentionally not done. Listed here so a maintainer doesn't
re-derive the design from scratch.

### Indentation: `match_anchor` algorithm

`indent` is accepted by the schema (`match_anchor` default, `preserve`,
`detect`) but the applier currently treats every mode as `preserve` —
content goes in verbatim. The full `match_anchor` algorithm is a
non-trivial heuristic with multiple edge cases (zero-width positions,
mixed indent in the existing block, content with relative indent
already applied by the LLM, etc.). Designed but not implemented;
algorithm sketch and seven worked edge cases live in
`docs/indent-design-notes.md` (untracked working notes).

Trigger: after MVP ships and real LLM-issued `apply_edit` calls give
us a corpus to validate the heuristic against.

### Event-driven diagnostic settle

Current diagnostic wait is a flat per-LSP timeout. A better approach:
listen for `DiagnosticChanged` autocmds with a debounce-on-quiet, exit
early when the server has actually published. Per-LSP table becomes
the upper-bound cap rather than the wait itself.

Trigger: real-usage signal that the latency matters. Until then, the
ceiling is correct and fast LSPs (lua_ls @ 300ms) already pay tolerable
latency.

### v2 anchor kinds

`treesitter`, `lsp_symbol`, `rename_symbol`, `lsp_code_action` are
recognised by the schema as `unsupported_anchor_kind`. The naming and
shape are reserved; implementation is deferred. Trigger: see which
ones LLMs actually want once `line_range` + `unique_text` are in use.

### Whole-file delete via direct apply

`delete_range` covering all lines of a file is currently refused with
`range_conflict`. A direct-apply path (bypass EditUI, do
`nvim_buf_set_lines(0, -1, {})` + `:write`) could support it, but
that's the same shape as "delete the file", which is what
`neovim__delete_items` is for. Defer until someone has a concrete use
case.

### Vim help page

A `doc/nvu-edit.txt` referenced from the terse MCP `tool_description`
would let the LLM look up the full protocol on demand without
bloating every tool-listing context. Concern: more tool surface to
maintain; LLM might not use it. Defer until we have signal that the
README-via-link approach is insufficient.

### `setup()` API for `ui_backend`

`LSP_WAIT_MS` and `DEFAULT_LSP_WAIT_MS` are currently exposed as
public module fields, mutated post-require. When we accumulate more
config knobs (LSP wait, diagnostic severity threshold, EditUI keymaps,
…), a proper `setup{...}` API will fold them in. Premature to do that
for one knob.

### Vendored / patched mcphub dependency

We currently depend on mcphub's `EditUI` API surface (specifically:
`open_file_in_editor`'s `buftype == ""` filter, `_handle_save`'s
`interactive == false` path, `state.completed_hunks` shape). A
breaking change in mcphub would break us silently. Trigger for
pinning or vendoring: first time mcphub ships an incompatible change.
For now, the manual smoke test against real `EditUI` is our regression
canary.
