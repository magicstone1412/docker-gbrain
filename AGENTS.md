# AGENTS.md

This file provides guidance to agents when working with code in this repository.

- This repo is only a Docker wrapper around upstream `garrytan/gbrain`; the application code is cloned into `/app` at image build time, so do not look for local Bun source or package scripts here.
- Build/run validation is container-oriented: `docker build -t docker-gbrain .` and `docker compose up -d --build`; there are no local lint or test commands in this repo.
- Runtime depends on a Postgres host resolvable as `gbrain-postgres:5432`; the entrypoint hard-codes that readiness check even when `DATABASE_URL` points elsewhere.
- Embedding provider priority is hard-coded in `entrypoint.sh`: `ZEROENTROPY_API_KEY` → `VOYAGE_API_KEY` → `OPENAI_API_KEY` → `--no-embedding`.
- ZeroEntropy requires the custom persisted config pair `zeroentropyai:zembed-1` plus `1280` dimensions; the entrypoint patches `~/.gbrain/config.json` after `gbrain init` because init overwrites it.
- Existing databases are detected by the `pages` table; initialized starts run migrations with `--no-embedding`, then patch embedding config separately.
- Persistent user content must live at `/data/brain`; startup rewrites the default Postgres source path to this mount and initializes it as a Git repo if needed.
- Background behavior is part of runtime: auto-commit every 30 seconds, then `gbrain sync --repo /data/brain`, `gbrain embed --stale`, link extraction, and timeline extraction every `SYNC_INTERVAL` seconds.
- Private brain remotes use mounted host SSH keys at `/root/.ssh:ro`; `GIT_SSH_COMMAND` must write known hosts to `/tmp/known_hosts`, not `/root/.ssh/known_hosts`.
- The MCP server is the foreground process: `gbrain serve --http --port 7333 --bind 0.0.0.0`.
