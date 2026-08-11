local M = {}

local API = 10000
local LOG = 30000
local VERSION = 2000

--- gh 2.97 stopped printing a response that carries terminal escape sequences
--- unless asked to, and a job's log is nothing but. Older gh has no such flag
--- to give, so which one is installed decides whether it is passed.
---@type boolean?
local escapes_supported

---@return boolean
local function escapes_allowed()
  if escapes_supported == nil then
    local r = vim.system({ 'gh', '--version' }, { text = true }):wait(VERSION)
    local v = vim.version.parse(r.stdout or '', { strict = false })
    escapes_supported = v ~= nil and vim.version.ge(v, { 2, 97, 0 })
  end
  return escapes_supported
end

--- Splits "owner/name", or yields gh's `{owner}`/`{repo}` placeholders. Those
--- expand to the *base* repository, which is where a fork's checks live.
---@param repo? string
---@return string owner
---@return string name
local function owner_name(repo)
  local o, n = (repo or ''):match('^([^/]+)/([^/]+)$')
  return o or '{owner}', n or '{repo}'
end

---@param repo? string
---@return string
local function slug(repo)
  local o, n = owner_name(repo)
  return o .. '/' .. n
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
    s = ('gh exited with code %d'):format(r.code)
  end
  return (s:gsub('%s+$', ''))
end

---@param args string[]
---@param on_done fun(out?: string, err?: string)
---@param timeout? integer
local function run(args, on_done, timeout)
  timeout = timeout or API
  local opts = { text = true, timeout = timeout }
  return vim.system(vim.list_extend({ 'gh' }, args), opts, function(r)
    vim.schedule(function()
      if r.code == 124 then
        on_done(nil, ('gh did not answer within %ds'):format(timeout / 1000))
      elseif r.code ~= 0 then
        on_done(nil, errmsg(r))
      else
        on_done(r.stdout or '')
      end
    end)
  end)
end

---@generic T
---@param args string[]
---@param on_done fun(data?: T, err?: string)
local function api(args, on_done)
  return run(vim.list_extend({ 'api' }, args), function(out, err)
    if err then
      return on_done(nil, err)
    end
    local ok, decoded = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
    if not ok or type(decoded) ~= 'table' then
      return on_done(nil, 'malformed JSON from gh')
    end
    on_done(decoded)
  end)
end

---@generic T
---@param query string
---@param vars table<string, string|integer>
---@param repo? string
---@param on_done fun(data?: T, err?: string)
local function graphql(query, vars, repo, on_done)
  local owner, name = owner_name(repo)
  local args = { 'graphql', '-F', 'owner=' .. owner, '-F', 'repo=' .. name }
  for k, v in pairs(vars) do
    args[#args + 1] = type(v) == 'number' and '-F' or '-f'
    args[#args + 1] = k .. '=' .. tostring(v)
  end
  args[#args + 1] = '-f'
  args[#args + 1] = 'query=' .. query
  return api(args, function(data, err)
    if err then
      return on_done(nil, err)
    end
    if data.errors and data.errors[1] then
      return on_done(nil, data.errors[1].message or 'GraphQL error')
    end
    on_done(data.data)
  end)
end

--- A revision and its checks in one request: the commit it resolves to, the
--- rollup state, and every context, Actions or otherwise. `databaseId` on a
--- CheckRun is the Actions job id, which is what the log endpoint takes.
local CHECKS_FOR_REV = [[
query($owner:String!,$repo:String!,$expr:String!){
  repository(owner:$owner,name:$repo){
    nameWithOwner
    object(expression:$expr){
      ... on Commit{
        oid
        messageHeadline
        statusCheckRollup{
          state
          contexts(first:100){
            totalCount
            nodes{
              __typename
              ... on CheckRun{
                name status conclusion detailsUrl databaseId startedAt
                checkSuite{ workflowRun{ databaseId workflow{ name } } }
              }
              ... on StatusContext{ context state targetUrl description }
            }
          }
        }
      }
    }
  }
}]]

---@class ci.gh.CheckRunNode
---@field __typename 'CheckRun'
---@field name string
---@field status ci.gql.Status
---@field conclusion? ci.gql.Conclusion
---@field detailsUrl string
---@field databaseId? integer
---@field startedAt? string
---@field checkSuite? { workflowRun?: { workflow?: { name: string } } }

---@class ci.gh.StatusContextNode
---@field __typename 'StatusContext'
---@field context string
---@field state ci.gql.Conclusion
---@field targetUrl? string

---@alias ci.gh.RollupNode ci.gh.CheckRunNode|ci.gh.StatusContextNode

---@class ci.Check
---@field name string
---@field status? ci.Status
---@field conclusion? ci.Conclusion
---@field url? string
---@field job_id? integer
---@field run_id? integer
---@field workflow? string
---@field started_at? string

--- Flattens rollup contexts, keeping the newest of each (workflow, name): a
--- rerun leaves the superseded attempt in the rollup.
---@param nodes? ci.gh.RollupNode[]
---@return ci.Check[]
local function to_checks(nodes)
  ---@type ci.Check[], table<string, integer>
  local out, seen = {}, {}
  for _, n in ipairs(nodes or {}) do
    ---@type ci.Check?
    local c
    if n.__typename == 'CheckRun' then
      local run_id, job_id = (n.detailsUrl or ''):match('/actions/runs/(%d+)/job/(%d+)')
      c = {
        name = n.name,
        status = n.status,
        conclusion = n.conclusion,
        url = n.detailsUrl,
        job_id = tonumber(job_id) or n.databaseId,
        run_id = tonumber(run_id),
        workflow = vim.tbl_get(n, 'checkSuite', 'workflowRun', 'workflow', 'name'),
        started_at = n.startedAt,
      }
    elseif n.__typename == 'StatusContext' then
      c = { name = n.context, conclusion = n.state, url = n.targetUrl }
    end
    if c then
      local key = (c.workflow or '') .. '\0' .. c.name
      local prev = seen[key]
      if not prev then
        out[#out + 1] = c
        seen[key] = #out
      elseif (c.started_at or '') >= (out[prev].started_at or '') then
        out[prev] = c
      end
    end
  end
  return out
end

---@class ci.gh.Rollup
---@field repo? string
---@field oid string
---@field headline string
---@field state? ci.gql.Conclusion
---@field checks ci.Check[]

--- Resolves a git revision and its checks in one request. {expr} is evaluated
--- by GitHub, so it sees the remote's refs rather than whatever was last
--- fetched.
---@param expr string
---@param repo? string
---@param on_done fun(res?: ci.gh.Rollup, err?: string)
function M.rollup(expr, repo, on_done)
  return graphql(CHECKS_FOR_REV, { expr = expr }, repo, function(data, err)
    if err then
      return on_done(nil, err)
    end
    local obj = vim.tbl_get(data or {}, 'repository', 'object')
    if not obj or not obj.oid then
      return on_done(nil, ('no such revision on %s: %s'):format(slug(repo), expr))
    end
    local rollup = obj.statusCheckRollup
    on_done({
      repo = vim.tbl_get(data, 'repository', 'nameWithOwner'),
      oid = obj.oid,
      headline = obj.messageHeadline,
      state = rollup and rollup.state or nil,
      checks = to_checks(rollup and rollup.contexts and rollup.contexts.nodes),
    })
  end)
end

--- Open PRs with this head branch, plus the viewer, so a fork PR can be told
--- from a stranger's PR that happens to share the branch name.
local PR_FOR_BRANCH = [[
query($owner:String!,$repo:String!,$head:String!){
  viewer{ login }
  repository(owner:$owner,name:$repo){
    nameWithOwner
    pullRequests(headRefName:$head,first:20,states:[OPEN],orderBy:{field:UPDATED_AT,direction:DESC}){
      nodes{ number title headRefOid isCrossRepository headRepositoryOwner{ login } }
    }
  }
}]]

---@class ci.gh.Pr
---@field number integer
---@field title string
---@field headRefOid string

---@class ci.gh.BranchPr : ci.gh.Pr
---@field headRepositoryOwner? { login: string }
---@field repo? string

--- Finds the open PR for {branch}. A fork PR lives on the base repository,
--- where the branch name may not be unique, so the viewer's own PR wins.
---@param branch string
---@param repo? string
---@param on_done fun(pr?: ci.gh.BranchPr, err?: string)
function M.pr_for_branch(branch, repo, on_done)
  return graphql(PR_FOR_BRANCH, { head = branch }, repo, function(data, err)
    if err then
      return on_done(nil, err)
    end
    local me = vim.tbl_get(data or {}, 'viewer', 'login')
    local owner = vim.tbl_get(data or {}, 'repository', 'nameWithOwner')
    local nodes = vim.tbl_get(data or {}, 'repository', 'pullRequests', 'nodes') or {}
    local mine, any
    for _, n in ipairs(nodes) do
      any = any or n
      if vim.tbl_get(n, 'headRepositoryOwner', 'login') == me then
        mine = mine or n
      end
    end
    local pr = mine or any
    if pr then
      pr.repo = owner
    end
    on_done(pr)
  end)
end

--- Just enough of a PR to find its checks: its head commit.
local PR_BY_NUMBER = [[
query($owner:String!,$repo:String!,$n:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$n){ number title headRefOid }
  }
}]]

---@param number integer
---@param repo? string
---@param on_done fun(pr?: ci.gh.Pr, err?: string)
function M.pr_by_number(number, repo, on_done)
  return graphql(PR_BY_NUMBER, { n = number }, repo, function(data, err)
    if err then
      return on_done(nil, err)
    end
    local pr = vim.tbl_get(data or {}, 'repository', 'pullRequest')
    if not pr then
      return on_done(nil, ('no pull request #%d on %s'):format(number, slug(repo)))
    end
    on_done(pr)
  end)
end

---@class ci.gh.JobStep
---@field name string
---@field number integer
---@field status? ci.rest.Status
---@field conclusion? ci.rest.Conclusion
---@field started_at? string

---@class ci.gh.Job
---@field id integer
---@field run_id integer
---@field attempt? integer
---@field head_sha? string
---@field name string
---@field status? ci.rest.Status
---@field conclusion? ci.rest.Conclusion
---@field html_url? string
---@field workflow_name? string
---@field steps? ci.gh.JobStep[]

---@param id integer
---@param repo? string
---@param on_done fun(job?: ci.gh.Job, err?: string)
function M.job(id, repo, on_done)
  return api({ ('repos/%s/actions/jobs/%d'):format(slug(repo), id) }, on_done)
end

---@param id integer
---@param repo? string
---@param on_done fun(text?: string, err?: string)
function M.job_log(id, repo, on_done)
  local args = { 'api', ('repos/%s/actions/jobs/%d/logs'):format(slug(repo), id) }
  if escapes_allowed() then
    args[#args + 1] = '--allow-escape-sequences'
  end
  return run(args, function(out, err)
    if err then
      return on_done(nil, err)
    end
    on_done((out:gsub('^\239\187\191', '')))
  end, LOG)
end

---@param id integer
---@param attempt? integer
---@param repo? string
---@param on_done fun(jobs?: ci.gh.Job[], err?: string)
function M.run_jobs(id, attempt, repo, on_done)
  local path = attempt
      and ('repos/%s/actions/runs/%d/attempts/%d/jobs'):format(slug(repo), id, attempt)
    or ('repos/%s/actions/runs/%d/jobs?per_page=100'):format(slug(repo), id)
  return api({ path }, function(data, err)
    if err then
      return on_done(nil, err)
    end
    on_done(data.jobs or {})
  end)
end

---@class ci.gh.WorkflowRun
---@field id integer

---@param file string
---@param repo? string
---@param on_done fun(run?: ci.gh.WorkflowRun, err?: string)
function M.latest_run(file, repo, on_done)
  local path = ('repos/%s/actions/workflows/%s/runs?per_page=1'):format(slug(repo), file)
  return api({ path }, function(data, err)
    if err then
      return on_done(nil, err)
    end
    local latest = (data.workflow_runs or {})[1]
    if not latest then
      return on_done(nil, ('no runs for workflow %s'):format(file))
    end
    on_done(latest)
  end)
end

return M
