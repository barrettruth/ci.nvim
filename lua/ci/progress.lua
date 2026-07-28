--- Announces a long task as a |progress-message|. Returns a function that
--- revises it: 'running' with a percentage, or 'success'/'failed' to end it.
--- Handing the id back is what makes one message change rather than many
--- queue up.
---@param what string
---@return fun(status: 'running'|'success'|'failed', percent?: integer)
return function(what)
  local o = { kind = 'progress', source = 'ci', title = 'ci', status = 'running' }
  o.id = vim.api.nvim_echo({ { what } }, false, o)
  return function(status, percent)
    o.status, o.percent = status, percent
    vim.api.nvim_echo({ { status == 'running' and what or '' } }, false, o)
  end
end
