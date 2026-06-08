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
  git commit --allow-empty -m "init brain repo"
  cd /app
else
  # Ensure git config exists even after volume remount
  git -C /data/brain config user.email "gbrain@local" || true
  git -C /data/brain config user.name "GBrain" || true
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
  else
    echo "[sync] sync failed, will retry in ${SYNC_INTERVAL}s"
  fi
  echo "[sync] cycle ended, next in ${SYNC_INTERVAL}s..."
  sleep "$SYNC_INTERVAL"
done) &

# ---------------------------------------------------------------------------
# 9. Start MCP server (foreground / PID 1)
# ---------------------------------------------------------------------------
echo "Starting MCP server..."
exec gbrain serve --http --port 7333 --bind 0.0.0.0
