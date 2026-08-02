local api = vim.api
local buf_util = require('ci.buf')
local forge = require('ci.forge')
local msg = require('ci.msg')
local target = require('ci.target')

local M = {}

---@return string? name
local function branch()
  local r = vim.system({ 'git', 'rev-parse', '--abbrev-ref', 'HEAD' }, { text = true }):wait()
  if r.code ~= 0 then
    return nil
  end
  local name = vim.trim(r.stdout or '')
  return name ~= '' and name or nil
end

---@param t ci.Target
---@param on_uri fun(uri: string, url?: string)
---@param on_err fun(err: string)
local function resolve(t, on_uri, on_err)
  local host = t.host or forge.host()
  local be = forge.of(host)

  ---@param repo? string
  ---@param kind string
  ---@param id string|integer
  ---@param attempt? integer
  ---@return string? uri
  local function uri(repo, kind, id, attempt)
    local slug = repo or t.repo
    if not slug or not id then
      on_err('could not resolve the repository for this target')
      return nil
    end
    local base = ('ci://%s/%s/%s/%s'):format(host, slug, kind, id)
    return attempt and ('%s/%d'):format(base, attempt) or base
  end

  ---@param u? string
  ---@param url? string a browser page the resolution already learned
  local function done(u, url)
    if u then
      on_uri(u, url)
    end
  end

  if t.kind == 'job' then
    return done(uri(t.repo, 'job', t.id))
  end

  if t.kind == 'run' and t.index and be.run_by_index then
    return be.run_by_index(t.index, t.repo, function(r, e)
      if e then
        return on_err(e)
      end
      if not t.number then
        return done(uri(t.repo, 'run', r.id), r.html_url)
      end
      -- A Forgejo job URL names the job by position in its run, not by id.
      be.run_jobs(r.id, nil, t.repo, function(jobs, e2)
        if e2 then
          return on_err(e2)
        end
        local j = jobs[t.number + 1]
        if not j then
          return on_err(('run %d has no job %d'):format(t.index, t.number))
        end
        local page = require('ci.tea').job_page(r.html_url, t.number, t.attempt or j.attempt)
        done(uri(t.repo, 'job', j.id), page)
      end)
    end)
  end

  if t.kind == 'run' then
    return done(uri(t.repo, 'run', t.id, t.attempt))
  end

  if t.kind == 'pr' and t.number then
    return done(uri(t.repo, 'pr', t.number))
  end

  if t.kind == 'workflow' then
    return be.latest_run(t.file, t.repo, function(run, e)
      if e then
        return on_err(e)
      end
      done(uri(t.repo, 'run', run.id))
    end)
  end

  if t.kind == 'repo' or t.kind == 'rev' then
    local expr = (t.kind == 'rev' and t.expr) or 'HEAD^{commit}'
    return be.rollup(expr, t.repo, function(res, e)
      if e then
        return on_err(e)
      end
      done(uri(res.repo or t.repo, 'checks', res.oid))
    end)
  end

  local head = branch()
  if not head then
    return on_err('not in a git repository')
  end
  if head == 'HEAD' then
    return be.rollup('HEAD^{commit}', nil, function(res, e)
      if e then
        return on_err(e)
      end
      done(uri(res.repo, 'checks', res.oid))
    end)
  end
  be.pr_for_branch(head, nil, function(pr, e)
    if e then
      return on_err(e)
    end
    if pr then
      return done(uri(pr.repo, 'pr', pr.number))
    end
    be.rollup(head .. '^{commit}', nil, function(res, e2)
      if e2 then
        return on_err(('no open pull request for %s, and %s'):format(head, e2))
      end
      done(uri(res.repo, 'checks', res.oid))
    end)
  end)
end

---@param arg? string
---@param mods? vim.api.keyset.cmd.mods
function M.run(arg, mods)
  if arg == '.' then
    arg = (vim.fn.expand('<cWORD>'):gsub('^[%(%[{<"\']+', ''))
    arg = (arg:gsub('[%)%]}>.,;:"\']+$', ''))
  end
  if arg and vim.startswith(arg, 'ci://') then
    return buf_util.open(arg, mods)
  end
  local t, e = target.parse(arg)
  if not t then
    return msg.err(e or ('cannot resolve: %s'):format(arg))
  end
  local cli = forge.cli(t.host or forge.host())
  if vim.fn.executable(cli) == 0 then
    return msg.err(('%s is not on $PATH'):format(cli))
  end
  -- The resolving kinds ask GitHub which commit or run is meant, and there is
  -- no buffer yet to mark busy while they do.
  local report = t.kind ~= 'job' and msg.progress(('Resolving %s'):format(arg or 'HEAD'))
  -- Resolving a target is a round trip, and the window it was asked from is
  -- the one it belongs in, not whichever happens to be current by the time
  -- the answer lands.
  local from = api.nvim_get_current_win()
  resolve(t, function(uri, url)
    if report then
      report('success')
    end
    if api.nvim_win_is_valid(from) then
      api.nvim_set_current_win(from)
    end
    buf_util.open(uri, mods)
    if url then
      vim.b[0].ci = vim.tbl_extend('force', vim.b[0].ci or {}, { url = url })
    end
  end, function(e)
    if report then
      report('failed')
    end
    msg.err(e)
  end)
end

---@param buf? integer
---@return string? url
function M.url(buf)
  buf = buf or 0
  ---@type ci.BufVar?
  local b = vim.b[buf].ci
  if b and b.url and b.url ~= '' then
    return b.url
  end
  local u = buf_util.parse(vim.api.nvim_buf_get_name(buf))
  if not u then
    return nil
  end
  return forge.web(u.host, u.repo, u.kind, u.id, u.attempt)
end

return M
