local ansi = require('ci.ansi')

local api = vim.api

local M = {}

---@class ci.Uri
---@field repo string
---@field kind 'job'|'run'|'checks'|'pr'
---@field id string
---@field attempt? integer

---@param uri string
---@return ci.Uri?
function M.parse(uri)
  local body = uri:match('^ci://(.*)$')
  if not body then
    return nil
  end
  local owner, name, kind, rest = body:match('^([^/]+)/([^/]+)/([^/]+)/(.+)$')
  if not owner then
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

---@param buf integer
---@return integer
function M.bump(buf)
  local gen = (vim.b[buf].ci_gen or 0) + 1
  vim.b[buf].ci_gen = gen
  return gen
end

---@param buf integer
---@param gen integer
---@return boolean
function M.current(buf, gen)
  return api.nvim_buf_is_valid(buf) and vim.b[buf].ci_gen == gen
end

---@param buf integer
function M.options(buf)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = false
end

---@param buf integer
---@param lines string[]
function M.set(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

---@param buf integer
function M.clear(buf)
  api.nvim_buf_clear_namespace(buf, ansi.ns, 0, -1)
end

---@param buf integer
---@param msg string
function M.placeholder(buf, msg)
  M.set(buf, { msg })
end

---@param buf integer
---@param err string
function M.fail(buf, err)
  M.set(buf, { err })
  vim.notify('[ci]: ' .. err, vim.log.levels.ERROR)
end

local MAPS = {
  ['<CR>'] = '<Plug>(ci-open)',
  ['-'] = '<Plug>(ci-up)',
  ['gX'] = '<Plug>(ci-web)',
  ['g?'] = '<Plug>(ci-help)',
}

---@param buf integer
function M.keymaps(buf)
  for lhs, plug in pairs(MAPS) do
    if vim.fn.hasmapto(plug, 'n') == 0 then
      vim.keymap.set('n', lhs, plug, { buffer = buf, silent = true, remap = true })
    end
  end
end

function M.enter()
  local buf = api.nvim_get_current_buf()
  local u = M.parse(api.nvim_buf_get_name(buf))
  if not u then
    return
  end
  if u.kind == 'job' then
    return
  end
  local check = require('ci.list').at(buf, api.nvim_win_get_cursor(0)[1])
  if not check then
    return
  end
  if check.job_id then
    return M.open(('ci://%s/job/%d'):format(u.repo, check.job_id))
  end
  if check.url then
    return vim.ui.open(check.url)
  end
  vim.notify('[ci]: no logs for this check', vim.log.levels.WARN)
end

function M.up()
  local buf = api.nvim_get_current_buf()
  local u = M.parse(api.nvim_buf_get_name(buf))
  if not u or u.kind ~= 'job' then
    return
  end
  local b = vim.b[buf].ci
  local run = b and b.run_id
  if not run then
    return vim.notify('[ci]: no parent run', vim.log.levels.WARN)
  end
  M.open(('ci://%s/run/%d'):format(u.repo, run))
end

---@param buf integer
---@param uri string
function M.load(buf, uri)
  local u = M.parse(uri)
  if not u then
    return M.fail(buf, ('malformed ci:// URI: %s'):format(uri))
  end
  M.options(buf)
  M.keymaps(buf)
  M.clear(buf)
  local gen = M.bump(buf)
  if u.kind == 'job' then
    require('ci.log').render(buf, gen, u)
  else
    require('ci.list').render(buf, gen, u)
  end
  vim.bo[buf].filetype = 'ci'
end

---@param uri string
---@param mods? string
function M.open(uri, mods)
  local cmd = (mods and mods ~= '' and mods .. ' ' or '') .. 'edit'
  vim.cmd(('%s %s'):format(cmd, vim.fn.fnameescape(uri)))
end

return M
