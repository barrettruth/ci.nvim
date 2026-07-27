# ci.nvim

**GitHub Actions CI in Neovim**

> [!NOTE]
> Development, issues, and pull requests happen on
> [Forgejo](https://forge.barrettruth.com/barrettruth/ci.nvim).
> GitHub is maintained as a read-only mirror.

One command, `:CI`, no configuration. Logs land in a normal Neovim buffer with
real ANSI colours, two levels of folds, and the failing step already open.

## Requirements

- Neovim 0.11+
- [`gh`](https://cli.github.com), authenticated
- `git`

## Installation

With `vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({
  'https://forge.barrettruth.com/barrettruth/ci.nvim',
})
```

Or via [luarocks](https://luarocks.org/modules/barrettruth/ci.nvim):

```
luarocks install ci.nvim
```

## Usage

```vim
" checks for the active pull request on this branch
:CI

" any git revision, resolved by GitHub rather than locally
:CI master
:CI v0.11.0
:CI HEAD~3

" any github.com CI URL
:CI https://github.com/neovim/neovim/actions/runs/30208531214/job/89810718120
:CI https://github.com/neovim/neovim/pull/40993
:CI https://github.com/neovim/neovim/actions/workflows/test.yml

" the <cWORD> under the cursor
:CI .
```

Inside a `ci://` buffer: `<CR>` opens the check under the cursor, `-` goes from
a job back to its run, `gX` opens the checks on the remote, and `g?` shows the mappings.
Refresh buffers with `:e`/`R`.

## Documentation

```vim
:help ci
```
