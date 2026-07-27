local plugin_dir = vim.fn.getcwd()
vim.opt.runtimepath:prepend(plugin_dir)
vim.opt.packpath = {}

local M = {}

function M.reset_config(opts)
  local ci = require('ci')
  ci._test.reset()
  if opts then
    ci.setup(opts)
  end
end

return M
