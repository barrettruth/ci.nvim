local ansi = require('ci.ansi')
local forge = require('ci.forge')
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
---@field group string
---@field url string
---@field up? string
---@field run_id? integer the run a job belongs to
---@field checks? ci.Check[]
---@field pending? boolean
---@field gen integer
---@field loaded? boolean
---@field times? boolean

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

local EMPTY = 6

--- How long a buffer polls after it was acted on. A rerun leaves it settled
--- and stopped, and a cancel takes some twenty seconds to show.
local NUDGE = 30000

---@type table<integer, integer>
local waits = {}

---@type table<integer, integer>
local nudged = {}

--- Whether anything in {b} has yet to finish. A job says so outright; a list
--- is asked check by check.
---@param buf integer
---@param b ci.BufVar
---@return boolean
local function unsettled(buf, b)
  if (nudged[buf] or 0) > vim.uv.now() then
    return true
  end
  if b.pending then
    return true
  end
  local status = require('ci.status')
  for _, c in pairs(b.checks or {}) do
    local bucket = status.bucket(c.status, c.conclusion)
    if (bucket == 'running' or bucket == 'pending') and not status.manual(c.status) then
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
      if not b or #vim.fn.win_findbuf(buf) == 0 or not unsettled(buf, b) then
        return M.unwatch(buf)
      end
      if vim.bo[buf].busy ~= 0 then
        return
      end
      if b.checks and next(b.checks) == nil then
        waits[buf] = (waits[buf] or EMPTY) - 1
        if waits[buf] <= 0 then
          return M.unwatch(buf)
        end
      else
        waits[buf] = nil
      end
      -- A log served a piece at a time is added to the end; anything else is
      -- drawn again from the top.
      local log = require('ci.log')
      if log.tailing(buf) then
        log.tail(buf)
      elseif not M.reload(buf) then
        M.unwatch(buf)
      end
    end)
  )
end

--- Renders over {buf} where it stands, keeping the lines and the extmarks and
--- folds over them until there is more to add. Silent: the reader asked once.
---@param buf integer
---@return boolean ok
function M.reload(buf)
  quiet = true
  local ok = pcall(M.load, buf, api.nvim_buf_get_name(buf))
  quiet = false
  return ok
end

--- Keeps {buf} polling for a while whatever it looks like.
---@param buf integer
function M.nudge(buf)
  nudged[buf] = vim.uv.now() + NUDGE
  M.watch(buf)
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
  local seg = vim.split(body, '/', { plain = true })
  -- A repository path is whatever lies between the host and the kind: two
  -- segments on github, more under a gitlab subgroup. The rightmost kind wins,
  -- so a repository may be named after one.
  local at
  for i = #seg - 1, 3, -1 do
    if KINDS[seg[i]] then
      at = i
      break
    end
  end
  if not at then
    return nil
  end
  local rest = table.concat(seg, '/', at + 1)
  local id, attempt = rest:match('^(%d+)/(%d+)$')
  return {
    host = seg[1],
    repo = table.concat(seg, '/', 2, at - 1),
    kind = seg[at],
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
  return api.nvim_buf_is_valid(buf) and vim.tbl_get(vim.b[buf], 'ci', 'gen') == gen
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

--- Adds {lines} after everything {buf} holds, answering the zero-based row the
--- first landed on. Nothing above is rewritten, so its marks and folds stand.
---@param buf integer
---@param lines string[]
---@return integer at
function M.append(buf, lines)
  local at = api.nvim_buf_line_count(buf)
  -- A buffer nothing has been written to still holds one empty line, and
  -- appending after it would open the log on a blank it does not have.
  if at == 1 and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == '' then
    at = 0
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, at, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].busy = 0
  kept[buf] = nil
  reported[buf] = nil
  settle(buf, 'success')
  return at
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
  waits[buf] = nil
  nudged[buf] = nil
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
---@param host string
local function keymaps(buf, kind, host)
  local be = forge.of(host)
  api.nvim_buf_call(buf, function()
    map(buf, 'g?', 'help', 'ci.nvim mappings', { nowait = true })
    map(buf, '-', 'up', 'Go back to the list you came from')
    map(buf, 'R', 'refresh', 'Reload this buffer')
    map(buf, 'gX', 'web', 'Open in the browser')
    if be.act then
      map(buf, 'cr', 'rerun', ('Re-run this %s'):format(be.nouns.run))
      map(buf, 'cc', 'cancel', ('Cancel this %s'):format(be.nouns.run))
    end
    if be.play and kind == 'list' then
      map(buf, 'cp', 'play', 'Start the job under the cursor')
    end
    if kind == 'job' then
      map(buf, ']]', 'next-step', 'Go to the next step')
      map(buf, '[[', 'prev-step', 'Go to the previous step')
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
  if check.opens then
    return M.open(check.opens, { keepalt = true })
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
      group = check.group or '',
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
  local gen = (prev and prev.gen or 0) + 1

  -- What a reload cannot rediscover is carried over: a Forgejo job knows its
  -- name only from the list it was opened from, and a poll would blank it.
  ---@type ci.BufVar
  vim.b[buf].ci = {
    up = prev and prev.up or nil,
    title = prev and prev.title or '',
    status = prev and prev.status or '',
    repo = u.repo,
    group = prev and prev.group or '',
    url = prev and prev.url or '',
    run_id = prev and prev.run_id or nil,
    gen = gen,
    loaded = prev and prev.loaded or nil,
    times = prev and prev.times or nil,
  }

  keymaps(buf, u.kind == 'job' and 'job' or 'list', u.host)

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
