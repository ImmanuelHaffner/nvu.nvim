--- Tests for nvu.edit.snapshot.
---
--- Run headless:
---   nvim --headless --noplugin -u NONE \
---     -c "set rtp+=$PWD" -c "luafile tests/runner.lua" -c "qall!"

local snapshot = require'nvu.edit.snapshot'

describe('nvu.edit.snapshot', function()

    describe('HASH_LEN constant', function()
        it('is 7', function()
            assert.is.equal(7, snapshot.HASH_LEN)
        end)
    end)

    describe('compute', function()
        it('produces a 7-character token', function()
            assert.is.equal(7, #snapshot.compute('hello\n'))
        end)

        it('is deterministic — same input → same token', function()
            local t1 = snapshot.compute('content')
            local t2 = snapshot.compute('content')
            assert.is.equal(t1, t2)
        end)

        it('different content → different token (almost always)', function()
            -- Not strictly required by the hash, but for any two
            -- realistic strings the 28-bit prefix will differ.
            local t1 = snapshot.compute('content one')
            local t2 = snapshot.compute('content two')
            assert.is_truthy(t1 ~= t2)
        end)

        it('handles empty content', function()
            assert.is.equal(7, #snapshot.compute(''))
        end)

        it('handles content with embedded newlines', function()
            assert.is.equal(7, #snapshot.compute('a\nb\nc\n'))
        end)

        it('emits lowercase hex only', function()
            -- vim.fn.sha256 returns lowercase; verify we don't accidentally
            -- introduce case via the substring.
            for _, content in ipairs({ '', 'a', 'ABC', string.rep('x', 100) }) do
                local t = snapshot.compute(content)
                assert.is_truthy(t:match('^[0-9a-f]+$'))
            end
        end)

        it('matches the first 7 hex chars of vim.fn.sha256 directly', function()
            local content = 'verification check'
            local expected = vim.fn.sha256(content):sub(1, 7)
            assert.is.equal(expected, snapshot.compute(content))
        end)

        it('asserts on non-string input', function()
            assert.is_falsy(pcall(snapshot.compute, 42))
            assert.is_falsy(pcall(snapshot.compute, nil))
            assert.is_falsy(pcall(snapshot.compute, { 'not', 'a', 'string' }))
        end)
    end)

    describe('matches', function()
        it('true when token matches content', function()
            local content = 'hello world'
            local token = snapshot.compute(content)
            assert.is_truthy(snapshot.matches(token, content))
        end)

        it('false when token does not match (content mutated)', function()
            local token = snapshot.compute('original')
            assert.is_falsy(snapshot.matches(token, 'mutated'))
        end)

        it('false when token is the wrong length', function()
            assert.is_falsy(snapshot.matches('abc', 'hello'))
            assert.is_falsy(snapshot.matches('abcdefgh', 'hello'))
        end)

        it('false when token is nil', function()
            assert.is_falsy(snapshot.matches(nil, 'content'))
        end)

        it('false when token is a non-string', function()
            assert.is_falsy(snapshot.matches(42, 'content'))
            assert.is_falsy(snapshot.matches({}, 'content'))
        end)
    end)

    describe('is_valid_format', function()
        it('accepts a well-formed token', function()
            assert.is_truthy(snapshot.is_valid_format('a3f9d2c'))
        end)

        it('accepts all-zero token', function()
            assert.is_truthy(snapshot.is_valid_format('0000000'))
        end)

        it('rejects uppercase hex', function()
            -- vim.fn.sha256 emits lowercase; any uppercase token did not
            -- come from compute() and we refuse it for clarity.
            assert.is_falsy(snapshot.is_valid_format('ABCDEF0'))
            assert.is_falsy(snapshot.is_valid_format('aB3dEf0'))
        end)

        it('rejects wrong length', function()
            assert.is_falsy(snapshot.is_valid_format('abc'))         -- too short
            assert.is_falsy(snapshot.is_valid_format('abcdef01'))    -- too long
            assert.is_falsy(snapshot.is_valid_format(''))            -- empty
        end)

        it('rejects non-hex characters', function()
            assert.is_falsy(snapshot.is_valid_format('abcdefg'))     -- "g" is not hex
            assert.is_falsy(snapshot.is_valid_format('zzzzzzz'))
            assert.is_falsy(snapshot.is_valid_format('!!!!!!!'))
        end)

        it('rejects non-string input', function()
            assert.is_falsy(snapshot.is_valid_format(nil))
            assert.is_falsy(snapshot.is_valid_format(42))
            assert.is_falsy(snapshot.is_valid_format({}))
        end)

        it('a freshly computed token always passes is_valid_format', function()
            for _, content in ipairs({ '', 'a', 'a\nb\nc\n', string.rep('x', 1000) }) do
                local t = snapshot.compute(content)
                assert.is_truthy(snapshot.is_valid_format(t))
            end
        end)
    end)
end)
