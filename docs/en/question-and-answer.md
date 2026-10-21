# Q&A: syncing a brain from multiple machines

This guide covers the case where `/data/brain` is stored in Git and another machine clones that repository, edits it, and pushes to a remote such as GitHub.

> **Scope:** The examples focus on `GBRAIN_MODE=managed`, which is the mode used by this repository's Compose deployment. Commands and refusal details can change between gbrain releases; when troubleshooting, follow the error and recovery suggestion from the version you are running.

## Short answer

- A commit pushed from another machine does **not automatically appear** in the brain host's checkout in managed mode.
- The upstream-supported way to bring remote commits into a managed checkout is:

  ```sh
  gbrain sources refresh default
  ```

  Then run the no-pull sync:

  ```sh
  gbrain sync --source default --no-pull
  ```

- This wrapper can refresh automatically before each sync cycle with:

  ```env
  GBRAIN_REFRESH_UPSTREAM=true
  ```

- **Do not run `git pull`, `git pull --rebase`, `git reset`, or manually edit page files in the managed checkout.** A managed worktree has its own owner/coordinator; direct Git writes may be refused or may leave the database and checkout out of sync.
- The safest way to change content from another machine is to use that machine as an **MCP client** and write through gbrain, rather than treating the brain host and the other machine as equal Git writers.

## Does the brain host notice when another machine pushes?

Not by itself when the brain host is in managed mode.

This repository's entrypoint runs:

```sh
gbrain sync --source default --no-pull
```

That command does not pull or fast-forward the checkout from its remote. After another machine pushes to `origin`, the brain host may continue using the old checkout, and `gbrain doctor` may report that the upstream is ahead by one or more commits.

With `GBRAIN_REFRESH_UPSTREAM=false` (the default), refresh it manually on the brain host:

```sh
gbrain sources refresh default
gbrain sync --source default --no-pull
```

`refresh` fast-forwards the checkout and synchronizes the changes into the database. It is not an arbitrary merge operation.

## Can the container fetch new commits automatically?

Yes. Set:

```env
GBRAIN_REFRESH_UPSTREAM=true
```

With Compose, put this in `.env` and recreate the service:

```sh
docker compose up -d --force-recreate gbrain
```

When enabled, the entrypoint performs this sequence before each sync cycle:

1. `gbrain sources refresh default`;
2. `gbrain sync --source default --no-pull`;
3. stale embedding, if an embedding key is configured.

The entrypoint's default `SYNC_INTERVAL` is `900` seconds; Compose overrides that default to `600` seconds.

Refresh is enabled only when:

- `GBRAIN_MODE=managed`; and
- the checkout has a remote named `origin`.

If refresh fails or is refused, the entrypoint logs the failure and still runs sync. Get the detailed reason with:

```sh
gbrain sources refresh default --dry-run
```

The variable is ignored in classic mode and when the repository has no `origin` remote.

## Is it safe to commit directly to the brain repository from another machine?

It should not be the normal workflow in managed mode.

A managed checkout is a **managed worktree**. Page changes should go through gbrain's persistence coordinator (`put_page`, `edit_page`, `remember`, MCP, and similar paths), so the database, files, and Git durability are updated in the intended order.

A direct commit from another machine can produce several outcomes.

### 1. The remote is simply ahead

If the brain host has not written anything new, `sources refresh` can usually fast-forward the checkout to the other machine's commit. Sync then imports the change into the database.

### 2. Both sides have commits — history diverges

For example:

1. Another machine pushes commit `A` to the remote.
2. The brain host writes a page and creates local commit `B` before it sees `A`.
3. The remote and local checkout no longer have a simple fast-forward relationship.

Then:

- the owner's push may be rejected;
- `sources refresh` may be refused because the histories diverged or the checkout is busy;
- the page may already exist in the local database/files while its Git backup or remote synchronization is still pending;
- repeatedly failed effects may be parked and reported by `gbrain doctor` as `parked_effects`.

This is a **Git durability** problem. Do not solve it by arbitrarily rebasing or resetting a checkout that gbrain manages.

### 3. Both sides edit the same page

If the file and database change in incompatible ways, gbrain may refuse the operation with an error such as `file_database_drift` instead of silently overwriting one side.

If a remote commit has been detected but not imported, writes to that page may be refused with a state such as `pending_import`. Complete refresh/sync and read the exact `suggestion` in the error before retrying.

## What is the safest workflow if another machine must push?

Keep the period with two active writers as short as possible:

1. **Prefer MCP/gbrain for writes**, rather than committing page files from another clone.
2. If you only need to read or draft, use a read-only clone; do not push to the canonical branch.
3. If committing from another machine is unavoidable:
   - verify the branch and remote before editing;
   - update that separate clone from the remote before starting;
   - edit only files the brain host is not currently writing;
   - make small commits and push promptly;
   - pause automated writers on the brain host while coordinating the handoff;
   - after the push, run on the brain host:

     ```sh
     gbrain sources refresh default --dry-run
     gbrain sources refresh default
     gbrain sync --source default --no-pull
     ```

   - verify:

     ```sh
     gbrain doctor --only sync_freshness
     gbrain doctor --only parked_effects
     gbrain sources writer status default --brain host --json
     ```

`git pull --rebase` on the **separate clone** is a preparation step for that clone. Do not run it in the managed checkout that gbrain uses as its canonical worktree.

## What should I do if refresh is refused?

Do not remove owner markers, edit the database, reset `HEAD`, or force-push. First collect the specific reason:

```sh
gbrain sources refresh default --dry-run
gbrain sources writer status default --brain host --json
gbrain doctor --only sync_freshness
gbrain doctor --only parked_effects
```

Common causes include:

- **Diverged history:** local and remote each contain commits the other lacks. Follow the error's recovery instructions; do not guess with `git pull --rebase` on the canonical checkout.
- **Dirty checkout:** there are changes that the gbrain owner has not handled. Identify the process that made them before cleaning anything.
- **Another sync/refresh is active:** wait for it to finish, then retry.
- **Writer unavailable or refused:** inspect `writer status` and use the coordinator command named by the error.
- **Git push failure or parked effects:** fix the named cause (credentials, remote, branch protection, and so on), then use gbrain's recovery suggestion. Do not force-push to hide the failure.

If the situation is unclear, back up the database and the complete `brain/` directory before intervening. The database and Git checkout are separate data layers; one may contain a change even while the other is incomplete.

## How do classic and managed differ?

| Mode | Main behavior | Suitable for |
| --- | --- | --- |
| `classic` | The entrypoint runs an auto-commit watcher and `gbrain sync --repo /data/brain`. | A simple setup where the container is the only writer. |
| `managed` | The auto-commit watcher is disabled; gbrain's owner/coordinator handles writes; sync uses `--no-pull`. | A brain with explicit ownership, coordinated persistence, and remote MCP clients. |

In managed mode, `gbrain serve` must run with a source that has already been claimed and activated. Do not switch between modes while a writer is still active. Follow upstream's runbook to quiesce, deactivate/activate, and verify the state.

## Does a Git remote automatically protect data when I push manually?

Not completely.

A push through gbrain's persistence path has its own durability and retry handling. A manual push from another clone does not pass through all of those safeguards; in particular, the owner's secret scan or other guards may not apply to a manual operation. Check secrets, the branch, and the content before pushing.

Do not commit:

- API keys, tokens, or credentials;
- private SSH keys;
- `.config`, runtime state, or sensitive data;
- files unrelated to the brain that happen to be inside the checkout.

## Upstream references

- [Topologies — gbrain](https://github.com/garrytan/gbrain/blob/master/docs/architecture/topologies.md): ownership, claim/activate, and managed persistence.
- [Shared-checkout Git](https://github.com/garrytan/gbrain/blob/master/docs/guides/shared-checkout-git.md): why direct Git operations are unsafe on managed worktrees and how checkout/remote handling works.
- [Write refusals](https://github.com/garrytan/gbrain/blob/master/docs/guides/write-refusals.md): refusal codes, causes, and recovery suggestions.
- [Troubleshooting](https://github.com/garrytan/gbrain/blob/master/docs/guides/troubleshooting.md): doctor commands and sync/effect diagnosis.

The upstream `master` pages may describe a newer release than the image you are running. When they differ, use the error message, `gbrain --version`, and the documentation shipped for that exact version as the source of truth.
