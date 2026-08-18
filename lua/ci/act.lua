local buf_util = require('ci.buf')
local forge = require('ci.forge')
local msg = require('ci.msg')

local api = vim.api

local M = {}

--- Conclusions github will not retry. `cancelled` is not among them, and
--- `status.bucket` files it under `skipped`, so the test is on the conclusion.
local PASSED = { success = true, skipped = true, neutral = true }

--- Runs already asked to stop this session, so a second `cc` escalates. Keyed
--- on the run: a checks list shows several rows of one.
---@type table<integer, boolean>
local asked = {}

--- Buffers with a question or a request outstanding. An overridden
--- |vim.ui.input()| does not block, so two can stack.
---@type table<integer, boolean>
local busy = {}

---@class ci.act.Target
---@field run integer
---@field repo string
---@field host string
---@field label string the group, when the view names one
---@field rows? ci.Check[] what the view shows of this run

--- What the forge at {host} calls a run.
---@param host string
---@return string
local function noun(host)
  return forge.of(host).nouns.run
end

--- What the two keys act on, or the reason they cannot. Read at the keypress,
--- because a list re-sorts itself worst-first on every poll and the question
--- that follows is a callback.
---@param u ci.Uri
---@param b ci.BufVar
---@param lnum integer
---@return ci.act.Target?
---@return string? refusal
function M.target(u, b, lnum)
  if u.kind == 'job' then
    if not b.run_id then
      return nil, ('this job does not name a %s'):format(noun(u.host))
    end
    return { run = b.run_id, repo = u.repo, host = u.host, label = b.group or '' }
  end

  ---@type ci.Check[]
  local rows = {}

  if u.kind == 'run' then
    -- A pinned attempt answers with its own state and the live run's
    -- rerun_url, so acting here would change something else.
    if u.attempt then
      local what = noun(u.host)
      return nil,
        ('this is attempt %d of %s %s; open the %s itself'):format(u.attempt, what, u.id, what)
    end
    local run = tonumber(u.id)
    if not run then
      return nil, ('malformed run id: %s'):format(u.id)
    end
    for _, c in pairs(b.checks or {}) do
      rows[#rows + 1] = c
    end
    return {
      run = run,
      repo = u.repo,
      host = u.host,
      label = rows[1] and rows[1].group or '',
      rows = rows,
    }
  end

  local check = (b.checks or {})[lnum]
  if not check then
    return nil, 'no check on this line'
  end
  -- The run, never the job: a check posted by an app has a databaseId of its
  -- own and no Actions run behind it.
  if not check.run_id then
    return nil, ('no %s for %s'):format(noun(u.host), check.name or 'this check')
  end
  for _, c in pairs(b.checks or {}) do
    if c.run_id == check.run_id then
      rows[#rows + 1] = c
    end
  end
  return {
    run = check.run_id,
    repo = u.repo,
    host = u.host,
    label = check.group or '',
    rows = rows,
  }
end

--- Which rerun github will take for {rows}, and how many jobs that names.
---@param rows ci.Check[]
---@return ci.gh.Act what
---@return integer count
function M.scope(rows)
  local failed = 0
  for _, c in ipairs(rows) do
    local concl = (c.conclusion or ''):lower()
    if concl ~= '' and not PASSED[concl] then
      failed = failed + 1
    end
  end
  if failed > 0 then
    return 'rerun-failed-jobs', failed
  end
  return 'rerun', #rows
end

--- "1 job", "all 9 jobs", "3 failed jobs".
---@param n integer
---@param failed boolean
---@return string
local function jobs(n, failed)
  if failed then
    return n == 1 and '1 failed job' or ('%d failed jobs'):format(n)
  end
  return n == 1 and '1 job' or ('all %d jobs'):format(n)
end

--- " (build)", or nothing when the view cannot name the group.
---@param t ci.act.Target
---@return string
local function tag(t)
  return t.label ~= '' and (' (%s)'):format(t.label) or ''
end

--- Neovim's own y/N, as `nvim/spellfile.lua` spells it.
---@param prompt string
---@param yes fun()
---@param no fun()
local function confirm(prompt, yes, no)
  vim.ui.input({ prompt = prompt, scope = 'editor' }, function(input)
    api.nvim_echo({ { ' ' } }, false, { kind = 'empty' })
    if input and input:lower() == 'y' then
      return yes()
    end
    no()
  end)
end

--- Where a rerun leaves you. Every attempt re-mints every job id, so a log is
--- a record of its attempt from here on and the new job is in the run.
---@param buf integer
---@param t ci.act.Target
---@param what ci.gh.Act
---@param win integer
local function after(buf, t, what, win)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  local u = buf_util.parse(api.nvim_buf_get_name(buf))
  local rerun = what == 'rerun' or what == 'rerun-failed-jobs'
  if u and u.kind == 'job' and rerun and api.nvim_win_get_buf(win) == buf then
    return api.nvim_win_call(win, function()
      buf_util.open(('ci://%s/%s/run/%d'):format(u.host, u.repo, t.run), { keepalt = true })
      buf_util.nudge(api.nvim_get_current_buf())
    end)
  end
  buf_util.nudge(buf)
  buf_util.reload(buf)
end

---@param buf integer
---@param t ci.act.Target
---@param what ci.gh.Act
---@param doing string
local function send(buf, t, what, doing)
  local report = msg.progress(doing)
  -- By the time an answer comes back the current window is wherever you
  -- wandered to.
  local win = api.nvim_get_current_win()
  forge.of(t.host).act(t.run, what, t.repo, function(err)
    busy[buf] = nil
    if err then
      report('failed')
      return msg.err(err)
    end
    report('success')
    asked[t.run] = (what == 'cancel' or what == 'force-cancel') or nil
    if api.nvim_win_is_valid(win) then
      after(buf, t, what, win)
    end
  end)
end

--- The buffer and what it acts on. A nil buffer has already been explained.
---@return integer? buf
---@return ci.act.Target?
local function start()
  local buf = api.nvim_get_current_buf()
  local u = buf_util.parse(api.nvim_buf_get_name(buf))
  ---@type ci.BufVar?
  local b = vim.b[buf].ci
  if not u or not b or busy[buf] then
    return nil
  end
  local t, refusal = M.target(u, b, api.nvim_win_get_cursor(0)[1])
  if not t then
    if refusal then
      msg.warn(refusal)
    end
    return nil
  end
  busy[buf] = true
  return buf, t
end

---@param buf integer
---@param t ci.act.Target
local function offer(buf, t)
  local what, n = M.scope(t.rows or {})
  local run_noun = noun(t.host)
  local prompt = n > 0
      and ('Re-run %s in %s %d%s? [y/N] '):format(
        jobs(n, what == 'rerun-failed-jobs'),
        run_noun,
        t.run,
        tag(t)
      )
    or ('Re-run %s %d%s? [y/N] '):format(run_noun, t.run, tag(t))
  confirm(prompt, function()
    send(buf, t, what, ('Re-running %s %d'):format(run_noun, t.run))
  end, function()
    busy[buf] = nil
  end)
end

--- Re-runs the run under the cursor: the jobs of it that did not pass, or all
--- of them when they all did.
function M.rerun()
  local buf, t = start()
  if not buf or not t then
    return
  end
  if t.rows then
    return offer(buf, t)
  end
  -- A log sees one job, so the rest of the run is asked for before the
  -- question can name a scope.
  forge.of(t.host).run_jobs(t.run, nil, t.repo, function(found, err)
    if err or not found then
      busy[buf] = nil
      return msg.err(err or ('no jobs in %s %d'):format(noun(t.host), t.run))
    end
    t.rows = vim.tbl_map(function(j)
      ---@type ci.Check
      return { name = j.name, status = j.status, conclusion = j.conclusion }
    end, found)
    offer(buf, t)
  end)
end

--- Cancels the run under the cursor, forcing it if one was already asked for.
function M.cancel()
  local buf, t = start()
  if not buf or not t then
    return
  end
  local run_noun = noun(t.host)
  local force = asked[t.run] or false
  local prompt = force
      and ('%s %d%s is still cancelling. Force cancel? [y/N] '):format(
        (run_noun:gsub('^%l', string.upper)),
        t.run,
        tag(t)
      )
    or ('Cancel %s %d%s? [y/N] '):format(run_noun, t.run, tag(t))
  confirm(prompt, function()
    send(buf, t, force and 'force-cancel' or 'cancel', ('Cancelling %s %d'):format(run_noun, t.run))
  end, function()
    busy[buf] = nil
  end)
end

return M
