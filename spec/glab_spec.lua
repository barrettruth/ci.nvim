local glab = require('ci.glab')
local log = require('ci.log')

---@param s string
---@return string
local function stamped(s)
  return ('2026-01-01T00:00:00.000000Z 00O %s'):format(s)
end

describe('glab.prefix', function()
  it('takes the stream flags with the stamp', function()
    local at, body = glab.prefix(stamped('hello'))
    assert.same('2026-01-01T00:00:00', at)
    assert.same('hello', body)
  end)

  it('leaves a line nothing stamped alone', function()
    local at, body = glab.prefix('plain output')
    assert.is_nil(at)
    assert.same('plain output', body)
  end)
end)

describe('glab.marks', function()
  it('names a section after the marker that is its whole line', function()
    local kind, rest = glab.marks('section_start:1787024369:step_script')
    assert.same('group', kind)
    assert.same('step_script', rest)
  end)

  it('prefers the text a marker introduces to the name inside it', function()
    local kind, rest =
      glab.marks('\27[0Ksection_start:1:coverage[collapsed=true]\r\27[0KRunning coverage report')
    assert.same('group', kind)
    assert.same('Running coverage report', rest)
  end)

  it('closes on a section end', function()
    assert.same('endgroup', glab.marks('section_end:1787024413:step_script'))
  end)

  it('ignores a line that merely mentions one', function()
    assert.is_nil(glab.marks('echo section_start:1:nope'))
  end)
end)

describe('log.parse on a forge with no steps', function()
  it('folds a section, and one inside it a level deeper', function()
    local text = table.concat({
      stamped('section_start:1:outer'),
      stamped('a'),
      stamped('section_start:2:inner'),
      stamped('b'),
      stamped('section_end:3:inner'),
      stamped('section_end:4:outer'),
    }, '\n')
    local folds = {}
    for _, r in ipairs(log.parse(text, {}, glab)) do
      folds[#folds + 1] = r.fold
    end
    assert.same({ '>1', '1', '>2', '2' }, folds)
  end)

  it('conceals the marker and shows the name', function()
    local rows = log.parse(stamped('section_start:1:step_script'), {}, glab)
    assert.same('step_script', rows[1].text:sub(rows[1].conceal + 1))
  end)
end)
