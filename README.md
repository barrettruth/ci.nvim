# ci.nvim

**GitHub Actions, GitLab CI/CD and Forgejo Actions in Neovim**

> [!NOTE]
> Development, issues, and pull requests happen on
> [Forgejo](https://forge.barrettruth.com/barrettruth/ci.nvim).
> GitHub is maintained as a read-only mirror.

<img width="1728" height="1057" alt="image" src="https://github.com/user-attachments/assets/306e710e-6f80-4e0d-b00d-632acdcaf9b9" />

Experience the power of `:CI`. Native CI logs in normal Neovim buffers with
real ANSI colours, step-level folds, and more.

## Requirements

- Neovim 0.13+
- `git`
- At least one of:
  - [`gh`](https://cli.github.com), authenticated (`gh auth login`), for github.com
  - [`glab`](https://gitlab.com/gitlab-org/cli), authenticated (`glab auth login`), for gitlab.com
  - [`tea`](https://gitea.com/gitea/tea), authenticated (`tea login add`), for Forgejo 16+

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
:CI 123

" git revision
:CI master
:CI v0.11.0
:CI HEAD~3

" github.com, gitlab.com or Forgejo CI URLs
:CI https://github.com/neovim/neovim/actions/runs/30208531214/job/89810718120
:CI https://github.com/neovim/neovim/pull/40993
:CI https://gitlab.com/gitlab-org/cli/-/pipelines/2767853157
:CI https://gitlab.com/gitlab-org/cli/-/merge_requests/3734
:CI https://codeberg.org/forgejo/forgejo/actions/runs/12

" the <cWORD> under the cursor
:CI .
```

Without an argument, `:CI` falls back to branch-head checks if no pull request
is open.

Work with a `ci://` buffer via buffer-local mappings. `<CR>` opens the check
under the cursor, and `-` goes back to the list you came from. Walk log steps
or sections with `[[` and `]]`.

Automatic refresh is best-effort. Use `R` or `:e` to reload a stale buffer.

## Documentation

```vim
:help ci
```

## Known limitations

- **Numbers (all forges)**: a bare `:CI 123` is a pull or merge request. Use `:CI refs/heads/123` for a numeric branch name.
- **In-progress jobs (GitHub)**: gh [cannot fetch running logs](https://github.com/cli/cli/issues/3484). Running jobs display their step status instead.
- **In-progress jobs (GitLab)**: pipeline views show job statuses. Opening a job follows its trace best-effort; updates can arrive in bursts tens of seconds apart.
- **Steps (GitLab)**: jobs have no steps, so a log's own sections fold in their place and `[[`/`]]` move between sections. Nothing folds beneath them.
- **Stages (GitLab)**: a checks list names no stage, because a commit's statuses do not carry one. A pipeline's own job list does.
- **Revisions (GitLab)**: branches, tags and SHAs are resolved by the server; `HEAD` is resolved locally. Git revision expressions such as `HEAD~3` are not supported.
- **In-progress jobs (Forgejo)**: logs are reloaded in full until a runner completion marker is found. A job buffer's status is not refreshed.
- **Re-run and cancel (Forgejo)**: unsuppported
- **Steps (Forgejo)**: logs fold on `##[group]` alone, which may be less
  accurate than Github and GitLab.
