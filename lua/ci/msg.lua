local M = {}

---@param message string
---@param hl? string
---@param err? boolean
local function echo(message, hl, err)
  vim.schedule(function()
    vim.api.nvim_echo({ { ('ci: %s'):format(message), hl } }, true, { err = err })
  end)
end

---@param message string
function M.err(message)
  echo(message, nil, true)
end

---@param message string
function M.warn(message)
  echo(message, 'WarningMsg')
end

--- Announces a long task as a |progress-message|. Returns a function that
--- revises it: 'running' with a percentage, or 'success'/'failed' to end it.
--- Handing the id back is what makes one message change rather than many
--- queue up.
---@param what string
---@return fun(status: 'running'|'success'|'failed', percent?: integer)
function M.progress(what)
  local o = { kind = 'progress', source = 'ci', title = 'ci', status = 'running' }
  o.id = vim.api.nvim_echo({ { what } }, false, o)
  return function(status, percent)
    o.status, o.percent = status, percent
    vim.api.nvim_echo({ { status == 'running' and what or '' } }, false, o)
  end
end

return M
