# AGENTS.md

## Repository scope

This repository is a Docker wrapper around upstream [`garrytan/gbrain`](https://github.com/garrytan/gbrain). The Bun application source is cloned into `/app` during the image build; it is not present locally. Keep changes focused on the image, entrypoint, Compose/deployment configuration, and documentation.

## Files and current state

- `Dockerfile` builds gbrain from an upstream tag and installs the runtime dependencies.
- `GBRAIN_VERSION` is the CI pin (`v0.60.420.0` currently).
- `entrypoint.sh` is the image's real entrypoint.
- `docker-compose.yml` is a managed-mode deployment template: it references the published image `skywirex/gbrain:latest` (the tag must include the current entrypoint with `GBRAIN_MODE` support), starts its own healthy `pgvector/pgvector:pg16` database, and bind-mounts local state, brain, gbrain config, and SSH keys.
- `README.md` is the user-facing source of truth for runtime variables and deployment caveats.

## Validation

There are no local Bun, lint, or test commands. Validate image changes with Docker:

```sh
docker build -t docker-gbrain .
```

For runtime validation, use a PostgreSQL service/container resolvable as `gbrain-postgres:5432`, a valid `DATABASE_URL`, and disposable mounted state. The Compose stack can be started with `docker compose up -d`; it uses the published image, so local Dockerfile/entrypoint changes require a direct local image build or an intentional Compose `build: .` change.

Before committing, at minimum inspect the diff and run shell syntax validation where available:

```sh
sh -n entrypoint.sh
git diff --check
git status --short
```

## Runtime contract

- The entrypoint readiness check is hard-coded to `gbrain-postgres:5432`, even if `DATABASE_URL` names another host.
- Embedding selection is `VOYAGE_API_KEY` → `OPENAI_API_KEY` → `--no-embedding`.
- Voyage persists as `voyage:voyage-4` with 1024 dimensions; OpenAI persists as `openai:text-embedding-3-large` with 3072 dimensions.
- `gbrain init` rewrites config, so embedding configuration and paid-run preapproval must be applied after init.
- Existing databases are detected through the `pages` table. First initialization and migration-only startup are intentionally separate paths.
- `/data/brain` is persistent user content. Startup points the default database source there and initializes/configures it as a Git repository.
- `GBRAIN_MODE=classic` (default) starts the 30-second auto-commit watcher and runs `gbrain sync --repo /data/brain`.
- `GBRAIN_MODE=managed` disables auto-commit and runs `gbrain sync --source default --no-pull`.
- `GBRAIN_REFRESH_UPSTREAM=true` (managed mode only, default false) runs `gbrain sources refresh <source>` before each sync cycle, fast-forwarding the checkout to origin. It is ignored in classic mode or without an `origin` remote, and a refused or failed refresh never stops the subsequent sync.
- Both modes run stale embedding on successful sync when an embedding key is configured. `SYNC_INTERVAL` defaults to 900 seconds; `EMBED_MAX_USD_PER_RUN` defaults to 1 USD.
- `AUTOPILOT_ENABLED=true` requires an embedding key. Autopilot may own the job worker; otherwise the entrypoint starts `gbrain jobs work`.
- The foreground process is `gbrain serve --http --port 7333 --bind 0.0.0.0`; an optional `GBRAIN_PUBLIC_URL` is appended as `--public-url` so the OAuth issuer matches the URL clients actually call.

## Secrets and SSH

- Do not log or commit API keys, database credentials, SSH keys, `.config`, `brain`, or runtime state.
- Custom `OPENAI_BASE_URL` and `ANTHROPIC_BASE_URL` values are normalized with a `/v1` suffix when absent.
- Private brain remotes use host SSH keys mounted read-only at `/root/.ssh`. `GIT_SSH_COMMAND` must use writable `/tmp/known_hosts`, never `/root/.ssh/known_hosts`.
- `BRAIN_REMOTE` configures `origin` and branch tracking when SSH keys are available.
- The Compose file publishes port 7333 on all host interfaces. Treat the MCP endpoint as network-accessible and restrict it at the firewall/private network in real deployments.
- Compose defaults to `GBRAIN_MODE=managed`, `SYNC_INTERVAL=600`, and `AUTOPILOT_ENABLED=true`; do not confuse these deployment defaults with the `entrypoint.sh` defaults (`classic`, 900, and false).

## Change guidance

1. Read the relevant shell, Docker, Compose, and workflow files before editing.
2. Preserve the existing runtime contract unless the task explicitly changes it.
3. Keep Docker validation container-oriented; there is no local application source to test.
4. If changing a runtime variable, startup step, mount, image tag, or CI pin, update `README.md` and this file in the same change.
5. If adding a deployment entrypoint or changing Compose to build locally, verify the referenced files actually exist and document the resulting startup path.
6. Keep changes minimal; do not add abstractions or dependencies for documentation/configuration-only work.
