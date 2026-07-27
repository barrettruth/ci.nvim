---@param message string
---@param level? integer
return function(message, level)
  vim.schedule(function()
    local hl = level == vim.log.levels.WARN and 'WarningMsg' or nil
    vim.api.nvim_echo({ { ('ci: %s'):format(message), hl } }, true, {
      err = level == vim.log.levels.ERROR,
    })
  end)
end
