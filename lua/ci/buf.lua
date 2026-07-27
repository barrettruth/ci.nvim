local ansi = require('ci.ansi')
local msg = require('ci.msg')

local api = vim.api

local M = {}

---@alias ci.Uri.Kind 'job'|'run'|'checks'|'pr'

---@class ci.Uri
---@field repo string
---@field kind ci.Uri.Kind
---@field id string
---@field attempt? integer

---@class ci.BufVar
---@field kind 'job'|'list'
---@field title string
---@field status string
---@field status_hl string
---@field repo string
---@field workflow string
---@field url string
---@field run_id integer
---@field up? string
---@field checks? ci.Check[]

local KINDS = { job = true, run = true, checks = true, pr = true }

---@type table<integer, table<integer, vim.fn.winsaveview.ret>>
local views = {}

---@param uri string
---@return ci.Uri?
function M.parse(uri)
  local body = uri:match('^ci://(.*)$')
  if not body then
    return nil
  end
  local owner, name, kind, rest = body:match('^([^/]+)/([^/]+)/([^/]+)/(.+)$')
  if not owner or not KINDS[kind] then
    return nil
  end
  local id, attempt = rest:match('^(%d+)/(%d+)$')
  return {
    repo = owner .. '/' .. name,
    kind = kind,
    id = id or rest,
    attempt = tonumber(attempt),
  }
end

--- Whether {gen} is still the buffer's newest load. Lets an in-flight request
--- discard itself when the buffer has since reloaded or been wiped.
---@param buf integer
---@param gen integer
---@return boolean
function M.current(buf, gen)
  return api.nvim_buf_is_valid(buf) and vim.b[buf].ci_gen == gen
end

---@param buf integer
---@param lines string[]
function M.set(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

---@param buf integer
---@param err string
function M.fail(buf, err)
  if not vim.b[buf].ci_loaded then
    M.set(buf, {})
  end
  msg(err, vim.log.levels.ERROR)
end

--- Records the view of every window showing {buf}. Called on |BufUnload|,
--- which still sees the old content; by |BufReadCmd| the buffer is empty.
---@param buf integer
function M.save_view(buf)
  local saved = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    saved[win] = api.nvim_win_call(win, vim.fn.winsaveview)
  end
  views[buf] = saved
end

---@param buf integer
function M.restore_view(buf)
  local saved = views[buf]
  views[buf] = nil
  if not saved then
    return
  end
  for win, view in pairs(saved) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
      api.nvim_win_call(win, function()
        vim.fn.winrestview(view)
      end)
    end
  end
end

---@param buf integer
function M.forget(buf)
  views[buf] = nil
  require('ci.log').forget(buf)
end

---@param buf integer
---@param lhs string
---@param name string
---@param desc string
---@param opts? table
local function map(buf, lhs, name, desc, opts)
  local plug = '<Plug>(ci-' .. name .. ')'
  if vim.fn.hasmapto(plug, 'n') == 0 then
    vim.keymap.set(
      'n',
      lhs,
      plug,
      vim.tbl_extend('keep', opts or {}, { buffer = buf, remap = true, silent = true, desc = desc })
    )
  end
end

---@param buf integer
---@param kind 'job'|'list'
local function keymaps(buf, kind)
  api.nvim_buf_call(buf, function()
    map(buf, 'g?', 'help', 'ci.nvim mappings', { nowait = true })
    map(buf, '-', 'up', 'Go up a level')
    map(buf, 'R', 'refresh', 'Reload this buffer')
    map(buf, 'gX', 'web', 'Open on github.com')
    if kind == 'job' then
      map(buf, 'gS', 'timestamps', 'Toggle the timestamp column')
    end
    if kind == 'list' then
      map(buf, '<CR>', 'open', 'Open the check under the cursor')
    end
  end)
end

--- Shows {uri}, splitting only if {mods} asks for it. An already-visible
--- buffer is jumped to rather than reloaded.
---@param uri string
---@param mods? vim.api.keyset.cmd.mods
function M.open(uri, mods)
  mods = mods or {}
  local split = (mods.split or '') ~= ''
    or mods.vertical
    or mods.horizontal
    or (mods.tab or -1) >= 0
  if not split then
    local win = vim.fn.bufwinid(vim.fn.bufnr(uri))
    if win ~= -1 then
      return api.nvim_set_current_win(win)
    end
  end
  vim.cmd({ cmd = split and 'split' or 'edit', args = { vim.fn.fnameescape(uri) }, mods = mods })
end

function M.enter()
  local buf = api.nvim_get_current_buf()
  local u = M.parse(api.nvim_buf_get_name(buf))
  ---@type ci.BufVar?
  local b = vim.b[buf].ci
  if not u or not b or not b.checks then
    return
  end
  local check = b.checks[api.nvim_win_get_cursor(0)[1]]
  if not check then
    return
  end
  if check.job_id then
    return M.open(('ci://%s/job/%d'):format(u.repo, check.job_id), { keepalt = true })
  end
  if check.url then
    return vim.ui.open(check.url)
  end
  msg('no logs for this check', vim.log.levels.WARN)
end

function M.up()
  ---@type ci.BufVar?
  local b = vim.b[api.nvim_get_current_buf()].ci
  if not b or not b.up then
    return msg('already at the top level', vim.log.levels.WARN)
  end
  M.open(b.up, { keepalt = true })
end

---@param buf integer
---@param uri string
function M.load(buf, uri)
  local u = M.parse(uri)
  if not u then
    return M.fail(buf, ('malformed ci:// URI: %s'):format(uri))
  end

  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modeline = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = false

  ---@type ci.BufVar
  vim.b[buf].ci = {
    kind = u.kind == 'job' and 'job' or 'list',
    title = '',
    status = '',
    status_hl = 'CiPending',
    repo = u.repo,
    workflow = '',
    url = '',
    run_id = 0,
  }

  keymaps(buf, u.kind == 'job' and 'job' or 'list')
  api.nvim_buf_clear_namespace(buf, ansi.ns, 0, -1)

  local gen = (vim.b[buf].ci_gen or 0) + 1
  vim.b[buf].ci_gen = gen
  M.set(buf, { u.kind == 'job' and 'Loading job log...' or 'Loading checks...' })

  if u.kind == 'job' then
    require('ci.log').render(buf, gen, u)
  else
    require('ci.list').render(buf, gen, u)
  end
  vim.bo[buf].filetype = 'ci'
end

return M
