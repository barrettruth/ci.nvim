local buf = require('ci.buf')
local ci = require('ci')
local forge = require('ci.forge')
local gh = require('ci.gh')
local glab = require('ci.glab')
local msg = require('ci.msg')

local errs, opened, saved

--- Puts the resolution on {host}, with {repo} for the answer a bare number
--- cannot carry, so `:CI` gets as far as naming a buffer with no forge to ask.
---@param host string
---@param be ci.Backend
---@param repo string
local function on(host, be, repo)
  forge.host = function()
    return host
  end
  be.repo = function(on_done)
    on_done(repo)
  end
end

describe(':CI with a number', function()
  before_each(function()
    errs, opened = {}, {}
    saved = {
      host = forge.host,
      cli = forge.cli,
      err = msg.err,
      open = buf.open,
      gh = gh.repo,
      glab = glab.repo,
    }
    forge.cli = function()
      return 'sh'
    end
    msg.err = function(m)
      errs[#errs + 1] = m
    end
    buf.open = function(uri)
      opened[#opened + 1] = uri
    end
  end)

  after_each(function()
    forge.host, forge.cli, msg.err, buf.open = saved.host, saved.cli, saved.err, saved.open
    gh.repo, glab.repo = saved.gh, saved.glab
  end)

  it('asks the forge which repository a bare number meant', function()
    on('github.com', gh, 'o/r')
    ci.run('7')
    assert.same({ 'ci://github.com/o/r/pr/7' }, opened)
    assert.same({}, errs)
  end)

  it('takes a bare number on any forge, having no sigil to disagree with', function()
    on('gitlab.com', glab, 'g/p')
    ci.run('123')
    assert.same({ 'ci://gitlab.com/g/p/pr/123' }, opened)
    assert.same({}, errs)
  end)

  it('takes the sigil its forge writes', function()
    on('github.com', gh, 'o/r')
    ci.run('#7')
    assert.same({ 'ci://github.com/o/r/pr/7' }, opened)

    on('gitlab.com', glab, 'g/p')
    ci.run('!8')
    assert.same({ 'ci://github.com/o/r/pr/7', 'ci://gitlab.com/g/p/pr/8' }, opened)
    assert.same({}, errs)
  end)

  it('turns down the sigil its forge does not, and says which it wants', function()
    on('gitlab.com', glab, 'g/p')
    ci.run('#7')
    assert.same({ 'gitlab.com writes a merge request !7, not #7' }, errs)
    assert.same({}, opened)

    on('github.com', gh, 'o/r')
    ci.run('!7')
    assert.same({
      'gitlab.com writes a merge request !7, not #7',
      'github.com writes a pull request #7, not !7',
    }, errs)
    assert.same({}, opened)
  end)

  it('keeps the repository a URL already named', function()
    on('gitlab.com', glab, 'wrong/one')
    ci.run('https://gitlab.com/g/s/p/-/merge_requests/7')
    assert.same({ 'ci://gitlab.com/g/s/p/pr/7' }, opened)
  end)

  it('reports what the forge said when it cannot name the repository', function()
    on('github.com', gh, 'o/r')
    gh.repo = function(on_done)
      on_done(nil, 'no git remotes found')
    end
    ci.run('7')
    assert.same({ 'no git remotes found' }, errs)
    assert.same({}, opened)
  end)
end)
