# Q&A: syncing and restoring a brain from Git

This guide covers the case where `/data/brain` is stored in Git and another machine clones that repository, edits it, and pushes to a remote such as GitHub. The last question covers how to restore the brain after a failure when only the repository on GitHub remains.

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

# FAQ: I edited `RESOLVER.md` directly. How do I update gbrain managed?

**Q1. Why do I need an extra step after editing the file?**

In `GBRAIN_MODE: managed`, every page write goes through gbrain so the database and file stay in sync. When you edit a file directly in `/data/brain`, the file differs from the database. gbrain calls this condition **drift**. A drifted page refuses coordinated writes (`source_changed`), and maintenance skips that page until you choose which side is authoritative.

**Q2. How do I know whether a page has drifted?**

Run `gbrain doctor`. Drift is present if you see this line:

```text
[WARN] maintenance_write_drift: 1 page(s) have a canonical file that differs from the database ...
```

**Q3. How do I identify exactly which page is different?**

```bash
gbrain sources reconcile default --brain host --audit --conflicts
```

Only pay attention to slugs with `still_present.reason: "file_database_drift"` (`resolver` is the slug for `RESOLVER.md`). Slugs with `agrees` are old conflicts that are now reconciled, while `page_missing` means the page has been deleted. These two types need no action.

**Q4. I edited the file and want the database to follow the file. Which command should I use?**

Use `--prefer file`. Follow these steps:

```bash
# 1. Back up the file (very quick and recommended)
cp /data/brain/RESOLVER.md /tmp/RESOLVER.bak.md

# 2. Preview; nothing is written yet
gbrain repair file-drift --source default --all-drifted --prefer file

# 3. Apply, using the exact hash printed by step 2
gbrain repair file-drift --source default --all-drifted --prefer file --apply --expect <hash>

# 4. Check again
gbrain doctor
```

**Q5. What should I check in the preview before applying it?**

- `file-drift: 1 item(s) to repair` and `e.g. default:resolver`: the list contains only the page you edited. Because `--all-drifted` applies to every drifted page, stop if you see an unexpected page.
- `prefer_file: ... (exactly the preferred side)` and `import the file into the page`: gbrain will import the file content into the database.
- A line such as `unknown: ... page_missing` refers to pages that have been deleted. The command does not touch them, so you can ignore it.
- The `cost` line: normally one page needs to be embedded again, at nearly zero cost.

**Q6. What stays unchanged, and what changes?**

According to the preview message, protected metadata remains from the database, tags are merged from both sides, protected takes and private fact rows are preserved. Your file is not changed because the command only imports the file into the database.

**Q7. What if I want the database to overwrite the file instead?**

Use `--prefer database` instead of `--prefer file`, following the same preview-then-apply process. Be careful because the file will be overwritten; back it up first.

**Q8. Is something broken if apply reports `STOPPED: writer_lock_unavailable`?**

No. This is behavior also seen with `repair stale-atoms`: a one-off CLI command can lose write access partway through, while progress is saved. Run the same command again and it will continue. With only one file-drift page, it usually finishes immediately. Do not delete the `.lock` file or kill the `serve` process yourself.

**Q9. Does autopilot affect this?**

If you ran `gbrain autopilot pause`, remember to run `gbrain autopilot resume` when finished. The pause state survives `gbrain upgrade` and `--install`, so autopilot will not start running again automatically if you forget.

**Q10. How can I avoid drift in the future?**

The most reliable approach is to edit pages through gbrain tools instead of editing files directly.

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

## If the brain fails and only the GitHub repository remains, how do I restore gbrain to its original state?

According to the upstream documentation on rebuilding a brain from a Git repository (`system-of-record.md`, "Disaster recovery" section), the short answer is: **content that lives in files is recoverable; content that exists only in the database is not.** The steps below should be rehearsed in advance (see section 5).

### 1. What is recoverable from GitHub, and what is lost

Upstream declares the repository to be the system of record: the database is a derived cache, and `gbrain sync && gbrain extract all` rebuilds everything from the markdown. Read the limits of that claim carefully. A newer version of the same document states explicitly that the rebuild convention only applies to knowledge that actually lives in canonical files; DB-only pages, facts not yet written into fences, audit history, and site-specific credentials cannot be recovered from markdown. The README likewise notes that DB-only pages, unresolved facts, revision history, and operational state require a separate database backup. Your earlier `gbrain backup status` run warned about exactly this.

| Recoverable from Git | Lost (not in Git) |
|---|---|
| `.md` pages, frontmatter, tags | DB-only pages (written via `database_only`) |
| Links, timelines, takes, facts inside fences in files | Facts not yet written into fences, `page_versions` history |
| Chunks and embeddings (rebuilt, **costs embed spend**) | `oauth_clients`, `access_tokens` (Hermes must be re-issued) |
| `RESOLVER.md`, `schema.md`, `gbrain.yml` if committed | `.config` settings, custom schema packs, audit logs |
| | `raw_data`, job queues, `dream_verdicts` (the last one can be rebuilt with `dream retriage --force`) |
| | Owner state: reservation, stamp, `admin_state`, `git_durability` |
| | `trust claim-sources` classifications; pages under `db_only`/gitignored paths |

Also, **only what was actually pushed is recoverable.** Untracked files: if the machine is lost before durability is enabled, they are gone. Check regularly: `git -C ~/docker/gbrain/brain status` and `git -C ~/docker/gbrain/brain log origin/master..HEAD` must be empty.

### 2. What you need outside of Git

- The compose file, `entrypoint.sh`, and Dockerfile. `~/docker/gbrain` is **not a Git repository**, so it is lost with the machine. Put these files in a separate repository (no secrets) together with a `.env.example`.
- API keys (Voyage, OpenAI), the SSH key with access to the `brain` repository, and the Postgres password. They can be re-issued, but you need somewhere to keep them (a password manager).
- The image: `skywirex/gbrain` on Docker Hub, or the Dockerfile to rebuild it. Record the tag and digest.
- `~/gbrain-backup/` currently sits on the same VM; it does not help if the machine is lost.

### 3. Recovery procedure (fresh environment, only GitHub left)

1. Rebuild the wrapper directory: compose, `.env` (new keys), and **empty** `./.config` and `./state`.
2. Clone the repository: `git clone git@github.com:magicstone1412/brain.git brain`. Check `git -C brain ls-files | grep -i gbrain-owner` to make sure no old stamp files were committed.
3. **Start with `GBRAIN_MODE=classic`.** A brain freshly cloned from Git is not yet claimed, so managed mode is not usable yet. The entrypoint will run `gbrain init` on first start (creates the schema), set `local_path`, and the sync loop will import all pages.
4. If you want to be proactive: inside the container run `gbrain sync --repo /data/brain`, then `gbrain extract all` (rebuild links, timelines, facts, takes), then `gbrain embed --stale` (preview with `--dry-run` first because it costs money).
5. Verify: compare `gbrain stats` against the baseline numbers you saved (821 pages, 3843 chunks, 755 links, 148 tags, 118 timeline; the page count may differ slightly because the old DB still had soft-deleted pages), then `gbrain doctor`.

### 4. What to redo after the data is back

1. Re-issue credentials for Hermes (new token or OAuth client) and update its configuration.
2. `gbrain trust claim-sources` (reclassify "your notes").
3. Restore hand-tuned configuration keys (`backup.remote_timeout_ms`...); custom schema packs must be recreated.
4. **Claim + activate again** following `gbrain-managed-migration-plan.md` (phases 2 through 4, skipping the old backup parts), then enable `git-durability` immediately. This time it is easier because the brain is new and clean.
5. Clean up test data and verify that `ls-remote` matches HEAD.

A variant: if you lost only the database but still have `./brain`, `./state`, and `./.config`, do not reuse a checkout that already carries a stamp and reservation, because they reference a brain id that no longer exists in the database. I have not verified how gbrain handles that. The safest option is a fresh clone from GitHub as above.

### 5. Prepare in advance so recovery actually works

1. **Verify GitHub is always up to date:** enable durability, run `gbrain backup check`, and periodically compare `git rev-parse HEAD` against `git ls-remote origin master`.
2. **`pg_dump` regularly to another machine** (object storage or another machine, encrypted). The DB-only items in the table above can only be saved this way.
3. **Rehearse recovery** in a separate compose project: different project name, its own Postgres and `./brain`, no published port 7333, no `BRAIN_REMOTE`, `AUTOPILOT_ENABLED=false`, no embed key (the entrypoint will run `--no-embedding`, costing nothing). Important: set `git remote set-url --push origin no_push` in the rehearsal checkout so it can never push to the real GitHub. Compare `gbrain stats` after `sync` and `extract all` against the baseline. Do this once a quarter.

## Upstream references

- [Topologies — gbrain](https://github.com/garrytan/gbrain/blob/master/docs/architecture/topologies.md): ownership, claim/activate, and managed persistence.
- [Shared-checkout Git](https://github.com/garrytan/gbrain/blob/master/docs/guides/shared-checkout-git.md): why direct Git operations are unsafe on managed worktrees and how checkout/remote handling works.
- [Write refusals](https://github.com/garrytan/gbrain/blob/master/docs/guides/write-refusals.md): refusal codes, causes, and recovery suggestions.
- [Troubleshooting](https://github.com/garrytan/gbrain/blob/master/docs/guides/troubleshooting.md): doctor commands and sync/effect diagnosis.

The upstream `master` pages may describe a newer release than the image you are running. When they differ, use the error message, `gbrain --version`, and the documentation shipped for that exact version as the source of truth.
