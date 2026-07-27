local gh = require('ci.gh')

local M = {}

local KNOWN = { gh = true }

local function check_config()
  local g = vim.g.ci
  if g == nil then
    return
  end
  if type(g) ~= 'table' then
    return vim.health.error('vim.g.ci must be a table, got ' .. type(g))
  end
  for k in pairs(g) do
    if not KNOWN[k] then
      vim.health.warn(('vim.g.ci.%s is not a recognised option'):format(k))
    end
  end
end

function M.check()
  vim.health.start('ci.nvim')

  if vim.fn.has('nvim-0.11.0') == 1 then
    vim.health.ok('Neovim 0.11.0+')
  else
    vim.health.error('ci.nvim requires Neovim 0.11.0+')
  end

  check_config()

  local cmd = gh.cmd()
  if vim.fn.executable(cmd[1]) == 0 then
    return vim.health.error(('%s not found on $PATH'):format(cmd[1]), {
      'Install the GitHub CLI: https://cli.github.com',
    })
  end
  vim.health.ok(('%s found'):format(cmd[1]))

  local auth = vim.system(vim.list_extend(gh.cmd(), { 'auth', 'status' }), { text = true }):wait()
  if auth.code ~= 0 then
    return vim.health.error('gh is not authenticated', { 'Run: gh auth login' })
  end
  vim.health.ok('gh is authenticated')

  local repo = vim
    .system(vim.list_extend(gh.cmd(), { 'api', 'repos/{owner}/{repo}', '--jq', '.full_name' }), {
      text = true,
    })
    :wait()
  if repo.code ~= 0 then
    return vim.health.warn(vim.trim(repo.stderr or 'cannot resolve a GitHub repository here'), {
      'ci.nvim resolves the base repository through gh.',
      'Run `gh repo set-default` inside a GitHub checkout to choose it.',
    })
  end
  vim.health.ok(('base repository resolves to %s'):format(vim.trim(repo.stdout)))
end

return M
