local buf = require('ci.buf')
local gh = require('ci.gh')

local LOG = table.concat({
  '2026-07-27T15:14:08.0000000Z ##[group]Setup',
  '2026-07-27T15:14:09.0000000Z \27[32mhello\27[0m',
  '2026-07-27T15:14:10.0000000Z ##[endgroup]',
  '2026-07-27T15:14:11.0000000Z ##[error]boom',
}, '\n')

local JOB = {
  id = 22,
  head_sha = 'abc1234def',
  name = 'build',
  status = 'completed',
  conclusion = 'success',
  workflow_name = 'test',
  html_url = 'https://github.com/o/r/actions/runs/11/job/22',
  steps = {
    { name = 'Setup', number = 1, conclusion = 'success', started_at = '2026-07-27T15:14:08Z' },
  },
}

local ROLLUP = {
  repo = 'o/r',
  oid = 'abc1234def',
  headline = 'a commit',
  checks = { { name = 'build', status = 'completed', conclusion = 'success', job_id = 22 } },
}

--- Stands in for the whole `gh` layer. {over} replaces individual responses;
--- a function is called with the callback, anything else is handed back.
---@param over? table<string, any>
local function stub(over)
  over = over or {}
  local function reply(key, fallback)
    return function(_, _, cb)
      local v = over[key] == nil and fallback or over[key]
      vim.schedule(function()
        if type(v) == 'function' then
          return v(cb)
        end
        cb(v)
      end)
    end
  end
  gh.job = reply('job', JOB)
  gh.job_log = reply('log', LOG)
  gh.rollup = reply('rollup', ROLLUP)
end

--- Opens {uri} in the current window and waits for the fetch to settle,
--- which 'busy' reports whether it succeeded or failed.
---@param uri string
---@return integer
local function open(uri)
  vim.cmd('edit ' .. uri)
  local b = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(0, b)
  vim.wait(2000, function()
    return vim.bo[b].busy == 0
  end)
  vim.wait(50)
  return b
end

---@param b integer
---@return string
local function text(b)
  return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n')
end

before_each(function()
  vim.cmd('silent! %bwipeout!')
  vim.cmd('runtime! plugin/ci.lua')
  stub()
end)

describe('a job log', function()
  it('keeps the log verbatim and adds only step headers', function()
    local b = open('ci://o/r/job/22')
    local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    assert.same('2026-07-27T15:14:08.0000000Z ✓ Setup', lines[1])
    assert.same('2026-07-27T15:14:09.0000000Z hello', lines[3])
    assert.is_nil(text(b):find('\27', 1, true))
    assert.is_nil(text(b):find('endgroup', 1, true))
  end)

  it('never writes chrome into the buffer', function()
    assert.is_nil(text(open('ci://o/r/job/22')):find('Loading'))
    stub({
      log = function(cb)
        cb(nil, 'gh: Not Found (HTTP 404)')
      end,
    })
    assert.same('', text(open('ci://o/r/job/99')))
  end)

  it('keeps a skipped job navigable when its log is gone', function()
    stub({
      job = vim.tbl_extend('force', JOB, { conclusion = 'skipped' }),
      log = function(cb)
        cb(nil, 'gh: Not Found (HTTP 404)')
      end,
    })
    local b = open('ci://o/r/job/22')
    assert.same('ci://o/r/checks/abc1234def', vim.b[b].ci.up)
    assert.same(JOB.html_url, vim.b[b].ci.url)
    assert.same('build', vim.b[b].ci.title)
  end)

  it('leaves what you were reading when a refresh fails', function()
    local b = open('ci://o/r/job/22')
    local before = text(b)
    stub({
      log = function(cb)
        cb(nil, 'gh: connection refused')
      end,
    })
    vim.cmd('edit')
    vim.wait(2000, function()
      return vim.bo[b].busy == 0
    end)
    assert.same(before, text(b))
  end)
end)

describe('the timestamp column', function()
  local ns = vim.api.nvim_create_namespace('ci.time')
  local function marks(b)
    return #vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, {})
  end

  it('toggles, and survives a reload without going stale', function()
    local b = open('ci://o/r/job/22')
    assert.same(0, marks(b))

    require('ci.log').timestamps()
    assert.same(4, marks(b))

    vim.cmd('edit')
    vim.wait(2000, function()
      return vim.bo[b].busy == 0
    end)
    vim.wait(50)
    assert.same(4, marks(b))
    assert.is_true(vim.b[b].ci_times)

    require('ci.log').timestamps()
    assert.same(0, marks(b))
  end)
end)

describe('navigation', function()
  it('sends you back to the list you came from', function()
    for _, from in ipairs({ 'ci://o/r/checks/abc1234def', 'ci://o/r/pr/7' }) do
      gh.pr_by_number = function(_, _, cb)
        vim.schedule(function()
          cb({ number = 7, title = 'a pull request', headRefOid = 'abc1234def' })
        end)
      end
      open(from)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      buf.enter()
      vim.wait(2000, function()
        return vim.bo[vim.api.nvim_get_current_buf()].busy == 0
      end)
      assert.same('ci://o/r/job/22', vim.api.nvim_buf_get_name(0))
      buf.up()
      assert.same(from, vim.api.nvim_buf_get_name(0))
    end
  end)

  it('falls back to the commit for a job opened by URL', function()
    open('ci://o/r/job/22')
    buf.up()
    assert.same('ci://o/r/checks/abc1234def', vim.api.nvim_buf_get_name(0))
  end)
end)
