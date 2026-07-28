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

  it('rejects anything it cannot render', function()
    assert.is_nil(buf.parse('ci://github.com/o/r/bogus/1'))
    assert.is_nil(buf.parse('ci://github.com/o/r/job'))
    assert.is_nil(buf.parse('https://github.com/o/r'))
    assert.is_nil(buf.parse('ci://'))
  end)
end)
