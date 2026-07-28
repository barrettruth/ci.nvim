local M = {}

function M.check()
  vim.health.start('ci.nvim')

  if vim.fn.has('nvim-0.13.0') == 1 then
    vim.health.ok('Neovim 0.13.0+')
  else
    vim.health.error('ci.nvim requires Neovim 0.13.0+')
  end

  local host = require('ci.forge').host()
  vim.health.info(('origin points at %s'):format(host))

  if vim.fn.executable('gh') == 1 then
    local auth = vim.system({ 'gh', 'auth', 'status' }, { text = true }):wait()
    if auth.code == 0 then
      vim.health.ok('gh found and authenticated')
    else
      vim.health.warn('gh is not authenticated', { 'Run: gh auth login' })
    end
  else
    vim.health.warn('gh not found on $PATH', {
      'Needed for github.com: https://cli.github.com',
    })
  end

  if vim.fn.executable('tea') == 1 then
    local ver = vim.system({ 'tea', 'api', 'version' }, { text = true }):wait()
    if ver.code == 0 then
      vim.health.ok('tea found and authenticated')
    else
      vim.health.warn('tea is not authenticated', { 'Run: tea login add' })
    end
  else
    vim.health.warn('tea not found on $PATH', {
      'Needed for Forgejo: https://gitea.com/gitea/tea',
    })
  end
end

return M
