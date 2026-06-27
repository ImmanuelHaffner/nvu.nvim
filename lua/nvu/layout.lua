--- Layout math utilities for adaptively sizing windows, pickers, and floats.
--- Pure numeric helpers — no Neovim window APIs are called, so these are
--- trivially testable and reusable across plugins (Telescope, outline,
--- diffview, …).
--- @module "nvu.layout"

local M = {}

--- Clamp a number to an inclusive range.
--- If `lo > hi` (e.g. an aggressive `min` on a tiny screen), `lo` wins, so the
--- result never drops below the requested minimum.
--- @param n number   Value to clamp
--- @param lo number  Lower bound (inclusive)
--- @param hi number  Upper bound (inclusive)
--- @return number
local function clamp(n, lo, hi)
    return math.max(lo, math.min(hi, n))
end

--- @class nvu.layout.AdaptiveExtentOpts
--- @field frac number    Target fraction of the extent, in (0, 1]. e.g. 0.6 -> 60%.
--- @field extent number  The dimension to size against (columns or rows), in cells.
---                       Required: the target is `frac * extent`.
--- @field min? number    Absolute lower bound, in cells. Default: 1.
--- @field max? number    Absolute upper bound, in cells. Default: no ceiling.
--- @field margin? number Cells to keep free at the far edge; tightens the ceiling to
---                       `extent - margin`. Default: 0. Combined with `max`, the
---                       tighter (smaller) of the two wins.

--- Compute an adaptive extent: a target fraction of an editor dimension,
--- clamped to `[min, min(max, extent - margin)]` and rounded to a whole cell.
---
--- This is the single mechanism behind the `clamp(round(frac * extent), min, max)`
--- idiom duplicated across the config (outline width, CodeCompanion picker,
--- diffview panel, …). It bakes in **no policy**: every bound is a parameter.
---
--- Adaptivity: because `extent` is sampled by the caller, wrap this in a closure
--- / Telescope layout function to re-resolve on every open — no `VimResized`
--- autocmd or cached state required.
---
--- @param opts nvu.layout.AdaptiveExtentOpts
--- @return number cells The clamped, rounded extent (always >= 1)
function M.adaptive_extent(opts)
    vim.validate{
        opts = { opts, 'table' },
    }
    vim.validate{
        frac = { opts.frac, 'number' },
        extent = { opts.extent, 'number' },
        min = { opts.min, 'number', true },
        max = { opts.max, 'number', true },
        margin = { opts.margin, 'number', true },
    }
    assert(opts.frac > 0 and opts.frac <= 1, 'nvu.layout.adaptive_extent: frac must be in (0, 1]')
    -- `margin` is meaningful only relative to a known extent; reject the
    -- nonsensical combination rather than silently ignoring it.
    assert(opts.margin == nil or opts.extent ~= nil,
        'nvu.layout.adaptive_extent: margin requires extent')

    local extent = opts.extent
    local min = opts.min or 1
    local margin = opts.margin or 0

    -- Effective ceiling: start from the screen extent minus margin, then fold in
    -- an explicit max if given. The smaller (tighter) bound wins.
    local ceiling = extent - margin
    if opts.max then
        ceiling = math.min(ceiling, opts.max)
    end

    local target = math.floor(opts.frac * extent + 0.5)  -- round half up
    return clamp(target, min, ceiling)
end

return M
