--- lazy.nvim integration utilities
--- Programmatic equivalents of `:Lazy check` and related lazy.nvim UI operations.
--- All functions return structured data; formatting is in a separate function.
--- @module "nvu.lazy"
local M = {}

--- @class nvu.lazy.CommitInfo
--- @field sha string Short commit SHA (7 characters)
--- @field subject string Commit subject line

--- @class nvu.lazy.PluginUpdate
--- @field name string Plugin name (lazy spec name)
--- @field dir string Absolute path to plugin install directory
--- @field from string Short current HEAD SHA (7 chars)
--- @field from_full string Full current HEAD SHA
--- @field to string Short target SHA (7 chars)
--- @field to_full string Full target SHA
--- @field branch string Target branch
--- @field count number Number of commits between from and to
--- @field log nvu.lazy.CommitInfo[] Per-commit log, newest first

--- @class nvu.lazy.PendingUpdates
--- @field updates nvu.lazy.PluginUpdate[] List of plugins with pending updates, sorted by commit count desc
--- @field fetch_age_seconds number? Seconds since the oldest plugin was last fetched (`nil` if no plugin has a `FETCH_HEAD`)
--- @field stale boolean `true` if `fetch_age_seconds` exceeds the freshness threshold (1 hour by default)

--- Freshness threshold (seconds) above which the comparison is considered stale.
--- After this many seconds since the most recent `git fetch`, `origin/<branch>`
--- refs may not reflect upstream and the comparison risks false negatives.
--- @type integer
local FRESHNESS_THRESHOLD_SECONDS = 60 * 60

--- Get the per-commit log between two refs in a plugin's git repo.
--- @param dir string Plugin install directory
--- @param from string Old SHA
--- @param to string New SHA
--- @return nvu.lazy.CommitInfo[]
local function get_commit_log(dir, from, to)
  local out = vim.fn.systemlist({
    'git', '-C', dir, 'log', '--oneline', '--no-merges', from .. '..' .. to,
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

--- Get the FETCH_HEAD age in seconds for a plugin, or `nil` if it has none.
--- @param dir string Plugin install directory
--- @return integer?
local function fetch_head_age(dir)
  local st = vim.uv.fs_stat(dir .. '/.git/FETCH_HEAD')
  if not st then return nil end
  return os.time() - st.mtime.sec
end

--- Run `git fetch` synchronously in a plugin's directory.
--- @param dir string Plugin install directory
--- @return boolean ok
local function git_fetch(dir)
  vim.fn.system({ 'git', '-C', dir, 'fetch', '--quiet' })
  return vim.v.shell_error == 0
end

--- @class nvu.lazy.PendingUpdatesOpts
--- @field fetch boolean? If `true`, runs `git fetch` on every installed plugin first. Slow (~0.5s per plugin, blocking); default `false` (trust whatever the latest `:Lazy check` already fetched).
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
  local Git = require'lazy.manage.git'
  local lazy = require'lazy'

  local plugins = lazy.plugins()

  if opts.fetch then
    for _, p in ipairs(plugins) do
      if p._.installed and not p._.is_local and p.dir then
        git_fetch(p.dir)
      end
    end
  end

  local updates = {}
  local max_age = nil
  for _, p in ipairs(plugins) do
    if p._.installed and not p._.is_local and p.dir then
      local ok_info, info = pcall(Git.info, p.dir)
      local ok_target, target = pcall(Git.get_target, p)
      if ok_info and ok_target and info and target and info.commit and target.commit and info.commit ~= target.commit then
        local count = select(2, pcall(Git.count, p.dir, info.commit, target.commit))
        table.insert(updates, {
          name = p.name,
          dir = p.dir,
          from = info.commit:sub(1, 7),
          from_full = info.commit,
          to = target.commit:sub(1, 7),
          to_full = target.commit,
          branch = target.branch,
          count = tonumber(count) or 0,
          log = get_commit_log(p.dir, info.commit, target.commit),
        })
      end
      local age = fetch_head_age(p.dir)
      if age and (max_age == nil or age > max_age) then
        max_age = age
      end
    end
  end

  table.sort(updates, function(a, b) return a.count > b.count end)

  return {
    updates = updates,
    fetch_age_seconds = max_age,
    stale = max_age ~= nil and max_age > threshold,
  }
end

--- Format pending-updates data as a human-readable Markdown overview.
---
--- Intended for piping to `print()` so an LLM agent reading the
--- `neovim__execute_lua` tool output can consume the per-plugin commit log
--- directly.
---
--- @param data nvu.lazy.PendingUpdates Output of `pending_updates()`
--- @return string Multi-line Markdown
function M.format_pending_updates(data)
  local lines = {}
  table.insert(lines, ('# Pending plugin updates (%d)'):format(#data.updates))
  table.insert(lines, '')

  if data.fetch_age_seconds then
    local hours = data.fetch_age_seconds / 3600
    table.insert(lines, ('Oldest plugin FETCH_HEAD: %.1f hours ago.'):format(hours))
    if data.stale then
      table.insert(lines, 'STALE — `origin/<branch>` refs may not reflect upstream. Ask the user to run `:Lazy check` first, then re-run this query.')
    end
  else
    table.insert(lines, 'No plugin has been fetched yet — ask the user to run `:Lazy check` first.')
  end
  table.insert(lines, '')

  if #data.updates == 0 then
    table.insert(lines, '_No updates available._')
    return table.concat(lines, '\n')
  end

  for _, u in ipairs(data.updates) do
    table.insert(lines, ('## %s — `%s` → `%s` (%d commits, branch=`%s`)'):format(
      u.name, u.from, u.to, u.count, u.branch))
    table.insert(lines, '')
    for _, c in ipairs(u.log) do
      table.insert(lines, ('- `%s` %s'):format(c.sha, c.subject))
    end
    table.insert(lines, '')
  end

  return table.concat(lines, '\n')
end

return M
