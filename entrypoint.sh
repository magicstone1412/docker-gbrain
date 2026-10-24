#!/bin/sh
set -e

# Validate GBRAIN_MODE first, before touching Postgres or the brain repo.
#   classic: legacy auto-commit watcher + `gbrain sync --repo`
#   managed: the brain must already be claimed AND activated (gbrain sources
#            writer claim/activate); gbrain serve is then the canonical owner.
GBRAIN_MODE="${GBRAIN_MODE:-classic}"
case "$GBRAIN_MODE" in
  classic|managed) ;;
  *) echo "Invalid GBRAIN_MODE: $GBRAIN_MODE (expected classic|managed)" >&2; exit 2 ;;
esac

# Brain checkout path and source id. Defaults keep the current layout.
#   BRAIN_DIR: absolute path of the brain checkout inside the container. It must
#     equal the path the source was claimed with (sources.local_path). On a
#     managed brain this script never rewrites that path (see section 6); to
#     really move a managed root use the documented `gbrain sources set-path`
#     flow, not this variable.
#   GBRAIN_SOURCE_ID: gbrain source id used for managed sync and local_path.
# Both values are interpolated into shell commands and one SQL statement, so
# they are restricted to a safe character set.
BRAIN_DIR="${BRAIN_DIR:-/data/brain}"
BRAIN_DIR="${BRAIN_DIR%/}"
GBRAIN_SOURCE_ID="${GBRAIN_SOURCE_ID:-default}"
case "$BRAIN_DIR" in
  "") echo "Invalid BRAIN_DIR: the root directory is not allowed" >&2; exit 2 ;;
  /*) ;;
  *) echo "Invalid BRAIN_DIR: $BRAIN_DIR (must be an absolute path)" >&2; exit 2 ;;
esac
case "$BRAIN_DIR" in
  *[!A-Za-z0-9._/-]*) echo "Invalid BRAIN_DIR: only A-Za-z0-9._/- are allowed" >&2; exit 2 ;;
  */..|*/../*|*/.|*/./*|*//*) echo "Invalid BRAIN_DIR: $BRAIN_DIR (no ., .. or // components)" >&2; exit 2 ;;
esac
case "$GBRAIN_SOURCE_ID" in
  ""|*[!A-Za-z0-9._-]*) echo "Invalid GBRAIN_SOURCE_ID: $GBRAIN_SOURCE_ID (only A-Za-z0-9._- are allowed)" >&2; exit 2 ;;
esac

# GBRAIN_REFRESH_UPSTREAM (managed mode only, default false): before every sync
# cycle run `gbrain sources refresh <source>`, the only way a managed checkout
# takes new upstream commits (for example commits pushed from another machine).
# A managed brain never runs `git pull` itself, and autopilot never runs
# `sources refresh`, so without this the checkout falls behind origin.
GBRAIN_REFRESH_UPSTREAM="${GBRAIN_REFRESH_UPSTREAM:-false}"
case "$GBRAIN_REFRESH_UPSTREAM" in
  true|false) ;;
  *) echo "Invalid GBRAIN_REFRESH_UPSTREAM: $GBRAIN_REFRESH_UPSTREAM (expected true|false)" >&2; exit 2 ;;
esac

echo "gbrain build: $(tr '\n' ' ' < /app/.gbrain-build-info)"

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
#    gbrain reads VOYAGE_API_KEY, OPENAI_API_KEY, and ANTHROPIC_API_KEY
#    directly from env — no `gbrain config set` needed.
# ---------------------------------------------------------------------------
echo "API key status:"
for var in VOYAGE_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY; do
  eval val=\$$var
  if [ -n "$val" ]; then
    echo "  ✓ $var is set"
  else
    echo "  - $var not set"
  fi
done

# ---------------------------------------------------------------------------
# 2b. Custom endpoint normalization (ANTHROPIC_BASE_URL / OPENAI_BASE_URL)
#     Works around gbrain issue #1250: the Vercel AI SDK POSTs to
#     "${ANTHROPIC_BASE_URL}/messages" verbatim, so a bare host
#     (https://api.example.com, no /v1) returns HTTP 404. gbrain reads these
#     vars straight from process.env, so exporting the corrected value here
#     is enough — no gbrain-side patch needed. Still open upstream as of
#     gbrain 0.37.3.0+; safe to keep even after it's fixed (idempotent).
# ---------------------------------------------------------------------------
normalize_base_url() {
  # $1 = raw URL, prints URL guaranteed to end in /v<N>
  case "$1" in
    */v[0-9]|*/v[0-9]/) printf '%s' "$1" ;;
    */) printf '%sv1' "$1" ;;
    *)  printf '%s/v1' "$1" ;;
  esac
}

if [ -n "$ANTHROPIC_BASE_URL" ]; then
  NORMALIZED=$(normalize_base_url "$ANTHROPIC_BASE_URL")
  if [ "$NORMALIZED" != "$ANTHROPIC_BASE_URL" ]; then
    echo "  ⚠ ANTHROPIC_BASE_URL missing /v1 — normalizing: $ANTHROPIC_BASE_URL -> $NORMALIZED"
    export ANTHROPIC_BASE_URL="$NORMALIZED"
  fi
  echo "  ✓ ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL (custom endpoint)"
fi

if [ -n "$OPENAI_BASE_URL" ]; then
  NORMALIZED=$(normalize_base_url "$OPENAI_BASE_URL")
  if [ "$NORMALIZED" != "$OPENAI_BASE_URL" ]; then
    echo "  ⚠ OPENAI_BASE_URL missing /v1 — normalizing: $OPENAI_BASE_URL -> $NORMALIZED"
    export OPENAI_BASE_URL="$NORMALIZED"
  fi
  echo "  ✓ OPENAI_BASE_URL=$OPENAI_BASE_URL (custom endpoint)"
fi

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
if [ -n "$VOYAGE_API_KEY" ]; then
  EMBEDDING_FLAG="--embedding-model voyage:voyage-4 --embedding-dimensions 1024"
  echo "Embedding provider: Voyage (voyage-4, 1024d)"
elif [ -n "$OPENAI_API_KEY" ]; then
  EMBEDDING_FLAG="--embedding-model openai:text-embedding-3-large"
  echo "Embedding provider: OpenAI (text-embedding-3-large)"
else
  EMBEDDING_FLAG="--no-embedding"
  echo "No embedding API key — deferring embedding setup."
fi

# Determine embed model/dims for patching later
if [ -n "$VOYAGE_API_KEY" ]; then
  EMBED_MODEL="voyage:voyage-4"
  EMBED_DIMS=1024
elif [ -n "$OPENAI_API_KEY" ]; then
  EMBED_MODEL="openai:text-embedding-3-large"
  EMBED_DIMS=3072
fi

if [ "$ALREADY_INITIALIZED" = "true" ]; then
  echo "Brain already initialized — running migrations only..."
  printf '1\n' | gbrain init --supabase --url "$DATABASE_URL" --no-embedding \
    || echo "  [warn] gbrain init (migrations) exited non-zero — continuing; check 'gbrain doctor'"
else
  echo "First-time initialization..."
  # shellcheck disable=SC2086
  printf '1\n' | gbrain init --supabase --url "$DATABASE_URL" $EMBEDDING_FLAG \
    || echo "  [warn] gbrain init exited non-zero — continuing; check 'gbrain doctor'"
fi

# Patch embedding config AFTER gbrain init — init always overwrites config.json,
# so we must patch after it runs, not before.
CONFIG_FILE="${GBRAIN_HOME:-$HOME}/.gbrain/config.json"
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
# 4b. Runtime settings that must be re-applied on every start
#     (gbrain init rewrites config.json, so set them AFTER init).
#
#     EMBED_MAX_USD_PER_RUN: gbrain >= 0.60.46 asks for approval before any
#       paid command and exits 3 (confirmation_required) when there is no
#       terminal. A per-run preapproval (host-only setting) lets small paid
#       runs proceed. Default: 1 (USD). Set EMBED_MAX_USD_PER_RUN to an empty
#       string to disable (compose must use ${EMBED_MAX_USD_PER_RUN-1}).
#
#     `|| echo` keeps `set -e` from killing the container on older gbrain
#     versions that don't know this key.
# ---------------------------------------------------------------------------
EMBED_MAX_USD_PER_RUN="${EMBED_MAX_USD_PER_RUN-1}"

if [ -n "$EMBED_MAX_USD_PER_RUN" ]; then
  gbrain config set consent.preapprove.paid.max_usd_per_run "$EMBED_MAX_USD_PER_RUN" \
    && echo "Embed preapproval: up to \$${EMBED_MAX_USD_PER_RUN} per paid run" \
    || echo "  [warn] could not set consent.preapprove.paid.max_usd_per_run"
fi

# ---------------------------------------------------------------------------
# 5. Ensure $BRAIN_DIR (default /data/brain) is a Git repo with git config
# ---------------------------------------------------------------------------
echo "Configuring brain repo ($BRAIN_DIR)..."

# True when $1 is a mount point inside this container (reads /proc/self/mountinfo in plain sh, no awk
# needed; BRAIN_DIR is restricted to a safe character set, so no unescaping).
is_mountpoint() {
  while read -r _ _ _ _ mp _; do
    [ "$mp" = "$1" ] && return 0
  done < /proc/self/mountinfo
  return 1
}

mkdir -p "$BRAIN_DIR"
if ! is_mountpoint "$BRAIN_DIR"; then
  echo "  [warn] $BRAIN_DIR is not a mount point: the brain lives in the container filesystem and is lost when the container is recreated"
fi
if [ "$GBRAIN_MODE" = "managed" ]; then
  BRAIN_PARENT=$(dirname "$BRAIN_DIR")
  if ! is_mountpoint "$BRAIN_PARENT"; then
    echo "  [warn] managed mode: $BRAIN_PARENT is not a mount point. The owner reservation (.gbrain-owner-*.json) is kept beside the root and would be lost on recreate (recovery_required)"
  fi
fi

# Global git config — must run unconditionally on every container start,
# not just on first init. Without this, git pull inside gbrain sync will
# hang waiting for an editor that doesn't exist in the container.
git config --global core.editor "true"
git config --global pull.rebase false
git config --global merge.conflictstyle diff3

if [ ! -d "$BRAIN_DIR/.git" ]; then
  cd "$BRAIN_DIR"
  git init
  git config user.email "gbrain@local"
  git config user.name "GBrain"
  git commit --allow-empty -m "init brain repo"
  cd /app
else
  # Ensure git config exists even after volume remount
  git -C "$BRAIN_DIR" config user.email "gbrain@local" || true
  git -C "$BRAIN_DIR" config user.name "GBrain" || true
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
    if git -C "$BRAIN_DIR" remote get-url origin >/dev/null 2>&1; then
      git -C "$BRAIN_DIR" remote set-url origin "$BRAIN_REMOTE"
    else
      git -C "$BRAIN_DIR" remote add origin "$BRAIN_REMOTE"
    fi
    echo "  origin set to $BRAIN_REMOTE"
  fi

  # If a remote exists, make the current branch track it so pull/push work.
  if git -C "$BRAIN_DIR" remote get-url origin >/dev/null 2>&1; then
    BRANCH=$(git -C "$BRAIN_DIR" symbolic-ref --short HEAD 2>/dev/null || echo main)
    if git -C "$BRAIN_DIR" fetch origin "$BRANCH" 2>/dev/null; then
      git -C "$BRAIN_DIR" branch --set-upstream-to="origin/$BRANCH" "$BRANCH" 2>/dev/null || true
      echo "  tracking origin/$BRANCH — SSH auth OK"
    else
      echo "  initial fetch failed (check key/permissions/URL) — sync will retry"
    fi
  fi
else
  echo "No SSH keys at /root/.ssh — brain repo treated as local-only."
fi

# ---------------------------------------------------------------------------
# 6. Source path in Postgres
#    classic: point the source at $BRAIN_DIR (idempotent: writes only when the
#             stored value differs).
#    managed: the claim recorded the path, so this script never rewrites it. It
#             only verifies that BRAIN_DIR matches. A different path would mean
#             running against the wrong checkout, and the owner reservation is
#             named after sha256(root).
# ---------------------------------------------------------------------------
CURRENT_LOCAL_PATH=$(psql "$DATABASE_URL" -Atc \
  "SELECT local_path FROM sources WHERE id = '$GBRAIN_SOURCE_ID';" 2>/dev/null || true)
if [ "$GBRAIN_MODE" = "managed" ]; then
  if [ -n "$CURRENT_LOCAL_PATH" ] && [ "$CURRENT_LOCAL_PATH" != "$BRAIN_DIR" ]; then
    echo "[error] managed mode: BRAIN_DIR=$BRAIN_DIR but sources.local_path=$CURRENT_LOCAL_PATH for source '$GBRAIN_SOURCE_ID'." >&2
    echo "        Refusing to start. Set BRAIN_DIR to the claimed path, or move the root with 'gbrain sources set-path'." >&2
    exit 78
  fi
  if [ -z "$CURRENT_LOCAL_PATH" ]; then
    echo "  [warn] managed mode: could not read sources.local_path for '$GBRAIN_SOURCE_ID'; path not verified"
  else
    echo "Managed mode: source '$GBRAIN_SOURCE_ID' path verified ($CURRENT_LOCAL_PATH)"
  fi
else
  psql "$DATABASE_URL" -c \
    "UPDATE sources SET local_path = '$BRAIN_DIR' WHERE id = '$GBRAIN_SOURCE_ID' AND local_path IS DISTINCT FROM '$BRAIN_DIR';" \
    2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 7. Runtime mode
#    classic keeps the legacy auto-commit + repository sync behavior.
#    managed leaves commits under managed persistence and uses coordinator sync.
# ---------------------------------------------------------------------------
echo "GBrain mode: $GBRAIN_MODE (brain: $BRAIN_DIR, source: $GBRAIN_SOURCE_ID)"

if [ "$GBRAIN_MODE" = "classic" ]; then
  echo "Starting auto-commit watcher..."
  (while true; do
    sleep 30
    cd "$BRAIN_DIR"
    if [ -n "$(git status --porcelain)" ]; then
      git add .
      git commit -m "auto: $(date '+%Y-%m-%d %H:%M:%S')" \
        && echo "[auto-commit] changes committed"
    fi
  done) &
else
  echo "Managed mode: auto-commit watcher disabled."
fi

# ---------------------------------------------------------------------------
# 8. Sync + embed loop
#    SYNC_INTERVAL: seconds between sync cycles (default: 900).
#    Set via -e SYNC_INTERVAL=300 in docker run or compose environment.
# ---------------------------------------------------------------------------
SYNC_INTERVAL="${SYNC_INTERVAL:-900}"
# Explicit spend cap for the embed backfill: works without a terminal and does
# not depend on the preapproval config surviving `gbrain init` (see 4b).
EMBED_CAP_ARGS=""
if [ -n "$EMBED_MAX_USD_PER_RUN" ]; then
  EMBED_CAP_ARGS="--max-usd $EMBED_MAX_USD_PER_RUN"
fi
# Upstream refresh is only meaningful on a managed brain whose checkout tracks a
# remote. A failed or refused refresh never stops the cycle: like upstream's
# scheduled recipe (`gbrain sources refresh <id>; gbrain sync --no-pull ...`) the
# sync still runs afterwards, which also lets it finish an unfinished cursor
# that a refresh may have refused on (sync_in_progress).
REFRESH_ENABLED=false
if [ "$GBRAIN_REFRESH_UPSTREAM" = "true" ]; then
  if [ "$GBRAIN_MODE" != "managed" ]; then
    echo "  [warn] GBRAIN_REFRESH_UPSTREAM=true ignored: only used in managed mode (classic sync pulls by itself)"
  elif ! git -C "$BRAIN_DIR" remote get-url origin >/dev/null 2>&1; then
    echo "  [warn] GBRAIN_REFRESH_UPSTREAM=true ignored: $BRAIN_DIR has no 'origin' remote to refresh from"
  else
    REFRESH_ENABLED=true
  fi
fi
echo "Upstream refresh before each sync cycle: $REFRESH_ENABLED"

refresh_upstream() {
  echo "[refresh] gbrain sources refresh $GBRAIN_SOURCE_ID (drain writes, fast-forward to origin, sync)..."
  rc=0
  gbrain sources refresh "$GBRAIN_SOURCE_ID" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "[refresh] done"
  else
    echo "[refresh] refused or failed (exit $rc); continuing with sync. Cause: gbrain sources refresh $GBRAIN_SOURCE_ID --dry-run"
  fi
}

echo "Starting sync+embed loop (mode: $GBRAIN_MODE, interval: ${SYNC_INTERVAL}s, embed cap: ${EMBED_MAX_USD_PER_RUN:-none})..."
(while true; do
  if [ "$REFRESH_ENABLED" = "true" ]; then
    refresh_upstream
  fi
  if [ "$GBRAIN_MODE" = "managed" ]; then
    if gbrain sync --source "$GBRAIN_SOURCE_ID" --no-pull; then
      SYNC_OK=true
    else
      SYNC_OK=false
    fi
  elif gbrain sync --repo "$BRAIN_DIR"; then
    SYNC_OK=true
  else
    SYNC_OK=false
  fi
  if [ "$SYNC_OK" = "true" ]; then
    if [ -n "$VOYAGE_API_KEY" ] || [ -n "$OPENAI_API_KEY" ]; then
      # shellcheck disable=SC2086
      gbrain embed --stale $EMBED_CAP_ARGS || echo "[embed] embed failed, will retry next cycle"
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
# 9. Start autopilot daemon (optional, controlled by AUTOPILOT_ENABLED)
#    Monitors brain health and runs overnight enrichment cycle automatically.
#    - Healthy brain (score 95+): sleeps 60min between ticks
#    - Unhealthy brain: runs full cycle (sync, extract, embed, consolidate, synthesize)
#    Enable via: AUTOPILOT_ENABLED=true in docker-compose environment.
#    Requires at least one embedding API key — autopilot runs embed phases
#    that are no-ops (or harmful) without a configured embedding provider.
#
#    `gbrain autopilot` is a self-maintaining daemon (lint, backlinks, sync,
#    extract, embed, orphans). It wakes every 300 s by default (`--interval <s>`;
#    adaptive: doubled when brain_score >= 90, halved (min 60 s) below 70).
#    On Postgres it spawns its own jobs worker child and dispatches each tick
#    through the job queue, unless started with `--no-worker` (no child) or
#    `--inline` (in-process, no child); `minion_mode=off` also means no child.
#
#    `--install` is the persistent entry point (flag consent: persistent_install).
#    The target is auto-detected (independent of GBRAIN_MODE): inside Docker
#    (/.dockerenv, RENDER, RAILWAY_ENVIRONMENT, FLY_APP_NAME) gbrain picks
#    `ephemeral-container`. That target writes ~/.gbrain/start-autopilot.sh (on
#    the ./.config volume), an executable that self-backgrounds with `nohup`,
#    and this entrypoint executes it directly on every container start.
#    `--no-inject` stops --install from editing any agent bootstrap files.
#
#    Operate it from OUTSIDE the container; never start a second daemon by hand:
#      docker exec gbrain gbrain autopilot --status --json
#      docker exec gbrain gbrain autopilot pause --reason "<why>"
#      docker exec gbrain gbrain autopilot resume
#      docker exec gbrain gbrain autopilot --retry-global [--phase <name>]
#    `pause` writes ~/.gbrain/autopilot-operator-paused: the daemon skips cycles
#    and job workers stop claiming jobs (an in-flight job finishes). The marker
#    lives on the ./.config volume and `--install` and `gbrain upgrade` keep it,
#    so it SURVIVES container restarts until `resume`. The sync+embed loop in
#    section 8 (plain CLI processes) is not held by it.
#    Changing AUTOPILOT_ENABLED or the API keys needs a container restart (a
#    running ephemeral daemon keeps its old environment).
#
#    The daemon wrapper inherits process environment, then sources shell
#    profiles, then ~/.gbrain/env last. Mirroring keys into that file gives
#    non-interactive daemon runs a deterministic override channel.
# ---------------------------------------------------------------------------
HAS_EMBEDDING_KEY=false
AUTOPILOT_WORKER_OWNED=false
if [ -n "$VOYAGE_API_KEY" ] || [ -n "$OPENAI_API_KEY" ]; then
  HAS_EMBEDDING_KEY=true
fi

if [ "${AUTOPILOT_ENABLED:-false}" = "true" ]; then
  if [ "$HAS_EMBEDDING_KEY" = "true" ]; then
    echo "Autopilot daemon starting. NOTE: an embedding key alone does not guarantee a usable LLM chat provider."
    echo "chronicle/dream/enrich require Anthropic or OpenAI chat and no-op if none is available."
    echo "Set ANTHROPIC_API_KEY or OPENAI_API_KEY, or check 'gbrain autopilot --status' / autopilot.log after boot."
    GBRAIN_DIR="${GBRAIN_HOME:-$HOME}/.gbrain"
    GBRAIN_ENV_FILE="$GBRAIN_DIR/env"
    START_SCRIPT="$GBRAIN_DIR/start-autopilot.sh"
    mkdir -p "$GBRAIN_DIR"

    # Regenerate the wrapper and env template on every container start.
    # On ephemeral targets this does not reload a running daemon: it keeps its
    # old environment until the container restarts or it is killed and relaunched.
    # Reinstall reloads a running daemon only on launchd and systemd targets.
    #
    # gbrain >= 0.60.46 treats --install as a persistent_install effect and
    # exits 3 (confirmation_required) without a terminal. AUTOPILOT_ENABLED=true
    # is the operator's consent, so pass --yes. (Command taken from gbrain's own
    # `if_yes` hint.) Without --yes the old start-autopilot.sh is reused only if
    # it survived in the container filesystem; a recreated container would have
    # no script and autopilot would silently not run.
    #
    # The install target is auto-detected (no --target). Inside Docker gbrain
    #   picks ephemeral-container via /.dockerenv. On a runtime without that
    #   marker it could pick systemd or crontab instead; then no start script
    #   is written and the "not found after --install" warning below fires.
    #   If that happens, add `--target ephemeral-container` here.
    # --no-inject: never edit agent bootstrap files (--inject-bootstrap is
    #   otherwise automatic when OpenClaw is detected).
    echo "Installing/reloading autopilot (target auto-detected)..."
    gbrain autopilot --install --yes --no-inject --brain host \
      || echo "  [warn] gbrain autopilot --install exited non-zero, continuing"

    # Mirror live container env into the daemon-owned env file (0600),
    # preserving any lines --install already wrote that we don't manage.
    touch "$GBRAIN_ENV_FILE"
    chmod 600 "$GBRAIN_ENV_FILE"
    for var in VOYAGE_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_BASE_URL OPENAI_BASE_URL; do
      val=$(printenv "$var" 2>/dev/null || true)
      [ -z "$val" ] && continue
      tmp_env=$(mktemp "${GBRAIN_ENV_FILE}.XXXXXX")
      grep -v "^${var}=" "$GBRAIN_ENV_FILE" > "$tmp_env" || true
      escaped_val=$(printf '%s' "$val" | sed "s/'/'\\\\''/g")
      printf "%s='%s'\n" "$var" "$escaped_val" >> "$tmp_env"
      chmod 600 "$tmp_env"
      mv "$tmp_env" "$GBRAIN_ENV_FILE"
    done
    chmod 600 "$GBRAIN_ENV_FILE"
    echo "  synced $(grep -c '=' "$GBRAIN_ENV_FILE" 2>/dev/null || echo 0) key(s) into $GBRAIN_ENV_FILE"

    # The container-mode artifact --install produces is itself executable
    # with a #!/bin/bash shebang and self-backgrounds via its own
    # `nohup ... &`. Execute it directly (not `. sourced`) so bash — not
    # this sh/dash entrypoint — runs it, and don't double-background: the
    # script returns almost immediately after its internal nohup call.
    if [ -x "$START_SCRIPT" ]; then
      echo "Starting autopilot via $START_SCRIPT ..."
      "$START_SCRIPT"
      echo "Autopilot started (pid $(cat "$GBRAIN_DIR/autopilot.pid" 2>/dev/null || echo '?'))."
      AUTOPILOT_WORKER_OWNED=true
    elif [ -f "$START_SCRIPT" ]; then
      echo "Starting autopilot via $START_SCRIPT (via sh, not marked executable) ..."
      sh "$START_SCRIPT"
      echo "Autopilot started."
      AUTOPILOT_WORKER_OWNED=true
    else
      echo "  [warn] $START_SCRIPT not found after --install — autopilot NOT running."
      echo "  Check 'gbrain autopilot --status' and container logs for the real cause."
    fi

    # Read-only sanity check of the daemon (`--status` only reads the lock,
    # markers and log). It exits 1 when the daemon is stale, has not run yet
    # (normal for the first seconds), is paused, or brain-wide maintenance is
    # stalled, and 2 when it self-disabled (repo gone), so it must never stop
    # startup; `timeout` keeps a hung call from delaying `gbrain serve`. An
    # operator pause is deliberately NOT lifted here: if the status shows the
    # daemon is paused, run `docker exec gbrain gbrain autopilot resume`.
    if [ "$AUTOPILOT_WORKER_OWNED" = "true" ]; then
      sleep 5
      echo "Autopilot status:"
      timeout 30 gbrain autopilot --status --json --brain host 2>&1 | sed 's/^/  /' || true
    fi
  else
    echo "Autopilot skipped — AUTOPILOT_ENABLED=true but no embedding API key is set."
    echo "Set VOYAGE_API_KEY or OPENAI_API_KEY to enable the daemon; chat phases also need Anthropic or OpenAI."
  fi
else
  echo "Autopilot disabled (set AUTOPILOT_ENABLED=true to enable)."
fi

# ---------------------------------------------------------------------------
# 10. Start a standalone worker only when autopilot did not take ownership.
#     This keeps async jobs processing when autopilot is disabled or skipped,
#     while avoiding an uncoordinated second worker when autopilot is running.
#     `gbrain autopilot` spawns its own jobs worker child by default on Postgres
#     (`--no-worker`, `--inline` and minion_mode=off turn that off). The wrapper
#     that --install generates passes none of them. If that ever changes, set
#     AUTOPILOT_WORKER_OWNED=false so this block starts the standalone worker.
#     Note the flag means "start script was launched", not "daemon is healthy".
# ---------------------------------------------------------------------------
if [ "$AUTOPILOT_WORKER_OWNED" = "false" ]; then
  echo "Starting job worker..."
  gbrain jobs work &
  JOB_WORKER_PID=$!
  echo "Job worker started (PID $JOB_WORKER_PID)"
fi

# ---------------------------------------------------------------------------
# 10b. Managed mode: report (read-only) whether the owner will commit and push.
#      git_durability is a per-host-binding setting stored in the database. Only
#      the operator can change it, with the trusted local CLI:
#        gbrain sources writer git-durability <source> --enable --dry-run
#        gbrain sources writer git-durability <source> --enable \
#          --admin-intent writer_git_durability --expected-state <admin_state>
#      This script deliberately never changes it: startup checks must leave
#      ownership administration alone. It only warns, because with durability
#      off the owner still writes page files but leaves them uncommitted.
# ---------------------------------------------------------------------------
if [ "$GBRAIN_MODE" = "managed" ]; then
  WRITER_STATUS=$(gbrain sources writer status "$GBRAIN_SOURCE_ID" --brain host --json 2>/dev/null || true)
  if printf '%s' "$WRITER_STATUS" | grep -Eq '"git_durability"[[:space:]]*:[[:space:]]*"on"'; then
    echo "Git durability: on (the owner commits and pushes page writes)"
  else
    echo "  [warn] managed mode: git_durability is not 'on' for source '$GBRAIN_SOURCE_ID' (or the status could not be read)."
    echo "         Page writes are saved as files but may stay UNCOMMITTED. Operator action: gbrain sources writer git-durability $GBRAIN_SOURCE_ID --enable --dry-run"
  fi
fi

# ---------------------------------------------------------------------------
# 11. Start MCP server (foreground / PID 1)
# ---------------------------------------------------------------------------
echo "Starting MCP server..."
# GBRAIN_PUBLIC_URL (optional): URL that clients (e.g. a separate Hermes host)
# actually call, so the OAuth issuer matches. Verify with `gbrain serve --help`
# that --public-url exists on your gbrain version before setting it.
SERVE_ARGS="--http --port 7333 --bind 0.0.0.0"
if [ -n "${GBRAIN_PUBLIC_URL:-}" ]; then
  SERVE_ARGS="$SERVE_ARGS --public-url $GBRAIN_PUBLIC_URL"
fi
# shellcheck disable=SC2086
exec gbrain serve $SERVE_ARGS