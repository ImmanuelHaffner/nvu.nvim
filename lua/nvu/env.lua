--- Environment detection utilities
--- @module nvu.env

local M = {}

local string_utils = require'nvu.string'

--- Checks whether this is a local Neovim instance.
--- A local instance has a servername starting with '/'.
--- @return boolean `true` if this is a local instance
function M.is_local()
    return string_utils.starts_with(vim.v.servername or '', '/')
end

--- Checks whether the current Neovim session is running over SSH.
--- Detects SSH by checking for SSH-related environment variables.
--- @return boolean `true` if running over SSH
function M.is_ssh()
    return (vim.env.SSH_CLIENT and vim.env.SSH_CLIENT ~= '')
        or (vim.env.SSH_CONNECTION and vim.env.SSH_CONNECTION ~= '')
        or (vim.env.SSH_TTY and vim.env.SSH_TTY ~= '')
end

--- Checks whether Neovim is connected via TCP client-server.
--- Detects this by checking if `vim.v.servername` matches host:port pattern.
--- @return boolean `true` if connected via TCP
function M.is_client_server()
    return vim.v.servername and vim.v.servername:find(':%d+$') ~= nil
end

--- Checks whether the UI is connected to a headless server.
--- @return boolean `true` if connected to a headless server
function M.is_headless()
    return not M.is_local()
end

--- Checks whether the tree-sitter CLI is available.
--- @return boolean `true` if tree-sitter CLI is installed and working
function M.has_treesitter_cli()
    local handle = io.popen('tree-sitter --version 2>/dev/null')
    if not handle then
        return false
    end
    local result = handle:read('*a')
    local success = handle:close()
    return (success and result and result:match('tree%-sitter') ~= nil) or false
end

return M
