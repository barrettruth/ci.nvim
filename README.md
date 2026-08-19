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
- (Optionally) [`gh`](https://cli.github.com) for github.com
- (Optionally) [`glab`](https://gitlab.com/gitlab-org/cli) for gitlab.com
- (Optionally) [`tea`](https://gitea.com/gitea/tea) for Forgejo 16+

The forge is chosen from `upstream`, else `origin`, matching how `tea` picks
the repository to query. Only gitlab.com is recognised as GitLab; any other
host is read as Forgejo.

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
:CI 123

" any git revision, resolved by GitHub rather than locally
:CI master
:CI v0.11.0
:CI HEAD~3

" any github.com, gitlab.com or Forgejo CI URL
:CI https://github.com/neovim/neovim/actions/runs/30208531214/job/89810718120
:CI https://github.com/neovim/neovim/pull/40993
:CI https://gitlab.com/gitlab-org/cli/-/pipelines/2767853157
:CI https://gitlab.com/gitlab-org/cli/-/merge_requests/3734
:CI https://codeberg.org/forgejo/forgejo/actions/runs/12

" the <cWORD> under the cursor
:CI .
```

Work with a `ci://` buffer via neovim-native mappings. `<CR>` opens the check
under the cursor — or, on GitLab, the child pipeline a trigger job started —
`-` goes back to the list you came from, `cr` re-runs, `cc` cancels, `cp`
starts a manual job, walk job steps with `[[` and `]]`, and more.

## Documentation

```vim
:help ci
```

## Known limitations

- **Numbers (all forges)**: a bare `:CI 123` is a pull request, so a revision that is all digits needs `:CI 123^{commit}` or `:CI refs/heads/123`.
- **In-progress jobs (GitHub)**: gh [does not support this](https://github.com/cli/cli/issues/3484). In-progress checks/jobs display their step status only, until completion.
- **In-progress jobs (GitLab)**: GitLab pushes a running job's trace in bursts tens of seconds apart, so the log follows at that pace however often it is polled.
- **Steps (GitLab)**: jobs have no steps, so a log's own sections fold in their place and `[[`/`]]` move between sections. Nothing folds beneath them.
- **Stages (GitLab)**: a checks list names no stage, because a commit's statuses do not carry one. A pipeline's own job list does.
- **Re-run and cancel (GitLab)**: retrying a pipeline reaches its failed and canceled jobs and no others, so `cr` on a green pipeline says so rather than asking. A cancel under way cannot be hurried, so a second `cc` says that rather than offering a force GitLab does not have.
- **Revisions (GitLab)**: not resolved by the server, so `:CI {rev}` takes a branch, tag or SHA, and `:CI HEAD` is answered locally.
- **Re-run and cancel (Forgejo)**: not supported.
- **Steps (Forgejo)**: no step names or step folds. The boundaries exist in Forgejo's database but are not served by its API.
- **Revisions (Forgejo)**: resolved with local `git rev-parse`, not by the server, so `:CI master` is your last fetch (may differ from the remote's ref).
- **Forks (Forgejo)**: `tea` resolves by remote name, preferring `upstream` over `origin`, rather than by asking the forge which repository is the base. A fork whose parent is not named `upstream` is queried as itself, and an `upstream` on a different forge is looked up on the wrong host.
- **Bare job ids (Forgejo)**: there is no single-job endpoint, so a job opened from a pasted URL shows its log without a name or status.
- **Attempts (Forgejo)**: a job id is stable across reruns and always shows the newest attempt (in contrast, GitHub mints new ids and pins). Older attempts are not reachable.
- **Old run URLs (Forgejo)**: a run URL names the run by its index, which is turned into an id by searching the last 100 runs. Older links report that rather than resolving.
