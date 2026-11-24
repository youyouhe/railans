#!/usr/bin/env bash
# 每月基础镜像刷新（拉最新 noble daily → 重建 dev-base）——双段化：报告模式 + apply 人工闸
#
# 用法（人工复核闸的落地）：
#   refresh-base-monthly.sh          # 报告模式（cron 默认）：发现新版本 + 下载 +
#                                    # simplestreams 索引 sha256 校验 + 写状态报告；
#                                    # 不 import、不重建
#   refresh-base-monthly.sh apply    # 人工显式：校验闸过后 import 源镜像 + 重建
#                                    # dev-base（月度人工执行）
#
# 校验闸：下载文件逐一与 images.json 索引自带的 sha256 对账（sha256sum -c），
# 不过即拒绝 import——TLS 传输 + 内容与索引绑定，恢复校验路径。
#
# 备选路线：`incus image copy images:ubuntu/24.04/cloud` 原生 remote 可免手工下载，
# 但 v6 下载抖动实测问题见 build-base-image-local.sh 头注。
#
# cron 建议：报告模式可挂 cron；apply 改人工月度执行——
#   0 4 1 * *  bash <kit-dir>/scripts/refresh-base-monthly.sh
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
OPS_ROOT="${RAILANS_OPS_ROOT:-$HOME/railans-ops}"
LOG="$OPS_ROOT/logs/refresh-base.log"
STATUS="$OPS_ROOT/logs/refresh-base-status.txt"
STAGING="$OPS_ROOT/refresh-staging"
mkdir -p "$(dirname "$LOG")" "$STAGING"
exec >>"$LOG" 2>&1
case "${1:-}" in
  "")     MODE=report ;;
  apply)  MODE=apply ;;
  *)      echo "用法: refresh-base-monthly.sh [apply]（无参=报告模式，不 import 不重建）" >&2; exit 64 ;;
esac
echo "==== refresh start $(date -Is) mode=${MODE} ===="
: >"$STATUS"
report() { echo "    $1"; echo "$1" >>"$STATUS"; }

cd "${KIT_DIR:-$HOME/railans-kit}"

# 1) 取上游最新 daily 的文件路径与索引声明 sha256（simplestreams 索引，IPv4）
BEST=$(curl -4 -s https://images.linuxcontainers.org/streams/v1/images.json | python3 -c "
import json,sys
d=json.load(sys.stdin)
best=None
for name,p in d['products'].items():
    if name=='ubuntu:noble:amd64:cloud':
        best=max(p['versions'].keys())
        it=p['versions'][best]['items']
        print(it['incus.tar.xz']['path'])
        print(it['incus.tar.xz']['sha256'])
        print(it['disk.qcow2']['path'])
        print(it['disk.qcow2']['sha256'])
        print(best)
") || true
[ -n "$BEST" ] || { echo "streams 索引获取失败"; exit 1; }
META=$(sed -n 1p <<<"$BEST");     META_SHA=$(sed -n 2p <<<"$BEST")
DISK=$(sed -n 3p <<<"$BEST");     DISK_SHA=$(sed -n 4p <<<"$BEST")
VER=$(sed -n 5p <<<"$BEST")
echo "上游版本: $VER"

META_F="${STAGING}/noble-meta-${VER}.tar.xz"
DISK_F="${STAGING}/noble-disk-${VER}.qcow2"

# 2) 下载（.part 落盘完成后改名，截断残留不会冒充完整文件；apply 复用报告模式暂存，已在则跳过）
download_staged() {
  if [[ ! -f "$META_F" ]]; then
    curl -4 -fsSL "https://images.linuxcontainers.org/$META" -o "${META_F}.part"
    mv "${META_F}.part" "$META_F"
  fi
  if [[ ! -f "$DISK_F" ]]; then
    curl -4 -fsSL "https://images.linuxcontainers.org/$DISK" -o "${DISK_F}.part"
    mv "${DISK_F}.part" "$DISK_F"
  fi
}

# 3) 校验闸：对索引声明值 sha256sum -c，不过即中止（下游不再 import）
verify_staged() {
  printf '%s  %s\n' "$META_SHA" "$META_F" >"${STAGING}/sha256s-${VER}.txt"
  printf '%s  %s\n' "$DISK_SHA" "$DISK_F" >>"${STAGING}/sha256s-${VER}.txt"
  echo "sha256 校验（对 simplestreams 索引声明值）："
  cat "${STAGING}/sha256s-${VER}.txt"
  sha256sum -c "${STAGING}/sha256s-${VER}.txt" \
    || { echo "sha256 闸不过：下载内容与索引不符，拒绝 import。修复：rm -rf ${STAGING} 后重跑（常见因：下载截断/中间盒）"; exit 1; }
  # 过闸后清掉旧版本暂存（只留当前 VER，apply 待用）
  find "$STAGING" -maxdepth 1 -type f -name 'noble-*' \
    ! -name "$(basename "$META_F")" ! -name "$(basename "$DISK_F")" -delete 2>/dev/null || true
}

upstream_current() {  # 本地 noble-cloud-vm 源镜像是否已在上游版本
  incus image list noble-cloud-vm --format csv 2>/dev/null | grep -qF "$VER"
}

if [[ "$MODE" == report ]]; then
  if upstream_current; then
    report "上游无更新（$VER 已是当前源镜像）——无需 apply"
  else
    download_staged
    verify_staged
    report "发现新版本 $VER：已下载并通过 sha256 闸（暂存 ${STAGING}）——人工执行 refresh-base-monthly.sh apply 完成导入与 dev-base 重建"
  fi
  echo "==== refresh done (report) $(date -Is) ===="
  exit 0
fi

# ---- apply（人工显式）：import + 重建 dev-base ----
if upstream_current; then
  echo "源镜像已是最新（$VER），跳过 import——继续重建 dev-base（零凭据/digest pin/sudo 模型生效需重建）"
else
  download_staged
  verify_staged   # 不过即拒绝 import
  OLD_FP=$(incus image list noble-cloud-vm --format csv | cut -d, -f2 | head -1)
  incus image import "$META_F" "$DISK_F" >/dev/null
  NEW_FP=$(incus image list noble-cloud-vm --format csv | cut -d, -f2 | head -1)
  incus image alias delete noble-cloud-vm 2>/dev/null || true
  incus image alias create noble-cloud-vm "$NEW_FP" >/dev/null
  [ -n "$OLD_FP" ] && [ "$OLD_FP" != "$NEW_FP" ] && incus image delete "$OLD_FP" 2>/dev/null || true
  echo "源镜像已更新: $NEW_FP"
fi

# 4) 重建 dev-base（文件推送 provision + 发布前自检闸，见构建脚本）。
#    顺序硬约束：控制面 assets 注入二进制先上线并验证，才允许本步产出零凭据镜像。
./scripts/build-base-image-local.sh || { echo "dev-base 重建失败"; exit 1; }
report "apply 完成：源镜像 $VER / dev-base 已重建"
echo "==== refresh done (apply) $(date -Is) ===="
