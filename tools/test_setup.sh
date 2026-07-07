#!/bin/bash
#
# tools/test_setup.sh - one-time setup for CLI testing of tap-github.
# Creates a venv at the repo root, installs the tap editable, and (if a
# config exists) runs a cheap auth smoke test via discovery.
#
# The GitHub token is NOT stored in the config. Put it in tools/.env as
#     TAP_GITHUB_AUTH_TOKEN=ghp_xxx
# and these scripts export it as GITHUB_TOKEN, which the tap's authenticator
# picks up natively (any GITHUB_TOKEN* env var is treated as a PAT).
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"   # tools/
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

cd "$REPO_ROOT"
if [ ! -d venv/tap-github ]; then
    python3 -m venv venv/tap-github
fi
. venv/tap-github/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -e .          # hatchling/hatch-vcs build; needs the git repo
echo "Installed $(tap-github --version 2>/dev/null | head -1)"

# Load the token from tools/.env -> GITHUB_TOKEN (see header).
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; . "$SCRIPT_DIR/.env"; set +a
    export GITHUB_TOKEN="${TAP_GITHUB_AUTH_TOKEN:-${GITHUB_TOKEN:-}}"
fi
if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "WARNING: no token found. Add TAP_GITHUB_AUTH_TOKEN to tools/.env" >&2
fi

# Two config modes (tap-github requires exactly one path option per run):
#   tools/test_config.json      -> repositories mode (sub_issues, issue_field_values,
#                                   issue_dependencies_*, issues, pull_requests, ...)
#   tools/test_config.org.json  -> organizations mode (issue_types, issue_fields,
#                                   projects, project_status_updates/views/workflows, ...)
made_config=0
for pair in "test_config.json:test_config.json.template" \
            "test_config.org.json:test_config.org.json.template"; do
    cfg="${pair%%:*}"; tmpl="${pair##*:}"
    if [ ! -f "$SCRIPT_DIR/$cfg" ]; then
        cp "$SCRIPT_DIR/$tmpl" "$SCRIPT_DIR/$cfg"
        echo "Created tools/$cfg from template - edit it to point at your repos/org."
        made_config=1
    fi
done
[ "$made_config" = 1 ] && echo "Re-run this script after editing the config(s)."

# Cheap credential smoke test: discovery authenticates against the GitHub API.
for cfg in test_config.json test_config.org.json; do
    if [ -f "$SCRIPT_DIR/$cfg" ]; then
        if tap-github --config "$SCRIPT_DIR/$cfg" --discover >/dev/null 2>&1; then
            echo "AUTH OK ($cfg)"
        else
            echo "AUTH FAILED ($cfg) - check tools/.env token and the config" >&2
        fi
    fi
done
