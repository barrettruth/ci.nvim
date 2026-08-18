local M = {}

local API = 10000
local GIT = 2000
local LOG = 30000

---@type ci.Nouns
M.nouns = { run = 'pipeline', group = 'stage' }

--- A stamped log line is a timestamp, two hex flags, the stream it came from,
--- and a space, or a plus where the line continues one already begun.
local TS = '^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)%.%d+Z %x%x[OE][ +](.*)$'

---@param raw string
---@return string? at
---@return string body
function M.prefix(raw)
  local at, body = raw:match(TS)
  if not at then
    return nil, raw
  end
  return at, body
end

--- A runner closes every log with one of these, so their absence is the only
--- signal that a job is still writing.
---@param text string
---@return boolean
function M.finished(text)
  return text:match('Job succeeded') ~= nil or text:match('ERROR: Job failed') ~= nil
end

---@param s string
---@return string
local function enc(s)
  return (s:gsub('[^%w%-%._~]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

--- A project is addressed by its full path with every slash escaped, or by
--- glab's own placeholder for whatever the remote points at.
---@param repo? string
---@return string
local function project(repo)
  if not repo or repo == '' then
    return ':fullpath'
  end
  return enc(repo)
end

--- What gitlab said, if {s} is one of its error envelopes.
---@param s string
---@return string?
local function said(s)
  local ok, decoded = pcall(vim.json.decode, s)
  if not ok or type(decoded) ~= 'table' then
    return nil
  end
  if type(decoded.message) == 'string' then
    return decoded.message
  end
  return type(decoded.error) == 'string' and decoded.error or nil
end

--- `glab api` writes gitlab's response to stdout and its own
--- "glab: … (HTTP 404)" line to stderr, so the body is read first: it is the
--- same sentence without the prefix.
---@param r vim.SystemCompleted
---@return string
local function errmsg(r)
  local out, err = vim.trim(r.stdout or ''), vim.trim(r.stderr or '')
  local s = said(out) or said(err) or (err ~= '' and err or out)
  if s == '' then
    s = ('glab exited with code %d'):format(r.code)
  end
  return (s:gsub('%s+$', ''))
end

---@param args string[]
---@param on_done fun(out?: string, err?: string)
---@param timeout? integer
local function run(args, on_done, timeout)
  timeout = timeout or API
  local opts = { text = true, timeout = timeout }
  return vim.system(vim.list_extend({ 'glab' }, args), opts, function(r)
    vim.schedule(function()
      if r.code == 124 then
        on_done(nil, ('glab did not answer within %ds'):format(timeout / 1000))
      elseif r.code ~= 0 then
        on_done(nil, errmsg(r))
      else
        on_done(r.stdout or '')
      end
    end)
  end)
end

---@generic T
---@param path string
---@param on_done fun(data?: T, err?: string)
local function api(path, on_done)
  return run({ 'api', path }, function(out, err)
    if err then
      return on_done(nil, err)
    end
    local ok, decoded = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
    if not ok or type(decoded) ~= 'table' then
      return on_done(nil, 'malformed JSON from glab')
    end
    on_done(decoded)
  end)
end

--- The project's full path. A `ci://` name has to spell it out, and glab's
--- placeholder resolves without ever saying what it resolved to.
---@param repo? string
---@param on_done fun(path?: string, err?: string)
local function resolve(repo, on_done)
  if repo and repo ~= '' then
    return on_done(repo)
  end
  api('projects/:fullpath', function(data, err)
    if err then
      return on_done(nil, err)
    end
    on_done(data.path_with_namespace)
  end)
end

--- gitlab resolves a branch, a tag or a sha, and no other revision, so HEAD is
--- answered here before it is asked for.
---@param expr string
---@return string
local function revision(expr)
  local rev = (expr:gsub('%^{commit}$', ''))
  if rev ~= 'HEAD' then
    return rev
  end
  local r = vim.system({ 'git', 'rev-parse', 'HEAD' }, { text = true }):wait(GIT)
  local sha = r.code == 0 and vim.trim(r.stdout or '') or ''
  return sha ~= '' and sha or rev
end

---@class ci.glab.Status
---@field id integer
---@field name string
---@field status ci.gitlab.Status
---@field allow_failure? boolean
---@field pipeline_id? integer
---@field target_url? string
---@field started_at? string

--- gitlab keeps one field where ci.nvim keeps two: how far a job got, and how
--- it ended. Only a job that has ended has a conclusion, and one told it may
--- fail ends as a warning rather than as a failure.
---@param s { status: string, allow_failure?: boolean }
---@return ci.Conclusion?
local function conclusion(s)
  if s.status == 'failed' then
    return s.allow_failure and 'warning' or 'failure'
  end
  if s.status == 'success' then
    return 'success'
  end
  if s.status == 'canceled' then
    return 'cancelled'
  end
  if s.status == 'skipped' then
    return 'skipped'
  end
  return nil
end

---@param rows? ci.glab.Status[]
---@return ci.Check[]
local function to_checks(rows)
  ---@type ci.Check[]
  local out = {}
  for _, s in ipairs(rows or {}) do
    out[#out + 1] = {
      name = s.name,
      status = s.status,
      conclusion = conclusion(s),
      url = s.target_url,
      job_id = s.id,
      run_id = s.pipeline_id,
      started_at = s.started_at,
    }
  end
  return out
end

--- A commit's statuses are its jobs plus anything posted from outside, which
--- is the same set github rolls up. They carry no stage, so a checks list
--- names no group where a pipeline's own job list does.
---@param expr string
---@param repo? string
---@param on_done fun(res?: ci.gh.Rollup, err?: string)
function M.rollup(expr, repo, on_done)
  resolve(repo, function(path, err)
    if err then
      return on_done(nil, err)
    end
    local p = project(path)
    api(('projects/%s/repository/commits/%s'):format(p, enc(revision(expr))), function(commit, e)
      if e then
        return on_done(nil, e)
      end
      local at = ('projects/%s/repository/commits/%s/statuses?per_page=100'):format(p, commit.id)
      api(at, function(rows, e2)
        if e2 then
          return on_done(nil, e2)
        end
        on_done({
          repo = path,
          oid = commit.id,
          headline = commit.title,
          checks = to_checks(rows),
        })
      end)
    end)
  end)
end

---@class ci.glab.Mr
---@field iid integer
---@field title string
---@field sha string
---@field target_project_id integer
---@field head_pipeline? { id: integer, sha: string, project_id: integer }

--- A merge request opened from a fork runs its pipeline on the fork, against a
--- merged result whose sha is not the branch head, so both the commit to roll
--- up and the project to roll it up in come from the pipeline.
---@param mr ci.glab.Mr
---@param on_done fun(pr?: ci.gh.Pr, err?: string)
local function to_pr(mr, on_done)
  local pipeline = mr.head_pipeline
  ---@type ci.gh.Pr
  local pr = {
    number = mr.iid,
    title = mr.title,
    headRefOid = (pipeline and pipeline.sha) or mr.sha,
  }
  if not pipeline or pipeline.project_id == mr.target_project_id then
    return on_done(pr)
  end
  api(('projects/%d'):format(pipeline.project_id), function(proj, err)
    if err then
      return on_done(nil, err)
    end
    pr.repo = proj.path_with_namespace
    on_done(pr)
  end)
end

---@param branch string
---@param repo? string
---@param on_done fun(pr?: ci.gh.BranchPr, err?: string)
function M.pr_for_branch(branch, repo, on_done)
  resolve(repo, function(path, err)
    if err then
      return on_done(nil, err)
    end
    local at = ('projects/%s/merge_requests?state=opened&source_branch=%s&order_by=updated_at'):format(
      project(path),
      enc(branch)
    )
    api(at, function(rows, e)
      if e then
        return on_done(nil, e)
      end
      local mr = (rows or {})[1]
      if not mr then
        return on_done(nil)
      end
      to_pr(mr, function(pr, e2)
        if not pr then
          return on_done(nil, e2)
        end
        pr.repo = pr.repo or path
        on_done(pr --[[@as ci.gh.BranchPr]])
      end)
    end)
  end)
end

---@param number integer
---@param repo? string
---@param on_done fun(pr?: ci.gh.Pr, err?: string)
function M.pr_by_number(number, repo, on_done)
  api(('projects/%s/merge_requests/%d'):format(project(repo), number), function(mr, err)
    if err then
      return on_done(nil, err)
    end
    to_pr(mr, on_done)
  end)
end

---@class ci.glab.Job
---@field id integer
---@field name string
---@field stage string
---@field status ci.gitlab.Status
---@field allow_failure? boolean
---@field web_url? string
---@field pipeline? { id: integer, sha: string }

--- The shared job shape is github's, so a stage travels in the field a
--- workflow name would. A gitlab job has no steps of its own.
---@param j ci.glab.Job
---@return ci.gh.Job
local function to_job(j)
  return {
    id = j.id,
    run_id = j.pipeline and j.pipeline.id,
    head_sha = j.pipeline and j.pipeline.sha,
    name = j.name,
    status = j.status,
    conclusion = conclusion(j),
    html_url = j.web_url,
    workflow_name = j.stage,
  }
end

---@param id integer
---@param repo? string
---@param on_done fun(job?: ci.gh.Job, err?: string)
function M.job(id, repo, on_done)
  api(('projects/%s/jobs/%d'):format(project(repo), id), function(data, err)
    if err then
      return on_done(nil, err)
    end
    on_done(to_job(data))
  end)
end

---@param id integer
---@param repo? string
---@param on_done fun(text?: string, err?: string)
function M.job_log(id, repo, on_done)
  local at = ('projects/%s/jobs/%d/trace'):format(project(repo), id)
  return run({ 'api', at }, function(out, err)
    if err then
      return on_done(nil, err)
    end
    on_done(out)
  end, LOG)
end

--- gitlab answers newest first and gives a stage no index of its own, so the
--- order jobs were created in is the only thing that puts the stages back in
--- the order they ran.
---@param id integer
---@param _attempt? integer a pipeline is retried in place and keeps no attempts
---@param repo? string
---@param on_done fun(jobs?: ci.gh.Job[], err?: string)
function M.run_jobs(id, _attempt, repo, on_done)
  local at = ('projects/%s/pipelines/%d/jobs?per_page=100'):format(project(repo), id)
  api(at, function(rows, err)
    if err then
      return on_done(nil, err)
    end
    ---@type ci.glab.Job[]
    local jobs = rows or {}
    table.sort(jobs, function(a, b)
      return a.id < b.id
    end)
    on_done(vim.tbl_map(to_job, jobs))
  end)
end

--- gitlab retries the failed and canceled jobs of a pipeline and nothing else,
--- and has no effect at all where there are none. Cancelling answers 200
--- whatever state the pipeline is in, so a second ask cannot force it.
---@param id integer
---@param what ci.gh.Act
---@param repo? string
---@param on_done fun(err?: string)
function M.act(id, what, repo, on_done)
  local verb = (what == 'cancel' or what == 'force-cancel') and 'cancel' or 'retry'
  local at = ('projects/%s/pipelines/%d/%s'):format(project(repo), id, verb)
  return run({ 'api', '--method', 'POST', at }, function(_, err)
    on_done(err)
  end)
end

return M
