#!/usr/bin/env bash
# Probe which OpenRouter free models are actually usable through codex.
# Sends a one-line task to each and reports OK / 429 / error + elapsed time.
#
# Usage: OPENROUTER_API_KEY=... bash probe-models.sh [model ...]
set -uo pipefail

BASE_CONFIG="${BASE_CONFIG:-/root/.codex-executor/config.toml}"
TASK='Create a file named NOTES.md containing exactly one line: ok
Do not do anything else.'

DEFAULT_MODELS=(
    cohere/north-mini-code:free
    recursive/flint-v1.0:free
    nvidia/nemotron-3-lightning:free
    dots-studio/dots-3-note-preview:free
    xingchen-agi/xing4.0-29b-a4b:free
)

if [[ $# -gt 0 ]]; then
    MODELS=("$@")
else
    MODELS=("${DEFAULT_MODELS[@]}")
fi

[[ -f "$BASE_CONFIG" ]] || { echo "missing $BASE_CONFIG" >&2; exit 2; }

for m in "${MODELS[@]}"; do
    home=$(mktemp -d)
    sed "s#^model = .*#model = \"${m}\"#" "$BASE_CONFIG" > "$home/config.toml"

    work=$(mktemp -d)
    ( cd "$work" && git init -q . && printf '# t\n' > README.md \
        && git add -A && git -c user.email=a@b -c user.name=a commit -qm init )

    start=$(date +%s)
    out=$(cd "$work" && printf '%s\n' "$TASK" \
        | CODEX_HOME="$home" timeout 90 codex exec --skip-git-repo-check --sandbox workspace-write 2>&1)
    rc=$?
    end=$(date +%s)
    took=$((end - start))

    if [[ -s "$work/NOTES.md" ]]; then
        printf '%-42s %4ds  OK\n' "$m" "$took"
    elif grep -q '429' <<< "$out"; then
        printf '%-42s %4ds  429 rate-limited\n' "$m" "$took"
    elif [[ $rc -eq 124 ]]; then
        printf '%-42s %4ds  TIMEOUT\n' "$m" "$took"
    else
        first=$(grep -iE '^ERROR|error:' <<< "$out" | head -1)
        printf '%-42s %4ds  FAIL  %s\n' "$m" "$took" "${first:0:60}"
    fi

    rm -rf "$home" "$work"
done
