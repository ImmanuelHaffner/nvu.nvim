--- nvu.nvim - Neovim Utilities
--- A collection of utility functions for Neovim plugin and config development.
--- @module nvu

local M = {}

M.core = require'nvu.core'
M.string = require'nvu.string'
M.path = require'nvu.path'
M.buffer = require'nvu.buffer'
M.env = require'nvu.env'
M.highlight = require'nvu.highlight'
M.telescope = require'nvu.telescope'
M.editor = require'nvu.editor'

return M
