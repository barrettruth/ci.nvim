local M = {}

function M.check()
  vim.health.start('ci.nvim')

  if vim.fn.has('nvim-0.11.0') == 1 then
    vim.health.ok('Neovim 0.11.0+')
  else
    vim.health.error('ci.nvim requires Neovim 0.11.0+')
  end

  if vim.fn.executable('gh') == 0 then
    return vim.health.error('gh not found on $PATH', {
      'Install the GitHub CLI: https://cli.github.com',
    })
  end
  vim.health.ok('gh found')

  local auth = vim.system({ 'gh', 'auth', 'status' }, { text = true }):wait()
  if auth.code ~= 0 then
    return vim.health.error('gh is not authenticated', { 'Run: gh auth login' })
  end
  vim.health.ok('gh is authenticated')
end

return M
