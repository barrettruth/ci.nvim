local M = {}

---@alias ci.Bucket 'fail'|'attention'|'running'|'pending'|'pass'|'skipped'

---@alias ci.Hl.Bucket 'CiPass'|'CiFail'|'CiRunning'|'CiPending'|'CiSkipped'|'CiAttention'
---@alias ci.Hl ci.Hl.Bucket|'CiGroup'|'CiCommand'|'CiDebug'|'CiUrl'|'CiMuted'

---@alias ci.gql.Status 'REQUESTED'|'QUEUED'|'IN_PROGRESS'|'COMPLETED'|'WAITING'|'PENDING'
---@alias ci.rest.Status 'requested'|'queued'|'in_progress'|'completed'|'waiting'|'pending'
---@alias ci.forgejo.Status 'unknown'|'success'|'failure'|'cancelled'|'skipped'|'waiting'|'running'|'blocked'

---@alias ci.gitlab.Status
---| 'created'
---| 'waiting_for_resource'
---| 'waiting_for_callback'
---| 'preparing'
---| 'pending'
---| 'running'
---| 'success'
---| 'failed'
---| 'canceled'
---| 'canceling'
---| 'skipped'
---| 'manual'
---| 'scheduled'

---@alias ci.Status ci.gql.Status|ci.rest.Status|ci.forgejo.Status|ci.gitlab.Status

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

--- `warning` is no forge's word. A job its forge was told it may fail is
--- neither a pass nor a failure, and this is how it reaches attention.
---@alias ci.Conclusion ci.gql.Conclusion|ci.rest.Conclusion|'warning'

---@type table<string, ci.Bucket>
local BUCKET = {
  success = 'pass',

  failure = 'fail',
  failed = 'fail',
  startup_failure = 'fail',
  timed_out = 'fail',
  error = 'fail',

  action_required = 'attention',
  warning = 'attention',

  in_progress = 'running',
  running = 'running',
  canceling = 'running',

  queued = 'pending',
  requested = 'pending',
  waiting = 'pending',
  waiting_for_resource = 'pending',
  waiting_for_callback = 'pending',
  pending = 'pending',
  expected = 'pending',
  blocked = 'pending',
  unknown = 'pending',
  created = 'pending',
  preparing = 'pending',
  scheduled = 'pending',
  -- A manual job waits to be asked for, and ranking it any higher would put
  -- every optional deploy above the jobs that are actually running.
  manual = 'pending',

  skipped = 'skipped',
  neutral = 'skipped',
  stale = 'skipped',
  cancelled = 'skipped',
  -- gitlab spells it with one l
  canceled = 'skipped',
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

--- Collapses every forge's status and conclusion values. Unknown ones are
--- pending, never passing, since the enums are open.
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

--- Everything needed to draw one check: its glyph, its highlight, and the
--- bucket both came from, which callers sort on.
---@param status? string
---@param conclusion? string
---@return string symbol
---@return ci.Hl.Bucket hl_group
---@return ci.Bucket bucket
function M.of(status, conclusion)
  local b = M.bucket(status, conclusion)
  return M.symbol[b], M.hl[b], b
end

--- One line for the winbar, worst bucket first: "3 fail, 1 running, 12/16
--- passing". Buckets with no checks are omitted.
--- Wraps {text} in {hl} as 'statusline' markup, for the `%{%…%}` winbar form.
---@param hl ci.Hl
---@param text string
---@return string
function M.paint(hl, text)
  return ('%%#%s#%s%%*'):format(hl, text)
end

---@param counts table<ci.Bucket, integer>
---@param total integer
---@return string
function M.summary(counts, total)
  if total == 0 then
    return M.paint('CiPending', 'no checks')
  end
  local parts = {}
  for _, b in ipairs({ 'fail', 'attention', 'running', 'pending', 'skipped' }) do
    if (counts[b] or 0) > 0 then
      parts[#parts + 1] = M.paint(M.hl[b], ('%d %s'):format(counts[b], b))
    end
  end
  if #parts == 0 then
    return M.paint('CiPass', ('%d passing'):format(total))
  end
  parts[#parts + 1] = M.paint('CiPass', ('%d/%d passing'):format(counts.pass or 0, total))
  return table.concat(parts, ', ')
end

return M
