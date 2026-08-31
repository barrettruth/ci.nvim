local msg = require('ci.msg')

describe('progress messages', function()
  local echo

  before_each(function()
    echo = vim.api.nvim_echo
  end)

  after_each(function()
    vim.api.nvim_echo = echo
  end)

  it('describes a completed task when it finishes', function()
    local calls = {}
    vim.api.nvim_echo = function(chunks, history, opts)
      calls[#calls + 1] = { chunks, history, vim.deepcopy(opts) }
      return 7
    end

    local report = msg.progress('Loading a run', 'Loaded a run')
    report('success')

    assert.same({ { 'Loaded a run' } }, calls[2][1])
    assert.is_false(calls[2][2])
    assert.same(7, calls[2][3].id)
    assert.same('success', calls[2][3].status)
  end)
end)
