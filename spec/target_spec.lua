local target = require('ci.target')

local GH = 'https://github.com/o/r'

describe('target.parse', function()
  it('defaults to the active pull request', function()
    assert.same({ kind = 'pr' }, target.parse(nil))
    assert.same({ kind = 'pr' }, target.parse(''))
  end)

  it('treats a bare argument as a revision, peeled to a commit', function()
    assert.same({ kind = 'rev', expr = 'master^{commit}' }, target.parse('master'))
    assert.same({ kind = 'rev', expr = 'v0.1.0^{commit}' }, target.parse('v0.1.0'))
  end)

  it('reads a job URL', function()
    assert.same(
      { kind = 'job', repo = 'o/r', id = 22 },
      target.parse(GH .. '/actions/runs/11/job/22')
    )
  end)

  it('ignores a step fragment', function()
    assert.same(
      { kind = 'job', repo = 'o/r', id = 22 },
      target.parse(GH .. '/actions/runs/11/job/22#step:5:99')
    )
  end)

  it('reads runs and attempts', function()
    assert.same({ kind = 'run', repo = 'o/r', id = 11 }, target.parse(GH .. '/actions/runs/11'))
    assert.same(
      { kind = 'run', repo = 'o/r', id = 11, attempt = 3 },
      target.parse(GH .. '/actions/runs/11/attempts/3')
    )
  end)

  it('treats a legacy check-run URL as a job', function()
    assert.same({ kind = 'job', repo = 'o/r', id = 22 }, target.parse(GH .. '/runs/22'))
  end)

  it('reads pull requests, with and without a check', function()
    assert.same({ kind = 'pr', repo = 'o/r', number = 7 }, target.parse(GH .. '/pull/7'))
    assert.same({ kind = 'pr', repo = 'o/r', number = 7 }, target.parse(GH .. '/pull/7/checks'))
    assert.same(
      { kind = 'job', repo = 'o/r', id = 22 },
      target.parse(GH .. '/pull/7/checks?check_run_id=22')
    )
  end)

  it('reads commits and workflows', function()
    assert.same(
      { kind = 'rev', repo = 'o/r', expr = 'abc123^{commit}' },
      target.parse(GH .. '/commit/abc123')
    )
    assert.same(
      { kind = 'workflow', repo = 'o/r', file = 'ci.yml' },
      target.parse(GH .. '/actions/workflows/ci.yml')
    )
  end)

  it('rejects what it cannot serve', function()
    assert.is_nil(target.parse(GH .. '/blob/main/README.md'))
    assert.is_nil(target.parse('https://gitlab.com/o/r'))
    assert.is_nil(target.parse(GH .. '/actions/caches'))
  end)
end)
