local glab = require('ci.glab')
local log = require('ci.log')

---@param s string
---@return string
local function stamped(s)
  return ('2026-01-01T00:00:00.000000Z 00O %s'):format(s)
end

---@param lines string[]
---@return string
local function joined(lines)
  return table.concat(lines, '\n') .. '\n'
end

--- Every place the text could be cut, which is every newline in it. A trace
--- read a piece at a time only ever breaks on one.
---@param text string
---@return integer[]
local function boundaries(text)
  local at, out = 0, {}
  while true do
    local nl = text:find('\n', at + 1, true)
    if not nl then
      return out
    end
    out[#out + 1], at = nl, nl
  end
end

describe('log.parse resumed from a carry', function()
  local text = joined({
    stamped('\27[0Ksection_start:1:outer\r\27[0K'),
    stamped('\27[0K\27[36;1mOuter section\27[0;m'),
    stamped('a line inside the outer section'),
    stamped('\27[0Ksection_start:2:inner\r\27[0KInner section'),
    stamped('a line two levels deep'),
    stamped('\27[0Ksection_end:3:inner\r\27[0K'),
    stamped('back out again'),
    stamped('\27[0Ksection_end:4:outer\r\27[0K'),
    stamped('after everything'),
  })

  it('gives the same rows as one pass, cut at any line', function()
    local once = log.parse(text, {}, glab)
    for _, cut in ipairs(boundaries(text)) do
      local head, rest = text:sub(1, cut), text:sub(cut + 1)
      local a, carry = log.parse(head, {}, glab)
      local b = log.parse(rest, {}, glab, carry)
      local got = vim.list_extend(vim.deepcopy(a), b)
      assert.same(#once, #got, ('cut at byte %d changed the row count'):format(cut))
      assert.same(once, got, ('cut at byte %d changed the rows'):format(cut))
    end
  end)

  it('gives the same rows cut at every line at once', function()
    ---@type ci.log.Row[]
    local got = {}
    local carry
    for _, cut in ipairs(boundaries(text)) do
      local piece = text:sub((carry and carry.at or 0) + 1, cut)
      local rows
      rows, carry = log.parse(piece, {}, glab, carry)
      carry.at = cut
      vim.list_extend(got, rows)
    end
    assert.same(log.parse(text, {}, glab), got)
  end)

  it('carries the group depth across the cut', function()
    local head = joined({ stamped('\27[0Ksection_start:1:outer\r\27[0KOuter') })
    local _, carry = log.parse(head, {}, glab)
    assert.same(1, carry.nest)
    local rows = log.parse(joined({ stamped('inside') }), {}, glab, carry)
    assert.same('1', rows[1].fold)
  end)

  it('carries a bare marker still waiting for its heading', function()
    local head = joined({ stamped('\27[0Ksection_start:1:outer\r\27[0K') })
    local rows, carry = log.parse(head, {}, glab)
    assert.same(0, #rows)
    assert.is_true(carry.heading)
    local next_rows = log.parse(joined({ stamped('The heading') }), {}, glab, carry)
    assert.same('>1', next_rows[1].fold)
  end)

  it('suppresses a leading blank only at the very start of a log', function()
    local first = log.parse(joined({ stamped('') }), {}, glab)
    assert.same(0, #first, 'a log that opens on a blank line draws nothing')
    local _, carry = log.parse(joined({ stamped('something') }), {}, glab)
    local later = log.parse(joined({ stamped('') }), {}, glab, carry)
    assert.same(1, #later, 'a blank line later in the log is a line')
  end)
end)
