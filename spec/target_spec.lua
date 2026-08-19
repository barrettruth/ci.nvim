local target = require('ci.target')

local GH = 'https://github.com/o/r'

describe('target.parse', function()
  it('defaults to the branch', function()
    assert.same({ kind = 'branch' }, target.parse(nil))
    assert.same({ kind = 'branch' }, target.parse(''))
    assert.same({ kind = 'branch' }, target.parse('  '))
  end)

  it('treats a bare argument as a revision, peeled to a commit', function()
    assert.same({ kind = 'rev', expr = 'master^{commit}' }, target.parse('master'))
    assert.same({ kind = 'rev', expr = 'v0.1.0^{commit}' }, target.parse('v0.1.0'))
  end)

  it('reads a bare number as a pull request', function()
    assert.same({ kind = 'pr', number = 7 }, target.parse('7'))
    assert.same({ kind = 'pr', number = 1234 }, target.parse('1234'))
  end)

  it('carries the sigil a number was written with', function()
    assert.same({ kind = 'pr', number = 7, sigil = '#' }, target.parse('#7'))
    assert.same({ kind = 'pr', number = 7, sigil = '!' }, target.parse('!7'))
  end)

  it('leaves a revision that only looks like a number', function()
    assert.same({ kind = 'rev', expr = '1234^{commit}^{commit}' }, target.parse('1234^{commit}'))
    assert.same({ kind = 'rev', expr = 'refs/heads/123^{commit}' }, target.parse('refs/heads/123'))
    assert.same({ kind = 'rev', expr = '12ab^{commit}' }, target.parse('12ab'))
    assert.same({ kind = 'rev', expr = '1.2.3^{commit}' }, target.parse('1.2.3'))
  end)

  it('takes a number no forge would mint as one', function()
    assert.same({ kind = 'rev', expr = '#7x^{commit}' }, target.parse('#7x'))
    assert.same({ kind = 'rev', expr = '#^{commit}' }, target.parse('#'))
    assert.same({ kind = 'rev', expr = '-7^{commit}' }, target.parse('-7'))
  end)

  it('reads a job URL', function()
    assert.same(
      { kind = 'job', host = 'github.com', repo = 'o/r', id = 22 },
      target.parse(GH .. '/actions/runs/11/job/22')
    )
  end)

  it('ignores a step fragment', function()
    assert.same(
      { kind = 'job', host = 'github.com', repo = 'o/r', id = 22 },
      target.parse(GH .. '/actions/runs/11/job/22#step:5:99')
    )
  end)

  it('reads runs and attempts', function()
    assert.same(
      { kind = 'run', host = 'github.com', repo = 'o/r', id = 11 },
      target.parse(GH .. '/actions/runs/11')
    )
    assert.same(
      { kind = 'run', host = 'github.com', repo = 'o/r', id = 11, attempt = 3 },
      target.parse(GH .. '/actions/runs/11/attempts/3')
    )
  end)

  it('treats a legacy check-run URL as a job', function()
    assert.same(
      { kind = 'job', host = 'github.com', repo = 'o/r', id = 22 },
      target.parse(GH .. '/runs/22')
    )
  end)

  it('reads pull requests, with and without a check', function()
    assert.same(
      { kind = 'pr', host = 'github.com', repo = 'o/r', number = 7 },
      target.parse(GH .. '/pull/7')
    )
    assert.same(
      { kind = 'pr', host = 'github.com', repo = 'o/r', number = 7 },
      target.parse(GH .. '/pull/7/checks')
    )
    assert.same(
      { kind = 'job', host = 'github.com', repo = 'o/r', id = 22 },
      target.parse(GH .. '/pull/7/checks?check_run_id=22')
    )
  end)

  it('reads commits and workflows', function()
    assert.same(
      { kind = 'rev', host = 'github.com', repo = 'o/r', expr = 'abc123^{commit}' },
      target.parse(GH .. '/commit/abc123')
    )
    assert.same(
      { kind = 'workflow', host = 'github.com', repo = 'o/r', file = 'ci.yml' },
      target.parse(GH .. '/actions/workflows/ci.yml')
    )
  end)

  it('reads Forgejo URLs', function()
    local FJ = 'https://forge.example.com/o/r'
    assert.same(
      { kind = 'run', host = 'forge.example.com', repo = 'o/r', index = 11, number = 0 },
      target.parse(FJ .. '/actions/runs/11/jobs/0')
    )
    assert.same(
      { kind = 'run', host = 'forge.example.com', repo = 'o/r', index = 11 },
      target.parse(FJ .. '/actions/runs/11')
    )
    assert.same(
      { kind = 'pr', host = 'forge.example.com', repo = 'o/r', number = 7 },
      target.parse(FJ .. '/pulls/7')
    )
    assert.same(
      { kind = 'rev', host = 'forge.example.com', repo = 'o/r', expr = 'abc123' },
      target.parse(FJ .. '/commit/abc123')
    )
  end)

  it('reads GitLab URLs, subgroups and all', function()
    local GL = 'https://gitlab.com/g/s/p'
    assert.same(
      { kind = 'run', host = 'gitlab.com', repo = 'g/s/p', id = 11 },
      target.parse(GL .. '/-/pipelines/11')
    )
    assert.same(
      { kind = 'job', host = 'gitlab.com', repo = 'g/s/p', id = 22 },
      target.parse(GL .. '/-/jobs/22')
    )
    assert.same(
      { kind = 'pr', host = 'gitlab.com', repo = 'g/s/p', number = 7 },
      target.parse(GL .. '/-/merge_requests/7')
    )
    assert.same(
      { kind = 'pr', host = 'gitlab.com', repo = 'g/s/p', number = 7 },
      target.parse(GL .. '/-/merge_requests/7/pipelines')
    )
    assert.same(
      { kind = 'rev', host = 'gitlab.com', repo = 'g/s/p', expr = 'abc123' },
      target.parse(GL .. '/-/commit/abc123')
    )
    assert.same(
      { kind = 'repo', host = 'gitlab.com', repo = 'g/s/p' },
      target.parse(GL .. '/-/pipelines')
    )
  end)

  it('rejects what it cannot serve', function()
    assert.is_nil(target.parse(GH .. '/blob/main/README.md'))
    assert.is_nil(target.parse('https://gitlab.com/o/r'))
    assert.is_nil(target.parse(GH .. '/actions/caches'))
  end)
end)

describe('forge.host', function()
  local forge = require('ci.forge')

  it('reads a host out of every remote form', function()
    for url, want in pairs({
      ['https://github.com/o/r.git'] = 'github.com',
      ['http://forge.example.com/o/r.git'] = 'forge.example.com',
      ['https://forge.example.com:3000/o/r.git'] = 'forge.example.com:3000',
      ['ssh://git@forge.example.com/o/r.git'] = 'forge.example.com',
      ['ssh://git@forge.example.com:2222/o/r.git'] = 'forge.example.com',
      ['git@github.com:o/r.git'] = 'github.com',
      ['git://github.com/o/r.git'] = 'github.com',
    }) do
      assert.same(want, forge.host_of(url), url)
    end
  end)

  it('knows which hosts gh serves', function()
    assert.is_true(forge.is_github('github.com'))
    assert.is_false(forge.is_github('forge.example.com'))
    assert.is_false(forge.is_github('notgithub.com'))
  end)

  it('knows gitlab only by name', function()
    assert.is_true(forge.is_gitlab('gitlab.com'))
    assert.is_true(forge.is_gitlab('team.gitlab.com'))
    assert.is_false(forge.is_gitlab('notgitlab.com'))
    assert.is_false(forge.is_gitlab('gitlab.example.com'))
    assert.is_false(forge.is_gitlab(nil))
  end)
end)
