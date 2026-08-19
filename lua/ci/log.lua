local ansi = require('ci.ansi')
local buf_util = require('ci.buf')
local forge = require('ci.forge')
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
---@param i integer one-based line
local function mark_time(buf, i)
  local at = (stamps[buf] or {})[i]
  if at then
    api.nvim_buf_set_extmark(buf, time_ns, i - 1, 0, {
      virt_text = { { at .. ' ', 'CiMuted' } },
      virt_text_pos = 'inline',
    })
  end
end

--- Draws the timestamp column over lines {from}+1 upward, which is all of them
--- unless a log has just grown and only the new ones want marking.
---@param buf integer
---@param from integer
---@param to integer
local function stamps_over(buf, from, to)
  for i = from + 1, to do
    mark_time(buf, i)
  end
end

---@param buf integer
---@param on boolean
local function times(buf, on)
  api.nvim_buf_clear_namespace(buf, time_ns, 0, -1)
  if on then
    for i in pairs(stamps[buf] or {}) do
      mark_time(buf, i)
    end
  end
  vim.b[buf].ci = vim.tbl_extend('force', vim.b[buf].ci, { times = on })
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

--- Forgejo leaves `::error::` and `::warning file=,line=::` literal where
--- GitHub's runner rewrites them to `##[error]`.
---@param body string
---@param name string
---@return string? text
function M.marker(body, name)
  return body:match('^##%[' .. name .. '%](.*)$')
    or body:match('^::' .. name .. '::(.*)$')
    or body:match('^::' .. name .. ' [^:]*::(.*)$')
end

--- Prefers {a}, falling back to what the buffer already had. A Forgejo job
--- arrives with most fields empty, and the list it was opened from knew them.
---@param a? string
---@param b? string
---@return string
local function kept(a, b)
  if a ~= nil and a ~= '' then
    return a
  end
  return b or ''
end

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

--- The common shape: an ISO timestamp, a space, the line. A forge that stamps
--- its lines with more than that supplies its own.
---@param raw string
---@return string? at
---@return string body
local function stamped(raw)
  local at, body = raw:match(TS)
  if not at then
    return nil, raw
  end
  return at, body
end

---@alias ci.log.Kind 'group'|'endgroup'|'error'|'warning'|'notice'|'debug'|'command'

--- github's markers, and Forgejo's spelling of them. A forge that writes
--- different ones says so itself.
---@param body string
---@return ci.log.Kind? kind
---@return string? rest the text the marker introduces, always its own tail
local function marked(body)
  if body:match('^##%[endgroup%]') or body:match('^::endgroup::') then
    return 'endgroup'
  end
  for _, name in ipairs({ 'group', 'error', 'warning', 'notice', 'debug' }) do
    local rest = M.marker(body, name)
    if rest then
      return name, --[[@as ci.log.Kind]]
        rest
    end
  end
  local command = body:match('^%[command%](.*)$')
  if command then
    return 'command', command
  end
  return nil
end

--- What the parse loop carries from one line to the next, so a log served in
--- pieces can be resumed where the last piece stopped.
---@class ci.log.Carry
---@field nest integer how many groups deep the text so far left the log
---@field heading boolean a bare group marker is still waiting for its header
---@field annot? ci.Hl the severity an unstamped run of lines is still under
---@field seen integer rows emitted by earlier calls

--- Splits a job log into rows. Lines are kept whole, with an offset marking
--- the stamp and the marker to conceal; steps come from the API rather than
--- the text, since a `run:` step logs its command, not its name.
---
--- {carry} resumes an earlier call. Steps are not carried: a forge that has
--- them serves no partial log, so the two never meet.
---@param text string
---@param steps ci.log.Step[]
---@param be? ci.Backend the forge whose log this is
---@param carry? ci.log.Carry
---@return ci.log.Row[]
---@return ci.log.Carry
function M.parse(text, steps, be, carry)
  local prefix = be and be.prefix or stamped
  local marks = be and be.marks or marked
  -- A step holds the first fold level on a forge that has steps; where one has
  -- none its groups take that level instead, and `]]` reaches them.
  local base = #steps > 0 and 1 or 0
  local seen = carry and carry.seen or 0

  --- The level {d} groups deep, opening a fold when {open}. Two is as deep as
  --- one goes, so a group nested below that joins the one above it.
  ---@param d integer
  ---@param open? boolean
  ---@return ci.log.Fold
  local function level(d, open)
    return ((open and '>%d' or '%d'):format(math.min(base + d, 2))) --[[@as ci.log.Fold]]
  end
  ---@type ci.log.Row[]
  local rows = {}
  local step_i, nest = 0, carry and carry.nest or 0
  --- Set by a group marker that carried no words of its own: the next line to
  --- be drawn is the heading, and heads the fold in the marker's place.
  local heading = carry and carry.heading or false
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
    nest = 0
    for _, si in ipairs(pending) do
      local s = steps[si]
      local sym, hl = status.of(s.status, s.conclusion)
      local stamp = s.at .. '.0000000Z '
      emit(('%s%s %s'):format(stamp, sym, s.name), '>1', hl, true, #stamp)
    end
    pending = {}
  end

  ---@type ci.Hl?
  local annot = carry and carry.annot or nil
  -- A log ends in a newline of its own, and a second would draw a line it does
  -- not have. One it genuinely ends on is still its own.
  if text ~= '' and text:sub(-1) ~= '\n' then
    text = text .. '\n'
  end
  for line in text:gmatch('([^\n]*)\n') do
    -- A runner that erases to end of line after a marker leaves the escape,
    -- the carriage return before it, and sometimes a note that it would like
    -- the section folded. None of the three means anything in a buffer, and a
    -- line without a carriage return carries none of them.
    local raw = line
    if raw:find('\r', 1, true) then
      raw = raw:gsub('%[collapsed=true%]\r\27%[0K$', ''):gsub('\r\27%[0K$', ''):gsub('\r$', '')
    end
    local at, body = prefix(raw)

    if at then
      while step_i < #steps and steps[step_i + 1].at <= at do
        step_i = step_i + 1
        pending[#pending + 1] = step_i
      end
    end

    local kind, rest = marks(body)

    if kind ~= 'endgroup' then
      flush()
    end

    local ts = #raw - #body

    -- A marker's body may run on for many lines, and only the first carries
    -- a timestamp. github.com bands the whole block, so the severity is held
    -- until a stamped line ends it.
    local here = level(nest)
    if at then
      annot = nil
    elseif annot then
      emit(raw, here, annot, nil, 0, nil, true)
      goto continue
    end

    if kind == 'endgroup' then
      heading = false
      nest = math.max(0, nest - 1)
    elseif kind == 'group' then
      nest = nest + 1
      if rest then
        emit(raw, level(nest, true), 'CiGroup', nil, ts + #body - #rest)
      else
        heading = true
      end
    elseif kind == 'error' then
      nest = 0
      annot = 'CiFail'
      emit(raw, level(0), 'CiFail', nil, ts + #body - #rest, 'Error: ')
    elseif kind == 'warning' then
      annot = 'CiAttention'
      emit(raw, here, 'CiAttention', nil, ts + #body - #rest, 'Warning: ')
    elseif kind == 'notice' then
      emit(raw, here, 'CiPending', nil, ts + #body - #rest, 'Notice: ')
    elseif kind == 'debug' then
      -- The marker stays. Every other one is concealed because a word takes
      -- its place; this one would leave nothing behind, and a colour alone
      -- cannot be relied on to say which lines were debugging output.
      emit(raw, here, 'CiDebug', nil, ts)
    elseif kind == 'command' then
      emit(raw, here, 'CiCommand', nil, ts + #body - #rest)
    elseif heading then
      heading = false
      emit(raw, level(nest, true), 'CiGroup', nil, ts)
    elseif body ~= '' or #rows + seen > 0 then
      emit(raw, here, nil, nil, ts)
    end
    ::continue::
  end

  flush()
  return rows, { nest = nest, heading = heading, annot = annot, seen = seen + #rows }
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
---@field step? boolean
---@field cont? boolean
---@field indent integer
---@field time? string

--- Lays the marks for one rendered line over {row}, which is zero-based.
---@param buf integer
---@param row integer
---@param m ci.log.Paint
---@param line string
local function decorate(buf, row, m, line)
  local prefix = math.min(m.conceal, #line)
  if prefix > 0 then
    api.nvim_buf_set_extmark(buf, ansi.ns, row, 0, { end_col = prefix, conceal = '' })
  end
  -- github.com draws a word where the marker is; the marker itself is
  -- concealed, so the word has to be virtual like the indent beside it.
  -- A band belongs to the message that carries a severity, not to
  -- everything wearing its colour. A step is named in the foreground, the
  -- way a passing one already is.
  local band = not m.step and BAND[m.hl] or nil
  local pre = {}
  if m.indent > 0 then
    pre[#pre + 1] = { ('  '):rep(m.indent), band }
  end
  if m.label then
    pre[#pre + 1] = { m.label, band and { band, m.hl, 'CiBold' } or m.hl }
  end
  if #pre > 0 and prefix < #line then
    api.nvim_buf_set_extmark(buf, ansi.ns, row, prefix, {
      virt_text = pre,
      virt_text_pos = 'inline',
    })
  end
  if band then
    -- Under the log's own colours, and out to the edge as on the web.
    api.nvim_buf_set_extmark(buf, ansi.ns, row, 0, {
      end_row = row + 1,
      hl_group = band,
      hl_eol = true,
      priority = 90,
    })
  elseif m.hl then
    api.nvim_buf_set_extmark(buf, ansi.ns, row, prefix, { end_row = row + 1, hl_group = m.hl })
  end
  ansi.apply(buf, row, m.spans, m.links, #line)
  for _, u in ipairs(m.urls) do
    api.nvim_buf_set_extmark(buf, ansi.ns, row, u[1], {
      end_col = u[2],
      hl_group = 'CiUrl',
      url = u[3],
    })
  end
end

--- Renders {rows} to lines and their marks, a chunk per tick, so a large log
--- does not block. {st} spans lines, and the reads that brought them.
---@param buf integer
---@param gen integer
---@param rows ci.log.Row[]
---@param st ci.ansi.State
---@param write fun(lines: string[], meta: ci.log.Paint[])
local function render(buf, gen, rows, st, write)
  local i = 1
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
        step = rows[k].step,
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
    write(lines, meta)
  end
  step()
end

---@param buf integer
---@return table<integer, boolean>
local function at_end(buf)
  local last = api.nvim_buf_line_count(buf)
  ---@type table<integer, boolean>
  local following = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    following[win] = api.nvim_win_get_cursor(win)[1] >= last
  end
  return following
end

--- Draws the whole log over whatever the buffer held, leaving {st} where the
--- last line ended it.
---@param buf integer
---@param gen integer
---@param rows ci.log.Row[]
---@param st ci.ansi.State
---@param done fun(following: table<integer, boolean>)
local function paint(buf, gen, rows, st, done)
  render(buf, gen, rows, st, function(lines, meta)
    -- How much of what is on screen the new render agrees with. A log only
    -- grows, so this is usually all of it, and the rest is an append.
    local existing = api.nvim_buf_get_lines(buf, 0, -1, false)
    local following = at_end(buf)

    local keep = 0
    while keep < #existing and keep < #lines and existing[keep + 1] == lines[keep + 1] do
      keep = keep + 1
    end
    if keep == #lines and keep == #existing then
      return done(following)
    end

    buf_util.set(buf, lines, keep)
    for k = keep + 1, #meta do
      decorate(buf, k - 1, meta[k], lines[k])
    end
    done(following)
  end)
end

--- Puts {rows} after everything the buffer holds. Nothing above is rewritten,
--- so its marks, its folds and any cursor not following the end all stand.
---@param buf integer
---@param gen integer
---@param rows ci.log.Row[]
---@param st ci.ansi.State
---@param done fun(following: table<integer, boolean>)
local function extend(buf, gen, rows, st, done)
  render(buf, gen, rows, st, function(lines, meta)
    local following = at_end(buf)
    if #lines == 0 then
      return done(following)
    end
    local at = buf_util.append(buf, lines)
    for k = 1, #meta do
      decorate(buf, at + k - 1, meta[k], lines[k])
    end
    done(following)
  end)
end

--- Holds a growing log open and keeps anyone already at the end there. A
--- fixed line is the wrong place to stand in a buffer that is still getting
--- longer. {open} lifts the folds that would hide the lines being waited for,
--- and belongs to the first sight of a running log: doing it on every read
--- would reopen every fold the reader has since closed.
---@param buf integer
---@param following table<integer, boolean>
---@param open? boolean
local function tail(buf, following, open)
  local last = api.nvim_buf_line_count(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    api.nvim_win_call(win, function()
      if open then
        vim.wo[win][0].foldlevel = 99
      end
      if following[win] then
        api.nvim_win_set_cursor(win, { last, 0 })
      end
    end)
  end
end

--- What a buffer following a growing log has to remember between reads: how
--- much of the trace it has drawn, and the state the parser and the ANSI
--- machine were left in by the last line of it.
---@class ci.log.Tail
---@field id integer
---@field repo? string
---@field be ci.Backend
---@field offset integer bytes of the trace already on screen
---@field carry ci.log.Carry
---@field st ci.ansi.State
---@field idle integer reads in a row that brought nothing
---@field due? integer uv time before which there is nothing worth asking for

---@type table<integer, ci.log.Tail>
local tails = {}

--- gitlab pushes a running job's log in bursts tens of seconds apart, so
--- reading every ten spends five requests to be told nothing. An empty read
--- widens the gap and the first byte closes it.
local TAIL_WAIT = 10000
local TAIL_MAX = 30000

--- Empty reads tolerated after the job stops. A trace that ends mid-line, or
--- without the runner's closing words, is otherwise read for as long as it is
--- open.
local TAIL_GRACE = 2

---@param idle integer
---@return integer
local function backoff(idle)
  return math.min(TAIL_WAIT * (idle + 1), TAIL_MAX)
end

--- How much of {s} is whole lines. Scans back over the last line only, so it
--- costs nothing on a trace that ends where it should.
---@param s string
---@return integer
local function whole(s)
  local cut = #s
  while cut > 0 and s:byte(cut) ~= 10 do
    cut = cut - 1
  end
  return cut
end

--- Whether {buf} is following a log its forge serves a piece at a time.
---@param buf integer
---@return boolean
function M.tailing(buf)
  return tails[buf] ~= nil
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
  local lines, marks = {}, {}
  for i, s in ipairs(job.steps or {}) do
    local sym, hl = status.of(s.status, s.conclusion)
    lines[i] = ('%s %s'):format(sym, s.name)
    marks[i] = hl
  end
  local sym, hl = status.of(job.status, job.conclusion)
  -- gitlab has no steps, and github serves none before a job starts, so the
  -- job's own state is all there is to say.
  if #lines == 0 then
    lines[1] = ('%s job is %s'):format(sym, job.conclusion or job.status or 'unknown')
    marks[1] = hl
  end
  buf_util.set(buf, lines)
  for i, mark in ipairs(marks) do
    api.nvim_buf_set_extmark(
      buf,
      ansi.ns,
      i - 1,
      0,
      { end_col = #tostring(lines[i]), hl_group = mark }
    )
  end
  -- A step is not a check, so it is not offered to <CR>; the flag is only
  -- here to tell the poll this buffer has not finished. One that has settled
  -- without a log will never have one.
  local bucket = status.bucket(job.status, job.conclusion)
  local waiting = bucket == 'running' or bucket == 'pending'
  vim.b[buf].ci = vim.tbl_extend('force', vim.b[buf].ci, { pending = waiting, loaded = true })
  if waiting then
    buf_util.watch(buf)
  end
end

---@param buf integer
---@param gen integer
---@param u ci.Uri
function M.render(buf, gen, u)
  local id = tonumber(u.id)
  if not id then
    return buf_util.fail(buf, ('malformed job id: %s'):format(u.id))
  end
  local reload = vim.b[buf].ci.loaded
  local showing = vim.b[buf].ci.times
  times(buf, false)

  ---@type ci.gh.Job?, string?, string?, boolean?
  local job, text, log_err, failed
  local function ready()
    if failed or not job or not text or not buf_util.current(buf, gen) then
      return
    end
    local be = forge.of(u.host)
    local steps = usable_steps(job.steps)
    -- A forge that serves a running job's log has to say when it stopped
    -- growing; GitHub never gets here until the job is over.
    local growing = be.finished ~= nil and not be.finished(text)
    -- Whether the rest of this log can be read a piece at a time. A forge
    -- with steps is left out: their positions come from the API rather than
    -- the text, and a parse resumed midway cannot place them.
    local piecemeal = growing and be.job_log_from ~= nil and #steps == 0
    -- The last line of a growing trace breaks off mid-line. Drawing that half
    -- would mean rewriting it once the rest arrived, which is the one thing an
    -- append cannot do, so it waits for the read that completes it.
    local drawn = piecemeal and text:sub(1, whole(text)) or text

    -- gitlab answers for a job that has not run with an empty 200 rather than
    -- an error, which leaves the same nothing a missing log does.
    if drawn == '' then
      return steplist(buf, job)
    end

    local rows, carry = M.parse(drawn, steps, be)
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
    if growing then
      vim.b[buf].ci = vim.tbl_extend('force', vim.b[buf].ci, { pending = true })
      buf_util.watch(buf)
    end
    ---@type ci.ansi.State
    local st = {}
    tails[buf] = piecemeal
        and {
          id = id,
          repo = u.repo,
          be = be,
          offset = #drawn,
          carry = carry,
          st = st,
          idle = 0,
        }
      or nil
    paint(buf, gen, rows, st, function(following)
      vim.b[buf].ci = vim.tbl_extend('force', vim.b[buf].ci, { loaded = true })
      times(buf, showing or false)
      -- A log still being written is read at its end, so it is left open and
      -- the cursor rides the last line for anyone already sitting there.
      if vim.tbl_get(vim.b[buf], 'ci', 'pending') then
        return tail(buf, following, not reload)
      end
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
    -- `completed` is github's word for it and no gitlab or Forgejo job carries
    -- it, so the bucket is asked rather than the spelling.
    local bucket = status.bucket(j.status, j.conclusion)
    if bucket == 'running' or bucket == 'pending' then
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

  forge.of(u.host).job(id, u.repo, function(data, err)
    if err then
      return fail(err)
    end
    job = data
    if buf_util.current(buf, gen) then
      local prev = vim.b[buf].ci or {}
      local sym, hl = status.of(job.status, job.conclusion)
      ---@type ci.BufVar
      vim.b[buf].ci = vim.tbl_extend('force', prev, {
        title = kept(job.name, prev.title),
        status = (job.status ~= nil and job.status ~= '') and status.paint(hl, sym)
          or kept(prev.status, status.paint(hl, sym)),
        group = kept(job.workflow_name, prev.group),
        url = kept(job.html_url, prev.url),
        run_id = job.run_id or prev.run_id,
        up = vim.b[buf].ci.up
          or (job.head_sha and ('ci://%s/%s/checks/%s'):format(u.host, u.repo, job.head_sha) or nil),
      })
    end
    if log_err then
      return settle(job, log_err)
    end
    ready()
  end)
  forge.of(u.host).job_log(id, u.repo, function(out, err)
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

--- Reads what the log grew by and puts it on the end, never asking twice for
--- bytes already drawn. A read that fails drops the tail state, leaving the
--- next poll to reload in full and report through the path that says it once.
---@param buf integer
function M.tail(buf)
  local t = tails[buf]
  local from = t and t.be.job_log_from
  if not t or not from then
    return
  end
  if t.due and vim.uv.now() < t.due then
    return
  end
  local gen = vim.tbl_get(vim.b[buf], 'ci', 'gen')
  vim.bo[buf].busy = 1

  ---@type ci.gh.Job?, string?, boolean
  local job, chunk, failed = nil, nil, false

  local function bail()
    failed = true
    tails[buf] = nil
    if api.nvim_buf_is_valid(buf) then
      vim.bo[buf].busy = 0
    end
  end

  local function ready()
    if failed or not job or not chunk or not buf_util.current(buf, gen) then
      return
    end
    local sym, hl = status.of(job.status, job.conclusion)
    vim.b[buf].ci = vim.tbl_extend('force', vim.b[buf].ci, { status = status.paint(hl, sym) })

    -- Only whole lines are drawn, so a read that brought half of one brought
    -- nothing, and the half is read again with the rest behind it.
    local grown = chunk:sub(1, whole(chunk))
    t.offset = t.offset + #grown
    t.idle = grown == '' and t.idle + 1 or 0
    t.due = vim.uv.now() + backoff(t.idle)

    local bucket = status.bucket(job.status, job.conclusion)
    local running = bucket == 'running' or bucket == 'pending'
    -- Where a job stopped without writing its closing words, its own state is
    -- the backstop.
    local closed = t.be.finished ~= nil and t.be.finished(grown)
    if closed or (not running and t.idle >= TAIL_GRACE) then
      tails[buf] = nil
      vim.b[buf].ci = vim.tbl_extend('force', vim.b[buf].ci, { pending = false })
    end

    if grown == '' then
      vim.bo[buf].busy = 0
      return
    end
    local rows, carry = M.parse(grown, {}, t.be, t.carry)
    t.carry = carry
    levels[buf], conceals[buf], stamps[buf] =
      levels[buf] or {}, conceals[buf] or {}, stamps[buf] or {}
    local at = #levels[buf]
    for i, r in ipairs(rows) do
      levels[buf][at + i] = r.fold
      conceals[buf][at + i] = r.conceal
      stamps[buf][at + i] = r.time
    end
    extend(buf, gen, rows, t.st, function(following)
      if vim.tbl_get(vim.b[buf], 'ci', 'times') then
        stamps_over(buf, at, at + #rows)
      end
      tail(buf, following)
    end)
  end

  t.be.job(t.id, t.repo, function(data, err)
    if err or not data then
      return bail()
    end
    job = data
    ready()
  end)
  from(t.id, t.offset, t.repo, function(out, err)
    if err then
      return bail()
    end
    chunk = out or ''
    ready()
  end)
end

---@param buf integer
function M.forget(buf)
  levels[buf] = nil
  conceals[buf] = nil
  stamps[buf] = nil
  tails[buf] = nil
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
    times(buf, not vim.b[buf].ci.times)
  end
end

return M
