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
    vim.wo.winbar = winbar[u.kind == 'job' and 'job' or 'list'] or ''
    if u.kind == 'job' then
      vim.wo.foldmethod = 'expr'
      vim.wo.foldexpr = 'v:lua.require("ci.log").fold(v:lnum)'
      vim.wo.foldlevel = 0
      vim.wo.foldenable = true
    else
      vim.wo.cursorline = true
    end
    vim.wo.wrap = false
    vim.wo.list = false
  end,
})

vim.api.nvim_create_autocmd('BufWipeout', {
  pattern = 'ci://*',
  group = group,
  callback = function(args)
    require('ci.log').forget(args.buf)
    require('ci.list').forget(args.buf)
  end,
})

vim.api.nvim_create_user_command('CI', function(args)
  require('ci').run({ args = args.args, mods = args.mods })
end, {
  nargs = '?',
  bar = true,
  desc = 'GitHub Actions CI',
  complete = function(lead)
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
    if r.code ~= 0 then
      return {}
    end
    return vim.tbl_filter(function(x)
      return x ~= '' and vim.startswith(x, lead)
    end, vim.split(r.stdout or '', '\n', { trimempty = true }))
  end,
})

local opts = { silent = true }

vim.keymap.set('n', '<Plug>(ci-open)', function()
  require('ci.buf').enter()
end, opts)
vim.keymap.set('n', '<Plug>(ci-up)', function()
  require('ci.buf').up()
end, opts)
vim.keymap.set('n', '<Plug>(ci-web)', function()
  local url = require('ci').url(0)
  if url then
    vim.ui.open(url)
  else
    vim.notify('[ci]: no URL for this buffer', vim.log.levels.WARN)
  end
end, opts)
vim.keymap.set('n', '<Plug>(ci-help)', '<cmd>help ci-mappings<cr>', opts)
