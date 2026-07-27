if vim.g.loaded_ci then
  return
end
vim.g.loaded_ci = 1

require('ci.commands').setup()

vim.keymap.set('n', '<Plug>(ci-run)', function()
  require('ci').run()
end, { silent = true, desc = 'Run ci.nvim' })
