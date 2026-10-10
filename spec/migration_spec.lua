local migration = require('ci.migration')

local github = 'https://github.com/barrettruth/ci.nvim'
local message = table.concat({
  '[ci.nvim] This repository will be removed from GitHub on October 31, 2026.',
  'Install from Forgejo: https://forge.barrettruth.com/barrettruth/ci.nvim.',
  'See :help ci-migration.',
}, ' ')

describe('migration origins', function()
  it('matches each supported GitHub URL and suffix', function()
    for _, origin in ipairs({
      github,
      'http://github.com/barrettruth/ci.nvim',
      'git://github.com/barrettruth/ci.nvim',
      'ssh://git@github.com/barrettruth/ci.nvim',
      'git@github.com:barrettruth/ci.nvim',
    }) do
      for _, suffix in ipairs({ '', '.git', '/', '.git///' }) do
        assert.is_true(migration.is_github_origin(origin .. suffix))
      end
    end
  end)

  it('rejects other hosts, repositories, owners, and values', function()
    for _, origin in ipairs({
      'https://forge.barrettruth.com/barrettruth/ci.nvim',
      'https://github.com/other/ci.nvim',
      'https://github.com/barrettruth/other.nvim',
      'https://github.com/barrettruth/ci.nvim-extra',
      'https://github.com.example/barrettruth/ci.nvim',
      '',
      false,
      1,
      {},
    }) do
      assert.is_false(migration.is_github_origin(origin))
    end
    assert.is_false(migration.is_github_origin(nil))
  end)
end)

describe('migration warning', function()
  local system, sync_system, executable, notify_once
  local command, options, on_done, notices

  before_each(function()
    system, sync_system = vim.system, vim.fn.system
    executable, notify_once = vim.fn.executable, vim.notify_once
    command, options, on_done, notices = nil, nil, nil, {}
    vim.fn.executable = function(name)
      assert.same('git', name)
      return 1
    end
    vim.fn.system = function()
      error('The migration check must not use vim.fn.system.')
    end
    vim.system = function(cmd, opts, callback)
      command, options, on_done = cmd, opts, callback
      return {
        wait = function()
          error('The migration check must not wait for Git.')
        end,
      }
    end
    vim.notify_once = function(text, level)
      notices[#notices + 1] = { text, level, vim.in_fast_event() }
    end
  end)

  after_each(function()
    vim.system, vim.fn.system = system, sync_system
    vim.fn.executable, vim.notify_once = executable, notify_once
  end)

  it('returns before Git completes and schedules the unchanged warning', function()
    migration.warn_if_github_source('/plugin root')
    assert.same({ 'git', '-C', '/plugin root', 'config', '--get', 'remote.origin.url' }, command)
    assert.same({ text = true }, options)
    assert.is_function(on_done)
    assert.same({}, notices)

    on_done({ code = 0, stdout = ' \t' .. github .. '.git\n' })
    assert.same({}, notices)
    assert.is_true(vim.wait(1000, function()
      return #notices == 1
    end))
    assert.same({ { message, vim.log.levels.WARN, false } }, notices)
  end)

  it('uses the plugin root by default', function()
    migration.warn_if_github_source()
    assert.same(migration.plugin_root(), command[3])
  end)

  it('does not notify for an unsuccessful command or an unmatched origin', function()
    for _, result in ipairs({
      { code = 1, stdout = github },
      { code = 128, stderr = 'fatal: not a git repository' },
      { code = 0 },
      { code = 0, stdout = '' },
      { code = 0, stdout = 'https://forge.barrettruth.com/barrettruth/ci.nvim' },
    }) do
      migration.warn_if_github_source('/plugin')
      on_done(result)
    end
    local drained = false
    vim.schedule(function()
      drained = true
    end)
    assert.is_true(vim.wait(1000, function()
      return drained
    end))
    assert.same({}, notices)
  end)

  it('does not start a process when Git is unavailable', function()
    vim.fn.executable = function()
      return 0
    end
    migration.warn_if_github_source('/plugin')
    assert.is_nil(command)
    assert.same({}, notices)
  end)

  it('does not report a process start failure', function()
    vim.system = function()
      error('ENOENT')
    end
    migration.warn_if_github_source('/plugin')
    assert.same({}, notices)
  end)

  it('notifies outside a fast event', function()
    migration.warn_if_github_source('/plugin')
    local fast
    local timer = assert(vim.uv.new_timer())
    timer:start(0, 0, function()
      fast = vim.in_fast_event()
      timer:close()
      on_done({ code = 0, stdout = github })
    end)
    assert.is_true(vim.wait(1000, function()
      return #notices == 1
    end))
    assert.is_true(fast)
    assert.same({ { message, vim.log.levels.WARN, false } }, notices)
  end)
end)

describe('migration Git subprocess', function()
  local root, notify_once, notices

  before_each(function()
    root = vim.fn.tempname()
    notify_once, notices = vim.notify_once, {}
    vim.notify_once = function(text, level)
      notices[#notices + 1] = { text, level, vim.in_fast_event() }
    end
    assert.same(0, vim.system({ 'git', 'init', '--quiet', root }):wait().code)
  end)

  after_each(function()
    vim.notify_once = notify_once
    vim.fn.delete(root, 'rf')
  end)

  it('reads the origin asynchronously and schedules notification', function()
    assert.same(
      0,
      vim.system({ 'git', '-C', root, 'config', 'remote.origin.url', github }):wait().code
    )
    migration.warn_if_github_source(root)
    assert.same({}, notices)
    assert.is_true(vim.wait(2000, function()
      return #notices == 1
    end))
    assert.same({ { message, vim.log.levels.WARN, false } }, notices)
  end)

  it('returns no origin when Git finds no remote', function()
    local completed, origin = false, 'pending'
    migration.origin(root, function(result)
      completed, origin = true, result
    end)
    assert.is_false(completed)
    assert.is_true(vim.wait(2000, function()
      return completed
    end))
    assert.is_nil(origin)
    assert.same({}, notices)
  end)
end)
