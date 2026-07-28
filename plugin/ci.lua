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
  CiCommand = 'Directory',
  CiUrl = 'Underlined',
  CiMuted = 'Comment',
}

for name, link in pairs(hl) do
  vim.api.nvim_set_hl(0, name, { default = true, link = link })
end

--- The band behind an annotation. github.com fills the line with a dark red
--- or yellow, but no Neovim group carries a severity background: every
--- Diagnostic* group is foreground only, and the foreground is a light tint
--- that would be unreadable as a fill. So one is mixed, {ratio} of the way
--- from the window background toward the severity colour.
---@param over string
---@return integer?
local function wash(over)
  local fg = vim.api.nvim_get_hl(0, { name = over, link = false }).fg
  local bg = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg
  if not fg or not bg then
    return nil
  end
  local ratio = 0.18
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local a = math.floor(bg / 2 ^ shift) % 256
    local b = math.floor(fg / 2 ^ shift) % 256
    out = out * 256 + math.floor(a + (b - a) * ratio + 0.5)
  end
  return out
end

vim.api.nvim_set_hl(0, 'CiBold', { default = true, bold = true })

local function bands()
  for name, over in pairs({ CiFailBand = 'CiFail', CiAttentionBand = 'CiAttention' }) do
    vim.api.nvim_set_hl(0, name, { default = true, bg = wash(over) })
  end
end
bands()

local group = vim.api.nvim_create_augroup('ci', { clear = true })

vim.api.nvim_create_autocmd({ 'ColorScheme', 'OptionSet' }, {
  group = group,
  callback = function(args)
    if args.event == 'ColorScheme' or args.match == 'background' then
      bands()
    end
  end,
})

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

local STATUS = [[%{%empty(b:ci.status) ? '' : ' | ' .. b:ci.status%}]]
local winbar = {
  job = [[LOG %{b:ci.repo}]] .. STATUS .. [[%( %{b:ci.title}%)%( | %{b:ci.workflow}%)%<]],
  list = [[CI %{b:ci.repo}]] .. STATUS .. [[%( | %{b:ci.title}%)%<]],
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
      vim.wo[0][0].conceallevel = 3
      vim.wo[0][0].concealcursor = 'nvic'
      vim.wo[0][0].foldtext = 'v:lua.require("ci.log").foldtext()'
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
plug('up', 'Go back to the list you came from', function()
  require('ci.buf').up()
end)
plug('web', 'Open on github.com', function()
  local url = require('ci').url(0)
  if url then
    vim.ui.open(url)
  else
    require('ci.msg').warn('no URL for this buffer')
  end
end)
plug('help', 'ci.nvim mappings', '<cmd>help ci-mappings<cr>')
plug('next-step', 'Go to the next step', function()
  require('ci.log').step(1)
end)
plug('prev-step', 'Go to the previous step', function()
  require('ci.log').step(-1)
end)
plug('timestamps', 'Toggle the timestamp column', function()
  require('ci.log').timestamps()
end)
plug('refresh', 'Reload this buffer', '<cmd>edit<cr>')
