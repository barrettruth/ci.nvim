local ansi = require('ci.ansi')
local buf_util = require('ci.buf')
local gh = require('ci.gh')
local status = require('ci.status')

local api = vim.api

local M = {}

local TS = '^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)%.%d+Z (.*)$'
local CHUNK = 1000

---@type table<integer, string[]>
local levels = {}

---@param lnum integer
---@return string
function M.fold(lnum)
  local l = levels[api.nvim_get_current_buf()]
  return l and l[lnum] or '0'
end

---@param steps table[]
---@return table[]
local function usable_steps(steps)
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
---@field fold string
---@field hl? string
---@field step? boolean

---@param text string
---@param steps table[]
---@return ci.log.Row[]
function M.parse(text, steps)
  local rows = {}
  local step_i, in_group = 0, false
  local pending = {}

  local function emit(line, fold, hl, step)
    rows[#rows + 1] = { text = line, fold = fold, hl = hl, step = step }
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

    local function flush()
      if #pending == 0 then
        return
      end
      in_group = false
      for _, si in ipairs(pending) do
        local s = steps[si]
        local sym, hl = status.of(s.status, s.conclusion)
        emit(('%s %s'):format(sym, s.name), '>1', hl, true)
      end
      pending = {}
    end

    if not endgroup then
      flush()
    end

    if endgroup then
      in_group = false
    elseif group then
      in_group = true
      emit(group, '>2', 'CiGroup')
    elseif err then
      in_group = false
      emit(err, '1', 'CiFail')
    elseif warn then
      emit(warn, in_group and '2' or '1', 'CiAttention')
    elseif notice then
      emit(notice, in_group and '2' or '1', 'CiPending')
    elseif body ~= '' or #rows > 0 then
      emit(body, in_group and '2' or '1')
    end
  end

  for _, si in ipairs(pending) do
    local s = steps[si]
    local sym, hl = status.of(s.status, s.conclusion)
    emit(('%s %s'):format(sym, s.name), '>1', hl, true)
  end

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

---@param buf integer
---@param gen integer
---@param rows ci.log.Row[]
---@param done fun()
local function paint(buf, gen, rows, done)
  local i, st = 1, {}
  local lines, meta = {}, {}
  local function step()
    if not buf_util.current(buf, gen) then
      return
    end
    local last = math.min(i + CHUNK - 1, #rows)
    for k = i, last do
      local text, spans, links = ansi.line(rows[k].text, st)
      lines[k] = text
      meta[k] = { spans, links, rows[k].hl }
    end
    i = last + 1
    if i <= #rows then
      return vim.schedule(step)
    end
    buf_util.set(buf, lines)
    for k, m in ipairs(meta) do
      if m[3] then
        api.nvim_buf_set_extmark(buf, ansi.ns, k - 1, 0, { end_row = k, hl_group = m[3] })
      end
      ansi.apply(buf, k - 1, m[1], m[2], #lines[k])
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
  buf_util.placeholder(buf, 'Loading job log...')

  local job, text, failed
  local function ready()
    if failed or not job or not text or not buf_util.current(buf, gen) then
      return
    end
    local sym, hl = status.of(job.status, job.conclusion)
    vim.b[buf].ci = {
      kind = 'job',
      title = job.name or '',
      status = sym,
      status_hl = hl,
      workflow = job.workflow_name or '',
      url = job.html_url,
      run_id = job.run_id,
    }
    local rows = M.parse(text, usable_steps(job.steps))
    levels[buf] = vim.tbl_map(function(r)
      return r.fold
    end, rows)
    paint(buf, gen, rows, function()
      local hit = first_failure(rows)
      if hit then
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          api.nvim_win_call(win, function()
            api.nvim_win_set_cursor(win, { hit, 0 })
            vim.cmd('normal! zv')
          end)
        end
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
end

return M
