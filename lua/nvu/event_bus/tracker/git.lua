--- nvu.event_bus.tracker.git
---
--- Tracks git HEAD (branch / detached-SHA) changes per repository root and emits
--- a fact onto the event bus. The signal that the LLM most often reasons against
--- when stale is *which branch the worktree is on* after a checkout, branch
--- switch, rebase, or pull; hunk counts (added/changed/removed) churn constantly
--- and are deliberately ignored as noise.
---
--- Source signal: the `User GitSignsUpdate` autocmd. This is a plain event
--- pattern (a string); if gitsigns is not installed, nothing ever fires it and
--- this tracker is silently inert. There is therefore NO static dependency on
--- gitsigns: this module imports nothing from it. The only gitsigns touchpoint
--- is reading the buffer-local `b:gitsigns_status_dict` inside the callback,
--- which is fully guarded (absent / malformed dict -> no-op).
---
--- gitsigns fires `GitSignsUpdate` per buffer and very frequently (on every
--- status recompute), so this tracker holds a small per-root cache of the last
--- seen HEAD and emits ONLY when it changes for that root. The router stays
--- ignorant of this de-duplication — noise policy is the tracker's job.
---
--- Pure module: imports nothing from CodeCompanion. Depends only on
--- `nvu.event_bus.router`, its sibling `util`, and core Neovim APIs.

local router = require("nvu.event_bus.router")
local util = require("nvu.event_bus.tracker.util")

local M = {}

--- Last HEAD seen per repository root, so we only emit on an actual change.
--- @type table<string, string>
local last_head = {}

--- A HEAD value that is a 7+ hex-digit string (and not a ref name) is almost
--- certainly a detached checkout reported as an abbreviated SHA. gitsigns may
--- also report things like "(HEAD detached)" depending on version; treat any
--- non-branch-looking value as detached for phrasing purposes.
--- @param head string
--- @return boolean
local function looks_detached(head)
    return head:match("^%x%x%x%x%x%x%x+$") ~= nil
end

--- Build the human/LLM-ready fact for a HEAD change.
--- @param head string The new HEAD (branch name or abbreviated SHA).
--- @param root string The repository root (working tree).
--- @return string
local function format_fact(head, root)
    local h = util.code_span(head)
    local r = util.code_span(util.tildify(root))
    if looks_detached(head) then
        return string.format("Git HEAD changed to %s (detached) in repo %s", h, r)
    end
    return string.format("Git HEAD changed to %s in repo %s", h, r)
end

--- Install the `User GitSignsUpdate` autocmd into the given augroup.
--- @param augroup integer The augroup id to attach the autocmd to.
function M.attach(augroup)
    vim.api.nvim_create_autocmd("User", {
        group = augroup,
        pattern = "GitSignsUpdate",
        desc = "nvu.event_bus: report git HEAD changes to registered sinks",
        callback = function(args)
            -- data.buffer is the buffer whose git status changed.
            local data = args.data
            local bufnr = type(data) == "table" and data.buffer or nil
            if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_loaded(bufnr) then
                return
            end

            -- Guarded read of gitsigns' buffer-local status dict. No import.
            local ok, dict = pcall(function() return vim.b[bufnr].gitsigns_status_dict end)
            if not ok or type(dict) ~= "table" then return end

            local head = dict.head
            local root = dict.root
            -- A repo with no commits yet, or a buffer outside any repo, may carry
            -- an empty head / nil root: nothing actionable to report.
            if type(head) ~= "string" or head == "" or type(root) ~= "string" or root == "" then
                return
            end

            -- Emit only when HEAD actually moved for this root.
            if last_head[root] == head then return end
            last_head[root] = head

            router.emit({ kind = "git", text = format_fact(head, root) })
        end,
    })
end

return M
