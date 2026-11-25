#!/usr/bin/env bash
# orca environmentRecipes · railans recipe —— resume 生命周期
#
# 职责：workspace 激活时把箱拉回 running 并重发新鲜的 orca 结果 JSON
# （orca runner 会重新解析，据此重建 ssh target）。主路径 railans
# `start <box>`；数据面 host:port 跨 stop/start 不变，重发主要是刷新 expires
# 并满足 resume 必须重发结果的契约。
#
# 回退：箱已被 TTL 删除时 start 报 box not found → 回退 create（`new`）造
# 新箱——箱名确定性同名，但箱内数据已失（TTL 是硬删除，见 README）。
#
# stdin：orca runner 传入的 JSON payload（含 create 结果原样回传）；
# stdout：恰好一个结果 JSON 对象（与 create 同构）；诊断只走 stderr。
# 锁不动：箱仍归本 workspace 持有（回退重建同名箱，锁依旧成立）。

set -euo pipefail
umask 077

log() { printf 'railans resume: %s\n' "$*" >&2; }
die() { printf 'railans resume: %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# ---- 前置 -------------------------------------------------------------------

command -v python3 >/dev/null 2>&1 \
  || die "需要 python3（本 recipe 零依赖口径：bash + ssh + python3）"

if [[ -n "${ORCA_VM_MODE:-}" && "${ORCA_VM_MODE}" != "resume" ]]; then
  die "ORCA_VM_MODE=${ORCA_VM_MODE} 与本脚本（resume）不符——检查 orca.yaml 的命令映射"
fi

[[ -n "${RAILANS_CTL_HOST:-}" ]] || die "RAILANS_CTL_HOST 未设置（railans 控制面主机名）"
[[ -n "${RAILANS_CTL_PORT:-}" ]] || die "RAILANS_CTL_PORT 未设置（railans 控制面 SSH 端口）"
[[ -n "${RAILANS_PROVIDER_KEY:-}" ]] || die "RAILANS_PROVIDER_KEY 未设置（已 enroll 的 provider 私钥路径；只传路径）"

key_abs=$(PROVIDER_KEY="${RAILANS_PROVIDER_KEY}" python3 - <<'PY'
import os, sys
p = os.path.expanduser(os.environ["PROVIDER_KEY"])
if not p:
    sys.exit(2)
print(os.path.abspath(p))
PY
) || die "RAILANS_PROVIDER_KEY 归一化失败（应为已 enroll 的 provider 私钥路径）"
[[ -r "$key_abs" ]] || die "provider 私钥不可读：$key_abs"

CTL_SSH="${RAILANS_CTL_SSH:-ssh}"
ctl_base="${CTL_SSH%% *}"
command -v -- "$ctl_base" >/dev/null 2>&1 || die "找不到可执行 $ctl_base（RAILANS_CTL_SSH/ssh）"

ctl() {
  # shellcheck disable=SC2086
  $CTL_SSH -n -p "$RAILANS_CTL_PORT" -i "$key_abs" \
    -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "git@$RAILANS_CTL_HOST" "$@"
}

# 与 create.sh 同一套 projectRoot 计算（回退重建时保持锚点目录一致）。
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

# ---- payload → 箱名与既有 target --------------------------------------------

payload=$(cat)

box=$(PAYLOAD="$payload" python3 - <<'PY'
import json, os, sys
try:
    p = json.loads(os.environ["PAYLOAD"])
    box = p["recipeResult"]["userData"]["box"]
    if not isinstance(box, str) or not box:
        raise KeyError(box)
except Exception:
    sys.exit(3)
print(box)
PY
) || die "stdin payload 缺 recipeResult.userData.box——无法定位箱名（本箱须先经 create 获得）"

# 既有 connection.target（label/host/port/username/projectRoot/expires 旧值）。
# payload 回传的 identityFile 可能已移动，一律以当前 RAILANS_PROVIDER_KEY 为准。
meta=$(PAYLOAD="$payload" python3 - <<'PY'
import json, os, sys
try:
    p = json.loads(os.environ["PAYLOAD"])
    conn = (p.get("recipeResult") or {}).get("connection") or {}
    t = conn.get("target") or {}
    ud = (p.get("recipeResult") or {}).get("userData") or {}
    vals = [t.get("label", ""), t.get("host", ""), t.get("port", ""),
            t.get("username", ""), conn.get("projectRoot", ""), ud.get("expires", "")]
    if not any(v not in ("", None) for v in vals):
        sys.exit(0)
    print("\t".join("" if v is None else str(v) for v in vals))
except SystemExit:
    raise
except Exception:
    sys.exit(0)
PY
)
p_label=""; p_host=""; p_port=""; p_user=""; p_root=""; p_expires=""
if [[ -n "$meta" ]]; then
  IFS=$'\t' read -r p_label p_host p_port p_user p_root p_expires <<<"$meta"
fi

# ---- start（not found → 回退 create 重建） -----------------------------------

rc=0
out=$(ctl start "$box") || rc=$?
if ((rc != 0)); then
  if [[ "$out" == *"not found"* ]]; then
    log "箱 $box 已不存在（TTL 到期或已被删除）——回退 create 重建全新空箱，箱内原数据不保"
    # create.sh 会复查锁（同 workspace 重放放行）并重算 projectRoot；
    # 清空 ORCA_VM_MODE 以免模式守卫拒绝。
    rebuilt=$(ORCA_VM_MODE= "$SCRIPT_DIR/create.sh") || {
      die "回退 create 重建失败（箱内原数据已不可恢复；可在 orca 里删除本 workspace 后重建）"
    }
    printf '%s\n' "$rebuilt"
    exit 0
  fi
  die "start $box 失败（rc=$rc）${out:+：$out}"
fi
[[ -z "$out" ]] || log "$out"

# ---- start 成功：ls 刷新 expires / 取兜底端口 --------------------------------

fresh_expires=""
fallback_port=""
rc=0
lsout=$(ctl ls --json) || rc=$?
if ((rc == 0)) && [[ -n "$lsout" ]]; then
  lsinfo=$(LS_JSON="$lsout" BOX="$box" python3 - <<'PY'
import json, os
try:
    for row in json.loads(os.environ["LS_JSON"]):
        if row.get("name") == os.environ["BOX"]:
            print("%s\t%s" % (row.get("expires", ""), row.get("port", "")))
            break
except Exception:
    pass
PY
  )
  if [[ -n "$lsinfo" ]]; then
    IFS=$'\t' read -r fresh_expires fallback_port <<<"$lsinfo"
  fi
else
  log "ls 刷新失败（rc=$rc）——沿用 create 时的结果字段继续"
fi

# ---- 重发结果 JSON -----------------------------------------------------------

result=$(PAYLOAD="$payload" BOX="$box" FRESH_EXPIRES="$fresh_expires" \
  FALLBACK_PORT="$fallback_port" KEY_PATH="$key_abs" CTL_HOST="$RAILANS_CTL_HOST" \
  PROJECT_ROOT="$project_root" python3 - <<'PY'
import json, os, sys
p = json.loads(os.environ["PAYLOAD"])
box = os.environ["BOX"]
conn = (p.get("recipeResult") or {}).get("connection") or {}
t = conn.get("target") or {}

host = t.get("host") or os.environ["CTL_HOST"]
port = t.get("port")
try:
    port = int(port)
except (TypeError, ValueError):
    port = 0
if port <= 0:
    try:
        port = int(os.environ["FALLBACK_PORT"])
    except (TypeError, ValueError):
        port = 0
if not host or port <= 0:
    print("payload 的 connection.target 缺 host/port，且兜底端口缺失——无法重建 target", file=sys.stderr)
    sys.exit(1)

label = t.get("label") or ("railans " + box)
username = t.get("username") or "dev"
project_root = conn.get("projectRoot") or os.environ["PROJECT_ROOT"]
expires = os.environ["FRESH_EXPIRES"] or (
    ((p.get("recipeResult") or {}).get("userData") or {}).get("expires", ""))

out = {
    "schemaVersion": 1,
    "connection": {
        "type": "ssh",
        "target": {
            "label": label,
            "host": host,
            "port": port,
            "username": username,
            "identityFile": os.environ["KEY_PATH"],
        },
        "projectRoot": project_root,
    },
    "userData": {"provider": "railans", "box": box, "expires": expires},
}
print(json.dumps(out, ensure_ascii=False))
PY
) || die "无法重发 orca 结果（详见上一行）"

log "箱 $box 已拉起，结果已重发"
printf '%s\n' "$result"
