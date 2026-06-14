--- nvu.nvim test runner.
---
--- A small busted-compatible runner with no external dependencies. Exposes
--- `describe`, `it`, and `assert.*` globals so spec files read like every
--- other Lua test suite. Discovers `*_spec.lua` files in `tests/`.
---
--- Why not plenary.nvim or mini.test?
---   * plenary.nvim was archived in 2026.
---   * mini.test would add a hard dev-dependency for ~5 assertion helpers.
---   * The scope is small enough to maintain inline.
---
--- Usage (headless):
---   nvim --headless --noplugin -u NONE \
---     -c "set rtp+=$PWD" \
---     -c "luafile tests/runner.lua" \
---     -c "qall!"
---
--- Or for one file:
---   nvim --headless --noplugin -u NONE \
---     -c "set rtp+=$PWD" \
---     -c "lua require'tests.runner'.run_file('tests/edit/schema_spec.lua')" \
---     -c "qall!"
---
--- @module "tests.runner"

local M = {}

--------------------------------------------------------------------------------
-- ANSI colour codes
--------------------------------------------------------------------------------

local has_tty = vim.fn.has('gui_running') == 0 and os.getenv('NO_COLOR') == nil

local function colour(code, s)
    if not has_tty then return s end
    return '\27[' .. code .. 'm' .. s .. '\27[0m'
end

local function green(s) return colour('32', s) end
local function red(s)   return colour('31', s) end
local function dim(s)   return colour('2',  s) end

--------------------------------------------------------------------------------
-- Test-state tracking
--------------------------------------------------------------------------------

local state = {
    describe_stack = {},
    results = {},  -- { { name=..., ok=bool, err=... } }
}

--- Build the fully-qualified name of the currently-executing test.
local function current_name(it_name)
    local parts = {}
    for _, d in ipairs(state.describe_stack) do
        table.insert(parts, d)
    end
    table.insert(parts, it_name)
    return table.concat(parts, ' ')
end

--------------------------------------------------------------------------------
-- describe / it
--------------------------------------------------------------------------------

local function describe(name, body)
    table.insert(state.describe_stack, name)
    local ok, err = pcall(body)
    table.remove(state.describe_stack)
    if not ok then
        -- A failure in describe-level setup is fatal for that block.
        table.insert(state.results, {
            name = current_name(name) .. ' [describe block]',
            ok = false,
            err = err,
        })
    end
end

local function it(name, body)
    local full = current_name(name)
    local ok, err = pcall(body)
    table.insert(state.results, { name = full, ok = ok, err = err })
end

--------------------------------------------------------------------------------
-- assert.* helpers (busted-compatible subset)
--------------------------------------------------------------------------------

--- Format a value for inclusion in an assertion error message.
local function fmt(v)
    local t = type(v)
    if t == 'string' then return string.format('%q', v) end
    if t == 'table'  then
        local ok, s = pcall(vim.inspect, v)
        return ok and s or tostring(v)
    end
    return tostring(v)
end

local function fail(msg, ctx)
    error(msg .. (ctx and ('\n  ' .. ctx) or ''), 3)
end

--- Lua's builtin `assert`, captured before we shadow `_G.assert` with our
--- busted-style table. Spec files (and the modules under test) commonly use
--- `assert(cond, msg)` for argument validation, so the global must remain
--- *callable* like the stdlib version while also exposing `.is_*` / `.are.*`
--- helpers as fields. We achieve that by giving the table a `__call`
--- metamethod that delegates to the real stdlib `assert`.
local lua_assert = assert

local nvu_assert = setmetatable({}, {
    __call = function(_, v, msg, ...)
        return lua_assert(v, msg, ...)
    end,
})

function nvu_assert.is_true(v, ctx)
    if v ~= true then
        fail('expected true, got ' .. fmt(v), ctx)
    end
end

function nvu_assert.is_false(v, ctx)
    if v ~= false then
        fail('expected false, got ' .. fmt(v), ctx)
    end
end

function nvu_assert.is_nil(v, ctx)
    if v ~= nil then
        fail('expected nil, got ' .. fmt(v), ctx)
    end
end

function nvu_assert.is_not_nil(v, ctx)
    if v == nil then
        fail('expected non-nil value', ctx)
    end
end

function nvu_assert.is_string(v, ctx)
    if type(v) ~= 'string' then
        fail('expected a string, got ' .. type(v) .. ' (' .. fmt(v) .. ')', ctx)
    end
end

--- Truthy in the Lua sense: anything that is not `nil` or `false`.
function nvu_assert.is_truthy(v, ctx)
    if v == nil or v == false then
        fail('expected a truthy value, got ' .. fmt(v), ctx)
    end
end

function nvu_assert.is_falsy(v, ctx)
    if v ~= nil and v ~= false then
        fail('expected a falsy value, got ' .. fmt(v), ctx)
    end
end

--- Deep-equality helper for `assert.is.equal` and `assert.are.same`.
local function deep_equal(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then return false end
    end
    for k, _ in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

--- The `assert.is.equal` namespace: shallow equality (matches busted).
nvu_assert.is = {}
function nvu_assert.is.equal(expected, actual, ctx)
    if expected ~= actual then
        fail(string.format('expected %s, got %s', fmt(expected), fmt(actual)), ctx)
    end
end
function nvu_assert.is.same(expected, actual, ctx)
    if not deep_equal(expected, actual) then
        fail(string.format('expected %s, got %s', fmt(expected), fmt(actual)), ctx)
    end
end

--- `assert.are.same`: deep equality (matches busted).
nvu_assert.are = {}
function nvu_assert.are.same(expected, actual, ctx)
    if not deep_equal(expected, actual) then
        fail(string.format('expected %s, got %s', fmt(expected), fmt(actual)), ctx)
    end
end
function nvu_assert.are.equal(expected, actual, ctx)
    if expected ~= actual then
        fail(string.format('expected %s, got %s', fmt(expected), fmt(actual)), ctx)
    end
end

--------------------------------------------------------------------------------
-- File discovery and execution
--------------------------------------------------------------------------------

--- Install busted globals into the global namespace for the duration of a run.
local function install_globals()
    _G.describe = describe
    _G.it = it
    _G.assert = nvu_assert
end

local function uninstall_globals()
    _G.describe = nil
    _G.it = nil
    -- We do NOT restore Lua's stdlib `assert`; spec files don't expect it
    -- after our harness has run. The headless process exits anyway.
end

--- Reset state between top-level invocations.
local function reset_state()
    state.describe_stack = {}
    state.results = {}
end

--- Run one spec file by path.
--- @param path string
function M.run_file(path)
    reset_state()
    install_globals()
    local ok, err = pcall(dofile, path)
    uninstall_globals()
    if not ok then
        io.stderr:write(red('FATAL: failed to load ' .. path .. ': ' .. tostring(err)) .. '\n')
        vim.cmd('cq 2')
        return
    end
    M.report(path)
end

--- Discover and run every `*_spec.lua` file under a directory (recursively).
--- @param dir string Directory to scan (relative to cwd or absolute).
function M.run_dir(dir)
    reset_state()
    install_globals()
    local files = vim.fn.glob(dir .. '/**/*_spec.lua', false, true)
    if #files == 0 then
        io.stderr:write(red('no *_spec.lua files found under ' .. dir) .. '\n')
        vim.cmd('cq 2')
    end
    table.sort(files)
    for _, f in ipairs(files) do
        local ok, err = pcall(dofile, f)
        if not ok then
            io.stderr:write(red('FATAL: failed to load ' .. f .. ': ' .. tostring(err)) .. '\n')
            vim.cmd('cq 2')
            return
        end
    end
    uninstall_globals()
    M.report(dir)
end

--------------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------------

function M.report(scope)
    local passed = 0
    local failed = 0
    for _, r in ipairs(state.results) do
        if r.ok then
            passed = passed + 1
            print(green('  ok  ') .. r.name)
        else
            failed = failed + 1
            print(red('  FAIL') .. ' ' .. r.name)
            for line in tostring(r.err):gmatch('[^\n]+') do
                print(dim('      ' .. line))
            end
        end
    end
    print('')
    print(string.format('%s — %d passed, %d failed (%d total)',
        scope,
        passed,
        failed,
        passed + failed))
    if failed > 0 then
        -- Use Neovim's `cq` to exit with code 1: `os.exit()` from inside Lua
        -- under `--headless` is ignored by the host loop.
        vim.cmd('cq 1')
    end
end

--------------------------------------------------------------------------------
-- Auto-run mode: when invoked via `:luafile tests/runner.lua`, scan tests/.
--------------------------------------------------------------------------------

-- Detect whether we're being `dofile`'d (auto-run) or `require`'d (programmatic).
-- vim.fn.expand('<sfile>') in the running script context only resolves when
-- the file is being sourced directly, so this is a reasonable proxy.
local sfile = debug.getinfo(1, 'S').source
if sfile:sub(1, 1) == '@' then
    local this_path = sfile:sub(2)
    -- If this file's parent dir is `tests/`, auto-run sibling specs.
    local parent = vim.fn.fnamemodify(this_path, ':h')
    if vim.fn.fnamemodify(parent, ':t') == 'tests'
       -- and we're being top-level loaded (no require'tests.runner' on the stack)
       and not package.loaded['tests.runner']
    then
        M.run_dir(parent)
    end
end

return M
