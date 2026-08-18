local M = {}

--- What a forge calls the two things ci.nvim has no neutral word for. Prose
--- only: the `ci://` kind stays `run` whatever the forge calls it.
---@class ci.Nouns
---@field run string a collection of jobs
---@field group string what a job belongs to, shown beside its name

---@class ci.Backend
---@field nouns ci.Nouns
---@field rollup fun(expr: string, repo?: string, on_done: fun(res?: ci.gh.Rollup, err?: string))
---@field pr_for_branch fun(branch: string, repo?: string, on_done: fun(pr?: ci.gh.BranchPr, err?: string))
---@field pr_by_number fun(number: integer, repo?: string, on_done: fun(pr?: ci.gh.Pr, err?: string))
---@field job fun(id: integer, repo?: string, on_done: fun(job?: ci.gh.Job, err?: string))
---@field job_log fun(id: integer, repo?: string, on_done: fun(text?: string, err?: string))
---@field run_jobs fun(id: integer, attempt?: integer, repo?: string, on_done: fun(jobs?: ci.gh.Job[], err?: string))
---@field latest_run fun(file: string, repo?: string, on_done: fun(run?: ci.gh.WorkflowRun, err?: string))
---@field act? fun(id: integer, what: ci.gh.Act, repo?: string, on_done: fun(err?: string))
---@field run_by_index? fun(index: integer, repo?: string, on_done: fun(run?: ci.tea.Run, err?: string))
---@field run? fun(id: integer, repo?: string, on_done: fun(run?: ci.tea.Run, err?: string))
---@field finished? fun(text: string): boolean

M.GITHUB = 'github.com'

local GIT = 2000

---@param url string
---@return string? host
function M.host_of(url)
  local scheme, authority = url:match('^(%a[%w+.%-]*)://([^/]+)')
  authority = authority or url:match('^([^/]+):')
  if not authority then
    return nil
  end
  authority = authority:gsub('^[^@]*@', '')
  if scheme == 'http' or scheme == 'https' then
    return authority
  end
  return (authority:gsub(':%d+$', ''))
end

---@param name string
---@return string? url
local function remote(name)
  local r = vim.system({ 'git', 'remote', 'get-url', name }, { text = true }):wait(GIT)
  if r.code ~= 0 then
    return nil
  end
  local url = vim.trim(r.stdout or '')
  return url ~= '' and url or nil
end

--- Which CLI to invoke, and nothing more: both resolve `{owner}`/`{repo}`
--- themselves. `tea` prefers a remote named `upstream` over `origin`, so the
--- same order is used here; picking the CLI from one remote while it reads
--- another is how a fork gets answered for by the wrong repository.
---@return string host
function M.host()
  local url = remote('upstream') or remote('origin')
  if not url then
    local r = vim.system({ 'git', 'remote' }, { text = true }):wait(GIT)
    local first = r.code == 0 and vim.split(vim.trim(r.stdout or ''), '\n')[1] or nil
    url = first and first ~= '' and remote(first) or nil
  end
  return url and M.host_of(url) or M.GITHUB
end

---@param host? string
---@return boolean
function M.is_github(host)
  host = host or M.GITHUB
  return host == M.GITHUB or host:match('%.github%.com$') ~= nil
end

--- Anything that is not github.com is assumed to speak Forgejo. A host `tea`
--- has no login for fails at the first request, which is a clearer error than
--- one invented here.
---@param host? string
---@return ci.Backend
function M.of(host)
  return M.is_github(host) and require('ci.gh') or require('ci.tea')
end

---@param host? string
---@return string
function M.cli(host)
  return M.is_github(host) and 'gh' or 'tea'
end

--- The browser page behind `gX`. The two forges disagree on nearly every
--- path: `pull` against `pulls`, and no `/checks` suffix on Forgejo.
---@param host string
---@param repo string
---@param kind ci.Uri.Kind|'repo'
---@param id? string|integer
---@param attempt? integer
---@return string
function M.web(host, repo, kind, id, attempt)
  local base = ('https://%s/%s'):format(host, repo)
  if M.is_github(host) then
    if kind == 'pr' then
      return ('%s/pull/%s/checks'):format(base, id)
    elseif kind == 'run' then
      local u = ('%s/actions/runs/%s'):format(base, id)
      return attempt and ('%s/attempts/%d'):format(u, attempt) or u
    elseif kind == 'checks' then
      return ('%s/commit/%s/checks'):format(base, id)
    end
    return base
  end
  -- A Forgejo run or job page is keyed on the run's index within the
  -- repository, which cannot be derived from the id its API answers to. Those
  -- pages name themselves; until one says so, the repository's is the honest
  -- answer.
  if kind == 'pr' then
    return ('%s/pulls/%s'):format(base, id)
  elseif kind == 'checks' then
    return ('%s/commit/%s'):format(base, id)
  end
  return ('%s/actions'):format(base)
end

return M
