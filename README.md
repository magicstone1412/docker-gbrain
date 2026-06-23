# docker-gbrain

Docker image wrapper for [gbrain](https://github.com/garrytan/gbrain), packaged as a Bun-based container with a persistent local brain repository and an HTTP MCP server.

The image builds `gbrain` from source, initializes it against a Postgres database, starts background sync for the local brain repo, and serves the MCP endpoint on port `7333`.

## What This Image Does

- Uses `oven/bun:latest` as the base image.
- Installs `git`, `netcat-openbsd`, `postgresql-client`, and `jq`.
- Clones `https://github.com/garrytan/gbrain` into `/app`.
- Runs `bun install` and `bun link`.
- Creates `/data/brain` as the persistent brain repository.
- Waits for a Postgres host named `gbrain-postgres` on port `5432`.
- Detects which embedding provider to use from environment variables.
- Runs `gbrain init --supabase` with the appropriate embedding flag.
- Lets `gbrain` read API keys directly from environment variables.
- Patches `~/.gbrain/config.json` after init so the selected embedding model/dimensions persist.
- Initializes `/data/brain` as a Git repository if needed.
- Updates the default source path in Postgres to `/data/brain`.
- Starts an auto-commit watcher for `/data/brain`.
- Runs a background sync/embed loop on a configurable interval.
- Runs `gbrain extract links` and `gbrain extract timeline` after each successful sync cycle.
- Starts the HTTP MCP server on `0.0.0.0:7333`.

## Requirements

- Docker
- A reachable Postgres database
- A `DATABASE_URL` environment variable
- A Postgres container or DNS host named `gbrain-postgres`
- At least one embedding API key (see below)

The entrypoint waits for `gbrain-postgres:5432`, so the Postgres service must be reachable by that name from inside the container.

## API Keys

Pass these as environment variables at runtime (via `-e` or `--env-file`). The entrypoint reports which keys are present, `gbrain` reads them directly from the environment, and the container selects the correct embedding provider automatically.

| Variable | Purpose | Priority |
|---|---|---|
| `ZEROENTROPY_API_KEY` | Default embedding (`zembed-1`) + reranker (`zerank-2`). Recommended — ~2× faster and ~2.6× cheaper than OpenAI. | 1st |
| `VOYAGE_API_KEY` | Alternative embedding provider (`voyage-3`). | 2nd |
| `OPENAI_API_KEY` | Fallback embedding (`text-embedding-3-large`); also used for chat models. | 3rd |
| `ANTHROPIC_API_KEY` | Optional. Enables query expansion via Claude Haiku to improve search quality. | — |
| `SYNC_INTERVAL` | Optional. Seconds between `sync` cycles. Default: `60`. | — |
| `BRAIN_REMOTE` | Optional. SSH remote URL for the brain repo (e.g. `git@github.com:you/brain.git`). Set as `origin` so `gbrain sync` can pull & push. See [Private Brain Repo (SSH)](#private-brain-repo-ssh). | — |

**Embedding provider selection priority:** `ZEROENTROPY_API_KEY` → `VOYAGE_API_KEY` → `OPENAI_API_KEY`.  
If none of these are set, the container starts with `--no-embedding` and vector search is unavailable until a key is configured.

> **Note:** `embedding_model` and `embedding_dimensions` are schema-level settings. If you change the provider after the first run, you must re-embed all content with `gbrain embed --stale`.

## Build

```sh
docker build -t docker-gbrain .
```

## Run

```sh
docker run --rm \
  --name gbrain \
  --network gbrain-network \
  -e DATABASE_URL="postgres://user:password@gbrain-postgres:5432/gbrain" \
  -e ZEROENTROPY_API_KEY="ze-..." \
  #-e OPENAI_API_KEY="sk-..." \
  #-e ANTHROPIC_API_KEY="sk-ant-..." \
  -e SYNC_INTERVAL="300" \
  -p 7333:7333 \
  -v gbrain-data:/data/brain \
  docker-gbrain
```

If `gbrain` is already running in Docker and you want to execute commands inside the container, use:

```sh
docker exec -ti gbrain /bin/bash
```

You can also pass keys from a file:

```sh
docker run --rm \
  --name gbrain \
  --network gbrain-network \
  --env-file .env \
  -p 7333:7333 \
  -v gbrain-data:/data/brain \
  docker-gbrain
```

Example `.env` file:

```env
DATABASE_URL=postgres://user:password@gbrain-postgres:5432/gbrain
ZEROENTROPY_API_KEY=ze-...
# OPENAI_API_KEY=sk-...
# ANTHROPIC_API_KEY=sk-ant-...
SYNC_INTERVAL=300
# VOYAGE_API_KEY=pa-...
```

## Docker Compose Example

```yaml
services:
  gbrain-postgres:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_USER: gbrain
      POSTGRES_PASSWORD: gbrain
      POSTGRES_DB: gbrain
    volumes:
      - gbrain-postgres-data:/var/lib/postgresql/data
    networks:
      - gbrain-network

  gbrain:
    build: .
    depends_on:
      - gbrain-postgres
    environment:
      DATABASE_URL: postgres://gbrain:gbrain@gbrain-postgres:5432/gbrain
      ZEROENTROPY_API_KEY: ${ZEROENTROPY_API_KEY:-}
      # OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      # VOYAGE_API_KEY: ${VOYAGE_API_KEY:-}
      # ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      SYNC_INTERVAL: ${SYNC_INTERVAL:-60}
    ports:
      - "7333:7333"
    volumes:
      - gbrain-data:/data/brain
    networks:
      - gbrain-network

volumes:
  gbrain-postgres-data:
  gbrain-data:

networks:
  gbrain-network:
```

Start with:

```sh
# export keys first (or put them in a .env file in the same directory)
export ZEROENTROPY_API_KEY=ze-...
docker compose up -d
```

## Persistent Data

The container declares `/data/brain` as a volume. Mount this path to keep the local brain repository across container rebuilds and restarts.

```sh
-v gbrain-data:/data/brain
```

On first startup, the entrypoint initializes this directory as a Git repository and creates an empty initial commit.

## Private Brain Repo (SSH)

If your brain repo lives on a **private** Git remote, the container needs SSH
credentials to pull and push. Containers can't share the host's `ssh-agent`, so
the host's SSH keys are mounted read-only and used directly.

The provided `docker-compose.yml` already wires this up:

```yaml
    environment:
      # SSH remote URL — set as origin and tracked by the current branch.
      BRAIN_REMOTE: ${BRAIN_REMOTE:-}
      # Use a writable known_hosts because the ~/.ssh mount below is read-only.
      GIT_SSH_COMMAND: "ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts"
    volumes:
      - ${HOME}/.ssh:/root/.ssh:ro
```

Run with the remote set (Linux host):

```sh
export BRAIN_REMOTE=git@github.com:you/brain.git
docker compose up -d --build
```

On startup the entrypoint:

1. Detects keys at `/root/.ssh` (the mounted host keys).
2. Seeds `/tmp/known_hosts` for `github.com` via `ssh-keyscan` so the first
   pull doesn't fail host-key verification (`accept-new` covers other hosts).
3. Sets `origin` to `BRAIN_REMOTE` (if provided) and makes the current branch
   track it, so the background sync loop can pull & push.

Notes:

- **Linux host only.** Bind-mounted key permissions are preserved on Linux, and
  the container runs as `root` so it can read the user's keys. On Windows/macOS
  Docker Desktop, the `:ro` mount may expose keys with permissions SSH rejects.
- The mount is **read-only** — the host keys are never modified.
- If `BRAIN_REMOTE` is omitted but the volume already has an `origin`, the
  existing remote is used as-is.
- Without any SSH keys, the brain repo is treated as **local-only** and the
  sync loop's `git pull` warning (`Already up to date.`) is harmless.

## MCP Server

The container exposes port `7333` and starts:

```sh
gbrain serve --http --port 7333 --bind 0.0.0.0
```

After the container is running, the HTTP MCP server is available on:

```
http://localhost:7333
```

## Startup Flow

The entrypoint performs these steps every time the container starts:

1. Waits until `gbrain-postgres:5432` accepts connections.
2. Reports which API keys are present in the environment.
3. Detects the embedding provider from environment variables (ZeroEntropy → Voyage → OpenAI → `--no-embedding`).
4. Checks whether the `pages` table already exists to distinguish first-time init from migration-only startup.
5. Runs `gbrain init --supabase --url "$DATABASE_URL"` with either the selected embedding model or `--no-embedding`.
6. Patches `~/.gbrain/config.json` after init so `embedding_model` and `embedding_dimensions` match the selected provider.
7. Ensures `/data/brain` is a Git repository with local commit identity configured.
8. Updates the default source in Postgres to use `/data/brain`.
9. Starts an auto-commit watcher that commits file changes in `/data/brain` every 30 seconds.
10. Starts a background loop that runs `gbrain sync --repo /data/brain`, then `gbrain embed --stale`, `gbrain extract links --source db`, and `gbrain extract timeline --source db` on each successful cycle.
11. Starts the HTTP MCP server.

Some initialization commands are allowed to fail without stopping the container, which makes repeated starts tolerant after the first successful setup.

## Files

- `Dockerfile` — builds the gbrain runtime image.
- `entrypoint.sh` — handles database readiness, API key wiring, initialization, background sync, and server startup.
