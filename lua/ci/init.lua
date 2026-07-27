---@class ci.Config
---@field debug boolean|string

---@class ci
---@field setup fun(opts?: table)
---@field run fun()
---@field get_config fun(): ci.Config
local M = {}

local log = require('ci.log')

---@type ci.Config
local default_config = {
  debug = false,
}

---@type ci.Config
local config = vim.deepcopy(default_config)

---@param opts? table
function M.setup(opts)
  opts = opts or {}
  vim.validate('ci.setup opts', opts, 'table')
  vim.validate('ci.setup opts.debug', opts.debug, { 'boolean', 'string' }, true)

  config = vim.tbl_deep_extend('force', default_config, opts)

  log.set_enabled(config.debug)
  log.dbg('initialized')
end

---@return ci.Config
function M.get_config()
  return config
end

function M.run()
  log.dbg('run')
  vim.notify('[ci]: not implemented', vim.log.levels.WARN)
end

M._test = {
  ---@diagnostic disable-next-line: assign-type-mismatch
  reset = function()
    config = vim.deepcopy(default_config)
  end,
}

if vim.g.ci then
  M.setup(vim.g.ci)
end

return M
