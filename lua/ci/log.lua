local ansi = require('ci.ansi')
local buf_util = require('ci.buf')
local gh = require('ci.gh')
local status = require('ci.status')

local api = vim.api

local M = {}

local TS = '^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)%.%d+Z (.*)$'
local CHUNK = 1000
local DATE, TIME, FRAC = 11, 19, 28

---@alias ci.log.Fold '0'|'1'|'2'|'>1'|'>2'

---@type table<integer, ci.log.Fold[]>
local levels = {}

---@type table<integer, integer[]>
local conceals = {}

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
---@field ts integer
---@field mark integer

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
  local function emit(line, fold, hl, step, ts, mark)
    rows[#rows + 1] =
      { text = line, fold = fold, hl = hl, step = step, ts = ts or 0, mark = mark or 0 }
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

    if endgroup then
      in_group = false
    elseif group then
      in_group = true
      emit(raw, '>2', 'CiGroup', nil, ts, #body - #group)
    elseif err then
      in_group = false
      emit(raw, '1', 'CiFail', nil, ts, #body - #err)
    elseif warn then
      emit(raw, in_group and '2' or '1', 'CiAttention', nil, ts, #body - #warn)
    elseif notice then
      emit(raw, in_group and '2' or '1', 'CiPending', nil, ts, #body - #notice)
    elseif command then
      emit(raw, in_group and '2' or '1', 'CiCommand', nil, ts, #body - #command)
    elseif body ~= '' or #rows > 0 then
      emit(raw, in_group and '2' or '1', nil, nil, ts)
    end
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
---@field ts integer
---@field mark integer

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
        ts = rows[k].ts,
        mark = rows[k].mark,
      }
    end
    i = last + 1
    if i <= #rows then
      return vim.schedule(step)
    end
    buf_util.set(buf, lines)
    for k, m in ipairs(meta) do
      local width = #lines[k]
      local function hide(from, to)
        if width > from then
          api.nvim_buf_set_extmark(buf, ansi.ns, k - 1, from, {
            end_col = math.min(to, width),
            conceal = '',
          })
        end
      end
      if m.ts > 0 then
        hide(0, DATE)
        hide(TIME, FRAC)
        api.nvim_buf_set_extmark(buf, ansi.ns, k - 1, DATE, {
          end_col = math.min(TIME, width),
          hl_group = 'CiMuted',
        })
      end
      if m.mark > 0 then
        hide(m.ts, m.ts + m.mark)
      end
      if m.hl then
        api.nvim_buf_set_extmark(buf, ansi.ns, k - 1, math.min(m.ts + m.mark, width), {
          end_row = k,
          hl_group = m.hl,
        })
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

---@param buf integer
---@param gen integer
---@param u ci.Uri
function M.render(buf, gen, u)
  local id = tonumber(u.id)
  if not id then
    return buf_util.fail(buf, ('malformed job id: %s'):format(u.id))
  end
  local reload = vim.b[buf].ci_loaded

  ---@type ci.gh.Job?, string?, boolean?
  local job, text, failed
  local function ready()
    if failed or not job or not text or not buf_util.current(buf, gen) then
      return
    end
    local sym, hl = status.of(job.status, job.conclusion)
    ---@type ci.BufVar
    vim.b[buf].ci = vim.tbl_extend('force', vim.b[buf].ci, {
      title = job.name or '',
      status = sym,
      status_hl = hl,
      workflow = job.workflow_name or '',
      url = job.html_url or '',
      run_id = job.run_id or 0,
      up = job.run_id and ('ci://%s/run/%d'):format(u.repo, job.run_id) or nil,
    })
    local rows = M.parse(text, usable_steps(job.steps))
    levels[buf] = vim.tbl_map(function(r)
      return r.fold
    end, rows)
    conceals[buf] = vim.tbl_map(function(r)
      return r.ts + r.mark
    end, rows)
    paint(buf, gen, rows, function()
      vim.b[buf].ci_loaded = true
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
    ready()
  end)
  gh.job_log(id, u.repo, function(out, err)
    if err then
      return fail(err)
    end
    text = out
    ready()
  end)
end

---@param buf integer
function M.forget(buf)
  levels[buf] = nil
  conceals[buf] = nil
end

return M
