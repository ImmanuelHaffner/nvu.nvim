--- mcphub adapter for the `nvu.edit` engine.
---
--- Registers two tools on mcphub's existing `neovim` native server via
--- `mcphub.add_tool("neovim", …)`:
---
---   * `neovim__apply_edit`              — structured batch edits
---   * `neovim__read_with_fingerprint`   — read + baseline-fingerprint emission
---
--- These are intended to ship together. `apply_edit` requires every op
--- to carry a `baseline_fingerprint` field; the only legitimate source
--- of those fingerprints is `read_with_fingerprint`. Once both are
--- registered, the user should disable the legacy `neovim__read_file`
--- tool from mcphub's config — required fingerprints make any other
--- read path a footgun.
---
--- This is the *only* file in `nvu.nvim` that imports `mcphub`; the
--- engines themselves (`nvu.edit`, `nvu.edit.read`) stay pure Lua and
--- unit-testable in isolation.
---
--- This file is intended to be `require`d from the user's Neovim config
--- *after* `mcphub.setup{}` has run. Side effect: registers both tools.
---
--- @module "mcphub._native.edit"

local ok, mcphub = pcall(require, 'mcphub')
if not ok then
    vim.notify(
        'mcphub._native.edit: mcphub.nvim is not available; '
        .. 'neovim__apply_edit and neovim__read_with_fingerprint will not be registered',
        vim.log.levels.WARN
    )
    return
end

local edit      = require'nvu.edit'
local edit_read = require'nvu.edit.read'

--------------------------------------------------------------------------------
-- Anchor schemas
--------------------------------------------------------------------------------

-- An Anchor selects a location or range in a file. Base anchors resolve to a
-- range; positional modifiers (before/after/inside) wrap a base anchor to
-- produce a position. The schema admits a 3-level nesting cap implicitly via
-- `Anchor → Modifier → BaseAnchor`; deeper nesting is unreachable because
-- modifiers only wrap base anchors, not other modifiers.

local base_anchor_schema = {
    oneOf = {
        -- line_range: by absolute, 1-based, inclusive line numbers.
        {
            type = 'object',
            properties = {
                by    = { type = 'string', const = 'line_range' },
                start = { type = 'integer', minimum = 1 },
                ['end'] = { type = 'integer', minimum = 1 },
            },
            required = { 'by', 'start', 'end' },
            additionalProperties = false,
        },
        -- unique_text: by a substring of file content. Must resolve to a single
        -- range unless `occurrence` disambiguates. `"all"` is valid only on
        -- delete_range; the engine enforces that at validation time.
        {
            type = 'object',
            properties = {
                by   = { type = 'string', const = 'unique_text' },
                text = { type = 'string', minLength = 1 },
                occurrence = {
                    oneOf = {
                        { type = 'string', const = 'all' },
                        {
                            type = 'object',
                            properties = { nth = { type = 'integer', minimum = 1 } },
                            required = { 'nth' },
                            additionalProperties = false,
                        },
                    },
                },
            },
            required = { 'by', 'text' },
            additionalProperties = false,
        },
        -- treesitter: by a query capture and optional name predicate. (v2)
        {
            type = 'object',
            properties = {
                by    = { type = 'string', const = 'treesitter' },
                query = { type = 'string', minLength = 1 },
                name  = { type = 'string' },
            },
            required = { 'by', 'query' },
            additionalProperties = false,
        },
        -- lsp_symbol: by an LSP document symbol. (v2)
        {
            type = 'object',
            properties = {
                by   = { type = 'string', const = 'lsp_symbol' },
                name = { type = 'string', minLength = 1 },
                kind = { type = 'string' },
            },
            required = { 'by', 'name' },
            additionalProperties = false,
        },
    },
}

local modifier_anchor_schema = {
    oneOf = {
        -- before / after: position immediately before/after a base anchor.
        {
            type = 'object',
            properties = {
                by = { type = 'string', enum = { 'before', 'after' } },
                of = base_anchor_schema,
            },
            required = { 'by', 'of' },
            additionalProperties = false,
        },
        -- inside: a position interior to a block-like base anchor.
        {
            type = 'object',
            properties = {
                by = { type = 'string', const = 'inside' },
                of = base_anchor_schema,
                at = { type = 'string', enum = { 'start', 'end' } },
            },
            required = { 'by', 'of', 'at' },
            additionalProperties = false,
        },
    },
}

-- The top-level Anchor admits either a base anchor (resolves to a range) or a
-- modifier-wrapped anchor (resolves to a position).
local anchor_schema = {
    oneOf = { base_anchor_schema, modifier_anchor_schema },
}

--------------------------------------------------------------------------------
-- Common op fragments
--------------------------------------------------------------------------------

local indent_schema = { type = 'string', enum = { 'match_anchor', 'preserve', 'detect' } }

-- baseline_fingerprint: a 7-character lowercase-hex content fingerprint
-- previously issued by neovim__read_with_fingerprint. The planner re-computes
-- and compares; mismatch → stale_fingerprint failure. See nvu.edit.fingerprint
-- for the format.
local baseline_fingerprint_schema = { type = 'string', pattern = '^[0-9a-f]{7}$' }

-- Ops that introduce content (replace_range, insert) must supply EXACTLY ONE
-- of `content` or `content_ref`. Expressed as `oneOf` over two required sets.
-- The shape below is meant to be `allOf`-merged with the per-op base.
local content_xor_schema = {
    oneOf = {
        {
            required = { 'content' },
            properties = { content = { type = 'string' } },
            not_ = { required = { 'content_ref' } },  -- documentation only; JSON Schema "not" added at runtime if validator supports it
        },
        {
            required = { 'content_ref' },
            properties = { content_ref = { type = 'string', pattern = '^[a-zA-Z_][a-zA-Z0-9_]*$' } },
        },
    },
}
-- Note: the `not_` key above is descriptive only — mcphub's validator may or
-- may not support the JSON-Schema `not` keyword. The engine re-validates
-- mutual exclusivity in Lua, which is authoritative.

--------------------------------------------------------------------------------
-- Per-op schemas
--------------------------------------------------------------------------------

local replace_range_schema = {
    type = 'object',
    properties = {
        kind                 = { type = 'string', const = 'replace_range' },
        path                 = { type = 'string', minLength = 1 },
        anchor               = anchor_schema,
        content              = { type = 'string' },
        content_ref          = { type = 'string', pattern = '^[a-zA-Z_][a-zA-Z0-9_]*$' },
        indent               = indent_schema,
        baseline_fingerprint = baseline_fingerprint_schema,
    },
    required = { 'kind', 'path', 'anchor' },
    additionalProperties = false,
    allOf = { content_xor_schema },
}

local insert_schema = {
    type = 'object',
    properties = {
        kind                 = { type = 'string', const = 'insert' },
        path                 = { type = 'string', minLength = 1 },
        anchor               = anchor_schema,
        content              = { type = 'string' },
        content_ref          = { type = 'string', pattern = '^[a-zA-Z_][a-zA-Z0-9_]*$' },
        indent               = indent_schema,
        baseline_fingerprint = baseline_fingerprint_schema,
    },
    required = { 'kind', 'path', 'anchor' },
    additionalProperties = false,
    allOf = { content_xor_schema },
}

local delete_range_schema = {
    type = 'object',
    properties = {
        kind                 = { type = 'string', const = 'delete_range' },
        path                 = { type = 'string', minLength = 1 },
        anchor               = anchor_schema,
        baseline_fingerprint = baseline_fingerprint_schema,
    },
    required = { 'kind', 'path', 'anchor' },
    additionalProperties = false,
}

-- v2: LSP-backed rename.
local rename_symbol_schema = {
    type = 'object',
    properties = {
        kind     = { type = 'string', const = 'rename_symbol' },
        path     = { type = 'string', minLength = 1 },
        position = {
            type = 'object',
            properties = {
                line      = { type = 'integer', minimum = 0 },
                character = { type = 'integer', minimum = 0 },
            },
            required = { 'line', 'character' },
            additionalProperties = false,
        },
        new_name             = { type = 'string', minLength = 1 },
        baseline_fingerprint = baseline_fingerprint_schema,
    },
    required = { 'kind', 'path', 'position', 'new_name' },
    additionalProperties = false,
}

-- v2: LSP code action (typically source.organizeImports, etc).
local lsp_code_action_schema = {
    type = 'object',
    properties = {
        kind     = { type = 'string', const = 'lsp_code_action' },
        path     = { type = 'string', minLength = 1 },
        range = {
            type = 'object',
            properties = {
                start_line = { type = 'integer', minimum = 1 },
                ['end_line'] = { type = 'integer', minimum = 1 },
            },
            required = { 'start_line', 'end_line' },
            additionalProperties = false,
        },
        kind_filter          = { type = 'string', minLength = 1 },
        baseline_fingerprint = baseline_fingerprint_schema,
    },
    required = { 'kind', 'path', 'range', 'kind_filter' },
    additionalProperties = false,
}

local op_schema = {
    oneOf = {
        replace_range_schema,
        insert_schema,
        delete_range_schema,
        rename_symbol_schema,
        lsp_code_action_schema,
    },
}

--------------------------------------------------------------------------------
-- Top-level request schema
--------------------------------------------------------------------------------

local input_schema = {
    type = 'object',
    properties = {
        ops = {
            type = 'array',
            minItems = 1,
            items = op_schema,
        },
        contents = {
            type = 'object',
            -- Keys must match the identifier-shape label pattern. We declare it
            -- on `propertyNames`; values are plain strings.
            propertyNames = { pattern = '^[a-zA-Z_][a-zA-Z0-9_]*$' },
            additionalProperties = { type = 'string' },
        },
        dry_run     = { type = 'boolean' },
        description = { type = 'string' },
    },
    required = { 'ops' },
    additionalProperties = false,
}

--------------------------------------------------------------------------------
-- Tool description (terse; the protocol is documented through the schema)
--------------------------------------------------------------------------------

local tool_description = [[
Apply a batch of structured edits to existing files. One call = one
transaction: either every op lands or none do.

Each op selects a location with an `anchor` (by `line_range`,
`unique_text`, or `before`/`after`/`inside` a base anchor) and either
replaces, inserts, or deletes. Content for replace/insert goes inline in
`content` for short single-line text, or by reference in
`content_ref` → `contents[label]` for multi-line bulk.

On ambiguity or miss, the response returns a structured failure with
candidate ranges and a hint — no fuzzy guessing, no silent wrong-location
edits. Reindentation defaults to matching the anchor's leading whitespace.

Use this for *editing inside existing files*. For file create / delete /
rename, use `neovim__write_file`, `neovim__delete_items`,
`neovim__move_item` respectively.
]]

--------------------------------------------------------------------------------
-- Tool registration
--------------------------------------------------------------------------------

--- @type MCPTool
local apply_edit_tool = {
    name = 'apply_edit',
    description = tool_description,
    inputSchema = input_schema,
    handler = function(req, res)
        local response = edit.apply(req.params or {})
        local ok_json, encoded = pcall(vim.json.encode, response)
        if not ok_json then
            return res:error('apply_edit: failed to encode response', { response = response })
        end
        return res:text(encoded):send()
    end,
}

local ok_add, err = pcall(mcphub.add_tool, 'neovim', apply_edit_tool)
if not ok_add then
    vim.notify(
        'mcphub._native.edit: failed to register neovim__apply_edit: ' .. tostring(err),
        vim.log.levels.ERROR
    )
end

--------------------------------------------------------------------------------
-- neovim__read_with_fingerprint — read a file and emit a baseline fingerprint
--------------------------------------------------------------------------------

local read_input_schema = {
    type = 'object',
    properties = {
        path = { type = 'string', minLength = 1 },
    },
    required = { 'path' },
    additionalProperties = false,
}

local read_description = [[
Read a file and receive its content together with an opaque baseline
fingerprint. The fingerprint is the LLM's receipt: pass it back
verbatim in the `baseline_fingerprint` field of every `apply_edit`
op against this file. The planner re-computes the fingerprint at
apply time and refuses the batch on mismatch (`stale_fingerprint`),
closing the race where the file mutates between read and edit.

This is the only read path that emits a fingerprint — and therefore
the only read path you should use when planning to edit. Treat the
fingerprint as opaque; do not parse or regenerate it.

Returns: { status: "ok", path, content, baseline_fingerprint, n_lines }
On error: { status: "failed", summary, failed: [{ reason, path, message, hint }] }
]]

--- @type MCPTool
local read_with_fingerprint_tool = {
    name        = 'read_with_fingerprint',
    description = read_description,
    inputSchema = read_input_schema,
    handler = function(req, res)
        local params = req.params or {}
        local response = edit_read.read_with_fingerprint(params.path)
        local ok_json, encoded = pcall(vim.json.encode, response)
        if not ok_json then
            return res:error('read_with_fingerprint: failed to encode response', { response = response })
        end
        return res:text(encoded):send()
    end,
}

local ok_add_read, err_read = pcall(mcphub.add_tool, 'neovim', read_with_fingerprint_tool)
if not ok_add_read then
    vim.notify(
        'mcphub._native.edit: failed to register neovim__read_with_fingerprint: ' .. tostring(err_read),
        vim.log.levels.ERROR
    )
end

return {
    apply_edit             = apply_edit_tool,
    read_with_fingerprint  = read_with_fingerprint_tool,
}
