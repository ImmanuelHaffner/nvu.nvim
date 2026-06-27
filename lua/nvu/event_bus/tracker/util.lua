--- nvu.event_bus.tracker.util
---
--- Shared phrasing helpers for trackers. Pure: imports nothing from
--- CodeCompanion. Keeps fact wording consistent across trackers (cwd, git, ...)
--- and avoids copy-paste drift.

local M = {}

--- Replace a leading $HOME with `~`. Unlike `nvu.path.shorten_absolute`, this
--- does NOT truncate intermediate directories: a fact must be a path the LLM
--- can act on verbatim, so we keep it whole.
--- @param path string
--- @return string
function M.tildify(path)
    local home = os.getenv("HOME")
    if home and home ~= "" and path:sub(1, #home) == home then
        return "~" .. path:sub(#home + 1)
    end
    return path
end

--- Wrap arbitrary text as a Markdown inline-code span, sizing the fence so any
--- backticks inside are preserved literally. On Unix a filename may contain any
--- byte except NUL and `/`, so a backtick is a legal path byte; a fixed
--- single-backtick fence would break the span. The fence is one backtick longer
--- than the longest run inside, padded per the CommonMark rule when the content
--- begins or ends with a backtick.
--- @param text string
--- @return string
function M.code_span(text)
    local longest = 0
    for run in text:gmatch("`+") do
        if #run > longest then longest = #run end
    end
    local fence = string.rep("`", longest + 1)
    local pad = (text:find("^`") or text:find("`$")) and " " or ""
    return fence .. pad .. text .. pad .. fence
end

return M
