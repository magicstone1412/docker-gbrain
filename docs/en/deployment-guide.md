# Deploying gbrain with Docker

## 1. Overview

This repository provides a Docker wrapper for [gbrain](https://github.com/garrytan/gbrain). The image performs the main tasks:

- build gbrain from the upstream source;
- connect to and initialize PostgreSQL with `pgvector`;
- keep the brain at `/data/brain` as a Git repository;
- sync content and build embeddings on a schedule;
- optionally run autopilot and the job worker;
- serve an HTTP MCP server on port `7333`.

By default the entrypoint runs in `classic` mode. The `docker-compose.yml` file is configured for `managed` mode and uses the published image `skywirex/gbrain:latest`.

## 2. Requirements

- Docker with BuildKit/Buildx.
- PostgreSQL with the `pgvector` extension.
- A `DATABASE_URL` variable pointing to a database reachable from the container.
- The PostgreSQL host must resolve as `gbrain-postgres`, because the entrypoint's readiness check hard-codes the hostname and port `gbrain-postgres:5432`.
- An embedding API key is optional. Without a key, gbrain still runs, but vector search and background embedding are disabled.

## 3. Building the image

Build from the default upstream tag:

```sh
docker build -t docker-gbrain .
```

Build from a specific tag:

```sh
docker build \
  --build-arg GBRAIN_TAG=v0.60.422.0 \
  -t docker-gbrain .
```

CI uses the value in the `GBRAIN_VERSION` file to build and publish the image for `linux/amd64` and `linux/arm64`.

## 4. Running with Docker

Create a network and make sure PostgreSQL is named `gbrain-postgres`, then run the container:

```sh
docker run --rm \
  --name gbrain \
  --network gbrain-net \
  -e DATABASE_URL='postgresql://user:password@gbrain-postgres:5432/gbrain' \
  -e VOYAGE_API_KEY='pa-...' \
  -p 7333:7333 \
  -v gbrain-brain:/data/brain \
  docker-gbrain
```

After startup:

- the interface/server is available at `http://localhost:7333`;
- the MCP endpoint is typically at `http://localhost:7333/mcp`.

Inspect the container:

```sh
docker exec -it gbrain /bin/bash
```

## 5. Choosing the embedding provider

The entrypoint selects the provider in the following order:

1. `VOYAGE_API_KEY` present: uses `voyage:voyage-4`, 1024 dimensions.
2. No Voyage but `OPENAI_API_KEY` present: uses `openai:text-embedding-3-large`, 3072 dimensions.
3. No key at all: runs with `--no-embedding`.

If you switch providers on an existing database, you must re-embed the existing content:

```sh
gbrain embed --stale
```

`gbrain init` overwrites the config, so the entrypoint always re-applies the embedding configuration after the init step.

## 6. Main runtime variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | required | Connection string to PostgreSQL. |
| `VOYAGE_API_KEY` | — | API key for Voyage embedding. |
| `OPENAI_API_KEY` | — | OpenAI embedding and chat provider. |
| `ANTHROPIC_API_KEY` | — | Optional chat provider for autopilot. |
| `OPENAI_BASE_URL` | — | OpenAI-compatible endpoint; the entrypoint appends `/v1` if missing. |
| `ANTHROPIC_BASE_URL` | — | Anthropic-compatible endpoint; the entrypoint appends `/v1` if missing. |
| `GBRAIN_MODE` | `classic` | Choose `classic` or `managed`. |
| `BRAIN_DIR` | `/data/brain` | Brain path inside the container. |
| `GBRAIN_SOURCE_ID` | `default` | Source used for managed sync. |
| `SYNC_INTERVAL` | `900` | Seconds between sync/embed cycles. |
| `EMBED_MAX_USD_PER_RUN` | `1` | Spend cap per background embedding run; leave empty to disable the cap. |
| `AUTOPILOT_ENABLED` | `false` | Enable autopilot; requires an embedding key. |
| `BRAIN_REMOTE` | — | Optional Git SSH remote for the brain repository. |
| `GBRAIN_PUBLIC_URL` | — | The URL clients actually call; passed through to the OAuth issuer. |
| `GBRAIN_HOME` | — | Optional root directory for gbrain state and config. |

## 7. Write ownership and brain consistency

A Brain stores the same content in two places:

1. the `.md` files in `/data/brain` — the canonical copy (source of truth), managed by Git;
2. the PostgreSQL database — an index serving gbrain's search and operations.

The important question is deciding who is allowed to write pages so these two copies never drift apart.

The `owner_unavailable` error means the `default` source has no valid owner. When Hermes calls `put_page`, gbrain refuses the operation instead of guessing which process is allowed to write.

You can picture it as a library:

- In `classic`, anyone can put books on the shelf (write files), and the librarian takes stock periodically (sync).
- In `managed`, only one librarian accepts books at the counter, logs them, shelves them, and reports to central storage (Git). That way the shelf and the log always match.

### Claim and activate

Managed mode is set up in two steps, in that exact order and back-to-back.

#### Step 1: Claim — appoint the owner

```sh
gbrain sources writer claim default --path /data/brain
```

This records that gbrain owns the `/data/brain` directory. It creates a seal in the checkout and a registration next to the directory, preventing two gbrain instances from claiming the same directory.

If the system requires an expected admin state, add:

```sh
gbrain sources writer claim default \
  --path /data/brain \
  --expected-state <admin_state>
```

`--expected-state <admin_state>` is a safety latch: if another process just changed the admin configuration, the stale value is refused instead of overwriting the new change.

After the claim, legacy write paths — such as classic sync or writing files manually into the checkout — are blocked.

#### Step 2: Activate — open the write counter

```sh
gbrain sources writer activate default --confirm-quiesced
```

`activate` turns on managed persistence. From that moment, every write must go through a single coordination point. The `--confirm-quiesced` flag requires confirmation that no other process is still writing to the brain.

Claiming without activating is a half state: legacy sync paths are blocked but `put_page` is not yet allowed. So claim and activate must be performed within the same migration flow, after stopping/quiescing other writers.

## 8. The two operating modes

#### Classic

This is the image's default mode:

- runs an auto-commit watcher every 30 seconds;
- uses `gbrain sync --repo /data/brain`;
- fits cases where the container is the process that owns committing and syncing the brain.

#### Managed

This is the Compose default mode:

- disables the auto-commit watcher;
- uses `gbrain sync --source <GBRAIN_SOURCE_ID> --no-pull`;
- requires the source to have been claimed and activated beforehand;
- treats `gbrain serve` as the primary owner of the brain.

In managed mode, the entrypoint only reads the `git_durability` state and warns if the state is not `on`. The entrypoint never changes ownership or durability itself. If you need to enable durability, the operator must do it via the gbrain CLI, after checking a dry-run.

Do not switch a managed brain back to `classic` without deactivating the writer first. Conversely, do not use managed mode for a source that has not been claimed/activated.

## 9. Brain repository and SSH remote

Mount `/data/brain` to keep content across container recreations. On first run, the entrypoint:

1. initializes the directory as a Git repository if needed;
2. points the database's default source at this path;
3. configures `origin` and branch tracking when `BRAIN_REMOTE` and SSH keys are present.

Example with a private SSH remote:

```sh
-e BRAIN_REMOTE='git@github.com:you/brain.git' \
-v "$HOME/.ssh:/root/.ssh:ro"
```

Since `/root/.ssh` is mounted read-only, known hosts are written to `/tmp/known_hosts`. `GIT_SSH_COMMAND` must use this writable path. If no SSH keys are mounted, the repository still works local-only.

## 10. Running with Docker Compose

Compose creates its own `pgvector` PostgreSQL and waits for its health check before starting gbrain. The default stack:

- uses the published image `skywirex/gbrain:latest`, not a build from this directory;
- uses database `gbrain`, user `gbrain`, development password `gbrain123`;
- enables `GBRAIN_MODE=managed`;
- enables autopilot;
- sets `SYNC_INTERVAL=600`;
- mounts `./state` at `/data`;
- mounts `./brain` at `/data/brain`;
- mounts `./.config` at `/root/.gbrain`;
- mounts `${HOME}/.ssh` read-only at `/root/.ssh`;
- publishes port `7333` on all host interfaces.

Start it:

```sh
export VOYAGE_API_KEY=pa-...
docker compose up -d
```

Optional variables can go in a `.env` file, for example `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `SYNC_INTERVAL`, `EMBED_MAX_USD_PER_RUN`, `AUTOPILOT_ENABLED`, and `BRAIN_REMOTE`.

### Note when developing the image

Compose uses the published image. Local changes to the `Dockerfile` or `entrypoint.sh` therefore do not take effect automatically. To test local changes, build the image and run it directly, or deliberately switch the Compose service to `build: .`.

## 11. Startup sequence

The entrypoint performs the following steps:

1. Waits for `gbrain-postgres:5432` to be ready.
2. Checks for API keys and normalizes custom base URLs.
3. Checks the `pages` table to determine whether the database is already initialized.
4. Runs `gbrain init` on first run, or runs migrations for an existing database.
5. Re-applies the embedding configuration and spend cap after `init`.
6. Initializes the brain repository and updates the source's local path.
7. Runs the classic watcher or managed sync depending on `GBRAIN_MODE`.
8. Periodically syncs and embeds stale content when an embedding key is configured.
9. Optionally starts autopilot; if autopilot does not own the worker, starts `gbrain jobs work`.
10. Runs the foreground server:

```sh
gbrain serve --http --port 7333 --bind 0.0.0.0
```

If `GBRAIN_PUBLIC_URL` is set, the entrypoint appends `--public-url` so the OAuth issuer matches the URL clients actually use.

## 12. Security and operations

- Change the PostgreSQL password `gbrain123` before using the stack outside a trusted environment.
- Port `7333` is published on `0.0.0.0`; restrict it with a firewall, a private network, or a bind to a specific interface.
- Never commit API keys, SSH keys, `.config`, `brain`, or runtime state.
- Use persistent volumes/bind mounts for the database, `/data`, and `/data/brain`.
- When switching embedding providers, check the dimensions and run `gbrain embed --stale` again.
- Before using managed mode, confirm the source has the right path, has been claimed/activated, and has the correct writer policy.
