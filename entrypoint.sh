#!/bin/sh
set -e

# ---------------------------------------------------------------------------
# 1. Wait for Postgres
# ---------------------------------------------------------------------------
echo "Waiting for Postgres..."
until nc -z gbrain-postgres 5432 2>/dev/null; do
  sleep 2
done
echo "Postgres ready!"

# ---------------------------------------------------------------------------
# 2. Report which API keys are present in the environment.
#    gbrain reads ZEROENTROPY_API_KEY, OPENAI_API_KEY, VOYAGE_API_KEY, and
#    ANTHROPIC_API_KEY directly from env — no `gbrain config set` needed.
# ---------------------------------------------------------------------------
echo "API key status:"
for var in ZEROENTROPY_API_KEY OPENAI_API_KEY VOYAGE_API_KEY ANTHROPIC_API_KEY; do
  eval val=\$$var
  if [ -n "$val" ]; then
    echo "  ✓ $var is set"
  else
    echo "  - $var not set"
  fi
done

# ---------------------------------------------------------------------------
# 3. Detect whether gbrain has already been initialized
# ---------------------------------------------------------------------------
ALREADY_INITIALIZED=false
if psql "$DATABASE_URL" -c "\dt pages" 2>/dev/null | grep -q "pages"; then
  ALREADY_INITIALIZED=true
fi

# ---------------------------------------------------------------------------
# 4. Initialize brain
# ---------------------------------------------------------------------------
# Determine embedding flag from env vars (used for both first-run and re-init)
if [ -n "$ZEROENTROPY_API_KEY" ]; then
  EMBEDDING_FLAG="--embedding-model zeroentropyai:zembed-1 --embedding-dimensions 1280"
  echo "Embedding provider: ZeroEntropy (zembed-1, 1280d)"
elif [ -n "$VOYAGE_API_KEY" ]; then
  EMBEDDING_FLAG="--embedding-model voyage:voyage-3"
  echo "Embedding provider: Voyage (voyage-3)"
elif [ -n "$OPENAI_API_KEY" ]; then
  EMBEDDING_FLAG="--embedding-model openai:text-embedding-3-large"
  echo "Embedding provider: OpenAI (text-embedding-3-large)"
else
  EMBEDDING_FLAG="--no-embedding"
  echo "No embedding API key — deferring embedding setup."
fi

# Determine embed model/dims for patching later
if [ -n "$ZEROENTROPY_API_KEY" ]; then
  EMBED_MODEL="zeroentropyai:zembed-1"
  EMBED_DIMS=1280
elif [ -n "$VOYAGE_API_KEY" ]; then
  EMBED_MODEL="voyage:voyage-3"
  EMBED_DIMS=1024
elif [ -n "$OPENAI_API_KEY" ]; then
  EMBED_MODEL="openai:text-embedding-3-large"
  EMBED_DIMS=3072
fi

if [ "$ALREADY_INITIALIZED" = "true" ]; then
  echo "Brain already initialized — running migrations only..."
  printf '1\n' | gbrain init --supabase --url "$DATABASE_URL" --no-embedding || true
else
  echo "First-time initialization..."
  # shellcheck disable=SC2086
  printf '1\n' | gbrain init --supabase --url "$DATABASE_URL" $EMBEDDING_FLAG || true
fi

# Patch embedding config AFTER gbrain init — init always overwrites config.json,
# so we must patch after it runs, not before.
CONFIG_FILE="$HOME/.gbrain/config.json"
mkdir -p "$(dirname "$CONFIG_FILE")"
if [ "$EMBEDDING_FLAG" != "--no-embedding" ]; then
  echo "Patching embedding config into $CONFIG_FILE (post-init)..."
  EXISTING=$(cat "$CONFIG_FILE" 2>/dev/null || echo "{}")
  printf '%s' "$EXISTING" | jq \
    --arg model "$EMBED_MODEL" \
    --argjson dims "$EMBED_DIMS" \
    'del(.embedding_disabled) | .embedding_model = $model | .embedding_dimensions = $dims' \
    > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
  echo "Embedding config patched: $EMBED_MODEL (${EMBED_DIMS}d)"
fi

# ---------------------------------------------------------------------------
# 5. Ensure /data/brain is a Git repo with git config
# ---------------------------------------------------------------------------
echo "Configuring brain repo..."
if [ ! -d /data/brain/.git ]; then
  cd /data/brain
  git init
  git config user.email "gbrain@local"
  git config user.name "GBrain"
  git config --global core.editor "true"
  git commit --allow-empty -m "init brain repo"
  cd /app
else
  # Ensure git config exists even after volume remount
  git -C /data/brain config user.email "gbrain@local" || true
  git -C /data/brain config user.name "GBrain" || true
fi

# ---------------------------------------------------------------------------
# 5b. SSH auth for a PRIVATE brain repo
#     The container can't share the host's ssh-agent, so we mount the host's
#     SSH keys read-only at /root/.ssh and authenticate over SSH.
#       - Seed a WRITABLE known_hosts (the mount is :ro, so we can't write
#         into /root/.ssh) and pin github.com's host key.
#       - BRAIN_REMOTE (optional): SSH remote URL, e.g.
#         git@github.com:you/brain.git — set/updated so `gbrain sync` can
#         pull & push. If the volume already has a remote, this is a no-op
#         unless BRAIN_REMOTE differs.
# ---------------------------------------------------------------------------
if [ -d /root/.ssh ] && ls /root/.ssh/id_* >/dev/null 2>&1; then
  echo "Host SSH keys detected — configuring SSH for git..."
  KNOWN_HOSTS=/tmp/known_hosts
  # Pin github.com (and ssh.github.com) so the first pull doesn't fail on
  # host-key verification. accept-new in GIT_SSH_COMMAND covers other hosts.
  ssh-keyscan -t rsa,ecdsa,ed25519 github.com ssh.github.com > "$KNOWN_HOSTS" 2>/dev/null \
    && echo "  known_hosts seeded for github.com" \
    || echo "  ssh-keyscan failed — relying on accept-new"

  export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS"

  if [ -n "$BRAIN_REMOTE" ]; then
    if git -C /data/brain remote get-url origin >/dev/null 2>&1; then
      git -C /data/brain remote set-url origin "$BRAIN_REMOTE"
    else
      git -C /data/brain remote add origin "$BRAIN_REMOTE"
    fi
    echo "  origin set to $BRAIN_REMOTE"
  fi

  # If a remote exists, make the current branch track it so pull/push work.
  if git -C /data/brain remote get-url origin >/dev/null 2>&1; then
    BRANCH=$(git -C /data/brain symbolic-ref --short HEAD 2>/dev/null || echo main)
    if git -C /data/brain fetch origin "$BRANCH" 2>/dev/null; then
      git -C /data/brain branch --set-upstream-to="origin/$BRANCH" "$BRANCH" 2>/dev/null || true
      echo "  tracking origin/$BRANCH — SSH auth OK"
    else
      echo "  initial fetch failed (check key/permissions/URL) — sync will retry"
    fi
  fi
else
  echo "No SSH keys at /root/.ssh — brain repo treated as local-only."
fi

# ---------------------------------------------------------------------------
# 6. Point Postgres default source at the mounted brain volume
# ---------------------------------------------------------------------------
psql "$DATABASE_URL" -c \
  "UPDATE sources SET local_path = '/data/brain' WHERE id = 'default';" \
  2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Auto-commit watcher (every 30s)
#    Commits any new/modified files so gbrain sync can pick them up.
# ---------------------------------------------------------------------------
echo "Starting auto-commit watcher..."
(while true; do
  sleep 30
  cd /data/brain
  if [ -n "$(git status --porcelain)" ]; then
    git add .
    git commit -m "auto: $(date '+%Y-%m-%d %H:%M:%S')" \
      && echo "[auto-commit] changes committed"
  fi
done) &

# ---------------------------------------------------------------------------
# 8. Sync + embed loop
#    SYNC_INTERVAL: seconds between sync cycles (default: 60).
#    Set via -e SYNC_INTERVAL=300 in docker run or compose environment.
# ---------------------------------------------------------------------------
SYNC_INTERVAL="${SYNC_INTERVAL:-60}"
echo "Starting sync+embed loop (interval: ${SYNC_INTERVAL}s)..."
(while true; do
  if gbrain sync --repo /data/brain; then
    if [ -n "$ZEROENTROPY_API_KEY" ] || [ -n "$OPENAI_API_KEY" ] || [ -n "$VOYAGE_API_KEY" ]; then
      gbrain embed --stale || echo "[embed] embed failed, will retry next cycle"
    else
      echo "[embed] skipped — no embedding API key set"
    fi
    gbrain extract links --source db 2>/dev/null || true
    gbrain extract timeline --source db 2>/dev/null || true
  else
    echo "[sync] sync failed, will retry in ${SYNC_INTERVAL}s"
  fi
  echo "[sync] cycle ended, next in ${SYNC_INTERVAL}s..."
  sleep "$SYNC_INTERVAL"
done) &

# ---------------------------------------------------------------------------
# 9. Start autopilot daemon (optional, controlled by AUTOPILOT_ENABLED)
#    Monitors brain health and runs overnight enrichment cycle automatically.
#    - Healthy brain (score 95+): sleeps 60min between ticks
#    - Unhealthy brain: runs full cycle (sync, extract, embed, consolidate, synthesize)
#    Enable via: AUTOPILOT_ENABLED=true in docker-compose environment.
#    Requires at least one embedding API key — autopilot runs embed phases
#    that are no-ops (or harmful) without a configured embedding provider.
# ---------------------------------------------------------------------------
HAS_EMBEDDING_KEY=false
if [ -n "$ZEROENTROPY_API_KEY" ] || [ -n "$VOYAGE_API_KEY" ] || [ -n "$OPENAI_API_KEY" ]; then
  HAS_EMBEDDING_KEY=true
fi

if [ "${AUTOPILOT_ENABLED:-false}" = "true" ]; then
  if [ "$HAS_EMBEDDING_KEY" = "true" ]; then
    echo "Starting autopilot daemon (max-usd: ${AUTOPILOT_MAX_USD:-5})..."
    gbrain autopilot --max-usd "${AUTOPILOT_MAX_USD:-5}" &
    echo "Autopilot started."
  else
    echo "Autopilot skipped — AUTOPILOT_ENABLED=true but no embedding API key is set."
    echo "Set ZEROENTROPY_API_KEY, VOYAGE_API_KEY, or OPENAI_API_KEY to enable autopilot."
  fi
else
  echo "Autopilot disabled (set AUTOPILOT_ENABLED=true to enable)."
fi

# ---------------------------------------------------------------------------
# 10. Start job worker (background)
#    Required for Postgres engine — processes queued minion/subagent jobs.
#    Without this, wedged_queue FAIL appears in gbrain doctor.
# ---------------------------------------------------------------------------
echo "Starting job worker..."
gbrain jobs work &
JOB_WORKER_PID=$!
echo "Job worker started (PID $JOB_WORKER_PID)"

# ---------------------------------------------------------------------------
# 11. Start MCP server (foreground / PID 1)
# ---------------------------------------------------------------------------
echo "Starting MCP server..."
exec gbrain serve --http --port 7333 --bind 0.0.0.0