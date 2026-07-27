local M = {}

---@return string[]
function M.cmd()
  local g = vim.g.ci
  local c = type(g) == 'table' and g.gh or nil
  if type(c) == 'string' then
    return { c }
  end
  return vim.deepcopy(c or { 'gh' })
end

---@param repo? string
---@return string owner
---@return string name
function M.owner_name(repo)
  if repo then
    local o, n = repo:match('^([^/]+)/([^/]+)$')
    if o then
      return o, n
    end
  end
  return '{owner}', '{repo}'
end

---@param repo? string
---@return string
function M.slug(repo)
  local o, n = M.owner_name(repo)
  return o .. '/' .. n
end

---@param r table
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
function M.run(args, on_done)
  local cmd = M.cmd()
  vim.list_extend(cmd, args)
  return vim.system(cmd, { text = true }, function(r)
    vim.schedule(function()
      if r.code ~= 0 then
        on_done(nil, errmsg(r))
      else
        on_done(r.stdout or '')
      end
    end)
  end)
end

---@param args string[]
---@param on_done fun(data?: table, err?: string)
function M.api(args, on_done)
  return M.run(vim.list_extend({ 'api' }, args), function(out, err)
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
---@param vars table<string, string>
---@param repo? string
---@param on_done fun(data?: table, err?: string)
function M.graphql(query, vars, repo, on_done)
  local owner, name = M.owner_name(repo)
  local args = { 'graphql', '-F', 'owner=' .. owner, '-F', 'repo=' .. name }
  for k, v in pairs(vars) do
    args[#args + 1] = '-f'
    args[#args + 1] = k .. '=' .. v
  end
  args[#args + 1] = '-f'
  args[#args + 1] = 'query=' .. query
  return M.api(args, function(data, err)
    if err then
      return on_done(nil, err)
    end
    if data.errors and data.errors[1] then
      return on_done(nil, data.errors[1].message or 'GraphQL error')
    end
    on_done(data.data)
  end)
end

local ROLLUP = [[
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
                name status conclusion detailsUrl databaseId
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

---@class ci.Check
---@field name string
---@field status? string
---@field conclusion? string
---@field url? string
---@field job_id? integer
---@field run_id? integer
---@field workflow? string

---@param nodes table[]
---@return ci.Check[]
local function to_checks(nodes)
  local out = {}
  for _, n in ipairs(nodes or {}) do
    if n.__typename == 'CheckRun' then
      local run_id, job_id = (n.detailsUrl or ''):match('/actions/runs/(%d+)/job/(%d+)')
      out[#out + 1] = {
        name = n.name,
        status = n.status,
        conclusion = n.conclusion,
        url = n.detailsUrl,
        job_id = tonumber(job_id) or n.databaseId,
        run_id = tonumber(run_id),
        workflow = vim.tbl_get(n, 'checkSuite', 'workflowRun', 'workflow', 'name'),
      }
    elseif n.__typename == 'StatusContext' then
      out[#out + 1] = {
        name = n.context,
        conclusion = n.state,
        url = n.targetUrl,
      }
    end
  end
  return out
end

---@param expr string
---@param repo? string
---@param on_done fun(res?: table, err?: string)
function M.rollup(expr, repo, on_done)
  return M.graphql(ROLLUP, { expr = expr }, repo, function(data, err)
    if err then
      return on_done(nil, err)
    end
    local obj = vim.tbl_get(data or {}, 'repository', 'object')
    if not obj or not obj.oid then
      return on_done(nil, ('no such revision on %s: %s'):format(M.slug(repo), expr))
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

---@param branch string
---@param repo? string
---@param on_done fun(pr?: table, err?: string)
function M.pr_for_branch(branch, repo, on_done)
  return M.graphql(PR_FOR_BRANCH, { head = branch }, repo, function(data, err)
    if err then
      return on_done(nil, err)
    end
    local me = vim.tbl_get(data or {}, 'viewer', 'login')
    local slug = vim.tbl_get(data or {}, 'repository', 'nameWithOwner')
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
      pr.repo = slug
    end
    on_done(pr)
  end)
end

local PR_BY_NUMBER = [[
query($owner:String!,$repo:String!,$n:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$n){ number title headRefOid }
  }
}]]

---@param number integer
---@param repo? string
---@param on_done fun(pr?: table, err?: string)
function M.pr_by_number(number, repo, on_done)
  local owner, name = M.owner_name(repo)
  local args = {
    'graphql',
    '-F',
    'owner=' .. owner,
    '-F',
    'repo=' .. name,
    '-F',
    'n=' .. tostring(number),
    '-f',
    'query=' .. PR_BY_NUMBER,
  }
  return M.api(args, function(data, err)
    if err then
      return on_done(nil, err)
    end
    if data.errors and data.errors[1] then
      return on_done(nil, data.errors[1].message)
    end
    local pr = vim.tbl_get(data, 'data', 'repository', 'pullRequest')
    if not pr then
      return on_done(nil, ('no pull request #%d on %s'):format(number, M.slug(repo)))
    end
    on_done(pr)
  end)
end

---@param id integer
---@param repo? string
---@param on_done fun(job?: table, err?: string)
function M.job(id, repo, on_done)
  return M.api({ ('repos/%s/actions/jobs/%d'):format(M.slug(repo), id) }, on_done)
end

---@param id integer
---@param repo? string
---@param on_done fun(text?: string, err?: string)
function M.job_log(id, repo, on_done)
  return M.run(
    { 'api', ('repos/%s/actions/jobs/%d/logs'):format(M.slug(repo), id) },
    function(out, err)
      if err then
        if err:match('[Nn]ot [Ff]ound') or err:match('404') then
          err = 'log unavailable: job is still running, was skipped, or its logs expired'
        end
        return on_done(nil, err)
      end
      on_done((out:gsub('^\239\187\191', '')))
    end
  )
end

---@param run integer
---@param attempt? integer
---@param repo? string
---@param on_done fun(jobs?: table[], err?: string)
function M.run_jobs(run, attempt, repo, on_done)
  local path = attempt
      and ('repos/%s/actions/runs/%d/attempts/%d/jobs'):format(M.slug(repo), run, attempt)
    or ('repos/%s/actions/runs/%d/jobs?per_page=100'):format(M.slug(repo), run)
  return M.api({ path }, function(data, err)
    if err then
      return on_done(nil, err)
    end
    on_done(data.jobs or {})
  end)
end

---@param file string
---@param repo? string
---@param on_done fun(run?: table, err?: string)
function M.latest_run(file, repo, on_done)
  local path = ('repos/%s/actions/workflows/%s/runs?per_page=1'):format(M.slug(repo), file)
  return M.api({ path }, function(data, err)
    if err then
      return on_done(nil, err)
    end
    local run = (data.workflow_runs or {})[1]
    if not run then
      return on_done(nil, ('no runs for workflow %s'):format(file))
    end
    on_done(run)
  end)
end

return M
