#!/usr/bin/env bash
# Build and test LIDAR projects on the ModelScope instance.
#
# Fetches private repos via codeload (needs GH_TOKEN), creates a per-project
# virtualenv, installs editable, and runs the test suite.
#
# With PUBLISH=1 the summary AND the failure logs are uploaded to
# lsnlxt/ms-runner on the `results` branch, so a run can be diagnosed without
# copying terminal output.
#
# Usage:
#   GH_TOKEN=... bash run-project.sh <repo|all|a,b,c> [ref] [base-dir]
#   REF omitted -> each repo's own default branch (queried from the API)
#   PUBLISH=1 ...    upload summary + failure logs
#   USE_VENV=0 ...   install into system python instead
#
# Exit codes: 0 ok, 2 usage/token, 3 fetch, 5 install failed,
#             otherwise pytest's code.
set -uo pipefail

REPO="${1:-}"
REF="${2:-}"
BASE="${3:-/mnt/workspace/projects}"
OWNER="${OWNER:-lsnlxt}"
RESULTS_REPO="${RESULTS_REPO:-ms-runner}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HOSTTAG="$(hostname)"

if [[ -z "$REPO" ]]; then
    echo "usage: run-project.sh <repo|all|a,b,c> [ref] [base-dir]" >&2
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
    mkdir -p "$BASE"
    printf '%s\t%s\t%s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >> "$BASE/summary.tsv"
}

api() {  # api METHOD PATH [BODY]
    local method="$1" path="$2" body="${3:-}"
    local -a a=(-sL -X "$method" -H "Accept: application/vnd.github+json")
    a+=(-H "Authorization: Bearer ${GH_TOKEN}")
    [[ -n "$body" ]] && a+=(-H "Content-Type: application/json" --data-binary "$body")
    curl "${a[@]}" "https://api.github.com/${path}"
}

default_ref() {  # 查仓库真正的默认分支，避免把 main 写死
    api GET "repos/${OWNER}/$1" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin).get("default_branch","main"))' 2>/dev/null \
        || echo main
}

publish_file() {  # publish_file <local-path> <remote-name>
    local src="$1" name="$2" path main_sha b64
    [[ -s "$src" ]] || return 0
    path="results/${name}"

    main_sha=$(api GET "repos/${OWNER}/${RESULTS_REPO}/git/ref/heads/main" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["object"]["sha"])' 2>/dev/null)
    [[ -n "$main_sha" ]] || { echo "   publish skipped: cannot read main"; return 1; }

    api POST "repos/${OWNER}/${RESULTS_REPO}/git/refs" \
        "{\"ref\":\"refs/heads/results\",\"sha\":\"${main_sha}\"}" >/dev/null

    b64=$(base64 -w0 "$src" 2>/dev/null || base64 "$src" | tr -d '\n')
    api PUT "repos/${OWNER}/${RESULTS_REPO}/contents/${path}" \
        "{\"message\":\"results ${name}\",\"content\":\"${b64}\",\"branch\":\"results\"}" >/dev/null
    echo "   published -> ${OWNER}/${RESULTS_REPO}:results/${name}"
}

publish() {
    publish_file "$BASE/summary.tsv" "${HOSTTAG}-${STAMP}.tsv"
    publish_file "$BASE/failures-${STAMP}.log" "${HOSTTAG}-${STAMP}-failures.log"
}

fail_note() {  # 失败时把日志尾巴收进文件，随结果一起上传
    mkdir -p "$BASE"
    {
        echo "===== $1 ($2)"
        echo "--- install log tail"
        tail -25 "/tmp/$1.install.log" 2>/dev/null
        echo "--- pytest log tail"
        tail -40 "/tmp/$1.pytest.log" 2>/dev/null
        echo
    } >> "$BASE/failures-${STAMP}.log"
}

one() {
    local repo="$1" ref="$2" ws tgz code rc py extra
    ws="$BASE/$1"
    tgz="/tmp/${repo}.tgz"

    [[ -n "$ref" ]] || ref=$(default_ref "$repo")
    echo "== ${repo}@${ref}"

    code=$(curl -sL --max-time 600 -w '%{http_code}' \
        -H "Authorization: Bearer ${GH_TOKEN}" -o "$tgz" \
        "https://codeload.github.com/${OWNER}/${repo}/tar.gz/refs/heads/${ref}")
    if [[ "$code" != "200" ]]; then
        echo "   FAIL fetch http=${code}"; record "$repo" "FETCH_FAIL_${code}"; return 3
    fi

    rm -rf "$ws"; mkdir -p "$ws"
    tar -xzf "$tgz" -C "$ws" --strip-components=1 || { record "$repo" TAR_FAIL; return 3; }

    cd "$ws" || { record "$repo" CD_FAIL; return 3; }
    if [[ ! -f pyproject.toml && ! -f setup.py ]]; then
        echo "   SKIP no pyproject.toml / setup.py"; record "$repo" SKIP_NO_BUILD; return 0
    fi

    py=python3
    if [[ "${USE_VENV:-1}" == "1" ]]; then
        if python3 -m venv "$ws/.venv" >/dev/null 2>&1; then
            py="$ws/.venv/bin/python"; echo "   venv: $ws/.venv"
        else
            echo "   WARN venv unavailable, using system python"
        fi
    fi

    extra=""
    if grep -qE '^dev[[:space:]]*=[[:space:]]*\[' pyproject.toml 2>/dev/null; then
        extra="[dev]"
    elif grep -qE '^test[[:space:]]*=[[:space:]]*\[' pyproject.toml 2>/dev/null; then
        extra="[test]"
    fi

    "$py" -m pip install -q -e ".${extra}" > "/tmp/${repo}.install.log" 2>&1
    rc=$?
    if [[ $rc -ne 0 && -n "$extra" ]]; then
        echo "   install with ${extra} failed, retrying plain"
        "$py" -m pip install -q -e . > "/tmp/${repo}.install.log" 2>&1
        rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        echo "   FAIL install (rc=$rc)"
        tail -4 "/tmp/${repo}.install.log" | sed 's/^/     /'
        record "$repo" INSTALL_FAIL
        fail_note "$repo" INSTALL_FAIL
        return 5
    fi

    if [[ ! -d tests ]]; then
        echo "   OK install (no tests/ directory)"; record "$repo" INSTALL_ONLY; return 0
    fi

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
        fail_note "$repo" "PYTEST_FAIL_${rc}"
    fi
    return $rc
}

mkdir -p "$BASE"

if [[ "$REPO" == "all" ]]; then
    list=("${ALL[@]}")
else
    IFS=',' read -r -a list <<< "$REPO"
fi

fails=0
for r in "${list[@]}"; do
    r="$(echo "$r" | tr -d ' ')"
    [[ -n "$r" ]] || continue
    one "$r" "$REF" || fails=$((fails + 1))
done

echo
echo "== done, failures: $fails / ${#list[@]}"
[[ "${PUBLISH:-0}" == "1" ]] && publish
[[ $fails -gt 0 ]] && exit 1
exit 0
