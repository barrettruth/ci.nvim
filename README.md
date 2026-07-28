# ci.nvim

**GitHub Actions CI in Neovim**

> [!NOTE]
> Development, issues, and pull requests happen on
> [Forgejo](https://forge.barrettruth.com/barrettruth/ci.nvim).
> GitHub is maintained as a read-only mirror.

![image](https://forge.barrettruth.com/attachments/d64b111f-9c84-4558-a725-1a5aea8570f5)

Experience the power of `:CI`. Native GHA logs in normal Neovim buffers with
real ANSI colours, step-level folds, and more.

## Requirements

- Neovim 0.13+
- [`gh`](https://cli.github.com), authenticated
- `git`

## Installation

With `vim.pack`:

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

Work with a `ci://` buffer via neovim-native mappings. `<CR>` opens the check
under the cursor, `-` goes back to the list you came from, walk job steps with
`[[` and `]]`, and more.

## Documentation

```vim
:help ci
```
