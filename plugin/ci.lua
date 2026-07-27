if vim.g.loaded_ci then
  return
end
vim.g.loaded_ci = 1

local hl = {
  CiPass = 'DiagnosticOk',
  CiFail = 'DiagnosticError',
  CiRunning = 'DiagnosticWarn',
  CiPending = 'Comment',
  CiSkipped = 'Comment',
  CiAttention = 'DiagnosticWarn',
  CiGroup = 'Title',
  CiMuted = 'Comment',
}
for name, link in pairs(hl) do
  vim.api.nvim_set_hl(0, name, { default = true, link = link })
end

local group = vim.api.nvim_create_augroup('ci', { clear = true })

vim.api.nvim_create_autocmd('BufReadCmd', {
  pattern = 'ci://*',
  group = group,
  nested = true,
  callback = function(args)
    require('ci.buf').load(args.buf, args.match)
  end,
})

vim.api.nvim_create_autocmd('BufUnload', {
  pattern = 'ci://*',
  group = group,
  callback = function(args)
    require('ci.buf').save_view(args.buf)
  end,
})

vim.api.nvim_create_autocmd('BufWipeout', {
  pattern = 'ci://*',
  group = group,
  callback = function(args)
    require('ci.buf').forget(args.buf)
  end,
})

local STATUS = [[%{%'%#' .. b:ci.status_hl .. '#' .. b:ci.status .. '%*'%}]]
local winbar = {
  job = 'LOG ' .. STATUS .. [[ %{b:ci.title}%( | %{b:ci.workflow}%)%<]],
  list = [[CI %{b:ci.title}%<]],
}

vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufReadPost' }, {
  pattern = 'ci://*',
  group = group,
  callback = function(args)
    local u = require('ci.buf').parse(args.match)
    if not u then
      return
    end
    local job = u.kind == 'job'
    vim.wo[0][0].winbar = winbar[job and 'job' or 'list']
    vim.wo[0][0].foldenable = job
    if job then
      vim.wo[0][0].foldmethod = 'expr'
      vim.wo[0][0].foldexpr = 'v:lua.require("ci.log").fold(v:lnum)'
      vim.wo[0][0].foldlevel = 0
    end
  end,
})

local refs = { at = 0, list = {} }

---@param lead string
---@return string[]
local function complete(lead)
  if vim.uv.now() - refs.at > 1000 then
    local r = vim
      .system({
        'git',
        'for-each-ref',
        '--format=%(refname:short)',
        'refs/heads',
        'refs/tags',
        'refs/remotes',
      }, { text = true })
      :wait()
    refs = { at = vim.uv.now(), list = vim.split(r.stdout or '', '\n', { trimempty = true }) }
  end
  return vim.tbl_filter(function(x)
    return vim.startswith(x, lead)
  end, refs.list)
end

vim.api.nvim_create_user_command('CI', function(args)
  require('ci').run(args.args, args.smods)
end, {
  nargs = '?',
  bar = true,
  desc = 'GitHub Actions CI',
  complete = complete,
})

---@param name string
---@param desc string
---@param fn function
local function plug(name, desc, fn)
  vim.keymap.set('n', '<Plug>(ci-' .. name .. ')', fn, { silent = true, desc = desc })
end

plug('open', 'Open the check under the cursor', function()
  require('ci.buf').enter()
end)
plug('up', 'Go to the parent run', function()
  require('ci.buf').up()
end)
plug('web', 'Open on github.com', function()
  local url = require('ci').url(0)
  if url then
    vim.ui.open(url)
  else
    vim.notify('[ci]: no URL for this buffer', vim.log.levels.WARN)
  end
end)
plug('help', 'ci.nvim mappings', '<cmd>help ci-mappings<cr>')
