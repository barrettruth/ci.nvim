local ansi = require('ci.ansi')
local buf_util = require('ci.buf')
local gh = require('ci.gh')
local status = require('ci.status')

local api = vim.api

local M = {}

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

---@class ci.list.Mark
---@field hl ci.Hl.Bucket
---@field sym_end integer
---@field suffix_col? integer

---@param buf integer
---@param gen integer
---@param repo string
---@param summary string
---@param title string
---@param checks ci.Check[]
local function paint(buf, gen, repo, summary, title, checks)
  if not buf_util.current(buf, gen) then
    return
  end
  table.sort(checks, order)

  local width = 0
  for _, c in ipairs(checks) do
    width = math.max(width, vim.fn.strdisplaywidth(c.name or ''))
  end
  width = math.min(width, 60)

  ---@type string[], table<integer, ci.list.Mark>, table<integer, ci.Check>
  local lines, marks, map = {}, {}, {}
  for _, c in ipairs(checks) do
    local sym, hl = status.of(c.status, c.conclusion)
    local name = c.name or '?'
    local pad = math.max(0, width - vim.fn.strdisplaywidth(name))
    local suffix = c.workflow or (c.job_id and '' or 'external')
    local text = ('%s %s%s  %s'):format(sym, name, (' '):rep(pad), suffix)
    lines[#lines + 1] = (text:gsub('%s+$', ''))
    marks[#lines] = {
      hl = hl,
      sym_end = #sym,
      suffix_col = #suffix > 0 and #text - #suffix or nil,
    }
    map[#lines] = c
  end
  if #checks == 0 then
    lines[#lines + 1] = 'No checks for this commit.'
  end

  buf_util.set(buf, lines)
  for lnum, m in pairs(marks) do
    api.nvim_buf_set_extmark(buf, ansi.ns, lnum - 1, 0, { end_col = m.sym_end, hl_group = m.hl })
    if m.suffix_col then
      api.nvim_buf_set_extmark(buf, ansi.ns, lnum - 1, m.suffix_col, {
        end_col = #lines[lnum],
        hl_group = 'CiMuted',
      })
    end
  end
  ---@type ci.BufVar
  vim.b[buf].ci = vim.tbl_extend('force', vim.b[buf].ci, {
    repo = repo,
    status = summary,
    title = title,
    checks = map,
  })
  vim.b[buf].ci_loaded = true
end

---@param checks ci.Check[]
---@return string
local function summarize(checks)
  ---@type table<ci.Bucket, integer>
  local counts = {}
  for _, c in ipairs(checks) do
    local b = status.bucket(c.status, c.conclusion)
    counts[b] = (counts[b] or 0) + 1
  end
  return status.summary(counts, #checks)
end

---@param buf integer
---@param gen integer
---@param repo string
---@param oid string
---@param label? string
---@param url? string github.com page for this view; the commit's if omitted
local function from_rollup(buf, gen, repo, oid, label, url)
  gh.rollup(oid, repo, function(res, err)
    if not buf_util.current(buf, gen) then
      return
    end
    if err then
      return buf_util.fail(buf, err)
    end
    local text = summarize(res.checks)
    local head = label and ('%s  %s'):format(res.oid:sub(1, 8), label) or res.headline or ''
    paint(buf, gen, res.repo or repo, text, vim.trim(head), res.checks)
    vim.b[buf].ci = vim.tbl_extend('force', vim.b[buf].ci, {
      url = url or ('https://github.com/%s/commit/%s/checks'):format(res.repo or repo, res.oid),
    })
  end)
end

---@param jobs ci.gh.Job[]
---@return ci.Check[]
local function jobs_to_checks(jobs)
  ---@type ci.Check[]
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
  if u.kind == 'checks' then
    return from_rollup(buf, gen, u.repo, u.id)
  end

  if u.kind == 'pr' then
    local n = tonumber(u.id)
    if not n then
      return buf_util.fail(buf, ('malformed PR number: %s'):format(u.id))
    end
    return gh.pr_by_number(n, u.repo, function(pr, err)
      if not buf_util.current(buf, gen) then
        return
      end
      if err then
        return buf_util.fail(buf, err)
      end
      from_rollup(
        buf,
        gen,
        u.repo,
        pr.headRefOid,
        pr.title,
        ('https://github.com/%s/pull/%d/checks'):format(u.repo, pr.number)
      )
    end)
  end

  if u.kind == 'run' then
    local n = tonumber(u.id)
    if not n then
      return buf_util.fail(buf, ('malformed run id: %s'):format(u.id))
    end
    return gh.run_jobs(n, u.attempt, u.repo, function(jobs, err)
      if not buf_util.current(buf, gen) then
        return
      end
      if err then
        return buf_util.fail(buf, err)
      end
      local checks = jobs_to_checks(jobs)
      local text = summarize(checks)
      local label = u.attempt and ('run %d (attempt %d)'):format(n, u.attempt)
        or ('run %d'):format(n)
      paint(buf, gen, u.repo, text, label, checks)
      local sha = jobs[1] and jobs[1].head_sha
      local page = ('https://github.com/%s/actions/runs/%d'):format(u.repo, n)
      vim.b[buf].ci = vim.tbl_extend('force', vim.b[buf].ci, {
        url = u.attempt and ('%s/attempts/%d'):format(page, u.attempt) or page,
        up = sha and ('ci://%s/checks/%s'):format(u.repo, sha) or nil,
      })
    end)
  end

  buf_util.fail(buf, ('unknown ci:// kind: %s'):format(u.kind))
end

return M
