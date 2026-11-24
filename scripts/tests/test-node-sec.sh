#!/usr/bin/env bash
# scripts/tests/test-node-sec.sh — 节点安全断言组（TC-M1 权限、TC-M4 systemd 低权、
# TC-L2 sudo 模型、TC-H2 零凭据勾检）+ 组 E 追加（TC-E image 弃用 stub 行为；
# TC-L2-02/TC-H2 中涉及 subcmd_image 闸链与 guest 段的正向断言随路径弃用退役，
# 负向零残留守卫保留）。
#
# 唯一事实源：仓库内被测实现（node/railans-node.sh + node/deploy/railans.service）。
# 注：unit 的 `ProtectHome` 按 `read-only` 断言（box_assets 源驻 /home，=yes 注入必 loud fail）。
#
# 隔离承诺（硬红线）：
#   - 权限断言（TC-M1 组）经 railans-node.sh 的 HC_PERMS_KIT_DIR / HC_PERMS_ETC_CONFIG /
#     HC_PERMS_DATA_DIR 路径钩子注入 mktemp -d 临时目录，绝不触碰真 .local-test/、
#     /etc/railans、/var/lib/railans（真机 chmod 属生产变更窗口）；
#   - unit / 静态段断言只 grep 仓库文件；git diff（TC-M4-03 自动部分）只读；
#   - subcmd_control 真机干跑【手册级】不代跑，此处只做静态断言（TC-M4-02）。
#
# systemd-analyze verify（TC-M4-01）：环境有 systemd 时才跑；本开发环境无
# /usr/local/bin/railans 二进制，`is not executable` 属环境噪音不算失败，
# 只断言 unit 自身无解析错误（Unknown key / Failed to parse / Missing）。

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
NODE_SCRIPT="$HERE/../../node/railans-node.sh"
UNIT_FILE="$HERE/../../node/deploy/railans.service"
STORE_FILE="$HERE/../../control/store.go"

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

case_setup() {
  cleanup
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-node-sec.XXXXXX")"
}

# ---- hc_control_perms 注入式调用：临时目录经 HC_PERMS_* 钩子喂入，输出与计数落文件 ----
# 用法：run_perms <输出文件> <kit目录> <etc配置> <数据目录>
run_perms() {
  local outf="$1" kit="$2" etc="$3" data="$4"
  bash -c '
set -euo pipefail
source "$1" help >/dev/null
HC_PERMS_KIT_DIR="$2" HC_PERMS_ETC_CONFIG="$3" HC_PERMS_DATA_DIR="$4" hc_control_perms
echo "HC_RESULT FAILS=$HC_FAILS WARNS=$HC_WARNS"
' runner "$NODE_SCRIPT" "$kit" "$etc" "$data" >"$outf" 2>&1
}

perm_line() {  # <输出> <grep 模式> -> 匹配行数
  grep -cE "$2" <<<"$1" || true
}
# ================================================================= TC-M1-01 kit 布局
case_m1_01() {
  case_setup
  local lt="$TMP/.local-test"
  mkdir -m 775 "$lt"
  printf 'cfg' >"$lt/config.yaml";      chmod 664 "$lt/config.yaml"
  printf 'code' >"$lt/enroll_code.txt"; chmod 664 "$lt/enroll_code.txt"
  printf '{}' >"$lt/state.json";        chmod 600 "$lt/state.json"
  printf 'log' >"$lt/railans.log";      chmod 600 "$lt/railans.log"

  # (a) 超宽形态：config/enroll_code 0664 → FAIL×2；目录 0775 → WARN×1；达标项 PASS
  run_perms "$TMP/out.a" "$TMP" "$TMP/no-such-etc.yaml" "$TMP/no-such-data"
  local out; out="$(cat "$TMP/out.a")"
  assert_eq "TC-M1-01a config/enroll 0664 判 FAIL ×2" "2" \
    "$(perm_line "$out" 'FAIL kit 布局 (config\.yaml|enroll_code\.txt)')"
  assert_cont "TC-M1-01a FAIL 行输出现值与期望" "现 0664 期望 ≤0600" "$out"
  assert_eq "TC-M1-01a 目录 0775 判 WARN ×1" "1" \
    "$(perm_line "$out" 'WARN kit 布局 \.local-test/ 目录')"
  assert_cont "TC-M1-01a WARN 行输出 0775" "现 0775 期望 ≤0750" "$out"
  assert_eq "TC-M1-01a 达标的 state/log 各 PASS" "2" \
    "$(perm_line "$out" '^  PASS kit 布局')"
  assert_eq "TC-M1-01a 计数 FAILS=2 WARNS=1" "HC_RESULT FAILS=2 WARNS=1" \
    "$(grep 'HC_RESULT' <<<"$out")"
  assert_eq "TC-M1-01a 打包布局钩子不存在整段 SKIP 不误伤" "1" \
    "$(perm_line "$out" '^  SKIP 打包布局')"

  # (b) 全达标形态：0700 目录 + 0600 全文件 → 零 FAIL 零 WARN
  chmod 700 "$lt"; chmod 600 "$lt/config.yaml" "$lt/enroll_code.txt"
  run_perms "$TMP/out.b" "$TMP" "$TMP/no-such-etc.yaml" "$TMP/no-such-data"
  out="$(cat "$TMP/out.b")"
  assert_eq "TC-M1-01b 全达标 FAILS=0 WARNS=0" "HC_RESULT FAILS=0 WARNS=0" \
    "$(grep 'HC_RESULT' <<<"$out")"
  assert_eq "TC-M1-01b 五项全 PASS" "5" "$(perm_line "$out" 'PASS kit 布局')"

  # (c) 路径不存在：整布局 SKIP 且零 FAIL（不误伤纯节点）
  run_perms "$TMP/out.c" "$TMP/no-such-kit" "$TMP/no-such-etc.yaml" "$TMP/no-such-data"
  out="$(cat "$TMP/out.c")"
  assert_eq "TC-M1-01c 全缺 SKIP 零计数" "HC_RESULT FAILS=0 WARNS=0" \
    "$(grep 'HC_RESULT' <<<"$out")"
  assert_cont "TC-M1-01c kit 布局整段 SKIP" "不存在（本机不是控制面工作目录），跳过" "$out"
  assert_cont "TC-M1-01c 打包布局整段 SKIP" "均不存在（非打包安装），跳过" "$out"
  assert_eq "TC-M1-01c 零 FAIL 行" "0" "$(perm_line "$out" '^  FAIL')"
}

# ================================================================= TC-M1-02 打包布局
case_m1_02() {
  case_setup
  local etc="$TMP/etc/railans/config.yaml" data="$TMP/var/lib/railans"
  mkdir -p "$(dirname "$etc")" "$data"
  printf 'cfg' >"$etc"; chmod 640 "$etc"
  printf '{}' >"$data/state.json";           chmod 600 "$data/state.json"
  printf 'key' >"$data/ssh_host_ed25519_key"; chmod 600 "$data/ssh_host_ed25519_key"

  # (a) 达标形态：0640 config + 0700 目录 + 0600 state/hostkey → 全 PASS
  chmod 700 "$data"
  run_perms "$TMP/out.a" "$TMP/no-such-kit" "$etc" "$data"
  local out; out="$(cat "$TMP/out.a")"
  assert_eq "TC-M1-02a 打包达标 FAILS=0 WARNS=0" "HC_RESULT FAILS=0 WARNS=0" \
    "$(grep 'HC_RESULT' <<<"$out")"
  assert_cont "TC-M1-02a config 0640 PASS 输出" "PASS 打包布局 config.yaml（含 enroll code） 权限 0640（期望 ≤0640）" "$out"
  assert_cont "TC-M1-02a 目录 0700 PASS" "PASS 打包布局数据目录 权限 0700（期望 ≤0700）" "$out"
  assert_cont "TC-M1-02a host key PASS" "PASS 打包布局 host key 权限 0600" "$out"

  # (b) 超宽形态：config 0664 → FAIL；目录 0755 → WARN；hostkey 0644 → WARN
  chmod 664 "$etc"; chmod 755 "$data"; chmod 644 "$data/ssh_host_ed25519_key"
  run_perms "$TMP/out.b" "$TMP/no-such-kit" "$etc" "$data"
  out="$(cat "$TMP/out.b")"
  assert_eq "TC-M1-02b config 0664 判 FAIL" "1" \
    "$(perm_line "$out" 'FAIL 打包布局 config\.yaml')"
  assert_cont "TC-M1-02b FAIL 行输出现值与期望" "现 0664 期望 ≤0640" "$out"
  assert_eq "TC-M1-02b 目录 0755 判 WARN" "1" \
    "$(perm_line "$out" 'WARN 打包布局数据目录')"
  assert_eq "TC-M1-02b hostkey 0644 判 WARN（非 FAIL 名目）" "1" \
    "$(perm_line "$out" 'WARN 打包布局 host key')"
  assert_eq "TC-M1-02b 计数 FAILS=1 WARNS=2" "HC_RESULT FAILS=1 WARNS=2" \
    "$(grep 'HC_RESULT' <<<"$out")"
}

# ================================================================= TC-M1-03 主链路不回归
case_m1_03() {
  case_setup
  local help_out help_rc
  help_out="$(bash "$NODE_SCRIPT" help 2>&1)" && help_rc=0 || help_rc=$?
  assert_rc "TC-M1-03 help 正常退出 0" 0 "$help_rc"
  assert_cont "TC-M1-03 help 清单含 healthcheck" "healthcheck" "$help_out"

  # 挂链位置：subcmd_healthcheck 内 hc_control_perms 在 hc_kvm 之前（静态 grep）
  local l_perm l_kvm chain
  chain="$(sed -n '/^subcmd_healthcheck() {/,/^}/p' "$NODE_SCRIPT")"
  assert_cont "TC-M1-03 断言链挂 hc_control_perms" "hc_control_perms" "$chain"
  l_perm="$(grep -n '  hc_control_perms$' "$NODE_SCRIPT" | cut -d: -f1 | head -1)"
  l_kvm="$(grep -n '  hc_kvm$' "$NODE_SCRIPT" | cut -d: -f1 | head -1)"
  if [[ -n "$l_perm" && -n "$l_kvm" ]] && (( l_perm < l_kvm )); then
    t_ok "TC-M1-03 挂点在 hc_kvm 之前（perm=$l_perm kvm=$l_kvm）"
  else
    t_fail "TC-M1-03 挂点位置不对（perm=$l_perm kvm=$l_kvm）"
  fi

  # 既有 hc_* 函数名零改动（各恰定义一次，含新增两组）
  local fn want
  for fn in hc_pass hc_warn hc_fail hc_skip hc_incus hc_members hc_self_name \
            hc_kvm hc_vm_capability hc_cluster hc_bridge hc_nftables hc_routes \
            hc_units hc_disk hc_time hc_ssh_user hc_all; do
    want="$(grep -c "^${fn}() {" "$NODE_SCRIPT" || true)"
    assert_eq "TC-M1-03 ${fn} 定义恰一次" "1" "$want"
  done
  assert_eq "TC-M1-03 hc_control_perms 定义恰一次" "1" \
    "$(grep -c '^hc_control_perms() {' "$NODE_SCRIPT" || true)"
}

# ================================================================= TC-M4-01 unit 静态断言
case_m4_01() {
  case_setup
  local unit; unit="$(cat "$UNIT_FILE")"
  local d
  for d in \
    "User=railans" "Group=railans" "SupplementaryGroups=incus-admin" \
    "AmbientCapabilities=CAP_NET_BIND_SERVICE" "CapabilityBoundingSet=CAP_NET_BIND_SERVICE" \
    "NoNewPrivileges=yes" "ProtectSystem=strict" \
    "ReadWritePaths=/var/lib/railans /etc/caddy/conf.d" "ProtectHome=read-only" \
    "PrivateTmp=yes" "ProtectKernelTunables=yes" "ProtectKernelModules=yes" \
    "ProtectControlGroups=yes" "ProtectClock=yes" "RestrictSUIDSGID=yes" \
    "RestrictRealtime=yes" "LockPersonality=yes" "MemoryDenyWriteExecute=yes" \
    "SystemCallArchitectures=native" "Restart=always" "RestartSec=3" \
    "LimitNOFILE=65535" "After=network-online.target snap.incus.daemon.service" \
    "ExecStart=/usr/local/bin/railans -config /etc/railans/config.yaml" \
    "WantedBy=multi-user.target"; do
    assert_cont "TC-M4-01 unit 含 $d" "$d" "$unit"
  done
  assert_eq "TC-M4-01 User=root 零残留" "0" "$(grep -c '^User=root' "$UNIT_FILE" || true)"
  assert_no "TC-M4-01 ProtectHome=yes 不在（头注修正版 read-only）" "ProtectHome=yes" "$unit"
  assert_eq "TC-M4-01 User=railans 恰一次" "1" "$(grep -c '^User=railans$' "$UNIT_FILE" || true)"

  # systemd-analyze verify（环境有 systemd 才跑；二进制缺失属环境噪音）
  if command -v systemd-analyze >/dev/null 2>&1; then
    local vout
    vout="$(systemd-analyze verify "$UNIT_FILE" 2>&1 | grep 'railans\.service' || true)"
    assert_no "TC-M4-01 verify 无 Unknown key（指令名全合法）" "Unknown key" "$vout"
    assert_no "TC-M4-01 verify 无解析失败" "Failed to parse" "$vout"
    assert_no "TC-M4-01 verify 无缺失段" "Missing section" "$vout"
    assert_no "TC-M4-01 verify 无缺失等号" "Missing '='" "$vout"
  else
    t_ok "TC-M4-01 systemd-analyze 不在环境，verify 跳过（注明）"
  fi
}

# ================================================================= TC-M4-02 subcmd_control 适配段静态断言
case_m4_02() {
  case_setup
  local src; src="$(cat "$NODE_SCRIPT")"
  local d
  for d in \
    'groupadd -r railans' \
    'useradd -r -g railans -s /usr/sbin/nologin railans' \
    'usermod -aG incus-admin railans' \
    'install -d -o railans -g railans -m 700 /var/lib/railans' \
    'chown -R railans:railans /var/lib/railans' \
    'chown root:railans "${CONFIG}"' \
    'chmod 0640 "${CONFIG}"' \
    'chgrp railans /etc/caddy/conf.d' \
    'chmod g+w /etc/caddy/conf.d' \
    '49-railans-caddy-reload.rules' \
    'org.freedesktop.systemd1.manage-units' \
    'install -m 0644 "${SCRIPT_DIR}/deploy/railans.service" /etc/systemd/system/railans.service' \
    'systemctl enable railans.service'; do
    assert_cont "TC-M4-02 subcmd_control 含 $d" "$d" "$src"
  done

  # 六步顺序：4/5 段内 useradd → 目录 → config 属组 → conf.d → polkit → 装 unit
  local l45 l_add l_dir l_cfg l_caddy l_polkit l_inst l_en
  l45="$(grep -n '4/5 安装 systemd 服务' "$NODE_SCRIPT" | cut -d: -f1 | head -1)"
  l_add="$(grep -n 'useradd -r -g railans' "$NODE_SCRIPT" | cut -d: -f1 | head -1)"
  l_dir="$(grep -n 'install -d -o railans' "$NODE_SCRIPT" | cut -d: -f1 | head -1)"
  l_cfg="$(grep -n 'chown root:railans' "$NODE_SCRIPT" | cut -d: -f1 | head -1)"
  l_caddy="$(grep -n 'chgrp railans /etc/caddy/conf.d' "$NODE_SCRIPT" | cut -d: -f1 | head -1)"
  l_polkit="$(grep -n '49-railans-caddy-reload.rules' "$NODE_SCRIPT" | cut -d: -f1 | head -1)"
  l_inst="$(grep -n 'install -m 0644 "${SCRIPT_DIR}/deploy/railans.service"' "$NODE_SCRIPT" | cut -d: -f1 | head -1)"
  l_en="$(grep -n 'systemctl enable railans.service' "$NODE_SCRIPT" | cut -d: -f1 | head -1)"
  if [[ -n "$l45" && -n "$l_add" && -n "$l_dir" && -n "$l_cfg" && -n "$l_caddy" && \
        -n "$l_polkit" && -n "$l_inst" && -n "$l_en" ]] \
    && (( l45 < l_add && l_add < l_dir && l_dir < l_cfg && l_cfg < l_caddy \
          && l_caddy < l_polkit && l_polkit < l_inst && l_inst < l_en )); then
    t_ok "TC-M4-02 六步顺序正确（$l45 < $l_add < $l_dir < $l_cfg < $l_caddy < $l_polkit < $l_inst < $l_en）"
  else
    t_fail "TC-M4-02 六步顺序断言失败（$l45 $l_add $l_dir $l_cfg $l_caddy $l_polkit $l_inst $l_en）"
  fi

  # L4 锚点不漂移：enroll code 明文 echo 段原样在（不顺手修的回归锚）
  assert_cont "TC-M4-02 L4 锚点：已生成随机 enroll_code echo 原样" \
    'echo "    已生成随机 enroll_code:"' "$src"
  assert_cont "TC-M4-02 L4 锚点：enroll 用法提示原样" \
    '保存好：客户端执行 ssh new.box.lan enroll <code> <label>' "$src"
}

# ================================================================= TC-M4-03 ctl.sh 共存互斥（自动部分）
case_m4_03() {
  case_setup
  # 本波未改 store.go（flock 互斥机制原样，双跑防护构造保证）
  if git rev-parse --verify main >/dev/null 2>&1; then
    local diff_bytes
    diff_bytes="$(git diff main -- control/store.go | wc -c | tr -d ' ')"
    assert_eq "TC-M4-03 git diff main -- control/store.go 为空" "0" "$diff_bytes"
  else
    t_ok "TC-M4-03 非 git 环境或无 main ref，diff 断言跳过（注明）"
  fi
  assert_cont "TC-M4-03 store.go flock 机制在位（正向锚）" "flock" \
    "$(cat "$STORE_FILE" 2>/dev/null || echo MISSING)"
}

# ================================================================= TC-L2-02 node 版同构修正
# node 版 image 弃用 stub 后，subcmd_image 闸链/guest 段
# 正向断言（99-railans.cfg 写入点/sudo:false/R2 注释/自检闸 90-railans-dev/
# 90-cloud-init-users 双删除点/retire 锚）随路径退役，由 case_e_imgdep 接棒断言
# 「stub 弃用行为」+ 保留参照完整性；本组仅留负向守卫，防字面借「复活路径」回流。
case_l2_02() {
  case_setup
  # 死 sed 已删（写入前对 99-railans.cfg 的 sed 不复存在）
  assert_eq "TC-L2-02 对 99-railans.cfg 的前置 sed 零残留" "0" \
    "$(grep -c 'sed -i .*99-railans\.cfg' "$NODE_SCRIPT" || true)"
  assert_eq "TC-L2-02 NOPASSWD heredoc 字面零残留" "0" \
    "$(grep -c 'sudo: \["ALL=(ALL) NOPASSWD:ALL"\]' "$NODE_SCRIPT" || true)"
}

# ================================================================= TC-H2 node 版勾检（test-node-sec 断言 node 版）
# node 版 image 弃用 stub 后，同语义注释/.cc-switch 目录/
# 闸链双断言（零凭据闸/orca 闸）随路径退役 → case_e_imgdep 接棒；本组仅留注入段
# 负向守卫（防凭据注入借「复活路径」回流，对全文件生效）。
case_h2_node() {
  case_setup
  # 注入段已删：cc-switch.db push / orca 打包 push 解压 wrapper 全无
  assert_eq "TC-H2-N 5b/7 注入步零残留" "0" "$(grep -c '5b/7' "$NODE_SCRIPT" || true)"
  assert_eq "TC-H2-N cc-switch.db push 零残留" "0" \
    "$(grep -cE 'file push.*cc-switch' "$NODE_SCRIPT" || true)"
  assert_eq "TC-H2-N orca 打包变量零残留" "0" "$(grep -c 'ORCA_CLI_TAR' "$NODE_SCRIPT" || true)"
  assert_eq "TC-H2-N orca tar 产物名零残留" "0" "$(grep -c 'orca-cli\.tar\.gz' "$NODE_SCRIPT" || true)"
  assert_eq "TC-H2-N orca wrapper 装载零残留" "0" "$(grep -c 'usr/local/bin/orca && chmod' "$NODE_SCRIPT" || true)"
  assert_eq "TC-H2-N 工具自检 orca 行零残留" "0" \
    "$(grep -c '/usr/local/bin/orca --version' "$NODE_SCRIPT" || true)"
  assert_eq "TC-H2-N 已注入回显零残留" "0" "$(grep -c '已注入' "$NODE_SCRIPT" || true)"
}

# ================================================================= TC-E image 弃用 stub
# node 版构建路径弃用：调用即非零退出 + 输出含「已弃用」+ 指路 local 版；
# guest 段保留不删（复活留参照），以参照完整性锚守护（heredoc 与原自检闸行仍在）。
case_e_imgdep() {
  case_setup
  local out rc
  # (a) 真调用（非 root 即可：stub 先打印后返回，不触 require_root / incus / BASE_IP 前置）
  out="$(bash "$NODE_SCRIPT" image 2>&1)" && rc=0 || rc=$?
  if (( rc != 0 )); then
    t_ok "TC-E image 调用即非零退出（rc=$rc）"
  else
    t_fail "TC-E image 调用即非零退出（期望非零实际 rc=0）"
  fi
  assert_cont "TC-E image 弃用输出含「已弃用」" "已弃用" "$out"
  assert_cont "TC-E image 弃用输出言明缺 90-railans-dev 写入" "90-railans-dev" "$out"
  assert_cont "TC-E image 弃用输出指路 local 版构建脚本" "scripts/build-base-image-local.sh" "$out"
  assert_cont "TC-E image 弃用输出含分发命令" "incus image copy dev-base local: --target <node>" "$out"

  # (b) usage 文案同步：image 行标注弃用并指路
  local usage_out
  usage_out="$(bash "$NODE_SCRIPT" help 2>&1)"
  assert_cont "TC-E usage image 行标注弃用→指路 local 版" \
    "建模板 VM 并 publish 成基础镜像(已弃用→用 build-base-image-local.sh)" "$usage_out"

  # (c) stub 结构行序：弃用说明 < return 1 < 保留参照注释 < require_root（保留体不执行）
  local fn l_msg l_ret l_note l_root
  fn="$(sed -n '/^subcmd_image() {/,/^}/p' "$NODE_SCRIPT")"
  l_msg="$(grep -n '已弃用' <<<"$fn" | head -1 | cut -d: -f1)"
  l_ret="$(grep -n '^  return 1$' <<<"$fn" | head -1 | cut -d: -f1)"
  l_note="$(grep -n '以下保留仅供参照，不构成可用路径' <<<"$fn" | head -1 | cut -d: -f1)"
  l_root="$(grep -n 'require_root' <<<"$fn" | head -1 | cut -d: -f1)"
  if [[ -n "$l_msg" && -n "$l_ret" && -n "$l_note" && -n "$l_root" ]] \
      && (( l_msg < l_ret && l_ret < l_note && l_note < l_root )); then
    t_ok "TC-E stub 行序正确（说明 $l_msg < return 1 $l_ret < 参照注释 $l_note < require_root $l_root）"
  else
    t_fail "TC-E stub 行序不对（$l_msg $l_ret $l_note $l_root）"
  fi

  # (d) 保留参照完整性：guest heredoc 与原自检闸行仍在（弃用保留不删）
  local src; src="$(cat "$NODE_SCRIPT")"
  assert_cont "TC-E guest 段保留：构建 heredoc 原样（参照文本）" \
    "cat >/tmp/railans-guest.sh <<'GUEST'" "$src"
  assert_cont "TC-E guest 段保留：原自检闸行原样（参照文本，非可用路径）" \
    'test -f /etc/sudoers.d/90-railans-dev' "$src"
}

# ---------------------------------------------------------------- 门禁 + 运行
if [[ ! -r "$NODE_SCRIPT" || ! -r "$UNIT_FILE" ]]; then
  printf 'test-node-sec: 找不到被测文件（%s / %s）\n' "$NODE_SCRIPT" "$UNIT_FILE" >&2
  exit 2
fi
if ! bash -n "$NODE_SCRIPT"; then
  printf 'test-node-sec: bash -n 未过，后续用例无从谈起\n' >&2
  exit 1
fi

printf '%s\n' "== 组 D+E 断言组（scripts/tests/test-node-sec.sh，全沙盒不碰真路径）=="
for case_fn in case_m1_01 case_m1_02 case_m1_03 case_m4_01 case_m4_02 case_m4_03 \
               case_l2_02 case_h2_node case_e_imgdep; do
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
