# Contributing

Development, issues, and pull requests happen on
[Forgejo](https://forge.barrettruth.com/barrettruth/ci.nvim).

## Scope

ci.nvim is a Neovim plugin for CI from the editor. It is not a general task
runner, terminal multiplexer, or build system.

## Pull Requests

Bug fixes and documentation fixes are welcome. AI-generated contributions are
not accepted.

For new behavior, open an issue first unless the change is small and already
fits the project's scope.

Behavior or configuration changes should update `README.md` and `doc/ci.txt`
when appropriate.

## Development

It is preferred to use the Nix development shell, which bundles all necessary
tools:

```sh
nix develop
```

## Checks

Run the local checks before opening a pull request:

```sh
nix develop --command just ci
```
