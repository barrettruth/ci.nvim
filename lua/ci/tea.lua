local M = {}

--- How far back a pasted run URL is looked up. Its index within the repository
--- cannot be turned into the id the API answers to any other way.
local RUN_SCAN = 100

local GIT = 2000
local API = 10000
local LOG = 30000

--- Forgejo Actions is modelled on GitHub's, down to the words.
---@type ci.Nouns
M.nouns = { run = 'run', group = 'workflow', pr = 'pull request', ref = '#' }

--- Forgejo ignores `limit` unless `page` is given with it, and answers with
--- every row when it is not. Always ask for both.
---@param n integer
---@return string
local function paged(n)
  return ('page=1&limit=%d'):format(n)
end

--- Splits "owner/name", or yields tea's `{owner}`/`{repo}` placeholders, which
--- it expands from the remote the way `gh` does.
---@param repo? string
---@return string
local function slug(repo)
  local o, n = (repo or ''):match('^([^/]+)/([^/]+)$')
  return (o or '{owner}') .. '/' .. (n or '{repo}')
end

--- " on owner/name", or nothing at all where tea is resolving the repository
--- itself: its placeholders stand in for a name only tea knows, and a reader
--- shown `{owner}/{repo}` learns less than one shown nothing.
---@param repo? string
---@return string
local function where(repo)
  return (repo and repo ~= '') and (' on ' .. repo) or ''
end

---@param r vim.SystemCompleted
---@return string
local function errmsg(r)
  local s = vim.trim(r.stderr or '')
  if s == '' then
    s = vim.trim(r.stdout or '')
  end
  local ok, decoded = pcall(vim.json.decode, s)
  if ok and type(decoded) == 'table' and decoded.message then
    s = decoded.message
  end
  if s == '' then
    s = ('tea exited with code %d'):format(r.code)
  end
  return (s:gsub('%s+$', ''))
end

---@param path string
---@param on_done fun(out?: string, err?: string)
---@param timeout? integer
local function run(path, on_done, timeout)
  timeout = timeout or API
  return vim.system({ 'tea', 'api', path }, { text = true, timeout = timeout }, function(r)
    vim.schedule(function()
      if r.code == 124 then
        on_done(nil, ('tea did not answer within %ds'):format(timeout / 1000))
      elseif r.code ~= 0 then
        on_done(nil, errmsg(r))
      else
        on_done(r.stdout or '')
      end
    end)
  end)
end

--- tea exits 0 and prints Forgejo's error envelope to stdout, so a 404 reads
--- as a successful response unless the body is inspected.
---@param decoded any
---@return string? err
local function envelope_error(decoded)
  if type(decoded) == 'table' and type(decoded.message) == 'string' and decoded.url ~= nil then
    return decoded.message
  end
  return nil
end

---@param path string
---@param on_done fun(data?: any, err?: string)
local function api(path, on_done)
  return run(path, function(out, err)
    if err then
      return on_done(nil, err)
    end
    local ok, decoded = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
    if not ok or type(decoded) ~= 'table' then
      -- tea exits zero whatever came back, and not every failure arrives as
      -- Forgejo's error envelope: a request that never reached a repository
      -- answers in plain text. Say what it said.
      local said = vim.trim((out or ''):gsub('\n.*$', ''))
      return on_done(nil, said ~= '' and said or 'no response from tea')
    end
    local enveloped = envelope_error(decoded)
    if enveloped then
      return on_done(nil, enveloped)
    end
    on_done(decoded)
  end)
end

---@class ci.tea.Job
---@field id integer
---@field run_id integer
---@field name string
---@field status string
---@field attempt? integer
---@field task_id? integer

---@class ci.tea.Run
---@field id integer
---@field index_in_repo? integer
---@field title? string
---@field status string
---@field commit_sha? string
---@field workflow_id? string
---@field html_url? string

--- The concrete "owner/name" behind tea's placeholders. GraphQL hands `gh` a
--- `nameWithOwner` for free; here it costs a request, and only when the caller
--- had no repository to begin with.
---@param repo? string
---@param on_done fun(slug?: string, err?: string)
local function resolve_repo(repo, on_done)
  if repo and repo ~= '' then
    return on_done(repo)
  end
  api(('repos/%s'):format(slug(nil)), function(data, err)
    if err then
      return on_done(nil, err)
    end
    local full = data and data.full_name
    if not full then
      return on_done(nil, 'cannot resolve the repository from origin')
    end
    on_done(full)
  end)
end

---@param on_done fun(repo?: string, err?: string)
function M.repo(on_done)
  return resolve_repo(nil, on_done)
end

--- Forgejo has no server-side revision parsing, so a revision is only as
--- current as the last fetch.
---@param expr string
---@return string? sha
local function rev_parse(expr)
  local r = vim
    .system({ 'git', 'rev-parse', '--verify', '--quiet', expr }, { text = true })
    :wait(GIT)
  if r.code ~= 0 then
    return nil
  end
  local sha = vim.trim(r.stdout or '')
  return sha ~= '' and sha or nil
end

--- A job's browser page hangs off its run's, by position within that run
--- rather than by id: .../actions/runs/{index}/jobs/{n}/attempt/{a}.
---@param page? string the run's own html_url
---@param pos integer zero-based position within the run
---@param attempt? integer
---@return string? url
function M.job_page(page, pos, attempt)
  if not page then
    return nil
  end
  return ('%s/jobs/%d/attempt/%d'):format(page, pos, attempt or 1)
end

---@param jobs ci.tea.Job[]
---@param owner ci.tea.Run
---@return ci.Check[]
local function jobs_to_checks(jobs, owner)
  ---@type ci.Check[]
  local out = {}
  for i, j in ipairs(jobs) do
    out[#out + 1] = {
      name = j.name,
      status = j.status,
      job_id = j.id,
      run_id = j.run_id or owner.id,
      workflow = owner.workflow_id,
      url = M.job_page(owner.html_url, i - 1, j.attempt),
    }
  end
  return out
end

--- One request for the commit's runs, then one per run for its jobs. There is
--- no rollup to ask instead.
---@param sha string
---@param repo? string
---@param on_done fun(checks: ci.Check[], headline?: string)
local function checks_for_sha(sha, repo, on_done)
  local path = ('repos/%s/actions/runs?head_sha=%s&%s'):format(slug(repo), sha, paged(50))
  api(path, function(data, err)
    if err then
      return on_done({}, nil)
    end
    local runs = (data or {}).workflow_runs or {}
    if #runs == 0 then
      return on_done({}, nil)
    end
    ---@type ci.Check[]
    local acc = {}
    local headline = runs[1].title
    local left = #runs
    for _, r in ipairs(runs) do
      api(('repos/%s/actions/runs/%d/jobs'):format(slug(repo), r.id), function(jobs, e)
        if not e and type(jobs) == 'table' then
          vim.list_extend(acc, jobs_to_checks(jobs, r))
        end
        left = left - 1
        if left == 0 then
          on_done(acc, headline)
        end
      end)
    end
  end)
end

--- Commit statuses are a history, not a rollup: every transition a context
--- went through is listed, newest first, so only the first of each is kept.
--- Actions jobs publish a status too, and those are dropped: the jobs list
--- already has them, with an id the log endpoint accepts.
---@param sha string
---@param repo? string
---@param on_done fun(checks: ci.Check[])
local function statuses_for_sha(sha, repo, on_done)
  api(('repos/%s/commits/%s/statuses'):format(slug(repo), sha), function(data, err)
    if err or type(data) ~= 'table' then
      return on_done({})
    end
    ---@type ci.Check[], table<string, boolean>
    local out, seen = {}, {}
    for _, s in ipairs(data) do
      local url = s.target_url or ''
      local name = s.context or s.description or 'status'
      if not url:match('/actions/runs/%d+/jobs/%d+') and not seen[name] then
        seen[name] = true
        out[#out + 1] = {
          name = name,
          conclusion = s.status,
          url = url:match('^https?://') and url or nil,
        }
      end
    end
    on_done(out)
  end)
end

--- Actions runs and legacy commit statuses are separate on Forgejo, so the two
--- are fetched and concatenated into the list GitHub returns as one rollup.
---@param expr string
---@param repo? string
---@param on_done fun(res?: ci.gh.Rollup, err?: string)
function M.rollup(expr, repo, on_done)
  local sha = expr:match('^%x%x%x%x%x%x%x+$') or rev_parse(expr)
  if not sha then
    return on_done(nil, ('cannot resolve revision locally: %s'):format(expr))
  end
  resolve_repo(repo, function(full, rerr)
    if not full then
      return on_done(nil, rerr)
    end
    checks_for_sha(sha, full, function(checks, headline)
      statuses_for_sha(sha, full, function(extra)
        vim.list_extend(checks, extra)
        on_done({
          repo = full,
          oid = sha,
          headline = headline or '',
          state = nil,
          checks = checks,
        })
      end)
    end)
  end)
end

--- Open pull requests are listed and matched on head ref. Unlike `gh` there is
--- no base-repository resolution, so a fork is searched as itself.
---@param branch string
---@param repo? string
---@param on_done fun(pr?: ci.gh.BranchPr, err?: string)
function M.pr_for_branch(branch, repo, on_done)
  api(('repos/%s/pulls?state=open&%s'):format(slug(repo), paged(50)), function(data, err)
    if err then
      return on_done(nil, err)
    end
    for _, p in ipairs(data or {}) do
      if vim.tbl_get(p, 'head', 'ref') == branch then
        return on_done({
          number = p.number,
          title = p.title,
          headRefOid = vim.tbl_get(p, 'head', 'sha'),
          repo = vim.tbl_get(p, 'base', 'repo', 'full_name') or repo,
        })
      end
    end
    on_done(nil)
  end)
end

---@param number integer
---@param repo? string
---@param on_done fun(pr?: ci.gh.Pr, err?: string)
function M.pr_by_number(number, repo, on_done)
  api(('repos/%s/pulls/%d'):format(slug(repo), number), function(data, err)
    if err then
      return on_done(nil, err)
    end
    if not data or not data.number then
      return on_done(nil, ('no pull request #%d%s'):format(number, where(repo)))
    end
    on_done({
      number = data.number,
      title = data.title,
      headRefOid = vim.tbl_get(data, 'head', 'sha'),
    })
  end)
end

--- Forgejo exposes no single-job endpoint, only that job's log. Everything a
--- job buffer draws besides the log is therefore unavailable from a bare id.
---@param id integer
---@param _repo? string
---@param on_done fun(job?: ci.gh.Job, err?: string)
function M.job(id, _repo, on_done)
  vim.schedule(function()
    on_done({ id = id, run_id = 0, name = '' })
  end)
end

---@param id integer
---@param repo? string
---@param on_done fun(text?: string, err?: string)
function M.job_log(id, repo, on_done)
  return run(('repos/%s/actions/jobs/%d/logs'):format(slug(repo), id), function(out, err)
    if err then
      return on_done(nil, err)
    end
    local body = out:gsub('^\239\187\191', '')
    if body:match('^%s*{') then
      local ok, decoded = pcall(vim.json.decode, body)
      local enveloped = ok and envelope_error(decoded)
      if enveloped then
        return on_done(nil, enveloped)
      end
    end
    on_done(body)
  end, LOG)
end

--- A Forgejo runner closes every log with this, so its absence is the only
--- signal that a job is still writing.
---@param text string
---@return boolean
function M.finished(text)
  return text:match('\240\159\143\129%s+Job %a+') ~= nil
end

--- Forgejo keeps no per-attempt job list; a rerun replaces the jobs in place.
---@param id integer
---@param _attempt? integer
---@param repo? string
---@param on_done fun(jobs?: ci.gh.Job[], err?: string)
function M.run_jobs(id, _attempt, repo, on_done)
  api(('repos/%s/actions/runs/%d/jobs'):format(slug(repo), id), function(data, err)
    if err then
      return on_done(nil, err)
    end
    on_done(data or {})
  end)
end

--- A run carries the browser page ci.nvim cannot build itself: web URLs are
--- keyed on the repo-scoped index, not the id the API answers to.
---@param id integer
---@param repo? string
---@param on_done fun(run?: ci.tea.Run, err?: string)
function M.run(id, repo, on_done)
  api(('repos/%s/actions/runs/%d'):format(slug(repo), id), function(data, err)
    if err then
      return on_done(nil, err)
    end
    on_done(data)
  end)
end

--- Translates the repo-scoped index a Forgejo run URL carries into the global
--- id its API wants. Only recent runs are searched; an old URL will miss.
---@param index integer
---@param repo? string
---@param on_done fun(run?: ci.tea.Run, err?: string)
function M.run_by_index(index, repo, on_done)
  api(('repos/%s/actions/runs?%s'):format(slug(repo), paged(RUN_SCAN)), function(data, err)
    if err then
      return on_done(nil, err)
    end
    for _, r in ipairs((data or {}).workflow_runs or {}) do
      if r.index_in_repo == index then
        return on_done(r)
      end
    end
    on_done(nil, ('run %d is not among the last %d%s'):format(index, RUN_SCAN, where(repo)))
  end)
end

---@param file string
---@param repo? string
---@param on_done fun(run?: ci.gh.WorkflowRun, err?: string)
function M.latest_run(file, repo, on_done)
  local path = ('repos/%s/actions/runs?workflow_id=%s&%s'):format(slug(repo), file, paged(1))
  api(path, function(data, err)
    if err then
      return on_done(nil, err)
    end
    local latest = ((data or {}).workflow_runs or {})[1]
    if not latest then
      return on_done(nil, ('no runs for workflow %s'):format(file))
    end
    on_done(latest)
  end)
end

return M
