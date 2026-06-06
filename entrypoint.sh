#!/bin/sh
set -e

echo "Waiting for Postgres..."
until nc -z gbrain-postgres 5432 2>/dev/null; do
  sleep 2
done
echo "Postgres ready!"

echo "Initializing brain..."
printf '1\n' | gbrain init --supabase --url "$DATABASE_URL" --no-embedding || true

echo "Configuring brain repo..."
if [ ! -d /data/brain/.git ]; then
  cd /data/brain
  git init
  git config user.email "gbrain@local"
  git config user.name "GBrain"
  git commit --allow-empty -m "init brain repo"
  cd /app
fi

psql "$DATABASE_URL" -c "UPDATE sources SET local_path = '/data/brain' WHERE id = 'default';" 2>/dev/null || true

echo "Starting background sync..."
gbrain sync --watch --interval 60 --repo /data/brain &

echo "Starting MCP server..."
exec gbrain serve --http --port 7333 --bind 0.0.0.0