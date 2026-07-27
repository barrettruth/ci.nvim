local M = {}

---@class ci.Target
---@field kind 'job'|'run'|'rev'|'pr'|'workflow'
---@field repo? string
---@field id? integer
---@field run? integer
---@field attempt? integer
---@field number? integer
---@field expr? string
---@field file? string
---@field step? integer
---@field line? integer

---@param s string
---@return string? path
---@return string? query
---@return string? fragment
local function split_url(s)
  local rest = s:match('^https?://[^/]+/(.*)$')
  if not rest then
    return nil
  end
  local frag = rest:match('#(.*)$')
  rest = rest:gsub('#.*$', '')
  local query = rest:match('%?(.*)$')
  rest = rest:gsub('%?.*$', '')
  return (rest:gsub('/+$', '')), query, frag
end

---@param frag? string
---@return integer? step
---@return integer? line
local function parse_fragment(frag)
  if not frag then
    return nil
  end
  local step, line = frag:match('^step:(%d+):(%d+)$')
  if step then
    return tonumber(step), tonumber(line)
  end
  return tonumber(frag:match('^step:(%d+)$'))
end

---@param url string
---@return ci.Target?
---@return string? err
local function parse_github(url)
  local path, query, frag = split_url(url)
  if not path then
    return nil
  end
  local owner, name, rest = path:match('^([^/]+)/([^/]+)/?(.*)$')
  if not owner or not name then
    return nil
  end
  local repo = owner .. '/' .. name
  local step, line = parse_fragment(frag)

  local run, job = rest:match('^actions/runs/(%d+)/job/(%d+)$')
  if run then
    return {
      kind = 'job',
      repo = repo,
      id = tonumber(job),
      run = tonumber(run),
      step = step,
      line = line,
    }
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

---@param uri string
---@return ci.Target?
---@return string? err
local function parse_ci(uri)
  local body = uri:match('^ci://(.*)$')
  if not body then
    return nil
  end
  local owner, name, kind, id = body:match('^([^/]+)/([^/]+)/([^/]+)/(.+)$')
  if not owner then
    return nil, ('malformed ci:// URI: %s'):format(uri)
  end
  local repo = owner .. '/' .. name
  if kind == 'job' then
    return { kind = 'job', repo = repo, id = tonumber(id) }
  elseif kind == 'run' then
    return { kind = 'run', repo = repo, id = tonumber(id) }
  elseif kind == 'pr' then
    return { kind = 'pr', repo = repo, number = tonumber(id) }
  elseif kind == 'checks' then
    return { kind = 'rev', repo = repo, expr = id }
  end
  return nil, ('unknown ci:// kind: %s'):format(kind)
end

---@param arg? string
---@return ci.Target?
---@return string? err
function M.parse(arg)
  arg = arg and vim.trim(arg) or ''
  if arg == '' then
    return { kind = 'pr' }
  end
  if arg:match('^ci://') then
    return parse_ci(arg)
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
