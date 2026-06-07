# docker-gbrain

Docker image wrapper for [gbrain](https://github.com/garrytan/gbrain), packaged as a Bun-based container with a persistent local brain repository and an HTTP MCP server.

The image builds `gbrain` from source, initializes it against a Postgres database, starts background sync for the local brain repo, and serves the MCP endpoint on port `7333`.

## What This Image Does

- Uses `oven/bun:latest` as the base image.
- Installs `git`, `netcat-openbsd`, and `postgresql-client`.
- Clones `https://github.com/garrytan/gbrain` into `/app`.
- Runs `bun install` and `bun link`.
- Creates `/data/brain` as the persistent brain repository.
- Waits for a Postgres host named `gbrain-postgres` on port `5432`.
- Detects which embedding provider to use from environment variables.
- Runs `gbrain init --supabase` with the appropriate embedding flag.
- Stores all provided API keys into `~/.gbrain/config.json` via `gbrain config set`.
- Initializes `/data/brain` as a Git repository if needed.
- Updates the default source path in Postgres to `/data/brain`.
- Starts `gbrain sync --watch` in the background.
- Starts the HTTP MCP server on `0.0.0.0:7333`.

## Requirements

- Docker
- A reachable Postgres database
- A `DATABASE_URL` environment variable
- A Postgres container or DNS host named `gbrain-postgres`
- At least one embedding API key (see below)

The entrypoint waits for `gbrain-postgres:5432`, so the Postgres service must be reachable by that name from inside the container.

## API Keys

Pass these as environment variables at runtime (via `-e` or `--env-file`). The entrypoint automatically writes each key into gbrain's config and selects the correct embedding provider.

| Variable | Purpose | Priority |
|---|---|---|
| `ZEROENTROPY_API_KEY` | Default embedding (`zembed-1`) + reranker (`zerank-2`). Recommended — ~2× faster and ~2.6× cheaper than OpenAI. | 1st |
| `VOYAGE_API_KEY` | Alternative embedding provider (`voyage-3`). | 2nd |
| `OPENAI_API_KEY` | Fallback embedding (`text-embedding-3-large`); also used for chat models. | 3rd |
| `ANTHROPIC_API_KEY` | Optional. Enables query expansion via Claude Haiku to improve search quality. | — |

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
  -e OPENAI_API_KEY="sk-..." \
  -e ANTHROPIC_API_KEY="sk-ant-..." \
  -p 7333:7333 \
  -v gbrain-data:/data/brain \
  docker-gbrain
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
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
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
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      VOYAGE_API_KEY: ${VOYAGE_API_KEY:-}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
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
export OPENAI_API_KEY=sk-...
docker compose up -d
```

## Persistent Data

The container declares `/data/brain` as a volume. Mount this path to keep the local brain repository across container rebuilds and restarts.

```sh
-v gbrain-data:/data/brain
```

On first startup, the entrypoint initializes this directory as a Git repository and creates an empty initial commit.

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
2. Writes any provided API keys to gbrain's config via `gbrain config set`.
3. Detects the embedding provider from environment variables (ZeroEntropy → Voyage → OpenAI → `--no-embedding`).
4. Runs `gbrain init --supabase --url "$DATABASE_URL" [--embedding-model <provider:model> | --no-embedding]`.
5. Ensures `/data/brain` is a Git repository.
6. Updates the default source in Postgres to use `/data/brain`.
7. Starts `gbrain sync --watch --interval 60 --repo /data/brain`.
8. Starts the HTTP MCP server.

Some initialization commands are allowed to fail without stopping the container, which makes repeated starts tolerant after the first successful setup.

## Files

- `Dockerfile` — builds the gbrain runtime image.
- `entrypoint.sh` — handles database readiness, API key wiring, initialization, background sync, and server startup.
