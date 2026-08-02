local ansi = require('ci.ansi')
local buf_util = require('ci.buf')
local forge = require('ci.forge')
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
  local existing = api.nvim_buf_get_lines(buf, 0, -1, false)
  local keep = 0
  while keep < #existing and keep < #lines and existing[keep + 1] == lines[keep + 1] do
    keep = keep + 1
  end

  buf_util.set(buf, lines, keep)
  for lnum, m in pairs(marks) do
    if lnum > keep then
      api.nvim_buf_set_extmark(buf, ansi.ns, lnum - 1, 0, { end_col = m.sym_end, hl_group = m.hl })
      if m.suffix_col then
        api.nvim_buf_set_extmark(buf, ansi.ns, lnum - 1, m.suffix_col, {
          end_col = #lines[lnum],
          hl_group = 'CiMuted',
        })
      end
    end
  end
  ---@type ci.BufVar
  vim.b[buf].ci = vim.tbl_extend('force', vim.b[buf].ci, {
    repo = repo,
    status = summary,
    title = title,
    checks = map,
    pending = #checks == 0,
  })
  vim.b[buf].ci_loaded = true
  buf_util.watch(buf)
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
---@param host string
---@param url? string forge page for this view; the commit's if omitted
local function from_rollup(buf, gen, repo, oid, label, url, host)
  forge.of(host).rollup(oid, repo, function(res, err)
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
      url = url or forge.web(host, res.repo or repo, 'checks', res.oid),
    })
  end)
end

---@param jobs ci.gh.Job[]
---@param page? string the run's browser page, where jobs are named by position
---@return ci.Check[]
local function jobs_to_checks(jobs, page)
  ---@type ci.Check[]
  local out = {}
  for i, j in ipairs(jobs) do
    out[#out + 1] = {
      name = j.name,
      status = j.status,
      conclusion = j.conclusion,
      url = j.html_url or require('ci.tea').job_page(page, i - 1, j.attempt),
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
    return from_rollup(buf, gen, u.repo, u.id, nil, nil, u.host)
  end

  if u.kind == 'pr' then
    local n = tonumber(u.id)
    if not n then
      return buf_util.fail(buf, ('malformed PR number: %s'):format(u.id))
    end
    return forge.of(u.host).pr_by_number(n, u.repo, function(pr, err)
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
        forge.web(u.host, u.repo, 'pr', pr.number),
        u.host
      )
    end)
  end

  if u.kind == 'run' then
    local n = tonumber(u.id)
    if not n then
      return buf_util.fail(buf, ('malformed run id: %s'):format(u.id))
    end
    local be = forge.of(u.host)
    -- Forgejo keys its run page on a different id than its API, and its job
    -- pages hang off that page, so it is fetched before the jobs are drawn.
    local function draw(page)
      be.run_jobs(n, u.attempt, u.repo, function(jobs, err)
        if not buf_util.current(buf, gen) then
          return
        end
        if err then
          return buf_util.fail(buf, err)
        end
        local checks = jobs_to_checks(jobs, page)
        local text = summarize(checks)
        local label = u.attempt and ('run %d (attempt %d)'):format(n, u.attempt)
          or ('run %d'):format(n)
        paint(buf, gen, u.repo, text, label, checks)
        local sha = jobs[1] and jobs[1].head_sha
        vim.b[buf].ci = vim.tbl_extend('force', vim.b[buf].ci, {
          url = page or forge.web(u.host, u.repo, 'run', n, u.attempt),
          up = sha and ('ci://%s/%s/checks/%s'):format(u.host, u.repo, sha) or nil,
        })
      end)
    end
    if be.run then
      return be.run(n, u.repo, function(r)
        draw(r and r.html_url or nil)
      end)
    end
    return draw(nil)
  end

  buf_util.fail(buf, ('unknown ci:// kind: %s'):format(u.kind))
end

return M
