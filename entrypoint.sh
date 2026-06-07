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
if [ "$ALREADY_INITIALIZED" = "true" ]; then
  echo "Brain already initialized — skipping embedding provider selection."
  echo "Running init to apply any pending migrations only..."
  printf '1\n' | gbrain init --supabase --url "$DATABASE_URL" --no-embedding || true
else
  echo "First-time initialization..."
  if [ -n "$ZEROENTROPY_API_KEY" ]; then
    EMBEDDING_FLAG="--embedding-model zeroentropyai:zembed-1"
    echo "Embedding provider: ZeroEntropy (zembed-1)"
  elif [ -n "$VOYAGE_API_KEY" ]; then
    EMBEDDING_FLAG="--embedding-model voyage:voyage-3"
    echo "Embedding provider: Voyage (voyage-3)"
  elif [ -n "$OPENAI_API_KEY" ]; then
    EMBEDDING_FLAG="--embedding-model openai:text-embedding-3-large"
    echo "Embedding provider: OpenAI (text-embedding-3-large)"
  else
    EMBEDDING_FLAG="--no-embedding"
    echo "No embedding API key found — deferring embedding setup (--no-embedding)."
    echo "Set ZEROENTROPY_API_KEY, OPENAI_API_KEY, or VOYAGE_API_KEY to enable vector search."
  fi
  # shellcheck disable=SC2086
  printf '1\n' | gbrain init --supabase --url "$DATABASE_URL" $EMBEDDING_FLAG || true
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
# 7. Auto-commit watcher
#    Watches /data/brain every 30s. If there are new or modified files,
#    commits them so gbrain sync can pick them up automatically.
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
# 8. Background sync (with auto-restart on crash)
# ---------------------------------------------------------------------------
echo "Starting background sync..."
(while true; do
  gbrain sync --watch --interval 60 --repo /data/brain
  echo "[sync] exited unexpectedly, restarting in 5s..."
  sleep 5
done) &

# ---------------------------------------------------------------------------
# 9. Start MCP server (foreground / PID 1)
# ---------------------------------------------------------------------------
echo "Starting MCP server..."
exec gbrain serve --http --port 7333 --bind 0.0.0.0