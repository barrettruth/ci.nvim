local M = {}

---@alias ci.Target.Kind 'job'|'run'|'rev'|'pr'|'workflow'|'repo'

---@class ci.Target
---@field kind ci.Target.Kind
---@field repo? string
---@field id? integer
---@field attempt? integer
---@field number? integer
---@field expr? string
---@field file? string

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

  local job = rest:match('^actions/runs/%d+/job/(%d+)$')
  if job then
    return { kind = 'job', repo = repo, id = tonumber(job) }
  end

  local arun, attempt = rest:match('^actions/runs/(%d+)/attempts/(%d+)$')
  if arun then
    return { kind = 'run', repo = repo, id = tonumber(arun), attempt = tonumber(attempt) }
  end

  local only_run = rest:match('^actions/runs/(%d+)$')
  if only_run then
    return { kind = 'run', repo = repo, id = tonumber(only_run) }
  end

  local wf = rest:match('^actions/workflows/([^/]+)$')
  if wf then
    return { kind = 'workflow', repo = repo, file = wf }
  end

  local pr = rest:match('^pull/(%d+)/checks$') or rest:match('^pull/(%d+)$')
  if pr then
    local check = query and query:match('check_run_id=(%d+)')
    if check then
      return { kind = 'job', repo = repo, id = tonumber(check) }
    end
    return { kind = 'pr', repo = repo, number = tonumber(pr) }
  end

  local sha = rest:match('^commit/(%x+)/checks$') or rest:match('^commit/(%x+)$')
  if sha then
    return { kind = 'rev', repo = repo, expr = sha .. '^{commit}' }
  end

  local legacy = rest:match('^runs/(%d+)$')
  if legacy then
    return { kind = 'job', repo = repo, id = tonumber(legacy) }
  end

  if rest == 'actions' then
    return { kind = 'repo', repo = repo }
  end

  return nil, ('unsupported GitHub URL: %s'):format(url)
end

---@param arg? string
---@return ci.Target?
---@return string? err
function M.parse(arg)
  arg = arg and vim.trim(arg) or ''
  if arg == '' then
    return { kind = 'pr' }
  end
  if arg:match('^https?://') then
    if not arg:match('^https?://[^/]*github%.com/') then
      return nil, ('not a github.com URL: %s'):format(arg)
    end
    return parse_github(arg)
  end
  return { kind = 'rev', expr = arg .. '^{commit}' }
end

return M
