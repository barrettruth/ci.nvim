local M = {}

function M.setup()
  vim.api.nvim_create_user_command('CI', function()
    require('ci').run()
  end, {
    nargs = 0,
    desc = 'Run ci.nvim',
  })
end

return M
