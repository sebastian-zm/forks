# Daily fork-sync routine

This is the runbook for the **once-a-day Cloud Routine** that keeps the forks in
this meta-repository (`airi`, `eventa`) current with their upstreams and keeps
the open pull requests rebased. Configure the daily schedule in the web UI for
the `forks` environment; this document is the prompt/instructions the routine
agent follows on each run.

> Use the `gh` CLI for **all** GitHub interactions (PRs, issues, labels). Do not
> use MCP tools. The routine is authorized to use any permission granted to the
> `GITHUB_TOKEN`.

## What runs each day

1. **Prepare the environment** (idempotent):
   ```bash
   ./setup.bash          # re-create `upstream` remotes (not tracked by git)
   ```

2. **Synchronize** — run the deterministic git/PR work:
   ```bash
   ./sync-forks.bash     # prints the path to a JSON report on stdout
   ```
   For each submodule with an `upstream` remote, this:
   - fetches `upstream` + `origin`,
   - fast-forwards the fork's default branch (`main`) to upstream and pushes it
     to `origin`,
   - for each open PR you authored against the upstream whose head branch lives
     in your fork, stages a rebase onto the branch the PR actually targets,
     fetched fresh from the upstream (`upstream/<base>`), on a throwaway
     `rebase/<head>` branch:
     - **clean** → force-pushes (`--force-with-lease`) the result to the real PR
       head (the open PR updates and re-runs upstream CI),
     - **conflict** → aborts, publishes `rebase/<head>` at the PR's current
       (un-rebased) tip as a clean place to resolve by hand, and records the
       conflict in the report. **The live PR branch is never left broken.**

   The script never opens issues — it only reports. Issue handling is step 3.

3. **Open / refresh issues for anything that wasn't clean.** Read the report
   (`.sync-forks-report.json`) and act on:
   - every `prs[]` entry with `status == "conflict"`, and
   - every `ff[]` entry with `status == "failed"` or `status == "error"`.

   Use `gh` and **deduplicate** so the daily cadence never spams issues.

### Issue conventions (dedup)

All routine issues live in **`sebastian-zm/forks`** and carry the label
`submodule-sync`. Ensure the label exists once per run:

```bash
gh label create submodule-sync \
  --repo sebastian-zm/forks \
  --color BFD4F2 \
  --description "Automated daily fork-sync routine" 2>/dev/null || true
```

Each problem maps to a **deterministic title** so repeats are detectable:

| Problem | Title |
| --- | --- |
| PR rebase conflict | `sync: rebase conflict in <upstream> PR #<number> (<head>)` |
| Default branch diverged / FF failed | `sync: <path> default branch cannot fast-forward to upstream` |

For each problem, look for an existing **open** issue with that exact title:

```bash
gh issue list --repo sebastian-zm/forks --state open --label submodule-sync \
  --search '"<title>" in:title' --json number,title \
  | jq -r '.[] | select(.title=="<title>") | .number'
```

- **If an open issue exists** → add a comment with the latest run's details
  (date, conflicting files, the `rebase/<head>` branch) rather than opening a
  duplicate.
- **If none exists** → create one:
  ```bash
  gh issue create --repo sebastian-zm/forks --label submodule-sync \
    --title "<title>" --body "<body>"
  ```

**Conflict body template:**

```
The daily fork-sync routine could not rebase an open PR cleanly.

- Submodule: <path>
- Upstream PR: <upstream>#<number> — <title>
- PR head branch: <head>
- Rebased onto: upstream/<base> (latest upstream base branch)
- Conflicting files:
  - <file>
  - ...

The un-rebased tip has been published to `<rebase_branch>` in the fork as a
clean starting point. To resolve:

    cd <path>
    git fetch origin && git fetch upstream
    git checkout <rebase_branch>          # == current PR head
    git rebase upstream/<base>             # resolve conflicts
    git push --force-with-lease origin <rebase_branch>:<head>

Then delete the helper branch: `git push origin --delete <rebase_branch>`.

Run: <generated_at>
```

**Fast-forward failure body template:**

```
The fork's default branch has diverged from upstream and can no longer be
fast-forwarded.

- Submodule: <path>
- Fork: <fork>
- Upstream: <upstream>
- Default branch: <default_branch>

The fork's `<default_branch>` has commits that are not in
`upstream/<default_branch>`. Investigate manually — the routine will not
force-update the default branch.

Run: <generated_at>
```

### Closing resolved issues (optional but recommended)

When a previously-conflicting PR comes back as `status == "rebased"` or
`"up_to_date"` (or an FF failure becomes `"updated"`/`"up_to_date"`), close the
matching open `submodule-sync` issue with a short comment noting it resolved on
`<generated_at>`. This keeps the issue list reflecting only live problems.

## Report schema

`sync-forks.bash` writes `./.sync-forks-report.json` (gitignored):

```json
{
  "generated_at": "2026-06-01T00:00:00Z",
  "ff": [
    { "type": "ff", "path": "airi", "upstream": "moeru-ai/airi",
      "fork": "sebastian-zm/airi", "default_branch": "main",
      "status": "updated|up_to_date|failed|error",
      "before": "<sha>", "after": "<sha>", "detail": "..." }
  ],
  "prs": [
    { "type": "pr", "path": "airi", "upstream": "moeru-ai/airi",
      "fork": "sebastian-zm/airi", "number": 1893,
      "head": "sebastian/feat/mdns-advertiser", "base": "main",
      "title": "...",
      "status": "rebased|up_to_date|conflict|skipped|error",
      "rebase_branch": "rebase/sebastian/feat/mdns-advertiser",
      "conflict_files": ["..."], "detail": "..." }
  ],
  "summary": { "ff_updated": 0, "ff_failed": 0,
               "pr_rebased": 0, "pr_conflicts": 0, "pr_errors": 0 }
}
```

## Scope notes

- Only PRs **you authored** against the upstream whose **head branch lives in
  your fork** are rebased (those are the ones the routine can push). Cross-fork
  PRs and PRs whose head is the default branch are reported as `skipped`.
- `clipboard-sync` is intentionally **not** managed here (its PR #44 targets
  `master` directly); sync it manually.
- The routine does **not** bump the meta-repo's pinned submodule commits — it
  only updates the forks and their PRs on GitHub.
