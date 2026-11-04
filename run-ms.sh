#!/usr/bin/env bash
# Bootstrap ms-worker.sh on a fresh ModelScope notebook instance and run one
# dry-run round against the public queue fixture.
#
# The download itself needs no credentials: this repository is public and
# codeload serves it without auth.
#
# Real runs need, exported before calling:
#   GH_TOKEN            read access to the private queue repo (lsnlxt/lidar-ai-bus)
#   OPENROUTER_API_KEY  for the codex execution step
#
# Environment:
#   MS_PROBE=1   also test PyPI reachability (adds up to 30s)
#
# Usage:
#   bash run-ms.sh [WORK_ROOT]
set -euo pipefail

MIRROR="https://codeload.github.com/lsnlxt/ms-runner/tar.gz/refs/heads/main"
WORK="${1:-/tmp/executor}"

# 环境能力自报：决定哪些仓库能在这台实例上构建。
# 便宜项总是跑；PyPI 连通性测试需要 MS_PROBE=1（最多多等 30 秒）。
probe() {
  echo "== environment =="
  printf '  python : %s\n' "$(python3 -V 2>&1)"
  printf '  cpu    : %s\n' "$(nproc 2>/dev/null || echo '?')"
  printf '  mem    : %s\n' "$(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo 2>/dev/null || echo '?')"
  printf '  cc     : %s\n' "$(gcc --version 2>/dev/null | head -1 || echo MISSING)"
  printf '  pyinc  : %s\n' "$(python3-config --includes 2>/dev/null || echo MISSING)"
  printf '  pip    : %s\n' "$(python3 -m pip --version 2>&1 | cut -d' ' -f1-2)"
  if [[ "${MS_PROBE:-0}" == "1" ]]; then
    printf '  pypi   : '
    if timeout 30 python3 -m pip download --no-deps -q --dest /tmp/_pp cython >/dev/null 2>&1; then
      echo reachable
    else
      echo UNREACHABLE
    fi
  fi
}

probe

curl -sL -o /tmp/ms-runner.tar.gz "$MIRROR"
tar -xzf /tmp/ms-runner.tar.gz -C /tmp --strip-components=1 ms-runner-main/ms-worker.sh
chmod +x /tmp/ms-worker.sh
bash -n /tmp/ms-worker.sh

export GH_TOKEN="${GH_TOKEN:-占位}"
export OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-占位}"
export WORK_ROOT="$WORK"
export BUS_OWNER="${BUS_OWNER:-lsnlxt}"
export BUS_REPO="${BUS_REPO:-ms-runner}"
export QUEUE_BRANCH="${QUEUE_BRANCH:-main}"

# 熔断计数器跨进程累计，反复 dry-run 会一路累加到 125。这里归零。
mkdir -p "${WORK}/guard"
printf '0' > "${WORK}/guard/consecutive_failures"

exec /tmp/ms-worker.sh --project test --dry-run --once
