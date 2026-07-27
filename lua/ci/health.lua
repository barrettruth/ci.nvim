local M = {}

function M.check()
  vim.health.start('ci.nvim')

  if vim.fn.has('nvim-0.11.0') == 1 then
    vim.health.ok('Neovim 0.11.0+ detected')
  else
    vim.health.error('ci.nvim requires Neovim 0.11.0+')
  end
end

return M
