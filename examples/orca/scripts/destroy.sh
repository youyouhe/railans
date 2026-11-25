#!/usr/bin/env bash
# orca environmentRecipes · railans recipe —— destroy 生命周期
#
# 职责：workspace/repo 删除或 orca Settings→Ephemeral VMs 清理时删箱
# （railans `rm <box>`）。rm 是最终一致：控制面同步删一次、失败转 deleting
# 由控制面每分钟重试、TTL 终删兜底，客户端无条件收 removed——所以删完必须
# `ls --json` 复核，直到箱从列表消失（≤60s）；复核不过退出码非 0，
# orca 记 cleanup_failed（可重试，也可用 Settings 页的手工清理命令兜底）。
#
# 容忍语义：rm 报 box not found 视作已删除（orca 侧连接失败会自动补跑 destroy，
# 箱可能实际并不存在）。
#
# stdin：orca runner 传入的 JSON payload；箱名取自
# payload.recipeResult.userData.box。stdout 无契约、保持干净。
# 成功后释放 repo 本地锁（state 文件的 activeBox 字段）。

set -euo pipefail
umask 077

log() { printf 'railans destroy: %s\n' "$*" >&2; }
die() { printf 'railans destroy: %s\n' "$*" >&2; exit 1; }

# ---- 前置 -------------------------------------------------------------------

command -v python3 >/dev/null 2>&1 \
  || die "需要 python3（本 recipe 零依赖口径：bash + ssh + python3）"

if [[ -n "${ORCA_VM_MODE:-}" && "${ORCA_VM_MODE}" != "destroy" ]]; then
  die "ORCA_VM_MODE=${ORCA_VM_MODE} 与本脚本（destroy）不符——检查 orca.yaml 的命令映射"
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

repo_root="${ORCA_REPO_PATH:-$PWD}"
state_file="${RAILANS_STATE_FILE:-$repo_root/.railans-orca-state.json}"

# ---- payload → 箱名 ---------------------------------------------------------

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

# ---- rm（not found 容忍） ----------------------------------------------------

rc=0
out=$(ctl rm "$box") || rc=$?
if ((rc != 0)); then
  if [[ "$out" == *"not found"* ]]; then
    log "rm：箱 $box 已不存在（视作已删除，继续复核）"
  else
    die "rm $box 失败（rc=$rc）${out:+：$out}"
  fi
else
  [[ -z "$out" ]] || log "$out"
fi

# ---- ls 复核（rm 最终一致，≤60s 内等箱从列表消失） ----------------------------

checks=12      # 12 次 × 5s ≈ 60s 上限
i=0
while :; do
  i=$((i + 1))
  rc=0
  lsout=$(ctl ls --json) || rc=$?
  present=1
  if ((rc == 0)) && [[ -n "$lsout" ]]; then
    present=$(LS_JSON="$lsout" BOX="$box" python3 - <<'PY'
import json, os, sys
try:
    rows = json.loads(os.environ["LS_JSON"])
except Exception:
    sys.exit(1)   # 列表解析不了：按仍在处理，重试
for row in rows:
    if row.get("name") == os.environ["BOX"]:
        print(1)
        break
else:
    print(0)
PY
  ) || present=1
  fi
  if [[ "$present" != "1" ]]; then
    break
  fi
  if ((i >= checks)); then
    die "复核失败：${checks} 次检查后箱 $box 仍未从控制面列表消失（deleting 尾巴未收敛）。orca 可重试清理；控制面每分钟重试删除、TTL 终删兜底"
  fi
  log "箱 $box 仍在列表（deleting 中），5s 后复核（$i/$checks）"
  sleep 5
done
log "复核通过：箱 $box 已从控制面列表消失"

# ---- 释放 repo 本地锁 --------------------------------------------------------

STATE_FILE="$state_file" python3 - <<'PY'
import json, os
path = os.environ["STATE_FILE"]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    raise SystemExit(0)
if isinstance(data, dict) and "activeBox" in data:
    del data["activeBox"]
    if data:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
    else:
        os.remove(path)
PY
log "已释放本地锁（$state_file）"
