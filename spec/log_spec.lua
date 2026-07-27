local log = require('ci.log')

---@param at string
---@param body string
---@return string
local function ts(at, body)
  return ('2026-01-01T00:00:%sZ %s'):format(at, body)
end

local STEPS = {
  { number = 1, name = 'Set up job', conclusion = 'success', started_at = '2026-01-01T00:00:00Z' },
  { number = 2, name = 'Build', conclusion = 'success', started_at = '2026-01-01T00:00:10Z' },
  { number = 3, name = 'Test', conclusion = 'failure', started_at = '2026-01-01T00:00:20Z' },
}

---@param steps table[]
---@return table[]
local function usable(steps)
  local out = {}
  for i, s in ipairs(steps) do
    out[#out + 1] = {
      name = s.name,
      conclusion = s.conclusion,
      status = s.status,
      at = s.started_at:sub(1, 19),
      number = s.number or i,
    }
  end
  return out
end

describe('log.parse', function()
  local text = table.concat({
    ts('00.0000000', 'Current runner version'),
    ts('01.0000000', '##[group]Runner Image'),
    ts('02.0000000', 'Ubuntu'),
    ts('03.0000000', '##[endgroup]'),
    ts('10.0000000', 'compiling'),
    ts('20.0000000', 'running tests'),
    ts('21.0000000', '##[error]Process completed with exit code 1.'),
  }, '\n')

  local rows = log.parse(text, usable(STEPS))

  it('emits one header per step, in step order', function()
    local headers = {}
    for _, r in ipairs(rows) do
      if r.step then
        headers[#headers + 1] = r.text
      end
    end
    assert.same({ '✓ Set up job', '✓ Build', '✗ Test' }, headers)
  end)

  it('starts a fold at every step header', function()
    for _, r in ipairs(rows) do
      if r.step then
        assert.equals('>1', r.fold)
      end
    end
  end)

  it('nests groups one level deeper and drops the markers', function()
    local group, inner
    for i, r in ipairs(rows) do
      if r.text == 'Runner Image' then
        group, inner = r, rows[i + 1]
      end
      assert.is_nil(r.text:match('^##%['))
    end
    assert.equals('>2', group.fold)
    assert.equals('2', inner.fold)
  end)

  it('strips timestamps', function()
    for _, r in ipairs(rows) do
      assert.is_nil(r.text:match('^%d%d%d%d%-%d%d%-%d%d'))
    end
  end)

  it('lifts errors out of groups so folding never hides them', function()
    local hit
    for _, r in ipairs(rows) do
      if r.hl == 'CiFail' and not r.step then
        hit = r
      end
    end
    assert.equals('Process completed with exit code 1.', hit.text)
    assert.equals('1', hit.fold)
  end)

  it('keeps step order when timestamps tie', function()
    local tied = usable({
      { number = 1, name = 'a', conclusion = 'success', started_at = '2026-01-01T00:00:00Z' },
      { number = 2, name = 'b', conclusion = 'success', started_at = '2026-01-01T00:00:00Z' },
      { number = 3, name = 'c', conclusion = 'failure', started_at = '2026-01-01T00:00:00Z' },
    })
    local names = {}
    for _, r in ipairs(log.parse(ts('00.0000000', 'x'), tied)) do
      if r.step then
        names[#names + 1] = r.text:sub(-1)
      end
    end
    assert.same({ 'a', 'b', 'c' }, names)
  end)
end)
