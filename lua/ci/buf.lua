local ansi = require('ci.ansi')
local msg = require('ci.msg')

local api = vim.api

local M = {}

---@alias ci.Uri.Kind 'job'|'run'|'checks'|'pr'

---@class ci.Uri
---@field host string
---@field repo string
---@field kind ci.Uri.Kind
---@field id string
---@field attempt? integer

---@class ci.BufVar
---@field title string
---@field status string
---@field repo string
---@field workflow string
---@field url string
---@field up? string
---@field checks? ci.Check[]
---@field pending? boolean

local KINDS = { job = true, run = true, checks = true, pr = true }

---@type table<integer, table<integer, vim.fn.winsaveview.ret>>
local views = {}

---@type table<integer, string[]>
local kept = {}

---@type table<integer, fun(status: 'running'|'success'|'failed', percent?: integer)>
local reports = {}

---@type table<integer, uv.uv_timer_t>
local timers = {}

--- Set while a poll reloads a buffer, so the refresh is silent: the reader
--- asked once, and a message every tick would be worse than none.
local quiet = false

---@type table<integer, boolean>
local reported = {}

local POLL = 10000

--- Whether anything in {b} has yet to finish. A job says so outright; a list
--- is asked check by check.
---@param b ci.BufVar
---@return boolean
local function unsettled(b)
  if b.pending then
    return true
  end
  local status = require('ci.status')
  for _, c in pairs(b.checks or {}) do
    local bucket = status.bucket(c.status, c.conclusion)
    if bucket == 'running' or bucket == 'pending' then
      return true
    end
  end
  return false
end

--- Keeps a buffer in step with a run that has not settled. A failed poll
--- leaves what was already on screen.
---@param buf integer
function M.watch(buf)
  if timers[buf] then
    return
  end
  local t = assert(vim.uv.new_timer())
  timers[buf] = t
  t:start(
    POLL,
    POLL,
    vim.schedule_wrap(function()
      ---@type ci.BufVar?
      local b = api.nvim_buf_is_valid(buf) and vim.b[buf].ci or nil
      if not b or #vim.fn.win_findbuf(buf) == 0 or not unsettled(b) then
        return M.unwatch(buf)
      end
      quiet = true
      -- Not `:edit`: that empties the buffer before anything is fetched, so
      -- every poll would be a rewrite of a log that only ever grew at the end.
      -- Rendering straight into the buffer leaves the old lines, and the
      -- extmarks and folds over them, in place until there is more to add.
      local ok = pcall(M.load, buf, api.nvim_buf_get_name(buf))
      quiet = false
      if not ok then
        M.unwatch(buf)
      end
    end)
  )
end

---@param buf integer
function M.unwatch(buf)
  local t = timers[buf]
  timers[buf] = nil
  if t then
    t:stop()
    t:close()
  end
end

---@param buf integer
---@param status 'success'|'failed'
local function settle(buf, status)
  local report = reports[buf]
  reports[buf] = nil
  if report then
    report(status)
  end
end

--- Advances the |progress-message| for {buf}, if one is running.
---@param buf integer
---@param percent integer
function M.tick(buf, percent)
  if reports[buf] then
    reports[buf]('running', percent)
  end
end

---@param uri string
---@return ci.Uri?
function M.parse(uri)
  local body = uri:match('^ci://(.*)$')
  if not body then
    return nil
  end
  local host, owner, name, kind, rest = body:match('^([^/]+)/([^/]+)/([^/]+)/([^/]+)/(.+)$')
  if not owner or not KINDS[kind] then
    return nil
  end
  local id, attempt = rest:match('^(%d+)/(%d+)$')
  return {
    host = host,
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

--- Replaces the buffer from {from} on, leaving everything before it and the
--- extmarks over it alone. A growing log is a pure append, so a poll should
--- not be a rewrite.
---@param buf integer
---@param lines string[]
---@param from? integer count of leading lines already correct
function M.set(buf, lines, from)
  from = from or 0
  -- Marks belong to the lines they were put on, so they are dropped over
  -- exactly the range being rewritten and no further.
  api.nvim_buf_clear_namespace(buf, ansi.ns, from, -1)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(
    buf,
    from,
    -1,
    false,
    from > 0 and vim.list_slice(lines, from + 1) or lines
  )
  vim.bo[buf].modifiable = false
  vim.bo[buf].busy = 0
  kept[buf] = nil
  reported[buf] = nil
  settle(buf, 'success')
end

---@param buf integer
---@param err string
function M.fail(buf, err)
  vim.bo[buf].busy = 0
  settle(buf, 'failed')
  if kept[buf] then
    M.set(buf, kept[buf])
    M.restore_view(buf)
  end
  -- A poll that keeps failing says so once. Repeating it every ten seconds
  -- tells the reader nothing they were not already told.
  if quiet and reported[buf] then
    return
  end
  reported[buf] = quiet
  msg.err(err)
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
  kept[buf] = api.nvim_buf_get_lines(buf, 0, -1, false)
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
  M.unwatch(buf)
  reported[buf] = nil
  settle(buf, 'success')
  views[buf] = nil
  kept[buf] = nil
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
---@param steps boolean whether the forge exposes step boundaries
local function keymaps(buf, kind, steps)
  api.nvim_buf_call(buf, function()
    map(buf, 'g?', 'help', 'ci.nvim mappings', { nowait = true })
    map(buf, '-', 'up', 'Go back to the list you came from')
    map(buf, 'R', 'refresh', 'Reload this buffer')
    map(buf, 'gX', 'web', 'Open in the browser')
    if kind == 'job' then
      if steps then
        map(buf, ']]', 'next-step', 'Go to the next step')
        map(buf, '[[', 'prev-step', 'Go to the previous step')
      end
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
    local from = api.nvim_buf_get_name(buf)
    M.open(('ci://%s/%s/job/%d'):format(u.host, u.repo, check.job_id), { keepalt = true })
    -- Forgejo serves a job's log but not the job, so what the list already
    -- knows about the check is handed down rather than refetched.
    local job = api.nvim_get_current_buf()
    local st = require('ci.status')
    local sym, hl = st.of(check.status, check.conclusion)
    vim.b[job].ci = vim.tbl_extend('force', vim.b[job].ci, {
      up = from,
      title = check.name or '',
      status = st.paint(hl, sym),
      workflow = check.workflow or '',
      url = check.url or '',
    })
    return
  end
  if check.url then
    return vim.ui.open(check.url)
  end
  msg.warn('no logs for this check')
end

function M.up()
  ---@type ci.BufVar?
  local b = vim.b[api.nvim_get_current_buf()].ci
  if not b or not b.up then
    return msg.warn('already at the top level')
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

  ---@type ci.BufVar?
  local prev = vim.b[buf].ci

  -- What a reload cannot rediscover is carried over: a Forgejo job knows its
  -- name only from the list it was opened from, and a poll would blank it.
  ---@type ci.BufVar
  vim.b[buf].ci = {
    up = prev and prev.up or nil,
    title = prev and prev.title or '',
    status = prev and prev.status or '',
    repo = u.repo,
    workflow = prev and prev.workflow or '',
    url = prev and prev.url or '',
  }

  keymaps(buf, u.kind == 'job' and 'job' or 'list', require('ci.forge').is_github(u.host))

  local gen = (vim.b[buf].ci_gen or 0) + 1
  vim.b[buf].ci_gen = gen
  vim.bo[buf].busy = 1
  settle(buf, 'success')
  if not quiet then
    reports[buf] = msg.progress(
      ('Loading %s %s'):format(u.repo, u.kind == 'checks' and 'checks' or u.kind .. ' ' .. u.id)
    )
  end

  if u.kind == 'job' then
    require('ci.log').render(buf, gen, u)
  else
    require('ci.list').render(buf, gen, u)
  end
  vim.bo[buf].filetype = 'ci'
end

return M
