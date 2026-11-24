#!/usr/bin/env bash
# scripts/tests/test-subid.sh — setup-subuid 断言组（TC-W4-01…08、09 自动部分、10）
#
# 唯一事实源：node/railans-node.sh 的 subcmd_setup_subuid 实现 + docs/runbook.md；
# 真机冒烟与 deploy 全链手册项属生产复核，本脚本不代跑。
#
# 隔离承诺（硬红线）：全部写入 mktemp -d 临时目录，经 SUBUID_FILE/SUBGID_FILE
# 注入，绝不触碰真 /etc/subuid、/etc/subgid。
#
# require_root 处理（按环境自适应，此为注明）：
#   - 已是 root（EUID=0）→ 以 `bash node/railans-node.sh setup-subuid` 子进程原样跑；
#   - 非 root → 经 `unshare -r` 用户命名空间把当前 uid 映射成 0 再跑（脚本零改动，
#     require_root 真实生效，写入落点仍在注入的临时目录）。当前开发环境 uid 非 0，
#     走的是 unshare 这条；两者皆不可用时整套测试拒绝运行（fail loud，不静默降级）。
#
# podman 探测 PATH 沙盒：
#   - 沙盒根 $TMP/bin 恒放一个 dirname 垫片（脚本顶部 SCRIPT_DIR 解析需要）；
#   - TC-W4-04：PATH 只有 $TMP/bin（内无 podman）→ 无论宿主机是否装了 podman 都必 SKIP；
#   - 其余用例：PATH="$TMP/bin:$PATH"，$TMP/bin/podman 为假可执行，
#     恒压过系统 podman（本开发环境 /usr/bin/podman 真实存在，压不住会误判）。
#
# TC-W4-05 注入（注明）：非 root 用 chmod 555 只读目录；root 无视目录权限，
#   改用「父目录不存在」注入——两种环境下 touch 锁文件/写目标都必败。

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
NODE_SCRIPT="$HERE/../../node/railans-node.sh"

PASS=0
FAIL=0
TMP=""

t_ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
t_fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

assert_eq() {  # <说明> <期望> <实际>
  if [[ "$2" == "$3" ]]; then t_ok "$1"; else t_fail "$1（期望 [$2] 实际 [$3]）"; fi
}
assert_cont() {  # <说明> <子串> <整体>
  if [[ "$3" == *"$2"* ]]; then t_ok "$1"; else t_fail "$1（未找到 [$2]）"; fi
}
assert_no() {  # <说明> <子串> <整体>
  if [[ "$3" != *"$2"* ]]; then t_ok "$1"; else t_fail "$1（不应出现 [$2]）"; fi
}
assert_rc() {  # <说明> <期望rc> <实际rc>
  if [[ "$2" == "$3" ]]; then t_ok "$1"; else t_fail "$1（期望 rc=$2 实际 rc=$3）"; fi
}

cleanup() {
  if [[ -n "${TMP:-}" ]]; then
    chmod -R u+rwX "$TMP" 2>/dev/null
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

# ---- 每用例独立沙盒（用例文档通用前置：每用例独立 mktemp -d）----
case_setup() {
  cleanup
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-subid.XXXXXX")"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/dirname" <<'EOF'
#!/bin/sh
# PATH 沙盒垫片：脚本顶部 SCRIPT_DIR 解析用到 dirname；沙盒可能不含系统目录
case "${1:-}" in --) shift ;; esac
printf '%s\n' "${1%/*}"
EOF
  chmod 755 "$TMP/bin/dirname"
  export SUBID_USER=tester
  export SUBUID_FILE="$TMP/subuid" SUBGID_FILE="$TMP/subgid"
  unset SUBUID_START SUBUID_COUNT SUBGID_START SUBGID_COUNT
}

# 假 podman：仅需可被 command -v 探到，不执行任何逻辑
make_fake_podman() {
  printf '#!/bin/sh\n# PATH 沙盒假 podman（test-subid）\n' > "$TMP/bin/podman"
  chmod 755 "$TMP/bin/podman"
}

# 被测调用：子命令形态、沙盒 PATH；输出/退出码落文件（TC-W4-07 要并发各留各的）。
# 非 root 时经 unshare -r 映射成命名空间 root（UNSHARE_BIN 用绝对路径，
# nopodman 用例的 bare PATH 里找不到 unshare 本体）。
# 用法：run_subid <输出文件> <rc文件> [nopodman]
run_subid() {
  local outf="$1" rcf="$2" sbx="$TMP/bin:$PATH" out rc
  if [[ "${3:-}" == "nopodman" ]]; then
    sbx="$TMP/bin"
  fi
  if [[ $(id -u) -eq 0 ]]; then
    out="$(PATH="$sbx" /bin/bash "$NODE_SCRIPT" setup-subuid 2>&1)" && rc=0 || rc=$?
  else
    out="$(PATH="$sbx" "$UNSHARE_BIN" -r /bin/bash "$NODE_SCRIPT" setup-subuid 2>&1)" && rc=0 || rc=$?
  fi
  printf '%s' "$out" > "$outf"
  printf '%s' "$rc" > "$rcf"
}

# ---------------------------------------------------------------- TC-W4-01 空环境首配
case_w4_01() {
  case_setup
  make_fake_podman
  run_subid "$TMP/out" "$TMP/rc"
  assert_rc "TC-W4-01 退出 0" 0 "$(cat "$TMP/rc")"
  assert_eq "TC-W4-01 subuid mode 600" "600" "$(stat -c '%a' "$TMP/subuid")"
  assert_eq "TC-W4-01 subgid mode 600" "600" "$(stat -c '%a' "$TMP/subgid")"
  assert_eq "TC-W4-01 subuid 恰一行" "tester:100000:65536" "$(cat "$TMP/subuid")"
  assert_eq "TC-W4-01 subgid 恰一行" "tester:100000:65536" "$(cat "$TMP/subgid")"
  assert_cont "TC-W4-01 输出含 PASS" "PASS" "$(cat "$TMP/out")"
  assert_cont "TC-W4-01 输出含写入内容" "tester:100000:65536" "$(cat "$TMP/out")"
}

# ---------------------------------------------------------------- TC-W4-02 幂等重入（已有同用户条目）
case_w4_02() {
  case_setup
  make_fake_podman
  printf 'tester:12345:999\n' > "$TMP/subuid"
  printf 'tester:12345:999\n' > "$TMP/subgid"
  cp "$TMP/subuid" "$TMP/subuid.before"
  cp "$TMP/subgid" "$TMP/subgid.before"
  run_subid "$TMP/out" "$TMP/rc"
  assert_rc "TC-W4-02 退出 0" 0 "$(cat "$TMP/rc")"
  cmp -s "$TMP/subuid.before" "$TMP/subuid" \
    && t_ok "TC-W4-02 subuid 逐字节不变" \
    || t_fail "TC-W4-02 subuid 被改写（不破坏既有映射被破坏）"
  cmp -s "$TMP/subgid.before" "$TMP/subgid" \
    && t_ok "TC-W4-02 subgid 逐字节不变" \
    || t_fail "TC-W4-02 subgid 被改写（不破坏既有映射被破坏）"
  assert_cont "TC-W4-02 输出 PASS 并回显现有范围" "已存在条目（tester:12345:999）" "$(cat "$TMP/out")"
}

# ---------------------------------------------------------------- TC-W4-03 不破坏既有映射（多用户共存）
case_w4_03() {
  case_setup
  make_fake_podman
  printf 'alice:5000:1000\nbob:6000:1000\n' > "$TMP/subuid"
  printf 'alice:5000:1000\nbob:6000:1000\n' > "$TMP/subgid"
  run_subid "$TMP/out" "$TMP/rc"
  assert_rc "TC-W4-03 退出 0" 0 "$(cat "$TMP/rc")"
  assert_eq "TC-W4-03 subuid 三行俱全、前两行逐字保序" \
    "alice:5000:1000
bob:6000:1000
tester:100000:65536" "$(cat "$TMP/subuid")"
  assert_eq "TC-W4-03 subgid 三行俱全、前两行逐字保序" \
    "alice:5000:1000
bob:6000:1000
tester:100000:65536" "$(cat "$TMP/subgid")"
}

# ---------------------------------------------------------------- TC-W4-04 无 podman 跳过（node3 场景）
case_w4_04() {
  case_setup
  # 沙盒内无 podman；bare PATH → 宿主机装没装 podman 都必 SKIP
  run_subid "$TMP/out" "$TMP/rc" nopodman
  assert_rc "TC-W4-04 退出 0" 0 "$(cat "$TMP/rc")"
  assert_cont "TC-W4-04 输出含 SKIP 与说明" "SKIP" "$(cat "$TMP/out")"
  if [[ ! -e "$TMP/subuid" && ! -e "$TMP/subgid" ]]; then
    t_ok "TC-W4-04 两文件均不存在（零写入）"
  else
    t_fail "TC-W4-04 SKIP 路径落了文件（subuid/subgid 出现了）"
  fi
}

# ---------------------------------------------------------------- TC-W4-05 写入失败 → FAIL
case_w4_05() {
  case_setup
  make_fake_podman
  # 注入用「父目录不存在」：真 root / unshare 映射 root（有 CAP_DAC_OVERRIDE）都会
  # 无视 555 目录权限，chmod 555 在两种环境都不保证写失败；父目录缺失则必败。
  export SUBUID_FILE="$TMP/nodir/subuid" SUBGID_FILE="$TMP/nodir/subgid"
  run_subid "$TMP/out" "$TMP/rc"
  if [[ "$(cat "$TMP/rc")" -ne 0 ]]; then
    t_ok "TC-W4-05 退出非 0（实际 rc=$(cat "$TMP/rc")）"
  else
    t_fail "TC-W4-05 写入失败却退出 0"
  fi
  assert_cont "TC-W4-05 输出 FAIL" "FAIL" "$(cat "$TMP/out")"
  if [[ ! -e "${SUBUID_FILE}" && ! -e "${SUBGID_FILE}" ]]; then
    t_ok "TC-W4-05 不产生半截文件（两目标均未落盘；中间态由逐文件 FAIL 输出言明）"
  else
    t_fail "TC-W4-05 留下半截文件"
  fi
}

# ---------------------------------------------------------------- TC-W4-06 范围参数覆盖
case_w4_06() {
  case_setup
  make_fake_podman
  export SUBUID_START=200000 SUBUID_COUNT=8192
  run_subid "$TMP/out" "$TMP/rc"
  assert_rc "TC-W4-06 退出 0" 0 "$(cat "$TMP/rc")"
  assert_eq "TC-W4-06 subuid 用覆盖段" "tester:200000:8192" "$(cat "$TMP/subuid")"
  assert_eq "TC-W4-06 subgid 仍为缺省段" "tester:100000:65536" "$(cat "$TMP/subgid")"
}

# ---------------------------------------------------------------- TC-W4-07 并发双跑不写重（flock 临界区）
case_w4_07() {
  case_setup
  make_fake_podman
  run_subid "$TMP/p1.out" "$TMP/p1.rc" &
  local j1=$!
  run_subid "$TMP/p2.out" "$TMP/p2.rc" &
  local j2=$!
  wait "$j1"
  wait "$j2"
  assert_rc "TC-W4-07 进程1 退出 0" 0 "$(cat "$TMP/p1.rc")"
  assert_rc "TC-W4-07 进程2 退出 0" 0 "$(cat "$TMP/p2.rc")"
  assert_eq "TC-W4-07 subuid 恰一行 tester 条目" "1" \
    "$(grep -c "^tester:" "$TMP/subuid" || true)"
  assert_eq "TC-W4-07 subgid 恰一行 tester 条目" "1" \
    "$(grep -c "^tester:" "$TMP/subgid" || true)"
  local both wrote skipped
  both="$(cat "$TMP/p1.out"; cat "$TMP/p2.out")"
  wrote="$(grep -c "已写入" <<<"$both" || true)"
  skipped="$(grep -c "已存在条目" <<<"$both" || true)"
  assert_eq "TC-W4-07 恰一个进程写入（已写入 ×2 文件）" "2" "$wrote"
  assert_eq "TC-W4-07 另一进程走已有即跳过（已存在 ×2 文件）" "2" "$skipped"
}

# ---------------------------------------------------------------- TC-W4-08 subuid/subgid 独立判定
case_w4_08() {
  case_setup
  make_fake_podman
  printf 'tester:7:3\n' > "$TMP/subuid"   # subuid 已有 tester；subgid 不存在
  run_subid "$TMP/out" "$TMP/rc"
  assert_rc "TC-W4-08 退出 0" 0 "$(cat "$TMP/rc")"
  assert_eq "TC-W4-08 subuid 不动" "tester:7:3" "$(cat "$TMP/subuid")"
  assert_eq "TC-W4-08 subgid 追加" "tester:100000:65536" "$(cat "$TMP/subgid")"
  assert_cont "TC-W4-08 输出言明 subuid 已存在" "subuid：tester 已存在条目" "$(cat "$TMP/out")"
  # subgid 文件此前不存在 → 输出为「已创建 …；已写入 …」，含「已写入」字样
  assert_cont "TC-W4-08 输出言明 subgid 已写入" "已写入 tester:100000:65536" "$(cat "$TMP/out")"
}

# ---------------------------------------------------------------- TC-W4-09 deploy 挂点不阻断（自动部分）
# 手册部分（deploy 全链真跑）属主控复核，本脚本只做函数级模拟（用例文档降级条款）。
case_w4_09() {
  case_setup
  # 1) 位置断言：3/5 incus-admin 步之后、4/4 VM 网络步之前
  local l35 l3b l44 hook hook_out hook_rc
  l35="$(grep -n '^echo "== 3/5 ' "$NODE_SCRIPT" | grep 'incus-admin' | cut -d: -f1 | head -1)"
  l3b="$(grep -n '3b/4 rootless podman subuid/subgid' "$NODE_SCRIPT" | cut -d: -f1 | head -1)"
  l44="$(grep -n '^echo "== 4/4 VM 网络' "$NODE_SCRIPT" | cut -d: -f1 | head -1)"
  if [[ -n "$l35" && -n "$l3b" && -n "$l44" ]] && (( l35 < l3b && l3b < l44 )); then
    t_ok "TC-W4-09 挂点位于 3/5（行 $l35）与 4/4（行 $l44）之间（行 $l3b）"
  else
    t_fail "TC-W4-09 挂点位置不对（3/5=$l35 3b/4=$l3b 4/4=$l44）"
  fi
  # 2) 同一调用点表达式 + 注入失败：主链路必须继续、WARN 含补跑指引
  hook="$(grep 'subcmd_setup_subuid ||' "$NODE_SCRIPT" | head -1)"
  if [[ -z "$hook" ]]; then
    t_fail "TC-W4-09 找不到挂点调用（subcmd_setup_subuid || ...）"
    return 0
  fi
  hook_out="$(bash -c '
subcmd_setup_subuid(){ echo "FAIL 注入失败"; return 1; }
'"$hook"'
echo DEPLOY-CONTINUED
' 2>&1)" && hook_rc=0 || hook_rc=$?
  assert_rc "TC-W4-09 注入失败后整链退出 0" 0 "$hook_rc"
  assert_cont "TC-W4-09 输出 WARN" "WARN" "$hook_out"
  assert_cont "TC-W4-09 WARN 含补跑指引" \
    "sudo ./node/railans-node.sh setup-subuid" "$hook_out"
  assert_cont "TC-W4-09 主链路走到网络步骤之后" "DEPLOY-CONTINUED" "$hook_out"
}

# ---------------------------------------------------------------- TC-W4-10 语法与登记完整性（门禁）
case_w4_10() {
  case_setup
  local bn_err bn_rc help_out unk_out unk_rc
  bn_err="$(bash -n "$NODE_SCRIPT" 2>&1)" && bn_rc=0 || bn_rc=$?
  assert_rc "TC-W4-10 bash -n 过" 0 "$bn_rc"
  assert_eq "TC-W4-10 bash -n 零输出" "" "$bn_err"
  help_out="$(bash "$NODE_SCRIPT" help 2>&1)"
  assert_cont "TC-W4-10 help/usage() 清单含 setup-subuid" "setup-subuid" "$help_out"
  assert_cont "TC-W4-10 头部子命令注释表含 setup-subuid" "setup-subuid" \
    "$(grep '^#   setup-subuid' "$NODE_SCRIPT")"
  assert_cont "TC-W4-10 main case 分发含 setup-subuid" "| setup-subuid" \
    "$(grep -F '| setup-subuid)' "$NODE_SCRIPT")"
  unk_out="$(bash "$NODE_SCRIPT" definitely-not-a-cmd 2>&1)" && unk_rc=0 || unk_rc=$?
  assert_rc "TC-W4-10 未知子命令退出 2" 2 "$unk_rc"
  assert_cont "TC-W4-10 未知子命令报错路径不回归" "未知子命令" "$unk_out"
}

# ---------------------------------------------------------------- 门禁 + 运行
if [[ ! -r "$NODE_SCRIPT" ]]; then
  printf 'test-subid: 找不到被测脚本 %s\n' "$NODE_SCRIPT" >&2
  exit 2
fi
if ! bash -n "$NODE_SCRIPT"; then
  printf 'test-subid: bash -n 未过，后续用例无从谈起\n' >&2
  exit 1
fi
UNSHARE_BIN="$(command -v unshare || true)"
if [[ $(id -u) -ne 0 ]]; then
  if [[ -z "$UNSHARE_BIN" ]] || ! "$UNSHARE_BIN" -r true 2>/dev/null; then
    printf 'test-subid: 非 root 且 unshare -r 不可用，require_root 无法按用例文档二选一处理，拒绝运行\n' >&2
    exit 2
  fi
fi

printf '%s\n' "== TC-W4 组（scripts/tests/test-subid.sh，全沙盒不碰真 /etc）=="
for case_fn in case_w4_01 case_w4_02 case_w4_03 case_w4_04 case_w4_05 \
               case_w4_06 case_w4_07 case_w4_08 case_w4_09 case_w4_10; do
  "$case_fn"
done
cleanup

printf '\n'
if (( FAIL > 0 )); then
  printf '结论：FAIL（%d 断言过 / %d 断言败）\n' "$PASS" "$FAIL"
  exit 1
fi
printf '结论：PASS（%d 断言全过）\n' "$PASS"
exit 0
