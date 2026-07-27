local M = {}

---@alias ci.Bucket 'fail'|'attention'|'running'|'pending'|'pass'|'skipped'

---@alias ci.Hl.Bucket 'CiPass'|'CiFail'|'CiRunning'|'CiPending'|'CiSkipped'|'CiAttention'
---@alias ci.Hl ci.Hl.Bucket|'CiGroup'|'CiMuted'

---@alias ci.gql.Status 'REQUESTED'|'QUEUED'|'IN_PROGRESS'|'COMPLETED'|'WAITING'|'PENDING'
---@alias ci.rest.Status 'requested'|'queued'|'in_progress'|'completed'|'waiting'|'pending'
---@alias ci.Status ci.gql.Status|ci.rest.Status

---@alias ci.gql.Conclusion
---| 'SUCCESS'
---| 'FAILURE'
---| 'NEUTRAL'
---| 'CANCELLED'
---| 'SKIPPED'
---| 'TIMED_OUT'
---| 'ACTION_REQUIRED'
---| 'STARTUP_FAILURE'
---| 'STALE'
---| 'EXPECTED'
---| 'ERROR'
---| 'PENDING'

---@alias ci.rest.Conclusion
---| 'success'
---| 'failure'
---| 'neutral'
---| 'cancelled'
---| 'skipped'
---| 'timed_out'
---| 'action_required'

---@alias ci.Conclusion ci.gql.Conclusion|ci.rest.Conclusion

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

---@type table<ci.Bucket, ci.Hl.Bucket>
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
---@return ci.Hl.Bucket hl_group
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
