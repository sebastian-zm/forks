# forks

A meta-repository for managing my forks of upstream projects as git submodules.

Each submodule's `origin` points to my fork; an `upstream` remote points to the
original project so changes can be pulled in. Because a submodule's remotes are
stored in the superproject's `.git/modules/<name>/config` (which is **not**
tracked by git and **not** pushed), the `upstream` remotes are recreated by
[`setup.bash`](./setup.bash) rather than committed.

## Submodules

| Path             | Fork (`origin`)                  | Upstream                  |
| ---------------- | -------------------------------- | ------------------------- |
| `airi`           | `sebastian-zm/airi`              | `moeru-ai/airi`           |
| `eventa`         | `sebastian-zm/eventa`            | `moeru-ai/eventa`         |
| `clipboard-sync` | `sebastian-zm/clipboard-sync`    | `dnut/clipboard-sync`     |

## Getting started

After cloning this repository:

```bash
git clone https://github.com/sebastian-zm/forks.git
cd forks
./setup.bash
```

`setup.bash` initializes every submodule and (re)creates each `upstream` remote.
Pushing to `upstream` is disabled as a safeguard against pushing to the original
repositories. The script is idempotent — re-run it any time, e.g. after adding a
new submodule.

## Pulling upstream changes into a fork

Replace `<submodule>` with `airi`, `eventa`, or `clipboard-sync`, and use the
submodule's default branch (`main` or `master`).

```bash
cd <submodule>
git fetch upstream
git checkout <default-branch>
git merge upstream/<default-branch>   # or: git rebase upstream/<default-branch>
git push origin <default-branch>      # update your fork on GitHub

cd ..                                 # back to this repo
git add <submodule>                   # record the new submodule commit
git commit -m "Update <submodule> submodule to latest upstream"
git push
```

## Adding a new fork

1. Add the submodule from your fork:
   ```bash
   git submodule add https://github.com/sebastian-zm/<repo>.git <repo>
   ```
2. Register its upstream in the `UPSTREAMS` map at the top of `setup.bash`.
3. Run `./setup.bash` to wire up the new `upstream` remote.
4. Commit `.gitmodules`, the new submodule, and `setup.bash`.
