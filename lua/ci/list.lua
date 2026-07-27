local ansi = require('ci.ansi')
local buf_util = require('ci.buf')
local gh = require('ci.gh')
local status = require('ci.status')

local api = vim.api

local M = {}

---@type table<integer, table<integer, ci.Check>>
local index = {}

---@param buf integer
---@param lnum integer
---@return ci.Check?
function M.at(buf, lnum)
  return (index[buf] or {})[lnum]
end

---@param buf integer
function M.forget(buf)
  index[buf] = nil
end

---@param a ci.Check
---@param b ci.Check
---@return boolean
local function order(a, b)
  local ra = status.rank[status.bucket(a.status, a.conclusion)]
  local rb = status.rank[status.bucket(b.status, b.conclusion)]
  if ra ~= rb then
    return ra < rb
  end
  return (a.name or '') < (b.name or '')
end

---@param buf integer
---@param gen integer
---@param repo string
---@param header string
---@param header_hl string
---@param checks ci.Check[]
local function paint(buf, gen, repo, header, header_hl, checks)
  if not buf_util.current(buf, gen) then
    return
  end
  table.sort(checks, order)

  local width = 0
  for _, c in ipairs(checks) do
    width = math.max(width, vim.fn.strdisplaywidth(c.name or ''))
  end
  width = math.min(width, 60)

  local lines, marks, map = { header, '' }, {}, {}
  for _, c in ipairs(checks) do
    local sym, hl = status.of(c.status, c.conclusion)
    local name = c.name or '?'
    local pad = math.max(0, width - vim.fn.strdisplaywidth(name))
    local suffix = c.workflow or (c.job_id and '' or 'external')
    local text = ('%s %s%s  %s'):format(sym, name, (' '):rep(pad), suffix)
    lines[#lines + 1] = (text:gsub('%s+$', ''))
    marks[#lines] = { hl, #sym, #suffix > 0 and #text - #suffix or nil }
    map[#lines] = c
  end
  if #checks == 0 then
    lines[#lines + 1] = 'No checks for this commit.'
  end

  buf_util.set(buf, lines)
  index[buf] = map
  api.nvim_buf_set_extmark(buf, ansi.ns, 0, 0, { end_row = 1, hl_group = header_hl })
  for lnum, m in pairs(marks) do
    api.nvim_buf_set_extmark(buf, ansi.ns, lnum - 1, 0, { end_col = m[2], hl_group = m[1] })
    if m[3] then
      api.nvim_buf_set_extmark(buf, ansi.ns, lnum - 1, m[3], {
        end_col = #lines[lnum],
        hl_group = 'CiMuted',
      })
    end
  end
  vim.b[buf].ci = {
    kind = 'list',
    repo = repo,
    title = header,
    status = '',
    status_hl = header_hl,
  }
end

---@param checks ci.Check[]
---@return string
---@return string
local function summarize(checks)
  local counts, total = {}, #checks
  for _, c in ipairs(checks) do
    local b = status.bucket(c.status, c.conclusion)
    counts[b] = (counts[b] or 0) + 1
  end
  local worst = 'pass'
  for _, b in ipairs({ 'fail', 'attention', 'running', 'pending', 'skipped' }) do
    if (counts[b] or 0) > 0 then
      worst = b
      break
    end
  end
  if total == 0 then
    worst = 'pending'
  end
  return status.summary(counts, total), status.hl[worst]
end

---@param buf integer
---@param gen integer
---@param repo string
---@param oid string
---@param label? string
local function from_rollup(buf, gen, repo, oid, label)
  gh.rollup(oid, repo, function(res, err)
    if err then
      return buf_util.fail(buf, err)
    end
    if not buf_util.current(buf, gen) then
      return
    end
    local text, hl = summarize(res.checks)
    local head = ('%s  %s  %s'):format(text, res.oid:sub(1, 8), label or res.headline or '')
    paint(buf, gen, res.repo or repo, (head:gsub('%s+$', '')), hl, res.checks)
  end)
end

---@param jobs table[]
---@return ci.Check[]
local function jobs_to_checks(jobs)
  local out = {}
  for _, j in ipairs(jobs) do
    out[#out + 1] = {
      name = j.name,
      status = j.status,
      conclusion = j.conclusion,
      url = j.html_url,
      job_id = j.id,
      run_id = j.run_id,
      workflow = j.workflow_name,
    }
  end
  return out
end

---@param buf integer
---@param gen integer
---@param u ci.Uri
function M.render(buf, gen, u)
  buf_util.placeholder(buf, 'Loading checks...')

  if u.kind == 'checks' then
    return from_rollup(buf, gen, u.repo, u.id)
  end

  if u.kind == 'pr' then
    local n = tonumber(u.id)
    if not n then
      return buf_util.fail(buf, ('malformed PR number: %s'):format(u.id))
    end
    return gh.pr_by_number(n, u.repo, function(pr, err)
      if err then
        return buf_util.fail(buf, err)
      end
      if not buf_util.current(buf, gen) then
        return
      end
      from_rollup(buf, gen, u.repo, pr.headRefOid, ('#%d %s'):format(pr.number, pr.title))
    end)
  end

  if u.kind == 'run' then
    local n = tonumber(u.id)
    if not n then
      return buf_util.fail(buf, ('malformed run id: %s'):format(u.id))
    end
    return gh.run_jobs(n, u.attempt, u.repo, function(jobs, err)
      if err then
        return buf_util.fail(buf, err)
      end
      if not buf_util.current(buf, gen) then
        return
      end
      local checks = jobs_to_checks(jobs)
      local text, hl = summarize(checks)
      local label = u.attempt and ('run %d (attempt %d)'):format(n, u.attempt)
        or ('run %d'):format(n)
      paint(buf, gen, u.repo, ('%s  %s'):format(text, label), hl, checks)
    end)
  end

  buf_util.fail(buf, ('unknown ci:// kind: %s'):format(u.kind))
end

return M
