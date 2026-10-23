# docker-gbrain

Docker wrapper for [gbrain](https://github.com/garrytan/gbrain). The image builds gbrain from upstream source, initializes it against PostgreSQL, persists the brain as a Git repository, and exposes gbrain's HTTP MCP server on port `7333`.

This repository contains the image build and the runtime entrypoint. The checked-in Compose file is a managed-mode deployment template for the published image.

## What is in this repository

- `Dockerfile` — multi-stage Bun image build. By default it resolves the newest upstream `v*` tag; CI passes the pinned value from `GBRAIN_VERSION`.
- `entrypoint.sh` — database initialization, embedding configuration, brain-repository setup, sync/embed jobs, optional autopilot, job worker, and the foreground MCP server.
- `docker-compose.yml` — managed-mode deployment template using the published `skywirex/gbrain:latest` image.
- `GBRAIN_VERSION` — upstream tag used by CI (`v0.60.413.0` currently).
- `docs/` — deployment guide, multi-node Q&A, and glossary, in English (`docs/en/`) and Vietnamese (`docs/vi/`).

## Documentation

- [Deployment guide (EN)](docs/en/deployment-guide.md) / [Deployment guide (VI)](docs/vi/deployment-guide.md) — build, run, embedding providers, runtime variables, classic vs managed modes, startup sequence, and security notes.
- [Multi-node brain Q&A (EN)](docs/en/question-and-answer.md) / [Multi-node brain Q&A (VI)](docs/vi/question-and-answer.md) — what happens when the brain repo is committed from another machine, and how `GBRAIN_REFRESH_UPSTREAM` fits in.
- [Glossary (EN)](docs/en/glossary.md) / [Glossary (VI)](docs/vi/glossary.md) — short definitions of the durability, writer status, managed vs classic, and admin-state terms used in the guide and Q&A.

## Requirements

- Docker with BuildKit/Buildx.
- PostgreSQL with the `pgvector` extension.
- A `DATABASE_URL` reachable from the container.
- The PostgreSQL host must be resolvable as `gbrain-postgres` because the entrypoint's readiness check is hard-coded to `gbrain-postgres:5432`, even when `DATABASE_URL` uses another host.
- An embedding key is optional, but without one vector search and background embedding are disabled.

## Build the image

Build the local image with the default upstream resolution:

```sh
docker build -t docker-gbrain .
```

Build a specific upstream tag:

```sh
docker build --build-arg GBRAIN_TAG=v0.60.413.0 -t docker-gbrain .
```

For reproducible CI builds, change `GBRAIN_VERSION`. The GitHub Actions workflow builds and publishes `linux/amd64` and `linux/arm64` images to GHCR and Docker Hub.

## Run with Docker

Create a Docker network and make PostgreSQL available as `gbrain-postgres`, then run:

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

The server is available at `http://localhost:7333` and the MCP endpoint is normally `http://localhost:7333/mcp`.

To inspect the running container:

```sh
docker exec -it gbrain /bin/bash
```

### Embedding and model variables

The entrypoint chooses the embedding provider in this order:

1. `VOYAGE_API_KEY` → `voyage:voyage-4`, 1024 dimensions.
2. `OPENAI_API_KEY` → `openai:text-embedding-3-large`, 3072 dimensions.
3. Neither key → `--no-embedding`.

Supported runtime variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | — | PostgreSQL connection string; required. |
| `VOYAGE_API_KEY` | — | Voyage embedding provider. |
| `OPENAI_API_KEY` | — | OpenAI embedding provider and chat provider. |
| `ANTHROPIC_API_KEY` | — | Optional chat provider for autopilot. |
| `OPENAI_BASE_URL` | — | Optional OpenAI-compatible endpoint; a missing `/v1` suffix is added. |
| `ANTHROPIC_BASE_URL` | — | Optional Anthropic-compatible endpoint; a missing `/v1` suffix is added. |
| `SYNC_INTERVAL` | `900` | Seconds between sync/embed cycles. |
| `EMBED_MAX_USD_PER_RUN` | `1` | Per-run cap passed to background embedding. Set empty to disable the cap. |
| `GBRAIN_MODE` | `classic` | `classic` uses the Git auto-commit/sync flow; `managed` uses `gbrain sync --source default --no-pull` and disables the auto-commit watcher. |
| `GBRAIN_REFRESH_UPSTREAM` | `false` | Managed mode only: runs `gbrain sources refresh <source>` (fast-forward to origin) before each sync cycle, so commits pushed to the remote from another machine reach this checkout. Ignored without an `origin` remote; a refused or failed refresh never stops the sync. |
| `AUTOPILOT_ENABLED` | `false` | Set to `true` to install and start gbrain's autopilot daemon. An embedding key is required; chat phases also need OpenAI or Anthropic. |
| `BRAIN_REMOTE` | — | Optional SSH remote for the brain repository. |
| `GBRAIN_PUBLIC_URL` | — | Optional URL that clients actually call; passed as `gbrain serve --public-url` so the OAuth issuer matches. |
| `GBRAIN_HOME` | — | Optional parent directory for gbrain state; config is stored under `$GBRAIN_HOME/.gbrain`. |

`gbrain init` rewrites its config, so the entrypoint patches the selected embedding model and dimensions after initialization. Changing providers on an existing database requires re-embedding, for example:

```sh
gbrain embed --stale
```

## Persistent brain and SSH remotes

Mount `/data/brain`; it is initialized as a Git repository on first startup and its `default` PostgreSQL source is pointed at that path.

For a private SSH remote, mount host keys read-only and set `BRAIN_REMOTE`:

```sh
-e BRAIN_REMOTE='git@github.com:you/brain.git' \
-v "$HOME/.ssh:/root/.ssh:ro"
```

The entrypoint writes known hosts to `/tmp/known_hosts` because `/root/.ssh` is read-only. It configures `origin` and branch tracking when keys are present. Without keys, the repository remains local-only. Linux host key permissions work most reliably; Docker Desktop may expose permissions that SSH rejects.

## Docker Compose

The checked-in `docker-compose.yml` is a runnable managed-mode deployment template. It:

- uses the published `skywirex/gbrain:latest` image rather than building this directory;
- starts PostgreSQL `pgvector/pgvector:pg16` with database `gbrain`, user `gbrain`, and password `gbrain123`;
- waits for the PostgreSQL health check before starting gbrain;
- enables `GBRAIN_MODE=managed` and autopilot by default;
- uses `SYNC_INTERVAL=600` seconds by default;
- bind-mounts `./state` at `/data`, `./brain` at `/data/brain`, `./.config` at `/root/.gbrain`, and `${HOME}/.ssh` read-only at `/root/.ssh`;
- exposes port `7333` on all host interfaces; restrict it with a firewall or bind it to a private interface.

Start it with:

```sh
export VOYAGE_API_KEY=pa-...
docker compose up -d
```

Optional values can be placed in a `.env` file, including `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `ANTHROPIC_API_KEY`, `SYNC_INTERVAL`, `EMBED_MAX_USD_PER_RUN`, `AUTOPILOT_ENABLED`, and `BRAIN_REMOTE`. The Compose database password is a development default; change it before using the stack outside a trusted environment.

The Compose service uses the published image. To test changes to the local `Dockerfile` and `entrypoint.sh`, build the image and run it directly as shown above, or change the Compose service to use `build: .` and the local image deliberately.

## Startup behavior

`entrypoint.sh` performs the following:

1. Waits for `gbrain-postgres:5432`.
2. Reports configured API keys and normalizes custom OpenAI/Anthropic base URLs.
3. Detects an existing database by checking for the `pages` table.
4. Runs `gbrain init` or migrations, then reapplies embedding and paid-run settings.
5. Initializes `/data/brain` as Git and points the default database source to it.
6. Runs either the classic auto-commit watcher or managed sync mode.
7. Periodically syncs and embeds stale content when an embedding key is available.
8. Optionally starts autopilot. If autopilot does not own the worker, starts `gbrain jobs work`.
9. Runs `gbrain serve --http --port 7333 --bind 0.0.0.0` in the foreground.

Initialization commands that are safe to repeat are intentionally tolerant of non-zero exits so an existing installation can restart.

## Security notes

- The Compose example uses a development database password and publishes MCP on `0.0.0.0`; change both for anything beyond a trusted network.
- Never commit API keys, SSH keys, `.config`, `brain`, or runtime state. These paths are ignored by `.gitignore`.
