#!/usr/bin/env bash
# orca environmentRecipes · railans recipe —— suspend 生命周期
#
# 职责：workspace sleep 时把箱停机保盘（railans `stop <box>`）。停机后数据面
# relay 断开、箱转入 stopped；磁盘保留，数据面 host:port 跨 stop/start 不变。
# orca 侧无自动 suspend——桌面断开 30 分钟后控制面 idle 回收会把箱停掉，
# 激活时由 resume 拉起，本脚本语义与之对齐。
#
# stdin：orca runner 传入的 JSON payload；箱名取自
# payload.recipeResult.userData.box（create 结果原样回传）。
#
# 失败退出码非 0（orca 记 suspend_failed，可重试）。stdout 无契约、保持干净。
# 锁不动：箱仍归本 workspace 持有。

set -euo pipefail
umask 077

log() { printf 'railans suspend: %s\n' "$*" >&2; }
die() { printf 'railans suspend: %s\n' "$*" >&2; exit 1; }

# ---- 前置 -------------------------------------------------------------------

command -v python3 >/dev/null 2>&1 \
  || die "需要 python3（本 recipe 零依赖口径：bash + ssh + python3）"

if [[ -n "${ORCA_VM_MODE:-}" && "${ORCA_VM_MODE}" != "suspend" ]]; then
  die "ORCA_VM_MODE=${ORCA_VM_MODE} 与本脚本（suspend）不符——检查 orca.yaml 的命令映射"
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

# ---- stop -------------------------------------------------------------------

rc=0
out=$(ctl stop "$box") || rc=$?
if ((rc != 0)); then
  die "stop $box 失败（rc=$rc）${out:+：$out}"
fi
[[ -z "$out" ]] || log "$out"
log "箱 $box 已停机保盘（stopped）"
