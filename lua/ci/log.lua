local ansi = require('ci.ansi')
local buf_util = require('ci.buf')
local gh = require('ci.gh')
local status = require('ci.status')

local api = vim.api

local M = {}

local TS = '^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)%.%d+Z (.*)$'
local CHUNK = 1000

---@alias ci.log.Fold '0'|'1'|'2'|'>1'|'>2'

---@type table<integer, ci.log.Fold[]>
local levels = {}

---@type table<integer, integer[]>
local conceals = {}

--- How far github.com nests a line. Only a group's body is pushed in; a
--- step's body sits flush beneath its header. A line that opens a fold
--- belongs to its parent, so it is nested one less than what it contains.
---@param fold ci.log.Fold
---@return integer
local function depth(fold)
  local n = tonumber(fold:match('%d')) or 0
  return math.max(0, (fold:sub(1, 1) == '>' and n - 1 or n) - 1)
end

---@type table<string, string>
local dates = {}

---@type table<integer, table<integer, string>>
local stamps = {}

local time_ns = api.nvim_create_namespace('ci.time')

--- An annotation is banded rather than coloured: github.com leaves the words
--- in the ordinary foreground and fills the line behind them.
---@type table<string, string>
local BAND = { CiFail = 'CiFailBand', CiAttention = 'CiAttentionBand' }

---@param buf integer
---@param on boolean
local function times(buf, on)
  api.nvim_buf_clear_namespace(buf, time_ns, 0, -1)
  if on then
    for i, at in pairs(stamps[buf] or {}) do
      api.nvim_buf_set_extmark(buf, time_ns, i - 1, 0, {
        virt_text = { { at .. ' ', 'CiMuted' } },
        virt_text_pos = 'inline',
      })
    end
  end
  vim.b[buf].ci_times = on
end

--- "2026-07-27T15:14:08" -> "Mon, 27 Jul 2026 15:14:08 GMT". The weekday needs
--- real date arithmetic, so it is resolved once per day rather than per line.
---@param at string
---@return string
local function human(at)
  local day = at:sub(1, 10)
  local head = dates[day]
  if not head then
    head = tostring(os.date('%a, %d %b %Y ', vim.fn.strptime('%Y-%m-%d', day)))
    dates[day] = head
  end
  return head .. at:sub(12) .. ' GMT'
end

--- Backs 'foldtext', which conceal does not apply to: without this the raw
--- timestamp and marker leak into every closed fold.
---@return string
function M.foldtext()
  local buf = api.nvim_get_current_buf()
  local n = (conceals[buf] or {})[vim.v.foldstart] or 0
  local line = api.nvim_buf_get_lines(buf, vim.v.foldstart - 1, vim.v.foldstart, false)[1] or ''
  return ('%s  %d lines'):format(line:sub(n + 1), vim.v.foldend - vim.v.foldstart + 1)
end

---@param lnum integer
---@return ci.log.Fold
function M.fold(lnum)
  local l = levels[api.nvim_get_current_buf()]
  return l and l[lnum] or '0'
end

---@class ci.log.Step
---@field name string
---@field status ci.rest.Status
---@field conclusion? ci.rest.Conclusion
---@field at string
---@field number integer

---@param steps? ci.gh.JobStep[]
---@return ci.log.Step[]
local function usable_steps(steps)
  ---@type ci.log.Step[]
  local out = {}
  for i, s in ipairs(steps or {}) do
    if s.started_at then
      out[#out + 1] = {
        name = s.name,
        conclusion = s.conclusion,
        status = s.status,
        at = s.started_at:sub(1, 19),
        number = s.number or i,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.number < b.number
  end)
  return out
end

---@class ci.log.Row
---@field text string
---@field fold ci.log.Fold
---@field hl? ci.Hl
---@field step? boolean
---@field conceal integer
---@field label? string
---@field cont? boolean
---@field time? string

--- Splits a job log into rows. Lines are kept whole, with an offset marking
--- the timestamp and `##[...]` marker to conceal; steps come from the API
--- rather than the text, since a `run:` step logs its command, not its name.
---@param text string
---@param steps ci.log.Step[]
---@return ci.log.Row[]
function M.parse(text, steps)
  ---@type ci.log.Row[]
  local rows = {}
  local step_i, in_group = 0, false
  ---@type integer[]
  local pending = {}

  ---@param line string
  ---@param fold ci.log.Fold
  ---@param hl? ci.Hl
  ---@param step? boolean
  local function emit(line, fold, hl, step, conceal, label, cont)
    conceal = conceal or 0
    rows[#rows + 1] = {
      text = line,
      fold = fold,
      hl = hl,
      step = step,
      conceal = conceal,
      label = label,
      cont = cont,
      time = conceal > 0 and human(line:sub(1, 19)) or nil,
    }
  end

  local function flush()
    if #pending == 0 then
      return
    end
    in_group = false
    for _, si in ipairs(pending) do
      local s = steps[si]
      local sym, hl = status.of(s.status, s.conclusion)
      local stamp = s.at .. '.0000000Z '
      emit(('%s%s %s'):format(stamp, sym, s.name), '>1', hl, true, #stamp)
    end
    pending = {}
  end

  ---@type ci.Hl?
  local annot
  for raw in (text .. '\n'):gmatch('([^\n]*)\n') do
    local at, body = raw:match(TS)
    if not at then
      at, body = nil, raw
    end

    if at then
      while step_i < #steps and steps[step_i + 1].at <= at do
        step_i = step_i + 1
        pending[#pending + 1] = step_i
      end
    end

    local group = body:match('^##%[group%](.*)$')
    local endgroup = body:match('^##%[endgroup%]')
    local err = body:match('^##%[error%](.*)$')
    local warn = body:match('^##%[warning%](.*)$')
    local notice = body:match('^##%[notice%](.*)$')
    local command = body:match('^%[command%](.*)$')

    if not endgroup then
      flush()
    end

    local ts = #raw - #body

    -- A marker's body may run on for many lines, and only the first carries
    -- a timestamp. github.com bands the whole block, so the severity is held
    -- until a stamped line ends it.
    if at then
      annot = nil
    elseif annot then
      emit(raw, in_group and '2' or '1', annot, nil, 0, nil, true)
      goto continue
    end

    if endgroup then
      in_group = false
    elseif group then
      in_group = true
      emit(raw, '>2', 'CiGroup', nil, ts + #body - #group)
    elseif err then
      in_group = false
      annot = 'CiFail'
      emit(raw, '1', 'CiFail', nil, ts + #body - #err, 'Error: ')
    elseif warn then
      annot = 'CiAttention'
      emit(raw, in_group and '2' or '1', 'CiAttention', nil, ts + #body - #warn, 'Warning: ')
    elseif notice then
      emit(raw, in_group and '2' or '1', 'CiPending', nil, ts + #body - #notice, 'Notice: ')
    elseif command then
      emit(raw, in_group and '2' or '1', 'CiCommand', nil, ts + #body - #command)
    elseif body ~= '' or #rows > 0 then
      emit(raw, in_group and '2' or '1', nil, nil, ts)
    end
    ::continue::
  end

  flush()
  return rows
end

---@param rows ci.log.Row[]
---@return integer?
local function first_failure(rows)
  for i, r in ipairs(rows) do
    if r.step and (r.hl == 'CiFail' or r.hl == 'CiAttention') then
      return i
    end
  end
  return nil
end

local URL = "https?://[%w%-%._~:/%?#%[%]@!%$&'%*%+,;=%%]+"

---@param text string
---@return ci.ansi.Span[]
local function urls(text)
  ---@type ci.ansi.Span[]
  local out = {}
  local from = 1
  while true do
    local a, b = text:find(URL, from)
    if not a or not b then
      return out
    end
    while b > a and text:sub(b, b):match('[%.,;:%)%]}>]') do
      b = b - 1
    end
    out[#out + 1] = { a - 1, b, text:sub(a, b) }
    from = b + 1
  end
end

---@class ci.log.Paint
---@field spans ci.ansi.Span[]
---@field links? string[]
---@field hl? ci.Hl
---@field urls ci.ansi.Span[]
---@field conceal integer
---@field label? string
---@field cont? boolean
---@field indent integer
---@field time? string

--- Renders {rows}, a chunk per tick, so a large log does not block.
---@param buf integer
---@param gen integer
---@param rows ci.log.Row[]
---@param done fun()
local function paint(buf, gen, rows, done)
  ---@type integer, ci.ansi.State
  local i, st = 1, {}
  ---@type string[], ci.log.Paint[]
  local lines, meta = {}, {}
  local function step()
    if not buf_util.current(buf, gen) then
      return
    end
    local last = math.min(i + CHUNK - 1, #rows)
    for k = i, last do
      local text, spans, links = ansi.line(rows[k].text, st)
      lines[k] = text
      meta[k] = {
        spans = spans,
        links = links,
        hl = rows[k].hl,
        urls = urls(text),
        conceal = rows[k].conceal,
        label = rows[k].label,
        cont = rows[k].cont,
        indent = depth(rows[k].fold),
        time = rows[k].time,
      }
    end
    i = last + 1
    if i <= #rows then
      buf_util.tick(buf, math.floor((i - 1) / #rows * 100))
      return vim.schedule(step)
    end
    buf_util.set(buf, lines)
    for k, m in ipairs(meta) do
      local prefix = math.min(m.conceal, #lines[k])
      if prefix > 0 then
        api.nvim_buf_set_extmark(buf, ansi.ns, k - 1, 0, { end_col = prefix, conceal = '' })
      end
      -- github.com draws a word where the marker is; the marker itself is
      -- concealed, so the word has to be virtual like the indent beside it.
      local band = BAND[m.hl]
      local pre = {}
      if m.indent > 0 then
        pre[#pre + 1] = { ('  '):rep(m.indent), band }
      end
      if m.label then
        pre[#pre + 1] = { m.label, band and { band, m.hl, 'CiBold' } or m.hl }
      end
      if #pre > 0 and prefix < #lines[k] then
        api.nvim_buf_set_extmark(buf, ansi.ns, k - 1, prefix, {
          virt_text = pre,
          virt_text_pos = 'inline',
        })
      end
      if band then
        -- Under the log's own colours, and out to the edge as on the web.
        api.nvim_buf_set_extmark(buf, ansi.ns, k - 1, 0, {
          end_row = k,
          hl_group = band,
          hl_eol = true,
          priority = 90,
        })
      elseif m.hl then
        api.nvim_buf_set_extmark(buf, ansi.ns, k - 1, prefix, { end_row = k, hl_group = m.hl })
      end
      ansi.apply(buf, k - 1, m.spans, m.links, #lines[k])
      for _, u in ipairs(m.urls) do
        api.nvim_buf_set_extmark(buf, ansi.ns, k - 1, u[1], {
          end_col = u[2],
          hl_group = 'CiUrl',
          url = u[3],
        })
      end
    end
    done()
  end
  step()
end

--- 404 is a log that was never written, 410 one that has aged out. Neither
--- code says which, but the job does, so name its state rather than guess at
--- the three it could have been.
---@param err string
---@param job ci.gh.Job
---@return string
local function no_log(err, job)
  if err:match('410') or err:match('[Gg]one') then
    return 'log expired'
  end
  if err:match('404') or err:match('[Nn]ot [Ff]ound') then
    return ('no log: job is %s'):format(job.conclusion or job.status or 'unknown')
  end
  return err
end

--- All a job can show before its log exists. The steps come back with the
--- job itself, so this costs nothing beyond what was already fetched, and
--- the poll that keeps a list current keeps this current too.
---@param buf integer
---@param job ci.gh.Job
local function steplist(buf, job)
  local lines, marks, checks = {}, {}, {}
  for i, s in ipairs(job.steps or {}) do
    local sym, hl = status.of(s.status, s.conclusion)
    lines[i] = ('%s %s'):format(sym, s.name)
    marks[i] = hl
    checks[i] = { name = s.name, status = s.status, conclusion = s.conclusion }
  end
  buf_util.set(buf, lines)
  for i, hl in ipairs(marks) do
    api.nvim_buf_set_extmark(
      buf,
      ansi.ns,
      i - 1,
      0,
      { end_col = #tostring(lines[i]), hl_group = hl }
    )
  end
  ---@diagnostic disable-next-line: assign-type-mismatch
  vim.b[buf].ci = vim.tbl_extend('force', vim.b[buf].ci, { checks = checks })
  vim.b[buf].ci_loaded = true
  buf_util.watch(buf)
end

---@param buf integer
---@param gen integer
---@param u ci.Uri
function M.render(buf, gen, u)
  local id = tonumber(u.id)
  if not id then
    return buf_util.fail(buf, ('malformed job id: %s'):format(u.id))
  end
  local reload = vim.b[buf].ci_loaded
  local showing = vim.b[buf].ci_times
  times(buf, false)

  ---@type ci.gh.Job?, string?, string?, boolean?
  local job, text, log_err, failed
  local function ready()
    if failed or not job or not text or not buf_util.current(buf, gen) then
      return
    end
    local rows = M.parse(text, usable_steps(job.steps))
    levels[buf] = vim.tbl_map(function(r)
      return r.fold
    end, rows)
    conceals[buf] = vim.tbl_map(function(r)
      return r.conceal
    end, rows)
    stamps[buf] = {}
    for i, r in ipairs(rows) do
      stamps[buf][i] = r.time
    end
    paint(buf, gen, rows, function()
      vim.b[buf].ci_loaded = true
      times(buf, showing or false)
      if reload then
        return buf_util.restore_view(buf)
      end
      local hit = first_failure(rows)
      if not hit then
        return
      end
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        api.nvim_win_call(win, function()
          api.nvim_win_set_cursor(win, { hit, 0 })
          vim.cmd('normal! zv')
        end)
      end
    end)
  end

  --- A running job has no log yet, so show how far it has got instead.
  ---@param j ci.gh.Job
  ---@param err string
  local function settle(j, err)
    if failed or not buf_util.current(buf, gen) then
      return
    end
    failed = true
    if j.status ~= 'completed' then
      return steplist(buf, j)
    end
    buf_util.fail(buf, no_log(err, j))
  end

  local function fail(err)
    if failed or not buf_util.current(buf, gen) then
      return
    end
    failed = true
    buf_util.fail(buf, err)
  end

  gh.job(id, u.repo, function(data, err)
    if err then
      return fail(err)
    end
    job = data
    if buf_util.current(buf, gen) then
      local sym, hl = status.of(job.status, job.conclusion)
      ---@type ci.BufVar
      vim.b[buf].ci = vim.tbl_extend('force', vim.b[buf].ci, {
        title = job.name or '',
        status = status.paint(hl, sym),
        workflow = job.workflow_name or '',
        url = job.html_url or '',
        up = vim.b[buf].ci.up
          or (job.head_sha and ('ci://%s/checks/%s'):format(u.repo, job.head_sha) or nil),
      })
    end
    if log_err then
      return settle(job, log_err)
    end
    ready()
  end)
  gh.job_log(id, u.repo, function(out, err)
    if err then
      log_err = err
      if job then
        settle(job, err)
      end
      return
    end
    text = out
    ready()
  end)
end

---@param buf integer
function M.forget(buf)
  levels[buf] = nil
  conceals[buf] = nil
  stamps[buf] = nil
end

--- Shows or hides the timestamp column. Its own namespace, so flipping it
--- leaves the ANSI highlights and the concealed prefix untouched.
--- Moves {count} steps. No fold motion does this: zj stops at every fold
--- start and a group is a fold too, so the level has to be read directly.
---@param dir -1|1
function M.step(dir)
  local fold = levels[api.nvim_get_current_buf()]
  if not fold then
    return
  end
  local from = api.nvim_win_get_cursor(0)[1]
  local at = from
  for _ = 1, vim.v.count1 do
    local n = at + dir
    while n >= 1 and n <= #fold and fold[n] ~= '>1' do
      n = n + dir
    end
    if n < 1 or n > #fold then
      break
    end
    at = n
  end
  if at == from then
    return
  end
  vim.cmd("normal! m'")
  api.nvim_win_set_cursor(0, { at, 0 })
  vim.cmd('normal! zv')
end

function M.timestamps()
  local buf = api.nvim_get_current_buf()
  if stamps[buf] then
    times(buf, not vim.b[buf].ci_times)
  end
end

return M
