local glab = require('ci.glab')
local log = require('ci.log')

local URI = 'ci://gitlab.com/g/p/job/7'

local JOB = { id = 7, name = 'build', status = 'running' }

---@param s string
---@return string
local function stamped(s)
  return ('2026-01-01T00:00:00.000000Z 00O %s'):format(s)
end

local GROWING = table.concat({ stamped('one'), stamped('two') }, '\n') .. '\n'

--- Stands in for the `glab` layer. {over} replaces individual responses; a
--- function is called with the callback, anything else is handed back.
---@param over? table<string, any>
local function stub(over)
  over = over or {}
  ---@param key string
  ---@param argc integer where the callback sits
  ---@param fallback any
  local function reply(key, argc, fallback)
    return function(...)
      local cb = select(argc, ...)
      local v = over[key] == nil and fallback or over[key]
      vim.schedule(function()
        if type(v) == 'function' then
          return v(cb)
        end
        cb(v)
      end)
    end
  end
  glab.job = reply('job', 3, JOB)
  glab.job_log = reply('log', 3, GROWING)
  glab.job_log_from = reply('from', 4, '')
  glab.run_jobs = reply('jobs', 4, {})
end

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
---@return string[]
local function lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

before_each(function()
  vim.cmd('silent! %bwipeout!')
  vim.cmd('runtime! plugin/ci.lua')
  stub()
end)

describe('glab.finished', function()
  it('reads the closing line and no other', function()
    assert.is_true(glab.finished(stamped('\27[32;1mJob succeeded\27[0;m') .. '\n'))
    assert.is_true(glab.finished(stamped('\27[31;1mERROR: Job failed: exit code 1\27[0;m') .. '\n'))
    assert.is_true(glab.finished(stamped('Job succeeded') .. '\n\n\n'))
  end)

  it('is not fooled by a job that prints the words itself', function()
    local text = table.concat({
      stamped('+ echo Job succeeded'),
      stamped('Job succeeded'),
      stamped('running the next thing'),
    }, '\n') .. '\n'
    assert.is_false(glab.finished(text))
  end)
end)

describe('a gitlab job with no log', function()
  it('says what the job is doing rather than drawing nothing', function()
    stub({ job = { id = 7, name = 'deploy', status = 'manual' }, log = '' })
    assert.same({ '○ job is manual' }, lines(open(URI)))
  end)

  it('stops watching once the job has settled without one', function()
    stub({ job = { id = 7, name = 'gone', status = 'skipped', conclusion = 'skipped' }, log = '' })
    local b = open(URI)
    assert.same({ '⊘ job is skipped' }, lines(b))
    assert.is_falsy(vim.b[b].ci.pending)
  end)

  it('keeps watching one that has still to run', function()
    stub({ job = { id = 7, name = 'deploy', status = 'manual' }, log = '' })
    assert.is_true(vim.b[open(URI)].ci.pending)
  end)

  it('reports a settled job whose log has gone rather than restating its state', function()
    stub({
      job = { id = 7, name = 'old', status = 'failed', conclusion = 'failure' },
      log = function(cb)
        cb(nil, 'glab: 404 Job Not Found (HTTP 404)')
      end,
    })
    assert.same({ '' }, lines(open(URI)))
  end)
end)

describe('a gitlab log still being written', function()
  it('is followed a piece at a time', function()
    local b = open(URI)
    assert.is_true(log.tailing(b))
    assert.same(2, #lines(b))
  end)

  it('adds what grew and leaves what is above untouched', function()
    local b = open(URI)
    local before = lines(b)
    stub({ from = table.concat({ stamped('three'), stamped('four') }, '\n') .. '\n' })
    log.tail(b)
    vim.wait(2000, function()
      return #lines(b) > #before
    end)
    local after = lines(b)
    assert.same(4, #after)
    assert.same(before[1], after[1])
    assert.same(before[2], after[2])
  end)

  it('draws no half a line, and reads it again with the rest behind it', function()
    local b = open(URI)
    stub({ from = stamped('half a line with no newline yet') })
    log.tail(b)
    vim.wait(300)
    assert.same(2, #lines(b))
  end)

  it('leaves a log alone for longer after a read that brought nothing', function()
    local b = open(URI)
    local reads = 0
    glab.job_log_from = function(_, _, _, cb)
      reads = reads + 1
      vim.schedule(function()
        cb('')
      end)
    end
    log.tail(b)
    vim.wait(2000, function()
      return vim.bo[b].busy == 0
    end)
    assert.same(1, reads)
    log.tail(b)
    vim.wait(200)
    assert.same(1, reads)
  end)

  it('stops following once the runner writes its closing words', function()
    local b = open(URI)
    stub({ from = stamped('Job succeeded') .. '\n' })
    log.tail(b)
    vim.wait(2000, function()
      return not log.tailing(b)
    end)
    assert.is_false(log.tailing(b))
    assert.is_false(vim.b[b].ci.pending)
  end)
end)

describe('a trigger job', function()
  it('is never offered as a job of its own', function()
    stub({
      jobs = {
        { id = 1, name = 'build', status = 'success', run_id = 9 },
        { id = 2, name = 'e2e', status = 'created', run_id = 9, bridge = true },
      },
    })
    local b = open('ci://gitlab.com/g/p/run/9')
    local by_name = {}
    for _, c in pairs(vim.b[b].ci.checks or {}) do
      by_name[c.name] = c
    end
    assert.same(1, by_name.build.job_id)
    assert.is_nil(by_name.e2e.job_id)
  end)
end)
