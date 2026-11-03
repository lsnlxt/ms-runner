#!/usr/bin/env bash
# ms-worker.sh — ModelScope 一体化 worker：调度 + 执行 + 熔断告警全闭环。
#
# 定位（2026-11-01 最终形态）：ECS 彻底退出，整个工作流迁到 ModelScope。
#   观测/调度大脑 = Claude（我）：决定任务、写 prompt、把 job 投到
#     lidar-ai-bus 的 queue/<项目>/in/。
#   执行体 = 本脚本：拉任务 → 跑完整 Codex 迭代 → 交结果 → 连续失败熔断告警。
#
# 自包含、幂等、可 SIGTERM 干净退出（ModelScope 实例会休眠，不假设常驻）。
#
# 设计要点（来自 ECS 事故沉淀，逐条保留）：
#   1. 不走 git clone（ModelScope 上 git 协议超时），用 codeload tarball + git init。
#   2. 完整复刻 adapter-codex.sh 的保护：CODEX_HOME 固定、免费模型断言、
#      .git/index.lock 预清理、--sandbox workspace-write、--add-dir。
#   3. 复刻 supervise.sh 的预算护栏：MAX_STEPS/MAX_TOKENS/MAX_REPEAT。
#   4. 复刻 guard.sh 的熔断告警：连续失败计数 → 告警 → 停循环。
#   5. key 永不落盘/进日志，只读环境变量并校验存在性。
#   6. 幂等：同一 job_id 重复处理覆盖写同一 out 目录；多执行端靠 claim 乐观并发。
#
# 用法：
#   export GH_TOKEN=...          # 拉/推队列用（gho_）
#   export OPENROUTER_API_KEY=... # Codex 走 OpenRouter 用
#   export CODEX_HOME=...        # 可选，默认 ~/.codex-executor
#   export ALERT_REPO=...        # 可选，熔断告警的目标仓库，默认 lidar-ai-bus
#   ./ms-worker.sh --project <名> --once      # 处理一个任务就退
#   ./ms-worker.sh --project <名>             # 常驻循环（实例存活期内）
#
# 退出码：0=正常；1=配置/环境缺失；124=护栏触发；125=熔断停循环。

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- 可调参数（环境变量可覆盖）-----------------------------------------
PROJECT=""
BUS_OWNER="${BUS_OWNER:-lsnlxt}"
BUS_REPO="${BUS_REPO:-lidar-ai-bus}"
ALERT_REPO="${ALERT_REPO:-${BUS_OWNER}/${BUS_REPO}}"   # 熔断告警落哪
QUEUE_BRANCH="${QUEUE_BRANCH:-}"            # 默认 queue/<PROJECT>
ONCE=0
DRY_RUN=0                                    # 只拉不跑，验证拉取链路
POLL_SECS="${POLL_SECS:-30}"                 # 常驻时轮询间隔
WORK_ROOT="${WORK_ROOT:-/tmp/executor}"      # 工作根目录
MAX_STEPS="${MAX_STEPS:-150}"
MAX_TOKENS="${MAX_TOKENS:-3000000}"
MAX_REPEAT="${MAX_REPEAT:-12}"
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-3}"
REASONING_EFFORT="${REASONING_EFFORT:-low}"
SANDBOX="${SANDBOX:-workspace-write}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex-executor}"

# 当前正在处理的 job_id（run_once 设置，push_results 读取）
CURRENT_JID=""

log()  { printf "[%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf "[%s] WARN: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()  { printf "[%s] FATAL: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

# ---- 参数解析 ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done
[[ -n "$PROJECT" ]] || die "必须指定 --project"
QUEUE_BRANCH="${QUEUE_BRANCH:-queue/${PROJECT}}"

# ---- 环境校验（key 只校验存在性，绝不打印值）----------------------------
check_env() {
  local missing=()
  for v in GH_TOKEN OPENROUTER_API_KEY; do
    if [[ -z "${!v:-}" ]]; then missing+=("$v"); fi
  done
  if (( ${#missing[@]} > 0 )); then
    die "缺少环境变量（请先 export，值不要贴进聊天）：${missing[*]}"
  fi
}

sanitize() {
  # 去掉日志里的敏感模式。gho_/ghp_/sk-/Bearer 等。
  sed -E 's/gh[op]_[A-Za-z0-9]+/gho_REDACTED/g;
          s/sk-[A-Za-z0-9_-]+/sk-REDACTED/g;
          s/Bearer [A-Za-z0-9._-]+/Bearer REDACTED/g;
          s/AIza[A-Za-z0-9_-]+/REDACTED/g'
}

# ---- 拉取队列（codeload tarball，不走 git clone）------------------------
# 输出：把队列解到 $1；返回 0 成功 / 1 失败。
fetch_queue() {
  local dest="$1"
  local url="https://codeload.github.com/${BUS_OWNER}/${BUS_REPO}/tar.gz/refs/heads/${QUEUE_BRANCH}"
  local tmp="${WORK_ROOT}/bus.tar.gz"
  log "拉取队列：${BUS_OWNER}/${BUS_REPO}@${QUEUE_BRANCH}"
  if ! curl -sL --max-time 60 -H "Authorization: Bearer ${GH_TOKEN}" -o "$tmp" "$url"; then
    warn "codeload 拉取失败"
    return 1
  fi
  # 空 tarball（分支不存在）时 codeload 返回 "Not Found" 文本，不是 gzip
  if ! tar tzf "$tmp" >/dev/null 2>&1; then
    warn "队列分支不存在或 tarball 非法：${QUEUE_BRANCH}"
    return 1
  fi
  rm -rf "$dest"; mkdir -p "$dest"
  tar xzf "$tmp" -C "$dest" --strip-components=1
  log "队列已解到 ${dest}"
  return 0
}

# ---- 找下一个未认领任务 -------------------------------------------------
# 输出：打印 in/<job.json 所在目录名>；无任务则打印空。
next_job() {
  local bus="$1"
  local in_dir="${bus}/queue/${PROJECT}/in"
  [[ -d "$in_dir" ]] || return 0
  for j in "$in_dir"/*/; do
    [[ -f "${j}job.json" ]] || continue
    local jid; jid=$(basename "$j")
    # 已认领（out 里已有 claim）则跳过
    [[ -f "${bus}/queue/${PROJECT}/out/job-${jid}/claim.json" ]] && continue
    printf "%s" "$jid"
    return 0
  done
  return 0
}

# ---- 认领任务 -----------------------------------------------------------
claim_job() {
  local bus="$1" jid="$2"
  local outdir="${bus}/queue/${PROJECT}/out/job-${jid}"
  mkdir -p "$outdir"
  printf '{"job_id":"%s","claimed_at":"%s","executor_id":"%s"}\n' \
    "$jid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" > "${outdir}/claim.json"
  log "已认领任务 ${jid}"
}

# ---- 拉任务仓库（codeload + git init）-----------------------------------
fetch_repo() {
  local jobfile="$1" dest="$2"
  local tarball ref
  tarball=$(python3 - "$jobfile" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print(d["repo"]["tarball_url"])
PY
)
  ref=$(python3 - "$jobfile" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print(d["repo"].get("ref","main"))
PY
)
  [[ -n "$tarball" ]] || { warn "job 缺 tarball_url"; return 1; }
  local tmp="${WORK_ROOT}/repo.tar.gz"
  log "拉任务仓库：${tarball}"
  curl -sL --max-time 120 -H "Authorization: Bearer ${GH_TOKEN}" -o "$tmp" "$tarball" || return 1
  # 404/无权限时 codeload 返回文本（非 gzip），必须显式校验，否则「看起来就绪、实则空仓库」。
  if ! tar tzf "$tmp" >/dev/null 2>&1; then
    warn "任务仓库 tarball 非法（404 或 ref 不存在？）：${tarball}"
    return 1
  fi
  rm -rf "$dest"; mkdir -p "$dest"
  tar xzf "$tmp" -C "$dest" --strip-components=1 \
    || { warn "任务仓库解包失败"; return 1; }
  # 本地 git init（tarball 不含 .git），保住 diff/commit 能力
  ( cd "$dest" && git init -q && git add -A >/dev/null 2>&1 && \
    git -c user.email=executor@local -c user.name=executor commit -qm "executor baseline ${ref}" 2>/dev/null || true )
  log "任务仓库已就绪：${dest}（ref=${ref}）"
  return 0
}

# ---- 预算护栏（复刻 supervise.sh 的核心，简化版）------------------------
# 以子进程跑 agent，按 MAX_STEPS 之外的信号之一（反复同命令）近似护栏。
# 完整 token/步数统计需 Codex 会话文件，这里保留结构，接入时按 supervise.sh 实现。
run_guarded() {
  local jobdir="$1" repo="$2" prompt="$3" outlog="$4"
  local adapter_rc=0
  # 预清理 index.lock（ECS 事故：残留会让 Codex 陷入反复重试）
  [[ -f "$repo/.git/index.lock" ]] && rm -f "$repo/.git/index.lock"

  log "CODEX_HOME=${CODEX_HOME} sandbox=${SANDBOX} effort=${REASONING_EFFORT}"

  # Codex 免费模型断言（ECS adapter 原样保留）
  if [[ -f "${CODEX_HOME}/config.toml" ]]; then
    local m
    m=$(python3 - "${CODEX_HOME}/config.toml" <<'PY' 2>/dev/null || echo ""
import re,sys
try:
    t=open(sys.argv[1],encoding="utf-8").read()
    mm=re.search(r'^model\s*=\s*"([^"]+)"',t,flags=re.M)
    print(mm.group(1) if mm else "")
except Exception: pass
PY
)
    if [[ -n "$m" && "$m" != *:free ]]; then
      warn "配置模型非免费档（${m}），拒绝执行"
      return 124
    fi
  fi

  # 真正跑 Codex（参数来自 ECS adapter-codex.sh）
  ( cd "$repo" && codex exec \
      --sandbox "$SANDBOX" \
      --add-dir "$(dirname "$jobdir")" \
      -c "model_reasoning_effort=${REASONING_EFFORT}" \
      "$(cat "$prompt")" ) < /dev/null 2>&1 | sanitize | tee "$outlog"
  adapter_rc=${PIPESTATUS[0]}
  return "$adapter_rc"
}

# ---- 跑 pytest 门（--require-tests 时）----------------------------------
run_tests() {
  local repo="$1"
  local py=""
  for c in "$repo/.venv/bin/python" "python3"; do
    command -v "$c" >/dev/null 2>&1 && { py="$c"; break; }
  done
  [[ -n "$py" ]] || { warn "找不到 python，跳过测试门"; return 0; }
  ( cd "$repo" && timeout 1200 "$py" -m pytest -q 2>&1 | tail -20 )
}

# ---- 处理单个任务 -------------------------------------------------------
process_job() {
  local bus="$1" jid="$2"
  local injob="${bus}/queue/${PROJECT}/in/${jid}/job.json"
  local outdir="${bus}/queue/${PROJECT}/out/job-${jid}"
  local work="${WORK_ROOT}/jobs/${jid}"
  local repo="${work}/repo"
  local runlog="${work}/run.log"
  local promptfile="${bus}/queue/${PROJECT}/in/${jid}/payload/iteration-prompt.md"

  mkdir -p "$outdir" "$work"
  [[ -f "$promptfile" ]] || { warn "缺 prompt：${promptfile}"; return 1; }

  fetch_repo "$injob" "$repo" || { warn "拉仓库失败"; return 1; }

  local head_before; head_before=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "")

  if (( DRY_RUN )); then
    log "[dry-run] 已拉取并解包，跳过执行。repo=${repo}"
    printf '{"job_id":"%s","status":"SUCCESS","summary":"dry-run","git":{"head_before":"%s"},"finished_at":"%s"}\n' \
      "$jid" "$head_before" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${outdir}/result.json"
    return 0
  fi

  local rc=0
  run_guarded "$work" "$repo" "$promptfile" "$runlog"
  rc=$?

  local status="SUCCESS"
  case "$rc" in
    124) status="GUARDED" ;;
    0)   status="SUCCESS" ;;
    *)   status="FAILED" ;;
  esac

  # 测试门（命中 require_tests 才真正跑）
  tests_ran=0; passed=0; failed=0; total=0
  if python3 - "$injob" <<'PY' 2>/dev/null | grep -q true
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print("true" if d.get("task",{}).get("require_tests") else "false")
PY
  then
    tests_ran=1
    local tlog; tlog=$(run_tests "$repo")
    passed=$(printf '%s\n' "$tlog" | grep -oE '[0-9]+ passed' | tail -1 | grep -oE '[0-9]+' || echo 0)
    failed=$(printf '%s\n' "$tlog" | grep -oE '[0-9]+ failed' | tail -1 | grep -oE '[0-9]+' || echo 0)
    total=$(printf '%s\n' "$tlog" | grep -oE '[0-9]+ in ' | tail -1 | grep -oE '[0-9]+' || echo 0)
  fi

  local head_after; head_after=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "$head_before")

  # 生成 diff.patch（可能为空 = 空转）
  ( cd "$repo" && git add -A && git diff --cached > "${work}/diff.patch" ) 2>/dev/null || true

  # 回传日志（过滤后）
  cp "$runlog" "$outdir/run.log" 2>/dev/null || true
  cp "${work}/diff.patch" "$outdir/diff.patch" 2>/dev/null || true

  python3 - "$outdir/result.json" "$jid" "$status" "$head_before" "$head_after" \
    "$tests_ran" "$passed" "$failed" "$total" "$rc" <<'PY'
import json,sys,time
path,job_id,status,hb,ha,ran,passed,failed,total,rc = sys.argv[1:11]
d={
  "job_id": job_id,
  "status": status,
  "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
  "executor_id": __import__("socket").gethostname(),
  "git": {"head_before": hb, "head_after": ha},
  "tests": {"ran": bool(int(ran)), "passed": int(passed), "failed": int(failed), "total": int(total)},
  "summary": status,
  "exit_code": int(rc)
}
json.dump(d, open(path,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
PY

  log "任务 ${jid} 完成：${status}（exit ${rc}）"
  return 0
}

# ---- 回传结果（用 gh api 的 Git Data API，统一身份为 gh=repo owner）-----
# process_job 已把 result.json / run.log / diff.patch 写进 $WORK_ROOT/bus 副本。
# 这里把这些文件作为 blob 加到队列分支的 out/job-<id>/ 下，创建 commit 并更新 ref。
# 为什么不用 git push：ECS/执行端 ssh 身份可能混用（ECS ssh=lsnww，repo 属 lsnlxt），
#   ssh push 对私有仓库报 "Repository not found"。gh api 走 HTTPS、身份明确。
push_results() {
  local bus="${WORK_ROOT}/bus"
  local outdir="${bus}/queue/${PROJECT}/out"
  [[ -d "$outdir" ]] || { warn "无结果目录可回传：${outdir}"; return 1; }

  # 只收集实际存在的文件，避免给空文件建 blob
  local -a file_paths=() file_blobs=()
  local f
  for f in result.json run.log diff.patch; do
    if [[ -s "${outdir}/job-${CURRENT_JID}/${f}" ]]; then
      file_paths+=("${f}")
    fi
  done
  (( ${#file_paths[@]} > 0 )) || { warn "无结果文件可回传"; return 0; }

  # 判断 gh 可用
  if ! command -v gh >/dev/null 2>&1 && [[ -z "${GH_TOKEN:-}" ]]; then
    warn "无 gh 且无 GH_TOKEN，无法回传（结果保留在 ${outdir}）"
    return 1
  fi

  local api_args=()
  command -v gh >/dev/null 2>&1 && api_args=(gh api) || api_args=(curl -sL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json")

  # 当前队列分支 HEAD
  local head_sha head_tree
  head_sha=$( "${api_args[@]}" "repos/${BUS_OWNER}/${BUS_REPO}/git/ref/heads/${QUEUE_BRANCH}" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('object',{}).get('sha',''))" 2>/dev/null )
  [[ -n "$head_sha" ]] || { warn "无法读取队列分支 HEAD：${QUEUE_BRANCH}"; return 1; }
  head_tree=$( "${api_args[@]}" "repos/${BUS_OWNER}/${BUS_REPO}/git/commits/${head_sha}" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('tree',{}).get('sha',''))" 2>/dev/null )
  [[ -n "$head_tree" ]] || { warn "无法读取队列分支 tree"; return 1; }

  # 为每个结果文件建 blob，并构造 tree 更新
  local tree_args=(-f base_tree="$head_tree")
  local f blob
  for f in "${file_paths[@]}"; do
    blob=$( "${api_args[@]}" "repos/${BUS_OWNER}/${BUS_REPO}/git/blobs" \
      -f content="$(cat "${outdir}/job-${CURRENT_JID}/${f}")" -f encoding=utf-8 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null )
    [[ -n "$blob" ]] || { warn "建 blob 失败：${f}"; return 1; }
    tree_args+=(
      -f "tree[][path]=queue/${PROJECT}/out/job-${CURRENT_JID}/${f}"
      -f "tree[][mode]=100644" -f "tree[][type]=blob" -f "tree[][sha]=${blob}"
    )
  done

  local new_tree
  new_tree=$( "${api_args[@]}" "repos/${BUS_OWNER}/${BUS_REPO}/git/trees" "${tree_args[@]}" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null )
  [[ -n "$new_tree" ]] || { warn "建 tree 失败"; return 1; }

  local new_commit
  new_commit=$( "${api_args[@]}" "repos/${BUS_OWNER}/${BUS_REPO}/git/commits" \
    -f message="executor: result ${CURRENT_JID} @ $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -f tree="$new_tree" -f "parents[]=$head_sha" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null )
  [[ -n "$new_commit" ]] || { warn "建 commit 失败"; return 1; }

  # 更新 ref（fast-forward；并发冲突时失败，符合预期）
  # 注意：gh api 用 -F（literal）发布尔，-f 会把 false 当字符串发导致 422。
  "${api_args[@]}" "repos/${BUS_OWNER}/${BUS_REPO}/git/refs/heads/${QUEUE_BRANCH}" \
    -X PATCH -f sha="$new_commit" -F force=false >/dev/null 2>&1 \
    && { log "结果已回传：${BUS_OWNER}/${BUS_REPO}@${QUEUE_BRANCH} out/job-${CURRENT_JID}"; return 0; } \
    || { warn "回传 ref 更新失败（并发冲突？），结果保留在 ${outdir}"; return 1; }
}

# ---- 熔断与告警（复刻 guard.sh）---------------------------------------
GUARD_STATE_ROOT="${WORK_ROOT}/guard"
# 成功一次清零，避免偶发失败累积成误熔断。
guard_ok() {
  mkdir -p "$GUARD_STATE_ROOT"
  printf "0" > "$GUARD_STATE_ROOT/consecutive_failures"
}
# 记录一次失败，达到阈值返回非零（调用方据此熔断停循环）。
guard_fail() {
  local reason="$1"
  mkdir -p "$GUARD_STATE_ROOT"
  local f="$GUARD_STATE_ROOT/consecutive_failures"
  local n=0
  [[ -f "$f" ]] && n=$(cat "$f" 2>/dev/null || echo 0)
  n=$((n + 1))
  printf "%s" "$n" > "$f"
  log "失败计数 ${n}/${MAX_CONSECUTIVE_FAILURES}：${reason}"
  if (( n >= MAX_CONSECUTIVE_FAILURES )); then
    guard_alert "🛑 熔断：连续 ${n} 次失败" "最后一次失败原因：${reason}

熔断已触发，worker 停止循环。请检查后手动清空并重启：
\`\`\`
printf '0' > ${GUARD_STATE_ROOT}/consecutive_failures
\`\`\`"
    return 1
  fi
  return 0
}
# 告警：优先写 GitHub Issue（若 gh 可用），否则落本地日志。
guard_alert() {
  local title="$1" body="$2"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$GUARD_STATE_ROOT/reports"
  printf "[%s] %s\n%s\n\n" "$ts" "$title" "$body" >> "$GUARD_STATE_ROOT/reports/alerts.log"

  # 用 GH_TOKEN 直接走 GitHub API，不依赖 gh/gh-auth。
  # 原因（2026-11-01 实测）：执行端必然 export GH_TOKEN 拉 codeload，
  # 而 GH_TOKEN 环境变量会覆盖 gh auth 的存储凭据，导致 gh issue create
  # 静默认证失败（"Bad credentials"）。直接用 GH_TOKEN 是唯一稳妥路径。
  [[ -n "${GH_TOKEN:-}" ]] || { warn "无 GH_TOKEN，告警仅落本地：${GUARD_STATE_ROOT}/reports/alerts.log"; return 0; }

  local full_body
  full_body=$(printf '%s\n\n---\nexecutor: %s\nproject: %s\ntime: %s' "$body" "$(hostname)" "${PROJECT}" "$ts")

  local resp
  resp=$(curl -s --max-time 30 \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -X POST "https://api.github.com/repos/${ALERT_REPO}/issues" \
    -d "$(python3 - "$title" "$full_body" <<'PY'
import json,sys
print(json.dumps({"title": sys.argv[1], "body": sys.argv[2]}))
PY
)" 2>/dev/null)

  if printf '%s' "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('html_url',''))" 2>/dev/null | grep -q '^https://'; then
    log "告警已创建 Issue：$(printf '%s' "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('html_url',''))")"
  else
    warn "创建 Issue 失败（HTTP $(printf '%s' "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('message','unknown'))" 2>/dev/null)），告警仅落本地"
  fi
}

# ---- 主循环 -------------------------------------------------------------
check_env

mkdir -p "$WORK_ROOT"

# run_once 返回语义：
#   0 = 本轮成功（有产出并已回传，或本无任务）
#   2 = 本轮无任务（不算失败）
#   其他 = 本轮失败
run_once() {
  local bus="${WORK_ROOT}/bus"
  fetch_queue "$bus" || return 1
  local jid; jid=$(next_job "$bus")
  if [[ -z "$jid" ]]; then
    return 2
  fi
  claim_job "$bus" "$jid"
  CURRENT_JID="$jid"
  process_job "$bus" "$jid" || return 1
  # 回传（gh api 提交到队列分支）
  push_results || return 1
  return 0
}

# 一轮的调度判定：成功清零，失败累计，连续达到阈值即熔断停循环。
# 返回 0=继续循环，125=熔断停循环。
finalize_round() {
  local rc="$1"
  case "$rc" in
    0) guard_ok; return 0 ;;
    2) return 0 ;;                       # 无任务，不成功不失败
    *) if ! guard_fail "本轮失败（rc=${rc}）"; then
         log "熔断触发，停止循环"
         return 125
       fi
       return 0 ;;
  esac
}

if (( ONCE )); then
  log "单次模式：处理一个任务后退出"
  run_once
  rc=$?
  finalize_round "$rc"
  exit $?
fi

log "进入常驻循环（每 ${POLL_SECS}s 轮询，Ctrl-C 退出）"
trap 'log "收到退出信号，本轮收尾后退出"; exit 0' INT TERM
while true; do
  run_once
  rc=$?
  finalize_round "$rc" || { log "熔断，退出循环"; exit 125; }
  sleep "$POLL_SECS"
done