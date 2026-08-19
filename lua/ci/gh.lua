local M = {}

local API = 10000
local LOG = 30000
local VERSION = 2000

---@type ci.Nouns
M.nouns = { run = 'run', group = 'workflow', pr = 'pull request', ref = '#' }

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

--- " on owner/name", or nothing at all where gh is resolving the repository
--- itself: its placeholders stand in for a name only gh knows, and a reader
--- shown `{owner}/{repo}` learns less than one shown nothing.
---@param repo? string
---@return string
local function where(repo)
  return (repo and repo ~= '') and (' on ' .. repo) or ''
end

--- What github said, if {s} is one of its error envelopes.
---@param s string
---@return string?
local function said(s)
  local ok, decoded = pcall(vim.json.decode, s)
  if ok and type(decoded) == 'table' and type(decoded.message) == 'string' then
    return decoded.message
  end
  return nil
end

--- `gh api` writes github's response to stdout and its own "gh: … (HTTP 403)"
--- line to stderr, so the body is read first: it is the same sentence without
--- the prefix.
---@param r vim.SystemCompleted
---@return string
local function errmsg(r)
  local out, err = vim.trim(r.stdout or ''), vim.trim(r.stderr or '')
  local s = said(out) or said(err) or (err ~= '' and err or out)
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

---@param query string
---@param vars table<string, string|integer>
---@param repo? string
---@return string[]
local function gql(query, vars, repo)
  local owner, name = owner_name(repo)
  local args = { 'graphql', '-F', 'owner=' .. owner, '-F', 'repo=' .. name }
  for k, v in pairs(vars) do
    args[#args + 1] = type(v) == 'number' and '-F' or '-f'
    args[#args + 1] = k .. '=' .. tostring(v)
  end
  args[#args + 1] = '-f'
  args[#args + 1] = 'query=' .. query
  return args
end

---@param data table
---@return string?
local function refused(data)
  local first = data.errors and data.errors[1]
  return first and (first.message or 'GraphQL error') or nil
end

---@generic T
---@param query string
---@param vars table<string, string|integer>
---@param repo? string
---@param on_done fun(data?: T, err?: string)
local function graphql(query, vars, repo, on_done)
  return api(gql(query, vars, repo), function(data, err)
    if err then
      return on_done(nil, err)
    end
    local bad = refused(data)
    if bad then
      return on_done(nil, bad)
    end
    on_done(data.data)
  end)
end

--- Every page of a connection. gh repeats the query with the cursor the last
--- page ended on, so long as the query takes an `$endCursor` and asks for
--- `pageInfo`, and writes a document a page that only `--slurp` makes one.
---@param query string
---@param vars table<string, string|integer>
---@param repo? string
---@param on_done fun(pages?: table[], err?: string)
local function graphql_pages(query, vars, repo, on_done)
  local args = gql(query, vars, repo)
  table.insert(args, 2, '--paginate')
  table.insert(args, 3, '--slurp')
  return api(args, function(pages, err)
    if err then
      return on_done(nil, err)
    end
    local out = {}
    for _, page in ipairs(pages or {}) do
      local bad = refused(page)
      if bad then
        return on_done(nil, bad)
      end
      out[#out + 1] = page.data
    end
    on_done(out)
  end)
end

--- A revision and its checks in one request: the commit it resolves to, the
--- rollup state, and every context, Actions or otherwise. `databaseId` on a
--- CheckRun is the Actions job id, which is what the log endpoint takes.
local CHECKS_FOR_REV = [[
query($owner:String!,$repo:String!,$expr:String!,$endCursor:String){
  repository(owner:$owner,name:$repo){
    nameWithOwner
    object(expression:$expr){
      ... on Commit{
        oid
        messageHeadline
        statusCheckRollup{
          state
          contexts(first:100,after:$endCursor){
            totalCount
            pageInfo{ hasNextPage endCursor }
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
---@field group? string
---@field started_at? string
---@field opens? string a `ci://` name this row leads to, where it is not a log

--- Flattens rollup contexts, keeping the newest of each (group, name): a
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
        group = vim.tbl_get(n, 'checkSuite', 'workflowRun', 'workflow', 'name'),
        started_at = n.startedAt,
      }
    elseif n.__typename == 'StatusContext' then
      c = { name = n.context, conclusion = n.state, url = n.targetUrl }
    end
    if c then
      local key = (c.group or '') .. '\0' .. c.name
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

local REPO_NAME = [[
query($owner:String!,$repo:String!){
  repository(owner:$owner,name:$repo){ nameWithOwner }
}]]

--- The concrete "owner/name" behind gh's placeholders. A `ci://` name has to
--- spell it out, and the placeholders resolve without ever saying to what.
---@param on_done fun(repo?: string, err?: string)
function M.repo(on_done)
  return graphql(REPO_NAME, {}, nil, function(data, err)
    if err then
      return on_done(nil, err)
    end
    local full = vim.tbl_get(data or {}, 'repository', 'nameWithOwner')
    if not full then
      return on_done(nil, 'cannot resolve the repository from the remote')
    end
    on_done(full)
  end)
end

--- Resolves a git revision and its checks in one request. {expr} is evaluated
--- by GitHub, so it sees the remote's refs rather than whatever was last
--- fetched.
---@param expr string
---@param repo? string
---@param on_done fun(res?: ci.gh.Rollup, err?: string)
function M.rollup(expr, repo, on_done)
  return graphql_pages(CHECKS_FOR_REV, { expr = expr }, repo, function(pages, err)
    if err then
      return on_done(nil, err)
    end
    local first = (pages or {})[1]
    local obj = vim.tbl_get(first or {}, 'repository', 'object')
    if not obj or not obj.oid then
      return on_done(nil, ('no such revision%s: %s'):format(where(repo), expr))
    end
    ---@type ci.gh.RollupNode[]
    local nodes = {}
    for _, page in ipairs(pages) do
      local ctx = vim.tbl_get(page, 'repository', 'object', 'statusCheckRollup', 'contexts')
      vim.list_extend(nodes, ctx and ctx.nodes or {})
    end
    local rollup = obj.statusCheckRollup
    on_done({
      repo = vim.tbl_get(first, 'repository', 'nameWithOwner'),
      oid = obj.oid,
      headline = obj.messageHeadline,
      state = rollup and rollup.state or nil,
      checks = to_checks(nodes),
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
---@field repo? string where its checks live, when that is not the repository asked

---@class ci.gh.BranchPr : ci.gh.Pr
---@field headRepositoryOwner? { login: string }

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
      return on_done(nil, ('no pull request #%d%s'):format(number, where(repo)))
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
---@field downstream? integer the run this one triggered, when it triggered one
--- rather than running anything itself
---@field bridge? boolean triggers rather than runs, so has no job of its own

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

--- Every page of them. An attempt's jobs were asked for without a page size at
--- all, so a rerun of more than thirty jobs lost the rest, and `--paginate`
--- over an endpoint answering with an object writes one object a page, which
--- is not one document until `--slurp` wraps them.
---@param id integer
---@param attempt? integer
---@param repo? string
---@param on_done fun(jobs?: ci.gh.Job[], err?: string)
function M.run_jobs(id, attempt, repo, on_done)
  local path = attempt
      and ('repos/%s/actions/runs/%d/attempts/%d/jobs?per_page=100'):format(slug(repo), id, attempt)
    or ('repos/%s/actions/runs/%d/jobs?per_page=100'):format(slug(repo), id)
  return api({ '--paginate', '--slurp', path }, function(pages, err)
    if err then
      return on_done(nil, err)
    end
    ---@type ci.gh.Job[]
    local jobs = {}
    for _, page in ipairs(pages or {}) do
      for _, j in ipairs(page.jobs or {}) do
        jobs[#jobs + 1] = j
      end
    end
    on_done(jobs)
  end)
end

---@alias ci.gh.Act 'rerun'|'rerun-failed-jobs'|'cancel'|'force-cancel'

--- Asks github to change a workflow run. REST only, the GraphQL schema having
--- no Actions mutation but the check-suite ones. Nothing is decoded: these
--- answer `{}` or an empty body, which `api()` would call malformed.
---@param id integer
---@param what ci.gh.Act
---@param repo? string
---@param on_done fun(err?: string)
function M.act(id, what, repo, on_done)
  local path = ('repos/%s/actions/runs/%d/%s'):format(slug(repo), id, what)
  return run({ 'api', '--method', 'POST', path }, function(_, err)
    on_done(err)
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
