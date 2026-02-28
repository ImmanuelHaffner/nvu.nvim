--- Adaptive Pickers - Telescope extension with dynamic path shortening and enhanced previewers
--- @module "telescope._extensions.adaptive_pickers"

local has_telescope, telescope = pcall(require, 'telescope')
if not has_telescope then
    error('adaptive_pickers requires telescope.nvim')
end

local nvu_telescope = require'nvu.telescope'

--- Default configuration
--- Note: max_path_len and max_title_len default to functions that use Telescope's layout logic
local config = {
    -- Path shortening (can be a number or a function returning a number)
    -- Default: dynamically calculated from Telescope's results pane width minus icon/padding
    max_path_len = function()
        return nvu_telescope.utils.get_results_width() - 5  -- subtract icon + padding
    end,
    -- Title shortening for preview window
    -- Default: dynamically calculated from Telescope's preview pane width minus padding
    max_title_len = function()
        return nvu_telescope.utils.get_preview_width() - 4
    end,

    -- Git commit display
    git = {
        hash_width = 10,
        author_width = 20,
        date_width = 10,
    },

    -- Which pickers to enhance (set to false to disable)
    pickers = {
        find_files = true,
        git_files = true,
        buffers = true,
        git_commits = true,
        git_bcommits = true,
        git_bcommits_range = true,
    },

    -- Prompt prefixes for each picker
    prompt_prefixes = {
        find_files = '󰱼 ',  -- alternatives: 󰱽 󰮗 󰈞 󰱼 🔍
        git_files = '  ',
        git_branches = ' ',
        git_commits = ' ',  -- alternatives:    
        git_bcommits = '  ',
        git_bcommits_range = '  ',
        buffers = ' ',
        live_grep = ' ',
    },
}

--- Merges user config with defaults
--- @param user_config table User-provided configuration
local function merge_config(user_config)
    config = vim.tbl_deep_extend('force', config, user_config or {})
end

--- Builds picker options for file-based pickers
--- @param picker_name string Name of the picker
--- @param title string Preview title
--- @return table Picker options
local function file_picker_opts(picker_name, title)
    return {
        prompt_prefix = config.prompt_prefixes[picker_name],
        entry_maker = nvu_telescope.entry_makers.file{ max_len = config.max_path_len },
        previewer = nvu_telescope.previewers.buffer{
            title = title,
            max_title_len = config.max_title_len,
        },
    }
end

--- Builds picker options for git commit pickers
--- @param picker_name string Name of the picker
--- @param include_file boolean Whether to scope preview to current file
--- @return table Picker options
local function git_commit_picker_opts(picker_name, include_file)
    return {
        prompt_prefix = config.prompt_prefixes[picker_name],
        git_command = { 'git', 'log', '--pretty=%H %an %ad %s', '--date=short' },
        entry_maker = nvu_telescope.entry_makers.git_commit(config.git),
        previewer = nvu_telescope.previewers.git_commit{ include_file = include_file },
    }
end

--- Setup function called when extension is loaded
--- @param ext_config table Extension configuration from telescope.setup()
--- @param telescope_config table Telescope's config.values
local function setup(ext_config, telescope_config)
    merge_config(ext_config)

    -- Get or initialize pickers table
    local pickers = telescope_config.pickers or {}

    -- Enhance find_files
    if config.pickers.find_files then
        pickers.find_files = vim.tbl_deep_extend(
            'force',
            pickers.find_files or {},
            file_picker_opts('find_files', 'Find files'),
            { hidden = true, no_ignore = true }
        )
    end

    -- Enhance git_files
    if config.pickers.git_files then
        pickers.git_files = vim.tbl_deep_extend(
            'force',
            pickers.git_files or {},
            file_picker_opts('git_files', 'Git files')
        )
    end

    -- Enhance buffers
    if config.pickers.buffers then
        pickers.buffers = vim.tbl_deep_extend(
            'force',
            pickers.buffers or {},
            file_picker_opts('buffers', 'Buffers'),
            { sort_lastused = true, sort_mru = true }
        )
    end

    -- Enhance git_commits
    if config.pickers.git_commits then
        pickers.git_commits = vim.tbl_deep_extend(
            'force',
            pickers.git_commits or {},
            git_commit_picker_opts('git_commits', false)
        )
    end

    -- Enhance git_bcommits
    if config.pickers.git_bcommits then
        pickers.git_bcommits = vim.tbl_deep_extend(
            'force',
            pickers.git_bcommits or {},
            git_commit_picker_opts('git_bcommits', true)
        )
    end

    -- Enhance git_bcommits_range
    if config.pickers.git_bcommits_range then
        pickers.git_bcommits_range = vim.tbl_deep_extend(
            'force',
            pickers.git_bcommits_range or {},
            {
                prompt_prefix = config.prompt_prefixes.git_bcommits_range,
                previewer = nvu_telescope.previewers.git_commit{ include_file = true },
            }
        )
    end

    -- Apply prompt prefixes for other pickers
    if config.prompt_prefixes.git_branches then
        pickers.git_branches = vim.tbl_deep_extend(
            'force',
            pickers.git_branches or {},
            { prompt_prefix = config.prompt_prefixes.git_branches }
        )
    end

    if config.prompt_prefixes.live_grep then
        pickers.live_grep = vim.tbl_deep_extend(
            'force',
            pickers.live_grep or {},
            { prompt_prefix = config.prompt_prefixes.live_grep }
        )
    end

    -- Write to telescope's picker config (used by builtins)
    -- Note: Must use set_pickers() to write to config.pickers, not config.values.pickers
    require('telescope.config').set_pickers(pickers)
end

--- Exported functions and utilities
local exports = {
    -- Expose components for advanced users
    entry_makers = nvu_telescope.entry_makers,
    previewers = nvu_telescope.previewers,
    utils = nvu_telescope.utils,

    -- Expose current config for inspection
    get_config = function()
        return vim.deepcopy(config)
    end,
}

return telescope.register_extension{
    setup = setup,
    exports = exports,
}
