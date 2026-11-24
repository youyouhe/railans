#!/usr/bin/env bash
# scripts/tests/test-build-gate.sh — 镜像构建/刷新静态断言组
#
# 唯一事实源：仓库内两脚本（build-base-image-local.sh / refresh-base-monthly.sh），
# 全部静态——不 incus、不网络、不 root。
# 真构建验证属生产变更窗口，本脚本不代跑。
#
# 断言组：
#   G1 注入段已删（cc-switch.db push 段、orca push+解压+wrapper 段）
#   G2 发布前自检闸三断言在位（零凭据两条 + sudo:false 一条）
#   G3 99-railans.cfg heredoc sudo:false、sudo 模型不动
#   G4 claude/cc-switch digest pin 在位、校验过再执行
#   G5 refresh 双段化（报告模式默认不 import 不重建）+ sha256 闸 + apply 仍调构建脚本
set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BUILD="$HERE/../build-base-image-local.sh"
REFRESH="$HERE/../refresh-base-monthly.sh"

PASS=0
FAIL=0

t_ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
t_fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

assert_cont() {  # <说明> <子串> <整体文本>
  if [[ "$3" == *"$2"* ]]; then t_ok "$1"; else t_fail "$1（未找到 [$2]）"; fi
}
assert_no() {  # <说明> <子串> <整体文本>
  if [[ "$3" != *"$2"* ]]; then t_ok "$1"; else t_fail "$1（不应出现 [$2]）"; fi
}
assert_rc() {  # <说明> <期望rc> <实际rc>
  if [[ "$2" == "$3" ]]; then t_ok "$1"; else t_fail "$1（期望 rc=$2 实际 rc=$3）"; fi
}
assert_count_ge() {  # <说明> <子串> <文本> <最小次数>
  local n
  n="$(grep -oF -- "$2" <<<"$3" | wc -l)"
  if (( n >= $4 )); then t_ok "$1（出现 ${n} 次 ≥ $4）"; else t_fail "$1（出现 ${n} 次 < $4）"; fi
}
ln_first() {  # <固定子串> <文件> → 首个命中行号（无命中输出空）
  grep -nF -- "$1" "$2" 2>/dev/null | head -1 | cut -d: -f1
}
assert_line_order() {  # <说明> <前锚子串> <后锚子串> <文件>（前锚行号 < 后锚行号）
  local a b
  a="$(ln_first "$2" "$4")"; b="$(ln_first "$3" "$4")"
  if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then
    t_ok "$1"
  else
    t_fail "$1（前锚[$2]=L${a:-无} 应早于 后锚[$3]=L${b:-无}）"
  fi
}

[[ -f "$BUILD" && -f "$REFRESH" ]] || { printf 'test-build-gate: 断言对象缺失（%s / %s）\n' "$BUILD" "$REFRESH" >&2; exit 2; }

BUILD_TXT="$(cat "$BUILD")"
REFRESH_TXT="$(cat "$REFRESH")"

printf '%s\n' "== 语法闸（bash -n）=="
bash -n "$BUILD";    assert_rc "bash -n build-base-image-local.sh" 0 $?
bash -n "$REFRESH";  assert_rc "bash -n refresh-base-monthly.sh"   0 $?

# ---- G1 注入段已删（零凭据）----
printf '%s\n' "== G1 注入段已删（H2）=="
assert_no  "cc-switch.db push 段已删"        'incus file push --uid 1000' "$BUILD_TXT"
assert_no  "cc-switch 注入回显已删"          'cc-switch.db 已注入' "$BUILD_TXT"
assert_no  "orca tar push 已删"              'incus file push "$ORCA_CLI_TAR"' "$BUILD_TXT"
assert_no  "guest 内解压+wrapper 段已删"     'chmod 755 /usr/local/bin/orca' "$BUILD_TXT"
assert_no  "guest 内 orca 自检行已删"        'orca --version' "$BUILD_TXT"
assert_no  "orca 注入回显已删"               'orca CLI 包已注入' "$BUILD_TXT"
assert_cont "注入段改写注释在位（不进镜像/ensureBox 按箱注入）" '凭据与 orca 包不进镜像，由控制面 ensureBox 按箱注入' "$BUILD_TXT"
assert_cont "push 目标目录保留（控制面注入落点）" 'install -d -o dev -g dev -m 700 /home/dev/.cc-switch' "$BUILD_TXT"
# orca tar 资产化：打包逻辑保留 + 产物落宿主资产目录
assert_cont "打包入口保留（ORCA_CLI_TAR）"        'ORCA_CLI_TAR=/tmp/orca-cli.tar.gz' "$BUILD_TXT"
assert_cont "资产目录取 RAILANS_ASSET_DIR 缺省 /var/lib/railans/assets" 'RAILANS_ASSET_DIR:-/var/lib/railans/assets' "$BUILD_TXT"
assert_cont "install -d -m 700 建目录"            'install -d -m 700 "${ASSET_DIR}"' "$BUILD_TXT"
assert_cont "install -m 640 落 orca-cli.tar.gz"   'install -m 640 "${ORCA_CLI_TAR}" "${ASSET_DIR}/orca-cli.tar.gz"' "$BUILD_TXT"
assert_cont ".sha256 随附"                        'orca-cli.tar.gz.sha256' "$BUILD_TXT"
assert_cont "目录不可建 loud fail"                'FATAL: orca 资产目录' "$BUILD_TXT"
assert_cont "目录不可写 loud fail"                '不可写。修复：sudo chown' "$BUILD_TXT"

# ---- G2 发布前自检闸三断言在位----
printf '%s\n' "== G2 自检闸三断言（零凭据两条 + sudo:false 一条）=="
assert_count_ge "闸：镜像内无 cc-switch.db"        'test ! -e /home/dev/.cc-switch/cc-switch.db' "$BUILD_TXT" 1
assert_count_ge "闸：镜像内无 /usr/local/bin/orca" 'test ! -e /usr/local/bin/orca' "$BUILD_TXT" 1
assert_count_ge "闸：99-railans.cfg 含 sudo: false" 'grep -q "sudo: false" /etc/cloud/cloud.cfg.d/99-railans.cfg' "$BUILD_TXT" 1

# ---- G3 sudo 模型（sudo:false）----
printf '%s\n' "== G3 L2 heredoc sudo:false =="
assert_cont "heredoc 改 sudo: false"                       'sudo: false' "$BUILD_TXT"
assert_no  "cloud-init 形态 NOPASSWD 行已除"               'sudo: ["ALL=(ALL) NOPASSWD:ALL"]' "$BUILD_TXT"
assert_cont "sudo 模型不动：90-railans-dev 仍在（唯一免密来源）" "echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-railans-dev" "$BUILD_TXT"
assert_cont "retire-cloudinit 兜底不动（语义边界）"        'railans-retire-cloudinit.service' "$BUILD_TXT"

# ---- G4 digest pin build 半----
printf '%s\n' "== G4 digest pin（claude / cc-switch）=="
assert_cont "claude installer digest 常量在位"   "CLAUDE_INSTALL_SH_SHA256='2c5506d110560bf618bbe88f678f2c2a0047c86a9c6585fc84976120b1de0b44'" "$BUILD_TXT"
assert_cont "cc-switch 固定 tag 常量在位"        "CC_SWITCH_TAG='v5.11.4'" "$BUILD_TXT"
assert_cont "cc-switch tar digest 常量在位"      "CC_SWITCH_TAR_SHA256='6c165ca6461f200aea1f739e4dad3be3ebacd21de864895679046ca99cd44024'" "$BUILD_TXT"
assert_cont "claude 落文件下载（不回切管道直跑）" 'curl -4 -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh' "$BUILD_TXT"
assert_cont "cc-switch 固定 tag URL"              'releases/download/${CC_SWITCH_TAG}/cc-switch-cli-linux-x64.tar.gz' "$BUILD_TXT"
assert_count_ge "sha256sum -c 过闸形态出现两次"   'sha256sum -c -' "$BUILD_TXT" 2
assert_cont "「升级走人工变更」注释在位"          '升级走人工变更' "$BUILD_TXT"
assert_no  "claude 管道直跑已除"                  'https://claude.ai/install.sh | bash' "$BUILD_TXT"
assert_no  "cc-switch latest 浮动源已除"          'releases/latest/download' "$BUILD_TXT"
# 校验过再执行（前：sha 闸行；后：执行行）
assert_line_order "claude：sha256 闸先于安装执行"  'sha256sum -c -' 'bash /tmp/claude-install.sh' "$BUILD"
assert_line_order "cc-switch：sha256 闸先于解包"   'sha256sum -c -' 'tar -xzf /tmp/cc-switch-cli-linux-x64.tar.gz -C /usr/local/bin cc-switch' "$BUILD"

# ---- G5 refresh 双段化 + sha256 闸----
printf '%s\n' "== G5 refresh 双段化 + sha256 闸 =="
assert_cont "用法双段说明（报告模式默认）"        '不 import、不重建' "$REFRESH_TXT"
assert_cont "apply 模式登记"                      'apply)  MODE=apply' "$REFRESH_TXT"
assert_cont "非法参数拒绝"                        '用法: refresh-base-monthly.sh [apply]' "$REFRESH_TXT"
assert_cont "simplestreams 索引取自带 sha256"     "['sha256']" "$REFRESH_TXT"
assert_cont "sha256 闸：sha256sum -c 对索引声明值" 'sha256sum -c "${STAGING}/sha256s-${VER}.txt"' "$REFRESH_TXT"
assert_cont "闸不过拒绝 import"                   '拒绝 import' "$REFRESH_TXT"
assert_cont "状态报告文件"                        'refresh-base-status.txt' "$REFRESH_TXT"
assert_cont "apply 段仍调 build 脚本"   './scripts/build-base-image-local.sh' "$REFRESH_TXT"
assert_cont "顺序约束注记在位"                   '顺序硬约束' "$REFRESH_TXT"
# 报告模式先于任何 import 退出（行序：report 收尾 → 首个 incus image import）
assert_line_order "报告模式路径不触 import（report 收尾行早于首个 import）" 'refresh done (report)' 'incus image import' "$REFRESH"

printf '\n'
if (( FAIL > 0 )); then
  printf '结论：FAIL（%d 断言过 / %d 断言败）\n' "$PASS" "$FAIL"
  exit 1
fi
printf '结论：PASS（%d 断言全过）\n' "$PASS"
exit 0
