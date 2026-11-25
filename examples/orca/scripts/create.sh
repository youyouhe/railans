#!/usr/bin/env bash
# orca environmentRecipes · railans recipe —— create 生命周期
#
# 职责：调 railans 控制面 `new --json` 开（或幂等复用）一只箱，把控制面回的
# boxView 转成 orca 的 ssh connection 结果契约打到 stdout。orca 会把该结果
# 注册成 runtime-owned 隐藏宿主并自动接 relay——本脚本不做也不该做宿主登记。
#
# 参数面（无 argv 通道）：
#   - orca runner 注入的 ORCA_* 环境变量（只读使用）；
#   - RAILANS_* 提供方配置（见 examples/orca/README.md 的环境变量表）；
#   - 生命周期 suspend/resume/destroy 从 stdin 收 JSON payload（orca runner 契约），
#     create 无 stdin payload；create 结果里的 userData 由 orca 原样回传，
#     其余三个命令靠它找回箱名。
#
# 输出契约：stdout 恰好一个 JSON 对象（schemaVersion 1 + connection + userData），
# 一切进度与诊断只走 stderr。失败退出码非 0。
#
# 安全边界：私钥只以路径参与（RAILANS_PROVIDER_KEY / 结果里的 identityFile），
# 密钥材料不进脚本、不进参数、不进输出；userData 只含非密值。
#
# 隔离测试缝：RAILANS_CTL_SSH 可整体覆写 ssh 可执行（连接参数仍照常拼在后面），
# 垫片测试 scripts/tests/test-orca-recipe.sh 即经由它注入假控制面，零网络。

set -euo pipefail
umask 077

log() { printf 'railans create: %s\n' "$*" >&2; }
die() { printf 'railans create: %s\n' "$*" >&2; exit 1; }

# ---- 0. 工具与模式前置 ----------------------------------------------------

command -v python3 >/dev/null 2>&1 \
  || die "需要 python3（本 recipe 零依赖口径：bash + ssh + python3）"

if [[ -n "${ORCA_VM_MODE:-}" && "${ORCA_VM_MODE}" != "create" ]]; then
  die "ORCA_VM_MODE=${ORCA_VM_MODE} 与本脚本（create）不符——检查 orca.yaml 的命令映射"
fi

# railans 箱走默认 orca-worktree 检出（schemaVersion 1）；其他检出模式显式拒绝。
if [[ -n "${ORCA_RECIPE_RESULT_SCHEMA_VERSION:-}" \
      && "${ORCA_RECIPE_RESULT_SCHEMA_VERSION}" != "1" ]]; then
  die "railans recipe 仅支持默认 orca-worktree 检出（schemaVersion 1），收到 ORCA_RECIPE_RESULT_SCHEMA_VERSION=${ORCA_RECIPE_RESULT_SCHEMA_VERSION}"
fi

# ---- 1. 提供方配置（env → 校验） ------------------------------------------

[[ -n "${RAILANS_CTL_HOST:-}" ]] || die "RAILANS_CTL_HOST 未设置（railans 控制面主机名）"
[[ -n "${RAILANS_CTL_PORT:-}" ]] || die "RAILANS_CTL_PORT 未设置（railans 控制面 SSH 端口）"
[[ -n "${RAILANS_PROVIDER_KEY:-}" ]] || die "RAILANS_PROVIDER_KEY 未设置（已 enroll 的 provider 私钥路径；只传路径）"

# ~/ 前缀展开成绝对路径再进结果 JSON（ssh -i 不做 ~ 展开）。
key_abs=$(PROVIDER_KEY="${RAILANS_PROVIDER_KEY}" python3 - <<'PY'
import os, sys
p = os.environ["PROVIDER_KEY"]
p = os.path.expanduser(p)
if not p:
    sys.exit(2)
print(os.path.abspath(p))
PY
) || die "RAILANS_PROVIDER_KEY 归一化失败（应为已 enroll 的 provider 私钥路径）"
[[ -r "$key_abs" ]] || die "provider 私钥不可读：$key_abs（先 enroll 并检查路径）"

CTL_SSH="${RAILANS_CTL_SSH:-ssh}"
ctl_base="${CTL_SSH%% *}"
command -v -- "$ctl_base" >/dev/null 2>&1 || die "找不到可执行 $ctl_base（RAILANS_CTL_SSH/ssh）"

# 控制面调用统一入口：ssh -p <port> -i <key> git@<host> <子命令...>
# IdentitiesOnly 钉死 provider 钥匙；BatchMode + accept-new 保证非交互不悬挂。
ctl() {
  # shellcheck disable=SC2086
  $CTL_SSH -n -p "$RAILANS_CTL_PORT" -i "$key_abs" \
    -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "git@$RAILANS_CTL_HOST" "$@"
}

# ---- 2. repo 本地锁（one key = one box 的防破防） --------------------------
# 一把 provider 钥匙在控制面只对应一只箱。若同 repo 开第二个 workspace，
# 控制面会把同一只箱幂等返回给两个 workspace——必须在本层挡住。
repo_root="${ORCA_REPO_PATH:-$PWD}"
state_file="${RAILANS_STATE_FILE:-$repo_root/.railans-orca-state.json}"
workspace_id="${ORCA_WORKSPACE_ID:-}"

lock_holder=""
if [[ -f "$state_file" ]]; then
  lock_holder=$(STATE_FILE="$state_file" python3 - <<'PY'
import json, os, sys
try:
    with open(os.environ["STATE_FILE"], encoding="utf-8") as f:
        data = json.load(f)
    holder = (data.get("activeBox") or {}).get("workspaceId") or ""
    print(holder)
except Exception:
    sys.exit(4)   # state 文件损坏：视作无锁，仅告警
PY
  ) || { lock_holder=""; log "state 文件无法解析（$state_file），视作无锁继续"; }

  if [[ -n "$lock_holder" && "$lock_holder" != "$workspace_id" ]]; then
    die "另一 workspace（$lock_holder）正持有 provider 箱（one key = one box：一把钥匙同时只服务一只箱）。先删除对应 workspace 或在 orca Settings→Ephemeral VMs 清理；若确认是残留锁，手工删除 state 文件的 activeBox 字段：$state_file"
  fi
fi

# ---- 3. new --json（可重试） -----------------------------------------------
# 控制面 new 自带阻塞到 ready；失败信封 retryable=true 才按 retry_after_seconds
# 退避，上限 3 次；配额类码 retryable=false，不重试、把文案透给用户。

attempt=0
t0=$SECONDS
boxview=""
while :; do
  attempt=$((attempt + 1))
  rc=0
  out=$(ctl new --json) || rc=$?
  if ((rc == 0)); then
    boxview=$out
    break
  fi

  err_line=$(OUT_JSON="$out" python3 - <<'PY'
import json, os, sys
try:
    e = json.loads(os.environ["OUT_JSON"])["error"]
except Exception:
    sys.exit(1)
code = e.get("code", "")
retryable = "1" if e.get("retryable") else "0"
after = int(e.get("retry_after_seconds") or 5)
print(code, retryable, after, e.get("message", ""))
PY
  ) || err_line=""

  if [[ -z "$err_line" ]]; then
    die "new 未回结构化错误信封（rc=$rc）——传输或服务异常，原始 stderr 已回显"
  fi

  read -r code retryable after msg <<<"$err_line"
  log "new 失败（rc=$rc）：${code} ${msg}"

  if [[ "$retryable" == "1" && "$attempt" -lt 3 ]]; then
    elapsed=$((SECONDS - t0))
    if ((elapsed + after > 900)); then
      die "重试预算（15 分钟墙钟）用尽，停止重试（code=${code}）"
    fi
    log "retryable=${code}，${after}s 后重试（第 $((attempt + 1))/3 次）"
    sleep "$after"
    continue
  fi
  die "create 失败（code=${code}，retryable=${retryable}，已试 ${attempt} 次）"
done

# ---- 4. projectRoot（箱上项目锚点目录，绝对路径） ---------------------------
# 基目录可由 RAILANS_PROJECT_ROOT_BASE 覆盖，默认箱内 dev 用户家目录下的 orca/；
# 有 ORCA_WORKSPACE_NAME 时按净化后的名字分段。

root_base="${RAILANS_PROJECT_ROOT_BASE:-/home/dev/orca}"
project_root="$root_base"
ws_seg=""
if [[ -n "${ORCA_WORKSPACE_NAME:-}" ]]; then
  ws_seg=$(printf '%s' "${ORCA_WORKSPACE_NAME}" | sed -e 's/[^A-Za-z0-9._-]/-/g' \
    -e 's/-\{2,\}/-/g' -e 's/^[-.]*//' -e 's/[-.]*$//')
fi
if [[ -n "$ws_seg" ]]; then
  project_root="${root_base%/}/$ws_seg"
fi

# ---- 5. boxView → orca 结果契约 --------------------------------------------

result=$(BOXVIEW="$boxview" KEY_PATH="$key_abs" PROJECT_ROOT="$project_root" python3 - <<'PY'
import json, os, sys
try:
    v = json.loads(os.environ["BOXVIEW"])
    box = v["box"]
    host = v["ssh_host"]
    port = int(v["ssh_port"])
    expires = v.get("expires", "")
except Exception as exc:
    print("boxView 缺字段或形态不符（%s）——控制面协议可能已漂移" % exc, file=sys.stderr)
    sys.exit(1)
if not box or not host or port <= 0:
    print("boxView 关键字段（box/ssh_host/ssh_port）为空", file=sys.stderr)
    sys.exit(1)
out = {
    "schemaVersion": 1,
    "connection": {
        "type": "ssh",
        "target": {
            "label": "railans " + box,
            "host": host,
            "port": port,
            "username": "dev",
            "identityFile": os.environ["KEY_PATH"],
        },
        "projectRoot": os.environ["PROJECT_ROOT"],
    },
    # userData 只放非密编排值；orca 的生命周期 payload 会原样回传，
    # suspend/resume/destroy 靠 userData.box 找回箱名。
    "userData": {"provider": "railans", "box": box, "expires": expires},
}
print(json.dumps(out, ensure_ascii=False))
PY
) || die "无法从 boxView 产出 orca 结果（详见上一行）"

# ---- 6. 记锁 + 回结果 -------------------------------------------------------

mkdir -p -- "$(dirname -- "$state_file")"
STATE_FILE="$state_file" BOXVIEW="$boxview" WS_ID="$workspace_id" python3 - <<'PY'
import datetime, json, os
box = json.loads(os.environ["BOXVIEW"])["box"]
path = os.environ["STATE_FILE"]
data = {}
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
data["activeBox"] = {
    "box": box,
    "workspaceId": os.environ["WS_ID"],
    "acquiredAt": datetime.datetime.now(datetime.timezone.utc)
    .isoformat(timespec="seconds"),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False)
PY

log "箱已就绪，结果已输出（箱名见 userData.box）"
printf '%s\n' "$result"
