#!/usr/bin/env bash
# One-shot: install the codex config, sanity-check credentials, run ONE real job.
#
# Unlike run-ms.sh (which only proves the fetch chain in --dry-run), this
# actually invokes codex and pushes the result back to the queue branch.
#
# Required env:
#   GH_TOKEN            read/write on the queue repo
#   OPENROUTER_API_KEY  free-tier capable key
#
# Optional:
#   CODEX_HOME          default ~/.codex-executor
#   BUS_OWNER/BUS_REPO/QUEUE_BRANCH   default lsnlxt/lidar-ai-bus/queue/test
#   PROJECT             default test
set -euo pipefail

MIRROR="https://codeload.github.com/lsnlxt/ms-runner/tar.gz/refs/heads/main"
WORK="${WORK_ROOT:-/tmp/executor}"

if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "GH_TOKEN is required" >&2
    exit 2
fi
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    echo "OPENROUTER_API_KEY is required" >&2
    exit 2
fi

curl -sL -o /tmp/wf.tgz "$MIRROR"
tar -xzf /tmp/wf.tgz -C /tmp --strip-components=1 \
    ms-runner-main/ms-worker.sh ms-runner-main/codex-config.toml
chmod +x /tmp/ms-worker.sh

export CODEX_HOME="${CODEX_HOME:-$HOME/.codex-executor}"
mkdir -p "$CODEX_HOME"
if [[ ! -f "$CODEX_HOME/config.toml" ]]; then
    cp /tmp/codex-config.toml "$CODEX_HOME/config.toml"
    echo "installed config -> $CODEX_HOME/config.toml"
fi

model=$(sed -n 's/^model[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$CODEX_HOME/config.toml" | head -1)
echo "CODEX_HOME=$CODEX_HOME"
echo "model=$model"
case "$model" in
    *:free) ;;
    *) echo "WARNING: model does not end in :free; the worker will refuse to run" >&2 ;;
esac

export WORK_ROOT="$WORK"
export BUS_OWNER="${BUS_OWNER:-lsnlxt}"
export BUS_REPO="${BUS_REPO:-lidar-ai-bus}"
export QUEUE_BRANCH="${QUEUE_BRANCH:-queue/test}"

mkdir -p "${WORK}/guard"
printf '0' > "${WORK}/guard/consecutive_failures"

exec /tmp/ms-worker.sh --project "${PROJECT:-test}" --once
