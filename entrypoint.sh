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
#    We check for a schema marker in Postgres (the 'pages' table).
#    If already initialized, skip --embedding-model to avoid dimension mismatch.
# ---------------------------------------------------------------------------
ALREADY_INITIALIZED=false
if psql "$DATABASE_URL" -c "\dt pages" 2>/dev/null | grep -q "pages"; then
  ALREADY_INITIALIZED=true
fi

# ---------------------------------------------------------------------------
# 4. Initialize brain
#    First run:   pick embedding provider from env vars (or --no-embedding).
#    Subsequent:  run init without --embedding-model so the stored schema is
#                 preserved. Changing embedding provider after first init
#                 requires a manual `gbrain embed --stale` — see README.
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
# 5. Ensure /data/brain is a Git repo
# ---------------------------------------------------------------------------
echo "Configuring brain repo..."
if [ ! -d /data/brain/.git ]; then
  cd /data/brain
  git init
  git config user.email "gbrain@local"
  git config user.name "GBrain"
  git commit --allow-empty -m "init brain repo"
  cd /app
fi

# ---------------------------------------------------------------------------
# 6. Point Postgres default source at the mounted brain volume
# ---------------------------------------------------------------------------
psql "$DATABASE_URL" -c \
  "UPDATE sources SET local_path = '/data/brain' WHERE id = 'default';" \
  2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Background sync
# ---------------------------------------------------------------------------
echo "Starting background sync..."
gbrain sync --watch --interval 60 --repo /data/brain &

# ---------------------------------------------------------------------------
# 8. Start MCP server (foreground / PID 1)
# ---------------------------------------------------------------------------
echo "Starting MCP server..."
exec gbrain serve --http --port 7333 --bind 0.0.0.0