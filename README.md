# ci.nvim

**GitHub Actions CI in Neovim**

> [!NOTE]
> Development, issues, and pull requests happen on
> [Forgejo](https://forge.barrettruth.com/barrettruth/ci.nvim).
> GitHub is maintained as a read-only mirror.

One command, `:CI`, no configuration. Logs land in a normal Neovim buffer with
real ANSI colours, two levels of folds, and the failing step already open.

Logs come from the raw Actions API rather than `gh run view --log`, which
replaces every escape byte with the literal characters `^[`. Escape sequences
are parsed into extmarks instead of being handed to a terminal channel, so the
buffer stays a text buffer — `/` search, folds, and yanking all work.

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
a job back to its run, `gX` opens github.com, `g?` shows the mappings. There is
no polling — `:e` refreshes.

`zM` in a job log collapses to the step list.

## Forks

Repository resolution is delegated entirely to `gh`, so pull requests from a
fork resolve to the base repository, where their checks actually live. This
matters: a fork with Actions enabled has its *own* runs for the same commit, so
querying the wrong side returns a confident, wrong answer rather than an error.

If `gh` picks the wrong repository, fix it once with `gh repo set-default`.

## Pickers

None are shipped. `require('ci').checks(cb)` hands you plain tables:

```lua
vim.keymap.set('n', '<leader>ci', function()
  require('ci').checks(function(checks, repo)
    vim.ui.select(checks, {
      prompt = 'CI',
      format_item = function(c) return c.name end,
    }, function(c)
      if c and c.job_id then
        vim.cmd.edit(('ci://%s/job/%d'):format(repo, c.job_id))
      end
    end)
  end)
end)
```

## Documentation

```vim
:help ci
```
