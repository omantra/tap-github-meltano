#!/bin/bash
#
# tools/test_fetch.sh - run extractions so devs can compare full vs incremental:
#   1. master data (FULL_TABLE)   -> tools/master_data.jsonl
#   2. event streams (INCREMENTAL) -> tools/streams.jsonl
#
#   ./tools/test_fetch.sh                     # both full syncs
#   ./tools/test_fetch.sh --head 20           # first 20 lines of each (quick peek)
#   ./tools/test_fetch.sh --state tools/state.json     # resume the incremental run
#   ./tools/test_fetch.sh --config tools/test_config.org.json --head 50   # org mode
#
# Options: --head N | --state FILE (streams only) | --config FILE
# Run ./tools/test_catalog.sh (with the matching --config) first.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"   # tools/
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

CONFIG="$SCRIPT_DIR/test_config.json"
MASTER_CAT="$SCRIPT_DIR/github_bronze_master_data_catalog.json"
STREAMS_CAT="$SCRIPT_DIR/github_bronze_streams_catalog.json"
MASTER_OUT="$SCRIPT_DIR/master_data.jsonl"
STREAMS_OUT="$SCRIPT_DIR/streams.jsonl"
LOG="$SCRIPT_DIR/tap-fetch.log"
HEAD=""
STATE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --head)     HEAD="${2:?--head needs a number}"; shift 2 ;;
    --head=*)   HEAD="${1#*=}"; shift ;;
    --state)    STATE="${2:?--state needs a file}"; shift 2 ;;
    --config)   CONFIG="${2:?--config needs a file}"; shift 2 ;;
    --config=*) CONFIG="${1#*=}"; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ ! -d "$REPO_ROOT/venv/tap-github" ]; then
    echo "Run ./tools/test_setup.sh first"; exit 1
fi
. "$REPO_ROOT/venv/tap-github/bin/activate"
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; . "$SCRIPT_DIR/.env"; set +a
    export GITHUB_TOKEN="${TAP_GITHUB_AUTH_TOKEN:-${GITHUB_TOKEN:-}}"
fi

# Run one catalog through the tap. stdout = Singer messages (SCHEMA/RECORD/STATE),
# stderr = logs/metrics -> $LOG (appended), so --head sees clean output and can
# stop the tap early. head precedes tee so $out is capped to the same N lines.
run_extraction() {
    local label="$1" catalog="$2" out="$3"; shift 3
    local extra=("$@")   # any additional tap args (e.g. --state)
    if [ ! -f "$catalog" ]; then
        echo "No $catalog - run ./tools/test_catalog.sh first"; exit 1
    fi
    echo ">> [$label] fetch ${HEAD:+(first $HEAD lines) }-> $out   (tap logs -> $LOG)" >&2
    if [ -n "$HEAD" ]; then
        set +o pipefail
        tap-github --config "$CONFIG" --catalog "$catalog" "${extra[@]}" 2>>"$LOG" \
            | head -n "$HEAD" | tee "$out"
        set -o pipefail
    else
        tap-github --config "$CONFIG" --catalog "$catalog" "${extra[@]}" 2>>"$LOG" \
            | tee "$out"
    fi
    echo ">> [$label] wrote $(wc -l < "$out") lines to $out" >&2
}

: > "$LOG"   # fresh log for this run

# 1) master data - FULL_TABLE streams, re-extracted in full every run.
run_extraction "master-data / FULL_TABLE" "$MASTER_CAT" "$MASTER_OUT"

echo "" >&2

# 2) event streams - INCREMENTAL streams; pass --state to resume from a bookmark.
stream_args=()
[ -n "$STATE" ] && stream_args=(--state "$STATE")
run_extraction "streams / INCREMENTAL" "$STREAMS_CAT" "$STREAMS_OUT" "${stream_args[@]}"

# Inspect what came back:
#   jq -r 'select(.type=="RECORD") | .stream' tools/master_data.jsonl | sort | uniq -c
#   jq -r 'select(.type=="RECORD") | .stream' tools/streams.jsonl     | sort | uniq -c
# Resume the incremental run from the last bookmark:
#   jq -c 'select(.type=="STATE") | .value' tools/streams.jsonl | tail -1 > tools/state.json
#   ./tools/test_fetch.sh --state tools/state.json
