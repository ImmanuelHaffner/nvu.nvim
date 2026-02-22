--- Telescope previewer utilities
--- @module nvu.telescope.previewers
local M = {}

local core = require'nvu.core'
local utils = require'nvu.telescope.utils'
local path_utils = require'nvu.path'

--- Highlights and jumps to a specific line in the previewer buffer.
--- Supports line ranges and column ranges for precise highlighting.
--- @param self table The previewer instance
--- @param bufnr number The buffer number
--- @param entry table The telescope entry with lnum, lnend, col, colend fields
local function jump_to_line(self, bufnr, entry)
    local telescope_utils = require'telescope.utils'
    local ns_previewer = vim.api.nvim_create_namespace('telescope.previewers')
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_previewer, 0, -1)

    if entry.lnum and entry.lnum > 0 then
        local lnum, lnend = entry.lnum - 1, (entry.lnend or entry.lnum) - 1

        local col, colend = 0, -1
        -- Both col delimiters should be provided for them to take effect.
        if entry.col and entry.colend then
            col, colend = entry.col - 1, entry.colend - 1
        end

        for i = lnum, lnend do
            pcall(
                telescope_utils.hl_range,
                bufnr,
                ns_previewer,
                'TelescopePreviewLine',
                { i, i == lnum and col or 0 },
                { i, i == lnend and colend or -1 }
            )
        end

        local middle_ln = math.floor(lnum + (lnend - lnum) / 2)
        pcall(vim.api.nvim_win_set_cursor, self.state.winid, { middle_ln + 1, 0 })
        if bufnr ~= nil then
            vim.api.nvim_buf_call(bufnr, function()
                vim.cmd'norm! zz'
            end)
        end
    end
end

--- Creates a buffer previewer that handles unnamed buffers and terminals.
--- @param opts? table Options: { title = string, max_title_len = number }
--- @return table A telescope buffer_previewer instance
function M.buffer(opts)
    opts = opts or {}
    local max_title_len = core.resolve(opts.max_title_len) or 100
    local previewers = require'telescope.previewers'
    local conf = require'telescope.config'.values

    local define_preview = function(self, entry)
        -- Check for terminal or special buftype
        local has_buftype = entry.bufnr
            and vim.api.nvim_buf_is_valid(entry.bufnr)
            and vim.bo[entry.bufnr].buftype ~= ''
            or false
        local p = utils.get_path_from_entry(entry)

        -- Workaround for unnamed buffer or terminal buffers
        if entry.bufnr and (p == '[No Name]' or has_buftype) then
            local lines = vim.api.nvim_buf_get_lines(entry.bufnr, 0, -1, false)
            vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
            -- Schedule so lines are present before jumping
            vim.schedule(function()
                jump_to_line(self, self.state.bufnr, entry)
            end)
        else
            conf.buffer_previewer_maker(p, self.state.bufnr, {
                bufname = self.state.bufname,
                winid = self.state.winid,
                callback = function(bufnr)
                    jump_to_line(self, bufnr, entry)
                end,
            })
        end
    end

    return previewers.new_buffer_previewer{
        define_preview = define_preview,
        get_buffer_by_name = function(_, entry)
            return utils.get_path_from_entry(entry)
        end,
        title = opts.title or 'Preview',
        dyn_title = function(_, entry)
            return path_utils.shorten_relative(entry.path, max_title_len)
        end,
    }
end

--- Creates a git commit previewer using delta for syntax highlighting.
--- @param opts? table Options: { include_file = boolean } - whether to scope to current file
--- @return table A telescope termopen_previewer instance
function M.git_commit(opts)
    opts = opts or {}
    local previewers = require'telescope.previewers'

    return previewers.new_termopen_previewer{
        dyn_title = function(_, entry)
            return 'Git commit: ' .. entry.value
        end,
        get_command = function(entry, _)
            local cmd = {
                'env', 'LESS=', 'GIT_PAGER=delta --paging=always --pager=less',
                'git', '--paginate', 'show', '--color=never', entry.value
            }
            if opts.include_file and entry.current_file then
                table.insert(cmd, '--')
                table.insert(cmd, entry.current_file)
            end
            return cmd
        end,
    }
end

return M
