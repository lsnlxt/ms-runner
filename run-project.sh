#!/usr/bin/env bash
# Build and test one LIDAR project on the ModelScope instance.
#
# Fetches a private repo via codeload (needs GH_TOKEN), creates a per-project
# virtualenv, installs the package editable, and runs its test suite.
# Results are appended to <base>/summary.tsv so they survive the instance.
#
# Per-project venvs matter: installing 18 projects into one system Python means
# they share (and fight over) the same dependency versions.
#
# Usage:
#   GH_TOKEN=... bash run-project.sh <repo> [ref] [base-dir]
#   GH_TOKEN=... bash run-project.sh all  [ref] [base-dir]
#   USE_VENV=0 ...   install into system python instead
#
# Exit codes: 0 ok, 2 usage/token, 3 fetch, 4 no build file,
#             5 install failed, otherwise pytest's code.
set -uo pipefail

REPO="${1:-}"
REF="${2:-main}"
BASE="${3:-/mnt/workspace/projects}"

if [[ -z "$REPO" ]]; then
    echo "usage: run-project.sh <repo|all> [ref] [base-dir]" >&2
    exit 2
fi
if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "GH_TOKEN is required (private repos)" >&2
    exit 2
fi

ALL=(
    laser-physics-core lidar-ai-bus lidar-atmosphere lidar-calibration lidar-cli
    lidar-data-model lidar-detectors lidar-geometry lidar-inversion
    lidar-signal-processing lidar-sim-service lidar-software-suite lidar-studio
    lidar-system-sim lidar-techprep-2027 flow-dashboard
)

record() {
    local repo="$1" status="$2"
    mkdir -p "$BASE"
    printf '%s\t%s\t%s\n' "$repo" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" >> "$BASE/summary.tsv"
}

one() {
    local repo="$1" ref="$2" ws="$BASE/$1" tgz code rc py status
    tgz="/tmp/${repo}.tgz"
    echo "== ${repo}@${ref}"

    code=$(curl -sL --max-time 600 -w '%{http_code}' \
        -H "Authorization: Bearer ${GH_TOKEN}" -o "$tgz" \
        "https://codeload.github.com/lsnlxt/${repo}/tar.gz/refs/heads/${ref}")
    if [[ "$code" != "200" ]]; then
        echo "   FAIL fetch http=${code}"
        record "$repo" "FETCH_FAIL_${code}"
        return 3
    fi

    rm -rf "$ws"
    mkdir -p "$ws"
    tar -xzf "$tgz" -C "$ws" --strip-components=1 || { record "$repo" TAR_FAIL; return 3; }

    cd "$ws" || { record "$repo" CD_FAIL; return 3; }
    if [[ ! -f pyproject.toml && ! -f setup.py ]]; then
        echo "   SKIP no pyproject.toml / setup.py"
        record "$repo" SKIP_NO_BUILD
        return 0
    fi

    py=python3
    if [[ "${USE_VENV:-1}" == "1" ]]; then
        if python3 -m venv "$ws/.venv" >/dev/null 2>&1; then
            py="$ws/.venv/bin/python"
            echo "   venv: $ws/.venv"
        else
            echo "   WARN venv unavailable, using system python"
        fi
    fi

    "$py" -m pip install -q -e . > "/tmp/${repo}.install.log" 2>&1
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "   FAIL install (rc=$rc), last lines:"
        tail -4 "/tmp/${repo}.install.log" | sed 's/^/     /'
        record "$repo" INSTALL_FAIL
        return 5
    fi

    if [[ ! -d tests ]]; then
        echo "   OK install (no tests/ directory)"
        record "$repo" INSTALL_ONLY
        return 0
    fi

    # 新 venv 里没有 pytest；项目自带的 dev extras 未必声明它
    if ! "$py" -m pytest --version >/dev/null 2>&1; then
        "$py" -m pip install -q pytest >> "/tmp/${repo}.install.log" 2>&1
    fi

    "$py" -m pytest -q > "/tmp/${repo}.pytest.log" 2>&1
    rc=$?
    tail -2 "/tmp/${repo}.pytest.log" | sed 's/^/   /'
    if [[ $rc -eq 0 ]]; then
        record "$repo" PASS
    else
        record "$repo" "PYTEST_FAIL_${rc}"
    fi
    return $rc
}

mkdir -p "$BASE"

if [[ "$REPO" == "all" ]]; then
    fails=0
    for r in "${ALL[@]}"; do
        one "$r" "$REF" || fails=$((fails + 1))
    done
    echo
    echo "== done, failures: $fails / ${#ALL[@]}"
    echo "== summary: $BASE/summary.tsv"
    exit $(( fails > 0 ? 1 : 0 ))
fi

one "$REPO" "$REF"
