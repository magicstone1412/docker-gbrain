# Glossary

| Term | Short explanation |
|---|---|
| **Durability** (Git durability) | Setting that controls whether the owner **commits and pushes** each page written to Git. Off: pages only exist in the DB and in files on this machine. On: pages also exist on GitHub. |
| **`on` / `off` / `unknown`** | The three values shown in `writer status`. `unknown` means it was never set. |
| **`durability_not_enabled`** | The state of a write that completed while durability was off: the file was written but not committed. This is why the file is left untracked. |
| **`--enable`** | The enable command. Probes with `git push --dry-run`, records the setting, and queues previous writes for a catch-up commit. |
| **`push_probe`** | The read-only push test step of `--enable`. `ok: true` means SSH and permissions are sufficient. |
| **`catch_up`** | The list of uncommitted files that will be committed and pushed as soon as durability is enabled. |
| **Git effect** | The commit/push work the owner queues after each page write. |
| **Parked** | An effect that has failed repeatedly and was set aside. Inspect with `gbrain doctor --only parked_effects`. |
| **Canonical owner** | The `gbrain serve` process designated as the only place that writes pages into the source. |
| **Claim / Activate** | Claim: designate the owner for a source. Activate: turn on managed persistence. They must be done back-to-back. |
| **Managed / Classic** | Managed: the owner writes and commits. Classic: files are written freely and the entrypoint watcher auto-commits. |
| **`admin_state`** | Fingerprint of the admin state; changes after every modification. Admin commands must pass `--expected-state` to prevent blind overwrites. |
| **`--admin-intent`** | Flag that names the admin action you intend to perform, so the command does not run the wrong one. |
| **`sources refresh`** | Command that pulls new commits from `origin` into the checkout (fast-forward only), then syncs. The owner never pulls on its own. |
| **`--no-pull`** | `sync` flag for the managed brain: only imports commits already present, never pulls from the remote. |
| **DB-only** | Data that exists only in the DB, with no files. Durability does not protect it; use `pg_dump`. |
