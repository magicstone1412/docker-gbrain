#!/bin/sh
set -e

echo "Waiting for Postgres..."
until nc -z gbrain-postgres 5432 2>/dev/null; do
  echo "Postgres not ready, retrying..."
  sleep 2
done
echo "Postgres ready!"

echo "Initializing brain..."
printf '1\n' | gbrain init --supabase --url "$DATABASE_URL" --no-embedding || true

echo "Starting MCP server..."
exec gbrain serve --http --port 7333 --bind 0.0.0.0