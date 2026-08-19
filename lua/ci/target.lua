local M = {}

---@alias ci.Target.Kind 'job'|'run'|'rev'|'pr'|'branch'|'workflow'|'repo'

---@class ci.Target
---@field kind ci.Target.Kind
---@field host? string
---@field repo? string
---@field id? integer
---@field index? integer
---@field attempt? integer
---@field number? integer
---@field expr? string
---@field file? string
---@field sigil? string the one the argument was written with, for resolve() to
---       hold against the forge's own

---@param s string
---@return string? path
---@return string? query
local function split_url(s)
  local rest = s:match('^https?://[^/]+/(.*)$')
  if not rest then
    return nil
  end
  rest = rest:gsub('#.*$', '')
  local query = rest:match('%?(.*)$')
  rest = rest:gsub('%?.*$', '')
  return (rest:gsub('/+$', '')), query
end

---@param url string
---@param host string
---@return ci.Target?
---@return string? err
local function parse_forgejo(url, host)
  local path = split_url(url)
  if not path then
    return nil
  end
  local owner, name, rest = path:match('^([^/]+)/([^/]+)/?(.*)$')
  if not owner or not name then
    return nil
  end
  local repo = owner .. '/' .. name

  -- Forgejo puts a run's repo-scoped index in its URL, but the API only
  -- accepts the global id, so these carry {index} for resolve() to translate.
  local run, job, attempt = rest:match('^actions/runs/(%d+)/jobs/(%d+)/attempt/(%d+)$')
  if not run then
    run, job = rest:match('^actions/runs/(%d+)/jobs/(%d+)$')
  end
  if run then
    return {
      kind = 'run',
      host = host,
      repo = repo,
      index = tonumber(run),
      number = tonumber(job),
      attempt = tonumber(attempt),
    }
  end

  local only_run = rest:match('^actions/runs/(%d+)$')
  if only_run then
    return { kind = 'run', host = host, repo = repo, index = tonumber(only_run) }
  end

  local pr = rest:match('^pulls/(%d+)$')
  if pr then
    return { kind = 'pr', host = host, repo = repo, number = tonumber(pr) }
  end

  local sha = rest:match('^commit/(%x+)$')
  if sha then
    return { kind = 'rev', host = host, repo = repo, expr = sha }
  end

  if rest == 'actions' then
    return { kind = 'repo', host = host, repo = repo }
  end

  return nil, ('unsupported Forgejo URL: %s'):format(url)
end

---@param url string
---@return ci.Target?
---@return string? err
local function parse_github(url)
  local path, query = split_url(url)
  if not path then
    return nil
  end
  local owner, name, rest = path:match('^([^/]+)/([^/]+)/?(.*)$')
  if not owner or not name then
    return nil
  end
  local repo = owner .. '/' .. name
  local host = 'github.com'

  local job = rest:match('^actions/runs/%d+/job/(%d+)$')
  if job then
    return { kind = 'job', host = host, repo = repo, id = tonumber(job) }
  end

  local arun, attempt = rest:match('^actions/runs/(%d+)/attempts/(%d+)$')
  if arun then
    return {
      kind = 'run',
      host = host,
      repo = repo,
      id = tonumber(arun),
      attempt = tonumber(attempt),
    }
  end

  local only_run = rest:match('^actions/runs/(%d+)$')
  if only_run then
    return { kind = 'run', host = host, repo = repo, id = tonumber(only_run) }
  end

  local wf = rest:match('^actions/workflows/([^/]+)$')
  if wf then
    return { kind = 'workflow', host = host, repo = repo, file = wf }
  end

  local pr = rest:match('^pull/(%d+)/checks$') or rest:match('^pull/(%d+)$')
  if pr then
    local check = query and query:match('check_run_id=(%d+)')
    if check then
      return { kind = 'job', host = host, repo = repo, id = tonumber(check) }
    end
    return { kind = 'pr', host = host, repo = repo, number = tonumber(pr) }
  end

  local sha = rest:match('^commit/(%x+)/checks$') or rest:match('^commit/(%x+)$')
  if sha then
    return { kind = 'rev', host = host, repo = repo, expr = sha .. '^{commit}' }
  end

  local legacy = rest:match('^runs/(%d+)$')
  if legacy then
    return { kind = 'job', host = host, repo = repo, id = tonumber(legacy) }
  end

  if rest == 'actions' then
    return { kind = 'repo', host = host, repo = repo }
  end

  return nil, ('unsupported GitHub URL: %s'):format(url)
end

--- gitlab writes `/-/` between a project and the noun that follows it, which
--- is the only thing telling a subgroup from a noun.
---@param url string
---@param host string
---@return ci.Target?
---@return string? err
local function parse_gitlab(url, host)
  local path = split_url(url)
  if not path or path == '' then
    return nil
  end
  local repo, rest = path:match('^(.-)/%-/(.*)$')
  if not repo then
    return nil, ('unsupported GitLab URL: %s'):format(url)
  end

  local job = rest:match('^jobs/(%d+)$')
  if job then
    return { kind = 'job', host = host, repo = repo, id = tonumber(job) }
  end

  local pipeline = rest:match('^pipelines/(%d+)$')
  if pipeline then
    return { kind = 'run', host = host, repo = repo, id = tonumber(pipeline) }
  end

  local mr = rest:match('^merge_requests/(%d+)')
  if mr then
    return { kind = 'pr', host = host, repo = repo, number = tonumber(mr) }
  end

  local sha = rest:match('^commit/(%x+)$')
  if sha then
    return { kind = 'rev', host = host, repo = repo, expr = sha }
  end

  if rest == 'pipelines' then
    return { kind = 'repo', host = host, repo = repo }
  end

  return nil, ('unsupported GitLab URL: %s'):format(url)
end

---@param arg? string
---@return ci.Target?
---@return string? err
function M.parse(arg)
  arg = arg and vim.trim(arg) or ''
  if arg == '' then
    return { kind = 'branch' }
  end
  if arg:match('^https?://') then
    local host = arg:match('^https?://([^/]+)/')
    if not host then
      return nil, ('not a forge URL: %s'):format(arg)
    end
    local forge = require('ci.forge')
    if forge.is_github(host) then
      return parse_github(arg)
    end
    if forge.is_gitlab(host) then
      return parse_gitlab(arg, host)
    end
    return parse_forgejo(arg, host)
  end
  -- Which sigil a forge writes is its own business, so the one given is
  -- carried rather than judged here, where no forge is known yet.
  local sigil, sigilled = arg:match('^([#!])(%d+)$')
  if sigilled then
    return { kind = 'pr', number = tonumber(sigilled), sigil = sigil }
  end
  -- Git wants four hex digits before it will read one as an abbreviated
  -- object, so a shorter number is never a revision, and a longer one is a
  -- pull request far more often than it is a commit that spells itself in
  -- decimal. `{n}^{commit}` still asks for the commit.
  if arg:match('^%d+$') then
    return { kind = 'pr', number = tonumber(arg) }
  end
  return { kind = 'rev', expr = arg .. '^{commit}' }
end

return M
