local M = {}

---@alias ci.Bucket 'fail'|'attention'|'running'|'pending'|'pass'|'skipped'

---@type table<string, ci.Bucket>
local BUCKET = {
  success = 'pass',

  failure = 'fail',
  startup_failure = 'fail',
  timed_out = 'fail',
  error = 'fail',

  action_required = 'attention',

  in_progress = 'running',

  queued = 'pending',
  requested = 'pending',
  waiting = 'pending',
  pending = 'pending',
  expected = 'pending',

  skipped = 'skipped',
  neutral = 'skipped',
  stale = 'skipped',
  cancelled = 'skipped',
}

---@type table<ci.Bucket, string>
M.symbol = {
  pass = '✓',
  fail = '✗',
  running = '●',
  pending = '○',
  skipped = '⊘',
  attention = '!',
}

---@type table<ci.Bucket, string>
M.hl = {
  pass = 'CiPass',
  fail = 'CiFail',
  running = 'CiRunning',
  pending = 'CiPending',
  skipped = 'CiSkipped',
  attention = 'CiAttention',
}

---@type table<ci.Bucket, integer>
M.rank = {
  fail = 1,
  attention = 2,
  running = 3,
  pending = 4,
  pass = 5,
  skipped = 6,
}

---@param status? string
---@param conclusion? string
---@return ci.Bucket
function M.bucket(status, conclusion)
  local s = status and status:lower() or nil
  local c = conclusion and conclusion:lower() or nil
  if c and c ~= '' then
    return BUCKET[c] or 'pending'
  end
  if s and s ~= '' then
    return BUCKET[s] or 'pending'
  end
  return 'pending'
end

---@param status? string
---@param conclusion? string
---@return string symbol
---@return string hl_group
---@return ci.Bucket bucket
function M.of(status, conclusion)
  local b = M.bucket(status, conclusion)
  return M.symbol[b], M.hl[b], b
end

---@param counts table<ci.Bucket, integer>
---@param total integer
---@return string
function M.summary(counts, total)
  if total == 0 then
    return 'no checks'
  end
  local parts = {}
  for _, b in ipairs({ 'fail', 'attention', 'running', 'pending', 'skipped' }) do
    if (counts[b] or 0) > 0 then
      parts[#parts + 1] = ('%d %s'):format(counts[b], b)
    end
  end
  if #parts == 0 then
    return ('%d passing'):format(total)
  end
  parts[#parts + 1] = ('%d/%d passing'):format(counts.pass or 0, total)
  return table.concat(parts, ', ')
end

return M
