#!/usr/bin/env bash
# 每月初：备份控制面状态 + dev-base 镜像导出（保留最近 3 份轮转）
# cron 建议: 30 4 1 * *  bash <kit-dir>/scripts/backup-monthly.sh
# （排在 refresh-base 之后半小时，备份的是当月新镜像）
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
OPS_ROOT="${RAILANS_OPS_ROOT:-$HOME/railans-ops}"
BK="$OPS_ROOT/backups/railans"
LOG="$OPS_ROOT/logs/backup.log"
KIT_DIR="${KIT_DIR:-$HOME/railans-kit}"
mkdir -p "$BK/images" "$BK/state" "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "==== backup start $(date -Is) ===="

DATE=$(date +%Y%m%d)

# 1) 控制面状态（热拷贝：原子 rename 写法，脏读概率极低；拷完做 JSON 校验）
cp "${KIT_DIR}/.local-test/state.json" "$BK/state/state-$DATE.json"
python3 -c "import json;json.load(open('$BK/state/state-$DATE.json'))" \
  || { echo "state 备份校验失败"; exit 1; }

# 2) dev-base 镜像导出（incus 对 VM 统一导出自动追加 .tar.gz，勿自行再压）
FP=$(incus image list dev-base --format csv | cut -d, -f2 | head -1)
[ -n "$FP" ] || { echo "dev-base 不存在，跳过导出"; exit 0; }
incus image export dev-base "$BK/images/dev-base-$DATE" >/dev/null

# 3) 轮转：每类保留最近 3 份
ls -1t "$BK"/state/state-*.json 2>/dev/null | tail -n +4 | xargs -r rm -f
ls -1t "$BK"/images/dev-base-*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f

echo "==== backup done $(date -Is): $(du -sh "$BK" | cut -f1) ===="
