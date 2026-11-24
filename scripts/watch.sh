#!/bin/bash
# Build-request watcher. Start once in Terminal and leave it running:
#     scripts/watch.sh
#
# Drop a file build/requests/<id>.req whose entire content is ONE allow-listed word:
#     bootstrap core-test mac ios all run-mac stop-mac ios-sim-run screenshot-sim
# The watcher runs `scripts/build.sh <word>` (never anything else), then writes
# build/requests/<id>.done containing the exit code and removes the .req.
# Logs: build/logs/<word>.log and build/logs/<word>.summary.
# <id> may only contain letters, digits, '.', '_' and '-'.
# The watcher only ever deletes files inside build/requests/.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQ_DIR="$ROOT/build/requests"
LOCK_DIR="$REQ_DIR/.watch.lock"
POLL_SECONDS="${CLIPSYNC_WATCH_INTERVAL:-2}"
case "$POLL_SECONDS" in ''|*[!0-9]*) POLL_SECONDS=2 ;; esac

mkdir -p "$REQ_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "error: another watcher seems to be running (lock: $LOCK_DIR)." >&2
    echo "       If not, remove that folder and start again." >&2
    exit 1
fi
cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "==> ClipSync watcher polling $REQ_DIR every ${POLL_SECONDS}s (Ctrl-C to stop)"

while true; do
    for req in "$REQ_DIR"/*.req; do
        [ -f "$req" ] || continue
        name="$(basename "$req")"
        id="${name%.req}"
        case "$id" in
            ''|*[!A-Za-z0-9._-]*)
                echo "==> ignoring request with invalid id: $name"
                rm -f "$req"
                continue
                ;;
        esac
        # Give writers a moment to finish the file.
        sleep 0.2
        word="$(head -c 64 "$req" 2>/dev/null | tr -d '[:space:]')"
        rm -f "$req"
        case "$word" in
            bootstrap|core-test|mac|ios|all|run-mac|stop-mac|ios-sim-run|screenshot-sim)
                echo "==> [$(date '+%H:%M:%S')] $id: build.sh $word"
                "$ROOT/scripts/build.sh" "$word"
                code=$?
                ;;
            *)
                echo "==> [$(date '+%H:%M:%S')] $id: rejected (not an allow-listed command)"
                code=64
                ;;
        esac
        echo "$code" > "$REQ_DIR/$id.done"
        echo "==> [$(date '+%H:%M:%S')] $id: done (exit $code)"
    done
    sleep "$POLL_SECONDS"
done
