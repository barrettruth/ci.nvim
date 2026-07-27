rockspec_format = '3.0'
package = 'ci.nvim'
version = 'scm-1'

source = {
  url = 'git+https://forge.barrettruth.com/barrettruth/ci.nvim.git',
}

description = {
  summary = 'CI for Neovim',
  homepage = 'https://forge.barrettruth.com/barrettruth/ci.nvim',
  license = 'GPL-3.0',
}

dependencies = {
  'lua >= 5.1',
}

test_dependencies = {
  'nlua',
  'busted >= 2.1.1',
}

test = {
  type = 'busted',
}

build = {
  type = 'builtin',
}
