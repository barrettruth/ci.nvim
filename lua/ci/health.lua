local M = {}

local PROBE = 10000

---@param cli string
---@param cmd string[]
---@return boolean? ok nil when {cli} never answered
local function probe(cli, cmd)
  local r = vim.system(cmd, { text = true }):wait(PROBE)
  if r.code == 124 then
    vim.health.warn(('%s did not answer within %ds'):format(cli, PROBE / 1000))
    return nil
  end
  return r.code == 0
end

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
    local ok = probe('gh', { 'gh', 'auth', 'status' })
    if ok then
      vim.health.ok('gh found and authenticated')
    elseif ok == false then
      vim.health.warn('gh is not authenticated', { 'Run: gh auth login' })
    end
  else
    vim.health.warn('gh not found on $PATH', {
      'Needed for github.com: https://cli.github.com',
    })
  end

  if vim.fn.executable('glab') == 1 then
    local ok = probe('glab', { 'glab', 'auth', 'status' })
    if ok then
      vim.health.ok('glab found and authenticated')
    elseif ok == false then
      vim.health.warn('glab is not authenticated', { 'Run: glab auth login' })
    end
  else
    vim.health.warn('glab not found on $PATH', {
      'Needed for gitlab.com: https://gitlab.com/gitlab-org/cli',
    })
  end

  if vim.fn.executable('tea') == 1 then
    local ok = probe('tea', { 'tea', 'api', 'version' })
    if ok then
      vim.health.ok('tea found and authenticated')
    elseif ok == false then
      vim.health.warn('tea is not authenticated', { 'Run: tea login add' })
    end
  else
    vim.health.warn('tea not found on $PATH', {
      'Needed for Forgejo: https://gitea.com/gitea/tea',
    })
  end
end

return M
