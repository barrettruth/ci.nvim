local buf_util = require('ci.buf')
local gh = require('ci.gh')
local target = require('ci.target')

local M = {}

---@param msg string
local function err(msg)
  vim.notify('[ci]: ' .. msg, vim.log.levels.ERROR)
end

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
---@param on_uri fun(uri: string)
local function resolve(t, on_uri)
  if t.kind == 'job' then
    return on_uri(('ci://%s/job/%d'):format(t.repo, t.id))
  end

  if t.kind == 'run' then
    return on_uri(
      t.attempt and ('ci://%s/run/%d/%d'):format(t.repo, t.id, t.attempt)
        or ('ci://%s/run/%d'):format(t.repo, t.id)
    )
  end

  if t.kind == 'pr' and t.number then
    return on_uri(('ci://%s/pr/%d'):format(t.repo, t.number))
  end

  if t.kind == 'workflow' then
    return gh.latest_run(t.file, t.repo, function(run, e)
      if e then
        return err(e)
      end
      on_uri(('ci://%s/run/%d'):format(t.repo, run.id))
    end)
  end

  if t.kind == 'repo' then
    return gh.rollup('HEAD^{commit}', t.repo, function(res, e)
      if e then
        return err(e)
      end
      on_uri(('ci://%s/checks/%s'):format(res.repo or t.repo, res.oid))
    end)
  end

  if t.kind == 'rev' then
    return gh.rollup(t.expr, t.repo, function(res, e)
      if e then
        return err(e)
      end
      on_uri(('ci://%s/checks/%s'):format(res.repo or t.repo, res.oid))
    end)
  end

  local head = branch()
  if not head then
    return err('not in a git repository')
  end
  if head == 'HEAD' then
    return gh.rollup('HEAD^{commit}', nil, function(res, e)
      if e then
        return err(e)
      end
      on_uri(('ci://%s/checks/%s'):format(res.repo, res.oid))
    end)
  end
  gh.pr_for_branch(head, nil, function(pr, e)
    if e then
      return err(e)
    end
    if pr then
      return on_uri(('ci://%s/pr/%d'):format(pr.repo, pr.number))
    end
    gh.rollup(head .. '^{commit}', nil, function(res, e2)
      if e2 then
        return err(('no open pull request for %s, and %s'):format(head, e2))
      end
      on_uri(('ci://%s/checks/%s'):format(res.repo, res.oid))
    end)
  end)
end

---@param arg? string
---@param mods? vim.api.keyset.cmd.mods
function M.run(arg, mods)
  if arg == '.' then
    arg = vim.fn.expand('<cWORD>')
  end
  if vim.fn.executable('gh') == 0 then
    return err('gh is not on $PATH; see https://cli.github.com')
  end
  if arg and vim.startswith(arg, 'ci://') then
    return buf_util.open(arg, mods)
  end
  local t, e = target.parse(arg)
  if not t then
    return err(e or ('cannot resolve: %s'):format(arg))
  end
  resolve(t, function(uri)
    buf_util.open(uri, mods)
  end)
end

---@param buf? integer
---@return string? url
function M.url(buf)
  buf = buf or 0
  ---@type ci.BufVar?
  local b = vim.b[buf].ci
  if b and b.url then
    return b.url
  end
  local u = buf_util.parse(vim.api.nvim_buf_get_name(buf))
  if not u then
    return nil
  end
  if u.kind == 'pr' then
    return ('https://github.com/%s/pull/%s/checks'):format(u.repo, u.id)
  elseif u.kind == 'run' then
    return ('https://github.com/%s/actions/runs/%s'):format(u.repo, u.id)
  elseif u.kind == 'checks' then
    return ('https://github.com/%s/commit/%s/checks'):format(u.repo, u.id)
  end
  return ('https://github.com/%s'):format(u.repo)
end

return M
