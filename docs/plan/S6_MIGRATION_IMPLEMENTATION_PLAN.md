# S6 Migration Implementation Plan

## Purpose

Migrate the container process model from the monolithic `entrypoint.sh` to s6-overlay v3 while preserving every existing gbrain runtime behavior. This is a process-supervision refactor, not a gbrain feature change.

Source of truth:

- `entrypoint.sh` for current behavior
- `docs/plan/S6_MIGRATION_SPEC.md` for constraints and acceptance criteria
- `AGENTS.md` for repository runtime contract

## Scope

The migration affects:

- `Dockerfile`: install and configure s6-overlay; use `/init` as entrypoint; retain legacy entrypoint for rollback.
- `rootfs/`: new s6 initialization scripts, services, and shared shell library.
- `docker-compose.yml`: remove Docker `init: true`; retain runtime environment, mounts, ports, and shutdown grace period.
- `README.md`, `docs/en/deployment-guide.md`, `docs/vi/deployment-guide.md`, and `AGENTS.md`: document the s6 startup model and rollback path if behavior or startup instructions change.
- `docs/plan/S6_MIGRATION_SPEC.md`: replace each resolved `VERIFY` item with tested evidence and the final selected mechanism.

Do not change:

- gbrain application behavior or upstream source.
- Database administration, including `git_durability`.
- Secret values, Compose database credentials, public port exposure, or volume locations.
- The existing compatibility lock path under `/root/.gbrain`.
- The embedding-provider precedence: Voyage, then OpenAI, then no embedding.

## Compatibility Contract

The implementation must preserve these invariants.

1. When `GBRAIN_HOME` is set, `HOME` must equal it for every application process.
2. Root plus `PUID`/`PGID` must recursively repair mismatched ownership inside `.gbrain` and `BRAIN_DIR`, including old nested lock files.
3. `PUID != 0` must preserve traversal to the compatibility lock mount by applying `chmod o+x /root` during root initialization.
4. The Compose mounts at `/home/gbrain/.gbrain` and `/root/.gbrain` must continue to target the same host `.config` directory.
5. All gbrain and Git commands run as the target uid/gid whenever `PUID != 0`.
6. SSH private keys must be copied into `/home/gbrain/.ssh-runtime` with private permissions. The system SSH Include file must be root-owned and mode `0644` so normal startup processes and root `docker exec` shells can use it.
7. The database readiness check stays hard-coded to `gbrain-postgres:5432`.
8. `gbrain init` must keep the existing first-run versus migration-only behavior. Embedding configuration and paid-run preapproval must still be applied after init.
9. Classic mode runs the auto-commit watcher and classic repository sync. Managed mode never starts auto-commit and uses `gbrain sync --source <id> --no-pull`.
10. A sync, refresh, or embed failure must not stop future sync cycles.
11. Autopilot failure must not stop startup. When no autopilot launch succeeds, the standalone jobs worker must run.
12. An operator autopilot pause must survive restart and must not be automatically resumed.
13. Managed mode may only report `git_durability`; it must never change it.
14. `docker exec` does not inherit s6 container environment. SSH and access required by interactive commands must not rely solely on `with-contenv` state.
15. A stopped `gbrain serve` must cause the container to stop so Compose restart policy handles recovery. Auxiliary services must not stop the container merely because they fail.

## Phase 0: Establish the Baseline

Before editing, inspect the complete current behavior in `entrypoint.sh` and produce an implementation checklist mapping each section to its replacement script.

| Current behavior | Replacement | Runs as |
| --- | --- | --- |
| Input validation and PUID/PGID setup | `cont-init.d/00-identity` plus `lib.sh` | root |
| PostgreSQL wait, key report, endpoint normalization | `cont-init.d/10-wait-postgres` | target uid after root setup where applicable |
| Database detection, init, config patching, paid-run preapproval | `cont-init.d/20-brain-init` | target uid |
| Git repository initialization and global Git config | `cont-init.d/30-git-repo` | target uid |
| SSH runtime key/config preparation and remote tracking | `cont-init.d/35-ssh` | root for system config; target uid for key/Git operations |
| Source local-path handling | `cont-init.d/40-source` | target uid |
| Autopilot installation and launch | `cont-init.d/50-autopilot-install` | target uid |
| Managed writer durability status report | `cont-init.d/60-writer-report` | target uid |
| Classic auto-commit watcher | `services.d/autocommit` | target uid |
| Refresh, sync, and stale embedding cycle | `services.d/sync-loop` | target uid |
| Fallback standalone jobs worker | `services.d/job-worker` | target uid |
| MCP HTTP server | `services.d/serve` | target uid |

Record the exact log messages and tolerated non-zero exit paths where they are operationally useful. Do not silently turn a tolerated legacy error into a fatal s6 init failure.

## Phase 1: Prove s6-overlay Semantics in a Minimal Image

Do not migrate the application logic until these s6-overlay behaviors are demonstrated in a test image using the selected pinned v3 release.

1. Select a fixed s6-overlay v3 release.
2. Record official download URLs and SHA256 sums for the `noarch` archive and architecture-specific archives needed for `linux/amd64` and `linux/arm64`.
3. Verify `/init`, `/command/with-contenv`, and `s6-applyuidgid` are present after extraction.
4. Verify that scripts in `/etc/cont-init.d` run in lexical order before services start.
5. Verify that writing `/run/s6/container_environment/NAME` makes `NAME` available to later `with-contenv` init scripts and service `run` scripts.
6. Verify the correct, supported way for the `serve` service to request full container shutdown when it exits.
7. Verify a conditional service-disabling method before relying on it. Test either a `down` file created before service startup, a permanent exit policy, or another documented s6 mechanism.
8. Verify SIGTERM forwarding and the practical shutdown time with `S6_KILL_GRACETIME=45000`.

Document exact commands, observed output, and the final selected service-disable and container-halt mechanisms in `S6_MIGRATION_SPEC.md`. Do not use undocumented internal paths merely because they appear plausible.

## Phase 2: Create the Rootfs Layout and Shared Library

Create this layout:

```text
rootfs/
  etc/
    gbrain/
      lib.sh
    cont-init.d/
      00-identity
      10-wait-postgres
      20-brain-init
      30-git-repo
      35-ssh
      40-source
      50-autopilot-install
      60-writer-report
    services.d/
      serve/
        run
        finish
      sync-loop/
        run
        finish
      autocommit/
        run
        finish
      job-worker/
        run
        finish
```

All executable scripts should begin with:

```sh
#!/command/with-contenv sh
set -eu
```

Place shared shell behavior in `rootfs/etc/gbrain/lib.sh`:

- `is_uint`
- `require_writable`
- `fix_owner`
- `is_mountpoint`
- `refresh_upstream`
- `as_user` or `target_exec`
- `export_env`
- marker helpers for `/run/gbrain`

`as_user` must run directly for uid 0 and use `s6-applyuidgid` for a non-root target. It must preserve the necessary environment while ensuring gbrain/Git-created files are target-owned.

Use s6 environment files only for state needed by init and supervised processes, for example `PUID`, `PGID`, `HOME`, `BRAIN_DIR`, `GBRAIN_MODE`, `GBRAIN_SOURCE_ID`, refresh enablement, sync interval, and embed cap. Keep runtime-only ownership state such as `autopilot-owned` in `/run/gbrain`.

## Phase 3: Implement Root Identity Initialization

Implement `00-identity` as the only init step that requires root privileges.

1. Validate `GBRAIN_MODE`, `BRAIN_DIR`, `GBRAIN_SOURCE_ID`, and `GBRAIN_REFRESH_UPSTREAM` exactly as the legacy script does.
2. Resolve `PUID` and `PGID`, defaulting to root behavior where unset.
3. Set and export `HOME` from `GBRAIN_HOME` when configured.
4. Create the target home, gbrain config directory, brain directory, and `/run/gbrain` as needed.
5. When running root with non-root `PUID`:
   - run `chmod o+x /root`;
   - remove the old SSH runtime directory before recreating it later;
   - recursively repair ownership under the gbrain config and brain directories;
   - shallowly repair the target home and parent directory of `BRAIN_DIR`.
6. Do not delete, relocate, recreate, or otherwise alter recorded files under `persistence/locks` beyond the required ownership repair.
7. Check that the persistent config directory is writable and exit `77` with the legacy actionable error if it is not.
8. Write `/etc/ssh/ssh_config.d/50-gbrain.conf` as root, root-owned, mode `0644`, pointing at the fixed SSH runtime config path.
9. Export common values into s6 container environment files for later scripts.

Test with a root-owned lock file several directories below `.config/persistence/locks`; after root startup with `PUID=1000`, it must belong to uid/gid 1000 and remain at the same path.

## Phase 4: Implement Initialization Steps

### `10-wait-postgres`

- Wait indefinitely for `gbrain-postgres:5432` using the existing readiness behavior.
- Report provider availability without printing keys.
- Normalize `OPENAI_BASE_URL` and `ANTHROPIC_BASE_URL` by appending `/v1` only when missing.
- Export normalized values for services if needed.

### `20-brain-init`

Run all gbrain commands as the target uid.

1. Detect existing setup through the `pages` table.
2. Select embedding settings in this exact order: Voyage, OpenAI, no embedding.
3. Preserve separate first initialization and migration-only gbrain init calls.
4. Preserve tolerated non-zero exit handling and warning text intent.
5. Patch embedding model and dimensions after `gbrain init` rewrites config.
6. Apply `consent.preapprove.paid.max_usd_per_run` after init when non-empty.
7. Ensure temporary config files are target-owned.

### `30-git-repo`

Run Git as the target uid.

- Create and validate `BRAIN_DIR`.
- Preserve mount warnings for brain root and managed-mode parent directory.
- Set Git editor, pull, and conflict configuration.
- Add `safe.directory` only when it is absent.
- Initialize a repository and empty initial commit when no `.git` directory exists.
- Preserve existing Git identity setup.

### `35-ssh`

Separate root-only and target-user work carefully.

- Search mounted SSH keys in the legacy order.
- Copy readable private keys to `/home/gbrain/.ssh-runtime` with directory mode `0700` and key mode `0600`.
- Produce runtime SSH config and known-hosts data.
- Keep the global Include file root-owned and readable so root `docker exec` shells work.
- Preserve SSH options including `IdentitiesOnly`, `StrictHostKeyChecking=accept-new`, and the writable known-hosts location.
- Configure `origin`, fetch the current branch, and set upstream only when usable keys and a remote exist.
- Do not log keys or credentials.

### `40-source`

- In classic mode, set the source path only when it differs.
- In managed mode, never rewrite the recorded source path.
- Fail clearly when managed `sources.local_path` differs from `BRAIN_DIR`.

### `50-autopilot-install`

Run as the target uid and preserve all legacy safety behavior.

1. Require an embedding key when `AUTOPILOT_ENABLED=true`.
2. Remove stale persistent `autopilot.lock` and `autopilot.pid` at each new container boot.
3. Rotate `autopilot.log` and keep the newest five historical files.
4. Run `gbrain autopilot --install --yes --no-inject --brain host`.
5. Parse `Start script:` first, then use the legacy fallback discovery order.
6. Reject and rename a legacy script that contains `/root/.gbrain` if current config is elsewhere.
7. Mirror relevant live keys and endpoint variables into `~/.gbrain/env` with mode `0600`, without logging secret values.
8. Launch the generated script without an extra background operator because the generated script backgrounds itself.
9. Write `autopilot-owned=true` only after the script launch returns success; write `false` otherwise.
10. Run the read-only status check with a timeout, but never fail startup due to status output.
11. Never remove the operator pause marker and never automatically resume a daemon.

Keep autopilot as init-launched unless upstream demonstrates a supported foreground mode. Do not infer a foreground mode from implementation details.

### `60-writer-report`

In managed mode only:

- Read writer status JSON.
- Report whether `git_durability` is `on` or `enabled`.
- Warn with the existing operator guidance otherwise.
- Never activate ownership or change durability.

## Phase 5: Implement Supervised Services

### `serve`

`services.d/serve/run` must execute the real gbrain server process under the target uid:

```sh
gbrain serve --http --port 7333 --bind 0.0.0.0
```

Append `--public-url "$GBRAIN_PUBLIC_URL"` only when it is configured.

Its tested `finish` behavior must request full container termination when the server exits, so Compose restart policy remains equivalent to the former PID 1 behavior.

### `sync-loop`

Run as target uid. Preserve this cycle:

1. In managed mode with refresh enabled and an `origin` remote, attempt `gbrain sources refresh <source>`.
2. Log and continue if refresh is refused or fails.
3. Run classic repository sync or managed `--source ... --no-pull` sync as appropriate.
4. Run stale embedding only after successful sync and only when an embedding key exists.
5. Include `--max-usd` when `EMBED_MAX_USD_PER_RUN` is non-empty.
6. Wait for `SYNC_INTERVAL`, whose entrypoint default remains 900 seconds.

A single cycle failure must not end future cycles. If using one-cycle service invocations, ensure s6 restart behavior includes an intentional delay and does not become a rapid failure loop.

### `autocommit`

Run only in classic mode, as target uid. Preserve the legacy 30-second auto-commit behavior and error handling. Disable the service through the selected and proven s6 conditional-service mechanism in managed mode.

### `job-worker`

Run `gbrain jobs work` as the target uid only when `/run/gbrain/autopilot-owned` is not `true`. Disable it through the selected and proven s6 mechanism when autopilot owns the worker. A worker failure may restart the worker but must not halt the container.

## Phase 6: Update the Image and Compose Configuration

### Dockerfile

1. Add `xz-utils` while retaining existing runtime dependencies.
2. Download fixed-version s6-overlay `noarch` and architecture tarballs.
3. Verify SHA256 checksums before extraction.
4. Extract s6-overlay into `/`.
5. Copy the `rootfs/` tree and mark all scripts executable.
6. Keep `GBRAIN_HOME`, existing uid 1000 setup, application read permissions, and runtime SSH Include location.
7. Preserve the old script as `/entrypoint.legacy.sh`.
8. Add the confirmed s6 runtime environment values, initially:

```dockerfile
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_KILL_GRACETIME=45000
```

9. Replace the entrypoint with:

```dockerfile
ENTRYPOINT ["/init"]
```

The final Dockerfile must build for both CI target architectures without downloading architecture-incompatible archives.

### Compose

1. Remove `init: true` because s6 must be PID 1.
2. Retain `stop_grace_period: 60s` and verify it exceeds s6 shutdown behavior plus server drain time.
3. Retain all current environment variables, mounts, dependencies, networks, ports, and logging configuration.
4. Retain both `.config` mounts, including `/root/.gbrain` compatibility mount.
5. Do not change the default published image strategy unless separately requested.

Document rollback as an explicit temporary override:

```yaml
entrypoint: ["/entrypoint.legacy.sh"]
init: true
```

Do not make legacy mode the default after the migration.

## Phase 7: Documentation and Contract Updates

Update user-facing documentation after the runtime behavior is proven:

- Replace statements that describe `entrypoint.sh` as PID 1 with the s6 model.
- Explain that s6 supervises server, sync, auto-commit, and fallback worker processes.
- Keep runtime variables and default values unchanged.
- Preserve the warning that Compose uses a published image and local Dockerfile changes need a deliberate local-image test path.
- Document the legacy rollback override.
- Explain why both `.config` mounts and `/root` traversal remain intentional compatibility behavior.

Update `AGENTS.md` to state that `/init` is the image entrypoint and describe the service ownership rules. Update the migration spec with resolved `VERIFY` evidence and remove claims that remain untested.

## Phase 8: Disposable Test Fixtures and Cleanup

Run runtime validation only against isolated, disposable state. Never point these tests at the normal Compose project, production database, real brain checkout, real `.config`, or real SSH keys: several acceptance cases intentionally run recursive ownership repair, remove stale autopilot files, and create or modify database state.

Create a dedicated test Compose definition or override named `docker-compose.s6-test.yml` with a separate project name and directories:

```text
fixtures/s6-test/
  state/                 # bind-mounted at /data
  brain/                 # bind-mounted at /data/brain
  config/                # bind-mounted at both gbrain config paths
  ssh/                   # optional throwaway test key only
```

Use the local image built for this migration, a disposable PostgreSQL volume, and an unprivileged local-only port such as `127.0.0.1:17333:7333`. Default fixture settings should be:

```text
AUTOPILOT_ENABLED=false
BRAIN_REMOTE=
VOYAGE_API_KEY=
OPENAI_API_KEY=
ANTHROPIC_API_KEY=
```

Run explicit variants only when a test needs them:

- root variant: `PUID=0 PGID=0`;
- target-user variant: `PUID=1000 PGID=1000`;
- classic and managed mode variants use separate fixture project names or fully cleaned fixture state;
- SSH tests use a throwaway key and a disposable remote, never host credentials;
- autopilot tests use controlled generated-script fixtures and must not use paid API keys unless an intentionally bounded integration test is approved.

Before the non-root ownership test, create a nested root-owned lock fixture under `fixtures/s6-test/config/persistence/locks/`. Afterward, assert that startup repaired its ownership without relocating it.

Use a distinct project name for every test run, for example:

```sh
docker compose -p gbrain-s6-test -f docker-compose.s6-test.yml up -d --force-recreate
```

Tear down test containers, anonymous resources, named test volumes, and bind-mounted fixture data when the run is complete:

```sh
docker compose -p gbrain-s6-test -f docker-compose.s6-test.yml down -v --remove-orphans
rm -rf fixtures/s6-test/state fixtures/s6-test/brain fixtures/s6-test/config fixtures/s6-test/ssh
```

Do not run the cleanup command from a directory where `fixtures/s6-test` is a symlink or has been repointed to user data. Verify the resolved paths before deletion.

## Phase 9: Verification Matrix

Run all checks against the disposable fixtures above and a PostgreSQL service resolvable as `gbrain-postgres:5432`.

### Static checks

```sh
find rootfs -type f \( -path '*/cont-init.d/*' -o -path '*/services.d/*' -o -name 'lib.sh' \) -exec sh -n {} \;
shellcheck -s sh rootfs/etc/gbrain/lib.sh rootfs/etc/cont-init.d/* rootfs/etc/services.d/*/run rootfs/etc/services.d/*/finish
git diff --check
git status --short
```

Record ShellCheck findings if it is unavailable or cannot be made clean without changing behavior.

### Image build

```sh
docker build -t docker-gbrain-s6 .
docker run --rm --entrypoint /bin/sh docker-gbrain-s6 -c 'test -x /init && test -x /command/with-contenv && command -v s6-applyuidgid && test -x /etc/cont-init.d/00-identity && test -x /etc/services.d/serve/run && test -f /entrypoint.legacy.sh'
```

### Root runtime

Start with root behavior, not Compose's default `PUID=1000`:

```sh
PUID=0 PGID=0 docker compose -p gbrain-s6-test -f docker-compose.s6-test.yml up -d --force-recreate gbrain
docker exec gbrain id
curl -fsS http://127.0.0.1:17333/health
docker logs gbrain
```

Pass conditions:

- `id` is root.
- HTTP health endpoint responds successfully.
- sync loop logs at least one cycle.
- server is supervised by s6.

### Non-root runtime and lock compatibility

```sh
PUID=1000 PGID=1000 docker compose -p gbrain-s6-test -f docker-compose.s6-test.yml up -d --force-recreate gbrain
docker top gbrain
docker logs gbrain
```

Before startup, create a root-owned nested lock file under `fixtures/s6-test/config/persistence/locks`. After startup verify:

- server, sync service, and fallback worker where enabled use uid 1000;
- nested lock ownership changes to 1000:1000;
- no `EACCES` appears;
- `gbrain sources writer status --json` reports a usable lock path;
- `namei -l` can traverse its `/root/.gbrain/...` path as uid 1000;
- after manually setting `/root` to `0700` and restarting, `00-identity` restores traversability.

### SSH

```sh
docker exec gbrain ssh -G github.com
docker exec -u 1000:1000 gbrain gbrain sources refresh default
```

Pass conditions:

- generated SSH settings identify `/home/gbrain/.ssh-runtime` paths;
- no `Bad owner or permissions` failure occurs in a root `docker exec` shell;
- target uid does not prompt for an SSH host fingerprint.

### Autopilot and worker fallback

Test these cases using disposable configuration:

1. A stale generated script that contains `/root/.gbrain` is ignored and renamed aside.
2. A generated script that exits non-zero does not stop the container.
3. Failed or absent autopilot launch enables the standalone jobs worker.
4. Successful launcher execution prevents a duplicate standalone worker.
5. Status check failure, pause status, and initial startup status do not stop the container.
6. An autopilot pause marker remains after restart and is not lifted automatically.

### Supervision

```sh
docker exec gbrain pkill -f 'gbrain sync'
docker exec gbrain pkill -f 'gbrain serve'
```

Pass conditions:

- sync activity resumes after the expected restart/next cycle;
- killing `gbrain serve` stops the container and Compose restarts it through `unless-stopped`.

### Graceful shutdown

```sh
time docker compose -p gbrain-s6-test -f docker-compose.s6-test.yml stop
```

Pass conditions:

- the stack stops within `stop_grace_period`;
- no avoidable SIGKILL occurs;
- worker and server receive orderly termination.

### Rollback

Apply the temporary legacy entrypoint override, restore Docker `init: true`, and start against the same disposable state. Verify legacy startup, existing config, source path, and lock path remain usable. Do not delete data as part of rollback.

## Deliverables

The implementation is complete only when it includes:

1. Pinned and checksum-verified s6-overlay installation.
2. New `rootfs` initialization and service scripts.
3. Preserved `/entrypoint.legacy.sh` rollback artifact.
4. Compose update removing `init: true` while retaining all mounts and runtime settings.
5. Documentation updates matching the proven process model.
6. Updated migration spec with every `VERIFY` result and selected design decision.
7. A concise acceptance report containing each test, command, result, and unresolved item.

## Explicitly Deferred

- Converting autopilot to an s6 longrun service unless upstream exposes and testing confirms a supported foreground mode.
- Guaranteeing direct non-root container launch via `user: "1000:1000"` if s6-overlay does not support it reliably; the supported path for this migration is root startup plus `PUID`/`PGID`.
- Changing gbrain writer ownership, durability, source management, or database configuration.
- Moving the recorded coordination lock to another directory.
- Adding a test framework, new runtime dependency, or unrelated configuration abstraction.

## Risks and Decision Gates

The highest-risk integration points are s6 container-halt semantics, conditional service disabling, target-uid execution, and old lock compatibility under `/root/.gbrain`.

Do not merge or publish the image until:

- the selected s6 version and checksums have been verified for both CI architectures;
- `serve` exit behavior and auxiliary-service behavior are proven in Docker;
- both root and `PUID=1000` startup paths pass against disposable persistent mounts;
- SSH works for both target uid processes and root `docker exec` shells;
- the legacy rollback path has been exercised;
- every acceptance item is marked pass, fail with a remediation, or explicitly untested with the reason.
