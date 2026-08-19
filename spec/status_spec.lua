local status = require('ci.status')

describe('status.bucket', function()
  it('prefers conclusion over status once a check completes', function()
    assert.equals('fail', status.bucket('COMPLETED', 'FAILURE'))
    assert.equals('pass', status.bucket('completed', 'success'))
  end)

  it('falls back to status while a check is unfinished', function()
    assert.equals('running', status.bucket('IN_PROGRESS', nil))
    assert.equals('pending', status.bucket('QUEUED', nil))
    assert.equals('pending', status.bucket('WAITING', ''))
  end)

  it('accepts both GraphQL and REST spellings', function()
    assert.equals(status.bucket(nil, 'TIMED_OUT'), status.bucket(nil, 'timed_out'))
    assert.equals(status.bucket(nil, 'ACTION_REQUIRED'), status.bucket(nil, 'action_required'))
  end)

  it('never reports an unfinished or skipped check as passing', function()
    for _, c in ipairs({ 'SKIPPED', 'NEUTRAL', 'STALE', 'CANCELLED' }) do
      assert.equals('skipped', status.bucket('COMPLETED', c))
    end
    for _, c in ipairs({ 'FAILURE', 'STARTUP_FAILURE', 'TIMED_OUT', 'ERROR' }) do
      assert.equals('fail', status.bucket('COMPLETED', c))
    end
  end)

  it('buckets every gitlab job status', function()
    assert.equals('fail', status.bucket('failed', nil))
    assert.equals('skipped', status.bucket('canceled', nil))
    assert.equals('running', status.bucket('canceling', nil))
    for _, s in ipairs({ 'created', 'waiting_for_resource', 'preparing', 'manual', 'scheduled' }) do
      assert.equals('pending', status.bucket(s, nil))
    end
  end)

  it('reports a failure that was allowed as needing attention', function()
    assert.equals('attention', status.bucket('failed', 'warning'))
  end)

  it('defaults unknown values to pending rather than passing', function()
    assert.equals('pending', status.bucket(nil, 'SOMETHING_NEW'))
    assert.equals('pending', status.bucket(nil, nil))
  end)

  it('sorts failures first', function()
    assert.is_true(status.rank.fail < status.rank.running)
    assert.is_true(status.rank.running < status.rank.pass)
    assert.is_true(status.rank.pass < status.rank.skipped)
  end)

  it('has a symbol and a highlight for every bucket', function()
    for _, b in ipairs({ 'pass', 'fail', 'running', 'pending', 'skipped', 'attention' }) do
      assert.is_string(status.symbol[b])
      assert.equals(1, vim.fn.strdisplaywidth(status.symbol[b]))
      assert.is_string(status.hl[b])
    end
  end)
end)

describe('status.manual', function()
  it('tells a job waiting on a person from one waiting on a runner', function()
    assert.is_true(status.manual('manual'))
    assert.is_false(status.manual('created'))
    assert.is_false(status.manual('pending'))
    assert.is_false(status.manual(nil))
  end)
end)
