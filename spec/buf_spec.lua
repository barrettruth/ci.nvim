local buf = require('ci.buf')

describe('buf.parse', function()
  it('reads every buffer kind', function()
    assert.same(
      { host = 'github.com', repo = 'o/r', kind = 'job', id = '22' },
      buf.parse('ci://github.com/o/r/job/22')
    )
    assert.same(
      { host = 'github.com', repo = 'o/r', kind = 'run', id = '11' },
      buf.parse('ci://github.com/o/r/run/11')
    )
    assert.same(
      { host = 'github.com', repo = 'o/r', kind = 'pr', id = '7' },
      buf.parse('ci://github.com/o/r/pr/7')
    )
    assert.same(
      { host = 'github.com', repo = 'o/r', kind = 'checks', id = 'abc' },
      buf.parse('ci://github.com/o/r/checks/abc')
    )
  end)

  it('reads a run attempt', function()
    assert.same(
      { host = 'github.com', repo = 'o/r', kind = 'run', id = '11', attempt = 3 },
      buf.parse('ci://github.com/o/r/run/11/3')
    )
  end)

  it('reads a repository nested under subgroups', function()
    assert.same(
      { host = 'gitlab.com', repo = 'g/s/p', kind = 'job', id = '99' },
      buf.parse('ci://gitlab.com/g/s/p/job/99')
    )
    assert.same(
      { host = 'gitlab.com', repo = 'g/run', kind = 'run', id = '12' },
      buf.parse('ci://gitlab.com/g/run/run/12')
    )
  end)

  it('rejects anything it cannot render', function()
    assert.is_nil(buf.parse('ci://github.com/o/r/bogus/1'))
    assert.is_nil(buf.parse('ci://github.com/o/r/job'))
    assert.is_nil(buf.parse('https://github.com/o/r'))
    assert.is_nil(buf.parse('ci://'))
  end)
end)
