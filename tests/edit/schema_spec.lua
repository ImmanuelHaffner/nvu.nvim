--- Tests for nvu.edit.schema.
---
--- Run headless:
---   nvim --headless --noplugin -u NONE \
---     -c "set rtp+=$PWD" -c "luafile tests/runner.lua" -c "qall!"
---
--- Or one file at a time (e.g. from inside a running Neovim):
---   :lua require'tests.runner'.run_file('tests/edit/schema_spec.lua')

local schema  = require'nvu.edit.schema'
local helpers = require'tests.edit.helpers'

--- Find the first error matching a (path, reason) pair, or nil.
local function find_error(errors, path, reason)
    for _, e in ipairs(errors) do
        if e.path == path and (reason == nil or e.reason == reason) then
            return e
        end
    end
    return nil
end

--- Assert that exactly one error matches the given path + reason.
local function assert_error(errors, path, reason)
    local hits = {}
    for _, e in ipairs(errors) do
        if e.path == path and (reason == nil or e.reason == reason) then
            table.insert(hits, e)
        end
    end
    assert.is.equal(1, #hits,
        string.format('expected exactly one error with path=%q reason=%q, found %d',
            path, tostring(reason), #hits))
    return hits[1]
end

describe('nvu.edit.schema', function()

    ----------------------------------------------------------------
    describe('top-level shape', function()
        it('rejects a non-table request', function()
            local ok, errors = helpers.validate('not an object')
            assert.is_false(ok)
            assert_error(errors, '', schema.ERROR_REASONS.wrong_type)
        end)

        it('rejects a request with no `ops` field', function()
            local ok, errors = helpers.validate{}
            assert.is_false(ok)
            local e = assert_error(errors, 'ops', schema.ERROR_REASONS.missing_field)
            assert.is_not_nil(e.hint)
        end)

        it('rejects an `ops` of the wrong type', function()
            local ok, errors = helpers.validate{ ops = 'not an array' }
            assert.is_false(ok)
            assert_error(errors, 'ops', schema.ERROR_REASONS.wrong_type)
        end)

        it('rejects an empty `ops` array', function()
            local ok, errors = helpers.validate{ ops = {} }
            assert.is_false(ok)
            assert_error(errors, 'ops', schema.ERROR_REASONS.out_of_range)
        end)

        it('rejects a non-boolean `dry_run`', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f', anchor = { by = 'line_range', start = 1, ['end'] = 1 } } },
                dry_run = 'yes',
            }
            assert.is_false(ok)
            assert_error(errors, 'dry_run', schema.ERROR_REASONS.wrong_type)
        end)

        it('rejects a non-string `description`', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f', anchor = { by = 'line_range', start = 1, ['end'] = 1 } } },
                description = 42,
            }
            assert.is_false(ok)
            assert_error(errors, 'description', schema.ERROR_REASONS.wrong_type)
        end)
    end)

    ----------------------------------------------------------------
    describe('contents map', function()
        it('rejects a non-object `contents`', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f', anchor = { by = 'line_range', start = 1, ['end'] = 1 } } },
                contents = 'not an object',
            }
            assert.is_false(ok)
            assert_error(errors, 'contents', schema.ERROR_REASONS.wrong_type)
        end)

        it('rejects non-identifier label keys', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f', anchor = { by = 'line_range', start = 1, ['end'] = 1 } } },
                contents = { ['1bad'] = 'x' },
            }
            assert.is_false(ok)
            assert.is_not_nil(find_error(errors, 'contents["1bad"]', schema.ERROR_REASONS.bad_pattern))
        end)

        it('rejects non-string label values', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f', anchor = { by = 'line_range', start = 1, ['end'] = 1 } } },
                contents = { good = 123 },
            }
            assert.is_false(ok)
            assert.is_not_nil(find_error(errors, 'contents["good"]', schema.ERROR_REASONS.wrong_type))
        end)
    end)

    ----------------------------------------------------------------
    describe('ops', function()
        it('rejects an op with no `kind`', function()
            local ok, errors = helpers.validate{
                ops = { { path = 'f', anchor = { by = 'line_range', start = 1, ['end'] = 1 } } }
            }
            assert.is_false(ok)
            assert_error(errors, 'ops[0].kind', schema.ERROR_REASONS.wrong_type)
        end)

        it('rejects an unknown op kind', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'nope', path = 'f', anchor = { by = 'line_range', start = 1, ['end'] = 1 } } }
            }
            assert.is_false(ok)
            assert_error(errors, 'ops[0].kind', schema.ERROR_REASONS.unknown_kind)
        end)

        it('rejects a future-kind op as unsupported (not unknown)', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'rename_symbol', path = 'f',
                    position = { line = 0, character = 0 }, new_name = 'foo' } }
            }
            assert.is_false(ok)
            local e = assert_error(errors, 'ops[0].kind', schema.ERROR_REASONS.unsupported_op_kind)
            assert.is_not_nil(e.hint)
        end)

        it('rejects an op with no `path`', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'delete_range',
                    anchor = { by = 'line_range', start = 1, ['end'] = 1 } } }
            }
            assert.is_false(ok)
            assert_error(errors, 'ops[0].path', schema.ERROR_REASONS.wrong_type)
        end)

        it('rejects an op with no `anchor`', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f' } }
            }
            assert.is_false(ok)
            assert_error(errors, 'ops[0].anchor', schema.ERROR_REASONS.missing_field)
        end)

        it('reports errors from multiple ops (does not bail on first)', function()
            local ok, errors = helpers.validate{
                ops = {
                    { kind = 'delete_range', path = 'f', anchor = { by = 'unknown' } },
                    { kind = 'delete_range', path = 'g', anchor = { by = 'unknown' } },
                }
            }
            assert.is_false(ok)
            assert.is_not_nil(find_error(errors, 'ops[0].anchor.by', schema.ERROR_REASONS.unknown_kind))
            assert.is_not_nil(find_error(errors, 'ops[1].anchor.by', schema.ERROR_REASONS.unknown_kind))
        end)
    end)

    ----------------------------------------------------------------
    describe('anchors', function()
        it('accepts a valid line_range anchor', function()
            local ok, parsed = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f',
                    anchor = { by = 'line_range', start = 10, ['end'] = 12 } } }
            }
            assert.is_true(ok)
            assert.is.equal('line_range', parsed.ops[1].anchor.by)
            assert.is.equal(10, parsed.ops[1].anchor.start)
            assert.is.equal(12, parsed.ops[1].anchor['end'])
        end)

        it('rejects a line_range with end < start', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f',
                    anchor = { by = 'line_range', start = 12, ['end'] = 10 } } }
            }
            assert.is_false(ok)
            assert_error(errors, 'ops[0].anchor.end', schema.ERROR_REASONS.out_of_range)
        end)

        it('rejects a line_range with non-positive bounds', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f',
                    anchor = { by = 'line_range', start = 0, ['end'] = 5 } } }
            }
            assert.is_false(ok)
            assert_error(errors, 'ops[0].anchor.start', schema.ERROR_REASONS.out_of_range)
        end)

        it('accepts a unique_text anchor with no occurrence', function()
            local ok, parsed = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f',
                    anchor = { by = 'unique_text', text = 'foo' } } }
            }
            assert.is_true(ok)
            assert.is.equal('foo', parsed.ops[1].anchor.text)
            assert.is_nil(parsed.ops[1].anchor.occurrence)
        end)

        it('accepts unique_text with occurrence={nth=N}', function()
            local ok, parsed = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f',
                    anchor = { by = 'unique_text', text = 'foo', occurrence = { nth = 3 } } } }
            }
            assert.is_true(ok)
            assert.is.equal(3, parsed.ops[1].anchor.occurrence.nth)
        end)

        it('accepts unique_text with occurrence="all" on delete_range', function()
            local ok, parsed = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f',
                    anchor = { by = 'unique_text', text = 'foo', occurrence = 'all' } } }
            }
            assert.is_true(ok)
            assert.is.equal('all', parsed.ops[1].anchor.occurrence)
        end)

        it('rejects unique_text with occurrence="all" on replace_range', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'replace_range', path = 'f',
                    anchor = { by = 'unique_text', text = 'foo', occurrence = 'all' },
                    content = 'x' } }
            }
            assert.is_false(ok)
            assert_error(errors, 'ops[0].anchor.occurrence',
                schema.ERROR_REASONS.occurrence_all_disallowed)
        end)

        it('rejects malformed occurrence', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f',
                    anchor = { by = 'unique_text', text = 'foo', occurrence = 42 } } }
            }
            assert.is_false(ok)
            assert_error(errors, 'ops[0].anchor.occurrence', schema.ERROR_REASONS.wrong_type)
        end)

        it('rejects treesitter / lsp_symbol as unsupported', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f',
                    anchor = { by = 'treesitter', query = '@function' } } }
            }
            assert.is_false(ok)
            assert_error(errors, 'ops[0].anchor.by', schema.ERROR_REASONS.unsupported_anchor_kind)
        end)
    end)

    ----------------------------------------------------------------
    describe('positional modifiers', function()
        it('accepts before/after wrapping a base anchor', function()
            local ok, parsed = helpers.validate{
                ops = { { kind = 'insert', path = 'f',
                    anchor = { by = 'after', of = { by = 'line_range', start = 5, ['end'] = 5 } },
                    content = 'x' } }
            }
            assert.is_true(ok)
            assert.is.equal('after', parsed.ops[1].anchor.by)
            assert.is.equal('line_range', parsed.ops[1].anchor.of.by)
        end)

        it('accepts inside with at="start" or at="end"', function()
            for _, at in ipairs{'start', 'end'} do
                local ok, parsed = helpers.validate{
                    ops = { { kind = 'insert', path = 'f',
                        anchor = { by = 'inside',
                                   of = { by = 'line_range', start = 5, ['end'] = 10 },
                                   at = at },
                        content = 'x' } }
                }
                assert.is_true(ok)
                assert.is.equal(at, parsed.ops[1].anchor.at)
            end
        end)

        it('rejects inside without `at`', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'insert', path = 'f',
                    anchor = { by = 'inside', of = { by = 'line_range', start = 5, ['end'] = 10 } },
                    content = 'x' } }
            }
            assert.is_false(ok)
            assert_error(errors, 'ops[0].anchor.at', schema.ERROR_REASONS.wrong_type)
        end)

        it('rejects insert with a bare base anchor (no modifier)', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'insert', path = 'f',
                    anchor = { by = 'line_range', start = 5, ['end'] = 5 },
                    content = 'x' } }
            }
            assert.is_false(ok)
            local e = assert_error(errors, 'ops[0].anchor', schema.ERROR_REASONS.bad_modifier_target)
            assert.is_not_nil(e.hint)
        end)

        it('accepts a bare base anchor on replace_range and delete_range', function()
            for _, kind in ipairs{'replace_range', 'delete_range'} do
                local op = { kind = kind, path = 'f',
                    anchor = { by = 'line_range', start = 5, ['end'] = 5 } }
                if kind == 'replace_range' then op.content = 'x' end
                local ok = helpers.validate{ ops = { op } }
                assert.is_true(ok, 'expected ' .. kind .. ' to accept a bare base anchor')
            end
        end)
    end)

    ----------------------------------------------------------------
    describe('content / content_ref', function()
        it('requires content or content_ref on replace_range', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'replace_range', path = 'f',
                    anchor = { by = 'line_range', start = 1, ['end'] = 1 } } }
            }
            assert.is_false(ok)
            assert_error(errors, 'ops[0]', schema.ERROR_REASONS.missing_content)
        end)

        it('requires content or content_ref on insert', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'insert', path = 'f',
                    anchor = { by = 'after', of = { by = 'line_range', start = 1, ['end'] = 1 } } } }
            }
            assert.is_false(ok)
            assert_error(errors, 'ops[0]', schema.ERROR_REASONS.missing_content)
        end)

        it('rejects both content and content_ref together', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'replace_range', path = 'f',
                    anchor = { by = 'line_range', start = 1, ['end'] = 1 },
                    content = 'x', content_ref = 'y' } },
                contents = { y = 'multi\nline' },
            }
            assert.is_false(ok)
            assert_error(errors, 'ops[0]', schema.ERROR_REASONS.mutually_exclusive)
        end)

        it('rejects a content_ref that does not resolve', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'replace_range', path = 'f',
                    anchor = { by = 'line_range', start = 1, ['end'] = 1 },
                    content_ref = 'nope' } },
                contents = { exists = 'x' },
            }
            assert.is_false(ok)
            local e = assert_error(errors, 'ops[0].content_ref',
                schema.ERROR_REASONS.dangling_content_ref)
            -- Available labels are listed in `got` so the LLM can self-correct.
            assert.is_string(e.got)
            assert.is_truthy(e.got:find('exists'),
                'expected `got` to list available labels, was: ' .. tostring(e.got))
        end)

        it('rejects a content_ref that is not identifier-shaped', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'replace_range', path = 'f',
                    anchor = { by = 'line_range', start = 1, ['end'] = 1 },
                    content_ref = '1bad' } },
                contents = { ['1bad'] = 'x' },  -- bad in contents too, but content_ref check comes first
            }
            assert.is_false(ok)
            -- The pattern violation will trip in contents OR in content_ref —
            -- either is fine; both indicate the same root cause.
            assert.is_true(
                find_error(errors, 'ops[0].content_ref', schema.ERROR_REASONS.bad_pattern) ~= nil
                or find_error(errors, 'contents["1bad"]', schema.ERROR_REASONS.bad_pattern) ~= nil
            )
        end)

        it('marks content_ref labels as used (no warning when referenced)', function()
            local ok, parsed = helpers.validate{
                ops = { { kind = 'replace_range', path = 'f',
                    anchor = { by = 'line_range', start = 1, ['end'] = 1 },
                    content_ref = 'helper' } },
                contents = { helper = 'x' },
            }
            assert.is_true(ok)
            assert.is.equal(0, #parsed.warnings,
                'expected no warnings when content_ref resolves')
        end)

        it('warns about unused content labels', function()
            local ok, parsed = helpers.validate{
                ops = { { kind = 'delete_range', path = 'f',
                    anchor = { by = 'line_range', start = 1, ['end'] = 1 } } },
                contents = { unused = 'wasted' },
            }
            assert.is_true(ok)
            assert.is.equal(1, #parsed.warnings)
            assert.is.equal(schema.WARNING_REASONS.unused_content_label,
                parsed.warnings[1].reason)
        end)
    end)

    ----------------------------------------------------------------
    describe('indent', function()
        it('defaults to match_anchor when omitted', function()
            local ok, parsed = helpers.validate{
                ops = { { kind = 'replace_range', path = 'f',
                    anchor = { by = 'line_range', start = 1, ['end'] = 1 },
                    content = 'x' } }
            }
            assert.is_true(ok)
            assert.is.equal('match_anchor', parsed.ops[1].indent)
        end)

        it('accepts match_anchor / preserve', function()
            for _, mode in ipairs{'match_anchor', 'preserve'} do
                local ok, parsed = helpers.validate{
                    ops = { { kind = 'replace_range', path = 'f',
                        anchor = { by = 'line_range', start = 1, ['end'] = 1 },
                        content = 'x', indent = mode } }
                }
                assert.is_true(ok)
                assert.is.equal(mode, parsed.ops[1].indent)
            end
        end)

        it('accepts detect with a warning and falls back to match_anchor', function()
            local ok, parsed = helpers.validate{
                ops = { { kind = 'replace_range', path = 'f',
                    anchor = { by = 'line_range', start = 1, ['end'] = 1 },
                    content = 'x', indent = 'detect' } }
            }
            assert.is_true(ok)
            assert.is.equal('match_anchor', parsed.ops[1].indent)
            assert.is.equal(1, #parsed.warnings)
            assert.is.equal(schema.WARNING_REASONS.indent_detect_fallback,
                parsed.warnings[1].reason)
        end)

        it('rejects an unknown indent mode', function()
            local ok, errors = helpers.validate{
                ops = { { kind = 'replace_range', path = 'f',
                    anchor = { by = 'line_range', start = 1, ['end'] = 1 },
                    content = 'x', indent = 'something' } }
            }
            assert.is_false(ok)
            assert_error(errors, 'ops[0].indent', schema.ERROR_REASONS.wrong_type)
        end)
    end)

    ----------------------------------------------------------------
    describe('format_error_summary', function()
        it('handles an empty list', function()
            assert.is.equal('no schema errors', schema.format_error_summary{})
            assert.is.equal('no schema errors', schema.format_error_summary(nil))
        end)

        it('counts request-level errors', function()
            local s = schema.format_error_summary{
                { path = 'ops', reason = 'missing_field', message = 'x' },
            }
            assert.is_truthy(s:find('1 request%-level error'))
        end)

        it('counts errors and distinct ops', function()
            -- `op_index` is 1-based Lua-native; JSON `path` stays 0-based.
            -- See the indexing-convention note in schema.lua's header.
            local s = schema.format_error_summary{
                { path = 'ops[0].kind', reason = 'unknown_kind', message = 'x', op_index = 1 },
                { path = 'ops[0].path', reason = 'wrong_type',   message = 'x', op_index = 1 },
                { path = 'ops[1].kind', reason = 'unknown_kind', message = 'x', op_index = 2 },
            }
            assert.is_truthy(s:find('3 errors across 2 ops'))
        end)
    end)

    ----------------------------------------------------------------
    describe('happy path: full request shape', function()
        it('parses a multi-op batch with inline and ref content', function()
            local ok, parsed = helpers.validate{
                description = 'rename and helper',
                dry_run = false,
                ops = {
                    { kind = 'replace_range', path = 'lua/foo.lua',
                      anchor = { by = 'unique_text', text = 'local x = 1' },
                      content = 'local x = 2' },
                    { kind = 'insert', path = 'lua/foo.lua',
                      anchor = { by = 'before', of = { by = 'line_range', start = 10, ['end'] = 10 } },
                      content_ref = 'helper', indent = 'preserve' },
                    { kind = 'delete_range', path = 'lua/foo.lua',
                      anchor = { by = 'unique_text', text = 'obsolete', occurrence = 'all' } },
                },
                contents = {
                    helper = 'function helper()\n    return true\nend\n',
                },
            }
            assert.is_true(ok)
            assert.is.equal(3, #parsed.ops)
            assert.is.equal('rename and helper', parsed.description)
            assert.is_false(parsed.dry_run)
            assert.is.equal('preserve', parsed.ops[2].indent)
            assert.is.equal('all', parsed.ops[3].anchor.occurrence)
            assert.is.equal(0, #parsed.warnings, 'no warnings expected')
        end)
    end)
end)
