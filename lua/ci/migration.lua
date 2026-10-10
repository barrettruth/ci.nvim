local M = {}

local message = table.concat({
  '[ci.nvim] This repository will be removed from GitHub on October 31, 2026.',
  'Install from Forgejo: https://forge.barrettruth.com/barrettruth/ci.nvim.',
  'See :help ci-migration.',
}, ' ')

---@param origin unknown
---@return boolean
function M.is_github_origin(origin)
  if type(origin) ~= 'string' then
    return false
  end

  origin = origin:gsub('/+$', ''):gsub('%.git$', '')

  return origin == 'https://github.com/barrettruth/ci.nvim'
    or origin == 'http://github.com/barrettruth/ci.nvim'
    or origin == 'git://github.com/barrettruth/ci.nvim'
    or origin == 'ssh://git@github.com/barrettruth/ci.nvim'
    or origin == 'git@github.com:barrettruth/ci.nvim'
end

---@return string
function M.plugin_root()
  local source = debug.getinfo(1, 'S').source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

---@param root string
---@param on_done fun(origin?: string)
function M.origin(root, on_done)
  if vim.fn.executable('git') ~= 1 then
    on_done()
    return
  end

  local ok = pcall(
    vim.system,
    { 'git', '-C', root, 'config', '--get', 'remote.origin.url' },
    { text = true },
    function(result)
      if result.code ~= 0 then
        on_done()
        return
      end
      on_done(vim.trim(result.stdout or ''))
    end
  )
  if not ok then
    on_done()
  end
end

---@param root? string
function M.warn_if_github_source(root)
  M.origin(root or M.plugin_root(), function(origin)
    if M.is_github_origin(origin) then
      vim.schedule(function()
        vim.notify_once(message, vim.log.levels.WARN)
      end)
    end
  end)
end

return M
