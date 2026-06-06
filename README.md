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
- Runs `gbrain init --supabase` using `DATABASE_URL`.
- Initializes `/data/brain` as a Git repository if needed.
- Updates the default source path in Postgres to `/data/brain`.
- Starts `gbrain sync --watch` in the background.
- Starts the HTTP MCP server on `0.0.0.0:7333`.

## Requirements

- Docker
- A reachable Postgres database
- A `DATABASE_URL` environment variable
- A Postgres container or DNS host named `gbrain-postgres`

The entrypoint waits for `gbrain-postgres:5432`, so the Postgres service must be reachable by that name from inside the container.

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
  -p 7333:7333 \
  -v gbrain-data:/data/brain \
  docker-gbrain
```

Replace the `DATABASE_URL` value with the connection string for your Postgres database.

## Docker Compose Example

```yaml

```

Start it with:

```sh

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

```text
http://localhost:7333
```

## Startup Flow

The entrypoint performs these steps every time the container starts:

1. Waits until `gbrain-postgres:5432` accepts connections.
2. Runs `gbrain init --supabase --url "$DATABASE_URL" --no-embedding`.
3. Ensures `/data/brain` is a Git repository.
4. Updates the default source in Postgres to use `/data/brain`.
5. Starts `gbrain sync --watch --interval 60 --repo /data/brain`.
6. Starts the HTTP MCP server.

Some initialization commands are allowed to fail without stopping the container, which makes repeated starts more tolerant after the first successful setup.

## Files

- `Dockerfile` builds the gbrain runtime image.
- `entrypoint.sh` handles database readiness, initialization, background sync, and server startup.
