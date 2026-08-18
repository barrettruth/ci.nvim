local act = require('ci.act')

---@param over? table
---@return ci.Uri
local function uri(over)
  return vim.tbl_extend(
    'force',
    { host = 'github.com', repo = 'o/r', kind = 'checks', id = 'abc123' },
    over or {}
  )
end

---@param over? table
---@return ci.BufVar
local function bufvar(over)
  return vim.tbl_extend(
    'force',
    { title = '', status = '', repo = 'o/r', group = '', url = '', gen = 1 },
    over or {}
  )
end

describe('act.scope', function()
  it('asks for the failures when there are any', function()
    local what, n = act.scope({
      { name = 'a', conclusion = 'success' },
      { name = 'b', conclusion = 'failure' },
      { name = 'c', conclusion = 'timed_out' },
    })
    assert.same('rerun-failed-jobs', what)
    assert.same(2, n)
  end)

  it('counts a cancelled job among them, as github does', function()
    local what, n = act.scope({
      { name = 'a', conclusion = 'success' },
      { name = 'b', conclusion = 'cancelled' },
    })
    assert.same('rerun-failed-jobs', what)
    assert.same(1, n)
  end)

  it('asks for everything when nothing failed', function()
    local what, n = act.scope({
      { name = 'a', conclusion = 'success' },
      { name = 'b', conclusion = 'skipped' },
    })
    assert.same('rerun', what)
    assert.same(2, n)
  end)

  it('leaves a run still going to github to refuse', function()
    local what, n = act.scope({ { name = 'a', status = 'in_progress' } })
    assert.same('rerun', what)
    assert.same(1, n)
  end)
end)

describe('act.target', function()
  it('takes the run of the row under the cursor', function()
    local b = bufvar({
      checks = {
        [1] = { name = 'a', run_id = 11, job_id = 21, group = 'test' },
        [2] = { name = 'b', run_id = 12, job_id = 22, group = 'lint' },
      },
    })
    local t = act.target(uri(), b, 2)
    assert.same(12, t.run)
    assert.same('lint', t.label)
    assert.same(1, #t.rows)
  end)

  it('gathers the rows sharing that run, and no others', function()
    local b = bufvar({
      checks = {
        [1] = { name = 'a', run_id = 11, conclusion = 'failure' },
        [2] = { name = 'b', run_id = 11, conclusion = 'success' },
        [3] = { name = 'c', run_id = 12, conclusion = 'failure' },
      },
    })
    local t = act.target(uri(), b, 1)
    assert.same(2, #t.rows)
    assert.same('rerun-failed-jobs', act.scope(t.rows))
  end)

  it('refuses a check that is not an Actions run', function()
    local b = bufvar({ checks = { [1] = { name = 'netlify/deploy', job_id = 99 } } })
    local t, why = act.target(uri(), b, 1)
    assert.is_nil(t)
    assert.truthy(why:find('netlify/deploy', 1, true))
  end)

  it('refuses a line with no check on it', function()
    assert.is_nil(act.target(uri(), bufvar(), 1))
  end)

  it('takes the run itself from a run view', function()
    local b = bufvar({ checks = { [1] = { name = 'a', run_id = 11, group = 'test' } } })
    local t = act.target(uri({ kind = 'run', id = '11' }), b, 1)
    assert.same(11, t.run)
    assert.same(1, #t.rows)
  end)

  it('refuses a pinned attempt, which answers for a run that moved on', function()
    local t, why = act.target(uri({ kind = 'run', id = '11', attempt = 2 }), bufvar(), 1)
    assert.is_nil(t)
    assert.truthy(why:find('attempt 2', 1, true))
  end)

  it('takes the run a job names, wherever the cursor is', function()
    local b = bufvar({ run_id = 11, group = 'test' })
    local t = act.target(uri({ kind = 'job', id = '22' }), b, 40)
    assert.same(11, t.run)
    assert.is_nil(t.rows)
  end)

  it('refuses a job that never learned its run', function()
    assert.is_nil(act.target(uri({ kind = 'job', id = '22' }), bufvar(), 1))
  end)
end)
