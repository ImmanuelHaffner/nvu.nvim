--- lazy.nvim integration utilities
--- Programmatic equivalents of `:Lazy check` and related lazy.nvim UI operations.
--- All functions return structured data; formatting is in a separate function.
--- @module "nvu.lazy"
local M = {}

--- @class nvu.lazy.CommitInfo
--- @field sha string Short commit SHA (7 characters)
--- @field subject string Commit subject line

--- @alias nvu.lazy.Direction "forward" | "backward" | "diverged"

--- @class nvu.lazy.PluginUpdate
--- @field name string Plugin name (lazy spec name)
--- @field dir string Absolute path to plugin install directory
--- @field from string Short current HEAD SHA (7 characters)
--- @field from_full string Full current HEAD SHA
--- @field to string Short target SHA (7 characters)
--- @field to_full string Full target SHA
--- @field branch string Target branch
--- @field count number Number of commits in the relevant direction (forward: `to` is `count` commits ahead of `from`; backward: `from` is `count` commits ahead of `to`; diverged: total commits unique to either side)
--- @field direction nvu.lazy.Direction Relationship between `from` and `to` — see notes below
--- @field log nvu.lazy.CommitInfo[] Per-commit log along the relevant direction (forward: `from..to` newest first; backward: `to..from`; diverged: union of both, prefixed appropriately)

--- @class nvu.lazy.PendingUpdates
--- @field updates nvu.lazy.PluginUpdate[] List of plugins with pending updates, sorted by commit count desc
--- @field fetch_age_seconds number? Seconds since the oldest plugin was last fetched (`nil` if no plugin has a `FETCH_HEAD`)
--- @field stale boolean `true` if `fetch_age_seconds` exceeds the freshness threshold (1 hour by default)
--- @field fetch_errors table<string, string> Map of plugin name to error message (`stderr` or `"timeout"`), populated only when `fetch = true` was passed. Empty table if all fetches succeeded.

--- Freshness threshold (seconds) above which the comparison is considered stale.
--- After this many seconds since the most recent `git fetch`, `origin/<branch>`
--- refs may not reflect upstream and the comparison risks false negatives.
--- @type integer
local FRESHNESS_THRESHOLD_SECONDS = 60 * 60

--- Parse `git log --oneline --no-merges <range>` output into structured entries.
--- @param dir string Plugin install directory
--- @param range string Git range expression (e.g. `'from..to'`)
--- @return nvu.lazy.CommitInfo[]
local function git_log(dir, range)
  local out = vim.fn.systemlist({
    'git', '-C', dir, 'log', '--oneline', '--no-merges', range,
  })
  if vim.v.shell_error ~= 0 then return {} end
  local log = {}
  for _, line in ipairs(out) do
    local sha, subject = line:match('^(%S+)%s+(.+)$')
    if sha and subject then
      table.insert(log, { sha = sha, subject = subject })
    end
  end
  return log
end

--- Determine the relationship between two refs in a plugin's git repo using
--- `git merge-base --is-ancestor`. One git call per probe (cheap).
---
--- @param dir string Plugin install directory
--- @param from string Current HEAD SHA
--- @param to string Target SHA
--- @return nvu.lazy.Direction
local function get_direction(dir, from, to)
  -- Is `from` an ancestor of `to`? If so, `to` is strictly ahead of `from`.
  vim.fn.system({ 'git', '-C', dir, 'merge-base', '--is-ancestor', from, to })
  local from_ancestor_of_to = vim.v.shell_error == 0

  -- Is `to` an ancestor of `from`? If so, `from` is strictly ahead of `to`.
  vim.fn.system({ 'git', '-C', dir, 'merge-base', '--is-ancestor', to, from })
  local to_ancestor_of_from = vim.v.shell_error == 0

  if from_ancestor_of_to then
    return 'forward'   -- upstream/target has new commits we don't have
  elseif to_ancestor_of_from then
    return 'backward'  -- local HEAD has commits the target doesn't (e.g. unpushed work)
  else
    return 'diverged'  -- neither is ancestor of the other (rebase, force-push, parallel work)
  end
end

--- Get the FETCH_HEAD age in seconds for a plugin, or `nil` if it has none.
--- @param dir string Plugin install directory
--- @return integer?
local function fetch_head_age(dir)
  local st = vim.uv.fs_stat(dir .. '/.git/FETCH_HEAD')
  if not st then return nil end
  return os.time() - st.mtime.sec
end

--- Default per-fetch timeout (milliseconds). A hung remote (DNS timeout,
--- unreachable host) would otherwise stall the whole call.
--- @type integer
local FETCH_TIMEOUT_MS = 30 * 1000

--- Default maximum number of concurrent `git fetch` processes. 8 is the
--- industry-conventional sweet spot for parallel git fetch (used by
--- `git fetch --jobs`, `mr`, etc.): roughly 10x speedup over serial, polite
--- to remotes (avoids rate-limiting and overwhelming small hosts).
--- @type integer
local FETCH_JOBS = 8

--- Run `git fetch` concurrently across a list of plugin directories using a
--- batch sliding-window scheduler. At any moment, at most `jobs` processes
--- are running; whenever one finishes another is spawned until the queue is
--- drained.
---
--- # Concurrency invariants
---
--- Neovim runs Lua on a single OS thread with a cooperative event loop. The
--- shared mutable state (`cursor`, `running`, `errors`) is therefore safe to
--- mutate without locks, provided two conditions hold:
---
--- 1. **No yield points inside `spawn_next`.** A Lua function runs to
---    completion without preemption between bytecode instructions; the only
---    way another Lua callback can interleave is at an explicit yield
---    (`coroutine.yield`, `vim.wait`, or any libuv-blocking call). `spawn_next`
---    contains no yields — it goes straight from incrementing `cursor` and
---    `running` to spawning the child process and returning.
---
--- 2. **`vim.system` returns asynchronously without invoking its callback.**
---    The callback is queued onto the main event loop via `vim.schedule_wrap`
---    and only fires between Lua ticks. Two callbacks therefore execute
---    serially, never overlapping — so the `running = running - 1` +
---    `spawn_next()` sequence in the callback is safe even when all `jobs`
---    children finish "simultaneously".
---
--- If either invariant is ever broken (e.g. introducing a `vim.wait` inside
--- `spawn_next`, or switching to a synchronous-callback API), the bookkeeping
--- will need a guard.
---
--- @param plugins LazyPlugin[] Installed, non-local plugins to fetch
--- @param jobs integer Maximum concurrent fetch processes
--- @param timeout_ms integer Per-fetch timeout in milliseconds
--- @return table<string, string> errors Map of plugin name to failure reason (empty if all succeeded)
local function git_fetch_concurrent(plugins, jobs, timeout_ms)
  local errors = {}
  local cursor = 1   -- index of the next plugin to spawn
  local running = 0  -- number of in-flight processes

  --- Spawn the next pending fetch (if any). Increments `cursor` and `running`.
  --- Safe to call concurrently from any number of completion callbacks —
  --- see "Concurrency invariants" on the enclosing function.
  local function spawn_next()
    if cursor > #plugins then return end
    local plugin = plugins[cursor]
    cursor = cursor + 1
    running = running + 1
    vim.system(
      { 'git', '-C', plugin.dir, 'fetch', '--quiet' },
      { text = true, timeout = timeout_ms },
      vim.schedule_wrap(function(result)
        if result.code ~= 0 then
          if result.signal == 15 then  -- SIGTERM, used by vim.system on timeout
            errors[plugin.name] = 'timeout after ' .. timeout_ms .. 'ms'
          else
            local stderr = (result.stderr or ''):gsub('%s+$', '')
            errors[plugin.name] = stderr ~= '' and stderr or ('exit code ' .. result.code)
          end
        end
        running = running - 1
        spawn_next()
      end)
    )
  end

  -- Prime the pump: spawn up to `jobs` initial processes
  for _ = 1, math.min(jobs, #plugins) do spawn_next() end

  -- Block the caller's thread until every process has finished. `vim.wait`
  -- runs the event loop so the schedule_wrap callbacks above can fire.
  -- Overall budget = number_of_batches * per-fetch timeout, with slack.
  local total_budget = math.ceil(#plugins / math.max(1, jobs)) * timeout_ms + 5000
  vim.wait(total_budget, function() return running == 0 end, 50)

  return errors
end

--- @class nvu.lazy.PendingUpdatesOpts
--- @field fetch boolean? If `true`, runs `git fetch` on every installed plugin first. Concurrent (bounded by `jobs`, default 8) — typically ~3-6s blocking for a ~80-plugin config. Default `false` (trust whatever the latest `:Lazy check` already fetched).
--- @field jobs integer? Maximum concurrent `git fetch` processes when `fetch = true` (default 8). Pass `math.huge` for unbounded; set higher only if your network is robust and you trust the remotes not to rate-limit.
--- @field fetch_timeout_ms integer? Per-fetch timeout in milliseconds (default 30000). Plugins that exceed this are recorded in `fetch_errors`.
--- @field freshness_threshold_seconds integer? Override the default freshness threshold (default: 3600).

--- Detect plugins with pending updates by comparing each installed plugin's
--- current HEAD against its target ref (lockfile pin or spec branch).
---
--- **Trust mode (default, `fetch = false`)**: relies on `origin/<branch>` refs
--- being current. Fast (milliseconds). Returns stale results if no recent
--- `git fetch` has been done. The returned `fetch_age_seconds` and `stale`
--- fields let the caller detect this.
---
--- **Fetch mode (`fetch = true`)**: runs `git fetch --quiet` on every
--- installed plugin first. Slow (typically ~30-60s for a config with ~80
--- plugins, blocking the editor). Reliable. Use only when the user can't
--- run `:Lazy check` themselves.
---
--- @param opts nvu.lazy.PendingUpdatesOpts?
--- @return nvu.lazy.PendingUpdates
function M.pending_updates(opts)
  opts = opts or {}
  local threshold = opts.freshness_threshold_seconds or FRESHNESS_THRESHOLD_SECONDS
  local jobs = opts.jobs or FETCH_JOBS
  local fetch_timeout_ms = opts.fetch_timeout_ms or FETCH_TIMEOUT_MS
  local Git = require'lazy.manage.git'
  local lazy = require'lazy'

  local plugins = lazy.plugins()

  -- Pre-filter to the set of installed, non-local plugins with a real dir.
  -- This is the working set for both fetch mode and the comparison below.
  local fetchable = {}
  for _, p in ipairs(plugins) do
    if p._.installed and not p._.is_local and p.dir then
      table.insert(fetchable, p)
    end
  end

  local fetch_errors = {}
  if opts.fetch then
    fetch_errors = git_fetch_concurrent(fetchable, jobs, fetch_timeout_ms)
  end

  -- Sort key for ordering updates: forward first (most actionable), then
  -- backward (typically unpushed local work), then diverged (needs human).
  -- Within each direction, descending by commit count.
  local DIRECTION_ORDER = { forward = 1, backward = 2, diverged = 3 }

  local updates = {}
  local max_age = nil
  for _, p in ipairs(fetchable) do
    local ok_info, info = pcall(Git.info, p.dir)
    local ok_target, target = pcall(Git.get_target, p)
    if ok_info and ok_target and info and target and info.commit and target.commit and info.commit ~= target.commit then
      local direction = get_direction(p.dir, info.commit, target.commit)
      local range, count, log
      if direction == 'forward' then
        range = info.commit .. '..' .. target.commit
        count = select(2, pcall(Git.count, p.dir, info.commit, target.commit))
        log = git_log(p.dir, range)
      elseif direction == 'backward' then
        range = target.commit .. '..' .. info.commit
        count = select(2, pcall(Git.count, p.dir, target.commit, info.commit))
        log = git_log(p.dir, range)
      else  -- diverged
        -- Both sides have unique commits. Show them as a union with a `from\to`
        -- triple-dot range, which yields the symmetric difference.
        range = info.commit .. '...' .. target.commit
        log = git_log(p.dir, range)
        count = #log
      end
      table.insert(updates, {
        name = p.name,
        dir = p.dir,
        from = info.commit:sub(1, 7),
        from_full = info.commit,
        to = target.commit:sub(1, 7),
        to_full = target.commit,
        branch = target.branch,
        count = tonumber(count) or 0,
        direction = direction,
        log = log,
      })
    end
    local age = fetch_head_age(p.dir)
    if age and (max_age == nil or age > max_age) then
      max_age = age
    end
  end

  table.sort(updates, function(a, b)
    local da, db = DIRECTION_ORDER[a.direction], DIRECTION_ORDER[b.direction]
    if da ~= db then return da < db end
    return a.count > b.count
  end)

  return {
    updates = updates,
    fetch_age_seconds = max_age,
    stale = max_age ~= nil and max_age > threshold,
    fetch_errors = fetch_errors,
  }
end

--- Format pending-updates data as a human-readable Markdown overview.
---
--- Intended for piping to `print()` so an LLM agent reading the
--- `neovim__execute_lua` tool output can consume the per-plugin commit log
--- directly.
---
--- Output is grouped by direction:
--- - `forward` — upstream has commits we don't have (the routine "update available" case).
--- - `backward` — local HEAD has commits upstream doesn't (typically unpushed local work, or a `:Lazy restore` to an old pin).
--- - `diverged` — neither side is an ancestor of the other (rebase/force-push upstream, or parallel work). Needs human resolution.
---
--- @param data nvu.lazy.PendingUpdates Output of `pending_updates()`
--- @return string Multi-line Markdown
function M.format_pending_updates(data)
  local lines = {}

  -- Bucket updates by direction (preserving the sorted order from the data).
  local by_direction = { forward = {}, backward = {}, diverged = {} }
  for _, u in ipairs(data.updates) do
    table.insert(by_direction[u.direction], u)
  end

  local header_counts = ('forward=%d, backward=%d, diverged=%d'):format(
    #by_direction.forward, #by_direction.backward, #by_direction.diverged)
  table.insert(lines, ('# Pending plugin changes (%d total: %s)'):format(#data.updates, header_counts))
  table.insert(lines, '')

  if data.fetch_age_seconds then
    local hours = data.fetch_age_seconds / 3600
    table.insert(lines, ('Oldest plugin FETCH_HEAD: %.1f hours ago.'):format(hours))
    if data.stale then
      table.insert(lines, 'STALE — `origin/<branch>` refs may not reflect upstream. Ask the user to run `:Lazy check` first (or call `pending_updates({ fetch = true })`), then re-run this query.')
    end
  else
    table.insert(lines, 'No plugin has been fetched yet — ask the user to run `:Lazy check` first.')
  end
  if data.fetch_errors and vim.tbl_count(data.fetch_errors) > 0 then
    table.insert(lines, '')
    table.insert(lines, ('**Fetch errors (%d):**'):format(vim.tbl_count(data.fetch_errors)))
    for name, err in pairs(data.fetch_errors) do
      table.insert(lines, ('- `%s`: %s'):format(name, err))
    end
  end
  table.insert(lines, '')

  if #data.updates == 0 then
    table.insert(lines, '_No pending changes._')
    return table.concat(lines, '\n')
  end

  local SECTION_TITLES = {
    forward  = 'Upstream ahead (available updates)',
    backward = 'Local ahead of upstream (unpushed/restored)',
    diverged = 'Diverged (needs human resolution)',
  }
  local SECTION_BLURBS = {
    forward  = 'These plugins have new upstream commits. Routine "update available" case — `:Lazy update <plugin>` will fast-forward.',
    backward = 'These plugins have local commits that upstream doesn\'t have. Common cause: locally-committed work that hasn\'t been pushed to your fork, or a `:Lazy restore` to an older pin while the tracking branch hasn\'t caught up. `:Lazy update` here would **rewind** local HEAD — likely not what you want.',
    diverged = 'Local and target both have commits the other doesn\'t. Common causes: upstream force-pushed (rebase), or you have local commits AND upstream advanced since the common base. Requires human inspection before any `:Lazy update`.',
  }

  for _, dir in ipairs({ 'forward', 'backward', 'diverged' }) do
    local bucket = by_direction[dir]
    if #bucket > 0 then
      table.insert(lines, ('## %s (%d)'):format(SECTION_TITLES[dir], #bucket))
      table.insert(lines, '')
      table.insert(lines, SECTION_BLURBS[dir])
      table.insert(lines, '')

      for _, u in ipairs(bucket) do
        local arrow
        if dir == 'forward'  then arrow = '→'
        elseif dir == 'backward' then arrow = '←'
        else arrow = '⇄'
        end
        table.insert(lines, ('### %s — `%s` %s `%s` (%d commits, branch=`%s`)'):format(
          u.name, u.from, arrow, u.to, u.count, u.branch))
        table.insert(lines, '')
        for _, c in ipairs(u.log) do
          table.insert(lines, ('- `%s` %s'):format(c.sha, c.subject))
        end
        table.insert(lines, '')
      end
    end
  end

  return table.concat(lines, '\n')
end

return M
