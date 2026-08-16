# ci.nvim

**GitHub and Forgejo Actions CI in Neovim**

> [!NOTE]
> Development, issues, and pull requests happen on
> [Forgejo](https://forge.barrettruth.com/barrettruth/ci.nvim).
> GitHub is maintained as a read-only mirror.

![image](https://forge.barrettruth.com/attachments/d64b111f-9c84-4558-a725-1a5aea8570f5)

Experience the power of `:CI`. Native Actions logs in normal Neovim buffers
with real ANSI colours, step-level folds, and more.

## Requirements

- Neovim 0.13+
- `git`
- [`gh`](https://cli.github.com) for github.com, authenticated
- [`tea`](https://gitea.com/gitea/tea) for Forgejo 16+, authenticated

The forge is chosen from `upstream`, else `origin`, matching how `tea` picks
the repository to query.

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

" any github.com or Forgejo CI URL
:CI https://github.com/neovim/neovim/actions/runs/30208531214/job/89810718120
:CI https://github.com/neovim/neovim/pull/40993
:CI https://codeberg.org/forgejo/forgejo/actions/runs/12

" the <cWORD> under the cursor
:CI .
```

Work with a `ci://` buffer via neovim-native mappings. `<CR>` opens the check
under the cursor, `-` goes back to the list you came from, `cr` re-runs and
`cc` cancels, walk job steps with `[[` and `]]`, and more.

## Documentation

```vim
:help ci
```

## Known limitations

- **In-progress jobs (GitHub)**: gh [does not support this](https://github.com/cli/cli/issues/3484). In-progress checks/jobs display their step status only, until completion.
- **Re-run and cancel (Forgejo)**: not supported. `cr` and `cc` are GitHub-only.
- **Steps (Forgejo)**: no step names, step folds, or `[[`/`]]`. The boundaries exist in Forgejo's database but are not served by its API.
- **Revisions (Forgejo)**: resolved with local `git rev-parse`, not by the server, so `:CI master` is your last fetch (may differ from the remote's ref).
- **Forks (Forgejo)**: `tea` resolves by remote name, preferring `upstream` over `origin`, rather than by asking the forge which repository is the base. A fork whose parent is not named `upstream` is queried as itself, and an `upstream` on a different forge is looked up on the wrong host.
- **Bare job ids (Forgejo)**: there is no single-job endpoint, so a job opened from a pasted URL shows its log without a name or status.
- **Attempts (Forgejo)**: a job id is stable across reruns and always shows the newest attempt (in contrast, GitHub mints new ids and pins). Older attempts are not reachable.
- **Old run URLs (Forgejo)**: a run URL names the run by its index, which is turned into an id by searching the last 100 runs. Older links report that rather than resolving.
