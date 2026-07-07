#!/bin/bash
#
# tools/test_catalog.sh - discover all streams for a config, then split them
# into two bronze catalogs by replication method:
#   github_bronze_master_data_catalog.json - FULL_TABLE streams (master data:
#       repositories, issue_types, issue_fields, labels, projects, sub_issues,
#       issue_field_values, issue_dependencies_*, project_* ...)
#   github_bronze_streams_catalog.json      - INCREMENTAL streams (event data:
#       issues, pull_requests, commits, issue_comments, ...)
#
# Splitting by "forced-replication-method" (from discovery metadata) means no
# hardcoded stream list to maintain. Parent streams are always synced for child
# context even when not selected, so each catalog stays runnable on its own.
#
#   ./tools/test_catalog.sh                              # repositories mode
#   ./tools/test_catalog.sh --config tools/test_config.org.json   # org mode
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"   # tools/
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

CONFIG="$SCRIPT_DIR/test_config.json"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)   CONFIG="${2:?--config needs a file}"; shift 2 ;;
    --config=*) CONFIG="${1#*=}"; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ ! -d "$REPO_ROOT/venv/tap-github" ]; then
    echo "Run ./tools/test_setup.sh first"; exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "jq is required (apt-get install jq)"; exit 1; }

. "$REPO_ROOT/venv/tap-github/bin/activate"
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; . "$SCRIPT_DIR/.env"; set +a
    export GITHUB_TOKEN="${TAP_GITHUB_AUTH_TOKEN:-${GITHUB_TOKEN:-}}"
fi

SRC="$SCRIPT_DIR/github_source_catalog.json"
MASTER="$SCRIPT_DIR/github_bronze_master_data_catalog.json"
STREAMS="$SCRIPT_DIR/github_bronze_streams_catalog.json"

# Discovery -> full catalog. Emits every stream with its schema and metadata.
# (Discovery authenticates, so a failure here usually means a bad/absent token
# in tools/.env or a config with the wrong path option.)
tap-github --config "$CONFIG" --discover > "$SRC"
echo "Discovered $(jq '.streams | length' "$SRC") streams -> $SRC"

# Select every stream whose breadcrumb-[] metadata has
# forced-replication-method == $1, writing the result to $2.
select_by_method() {
    local method="$1" out="$2"
    jq --arg m "$method" '
        .streams |= map(
          if any(.metadata[]; .breadcrumb==[] and .metadata."forced-replication-method"==$m)
          then .metadata |= map(if .breadcrumb==[] then .metadata.selected = true else . end)
          else . end)
      ' "$SRC" > "$out"
}

report_selected() {
    jq -r '.streams[]
           | select(any(.metadata[]; .breadcrumb==[] and .metadata.selected==true))
           | "  * " + .tap_stream_id' "$1"
}

select_by_method FULL_TABLE  "$MASTER"
select_by_method INCREMENTAL "$STREAMS"

echo ""
echo "Created $MASTER (master data / FULL_TABLE):"
report_selected "$MASTER"

echo ""
echo "Created $STREAMS (event streams / INCREMENTAL):"
report_selected "$STREAMS"

# (No jq? Open github_source_catalog.json and add "selected": true inside the
# breadcrumb-[] metadata of the streams you want, saving to a catalog above.)
