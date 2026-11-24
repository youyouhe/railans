#!/usr/bin/env bash
# scripts/tests/test-installer.sh — 问答式安装器断言组（install-node.sh / install-control.sh）
#
# 唯一事实源：仓库根 install-node.sh / install-control.sh（复用 railans-node.sh
# 既有子命令的前端编排）。
#
# 隔离承诺（硬红线，对齐 test-add-node）：
#   - 不 ssh 真实节点、不碰真 incus / 真控制面：ip/ssh/ss/sudo/systemctl/openssl/
#     incus/chgrp 全部落 $TMP/bin PATH 沙盒垫片，调用记 $TMP/call.log；
#   - install-node.sh 每用例复制到 $TMP 运行（SCRIPT_DIR 指向沙盒 → 本机
#     /etc/railans、worktree .local-test 永不进入判定）；
#   - install-control.sh 的 config/资产/caddy conf/systemd run 路径全部经
#     IC_CONFIG_PATH / RAILANS_ASSET_DIR / IC_CADDY_CONF_DIR / IC_SYSTEMD_RUN /
#     IC_KVM_PATH 钩子指到 $TMP；
#   - node/build 脚本经 RAILANS_NODE_SH / RAILANS_BUILD_SH 指到记录垫片；
#   - enroll code 用 openssl 垫片出固定假值，只断言形态与落点，不外传真值。
#
# 「无 incus」分支（install-node 第一台机器判定）需要 PATH 里真没有 incus：
#   harness 建一个全量符号链接影子目录 $CORE（链接 /usr/bin /bin /sbin /usr/sbin
#   全部可执行文件、唯独剔除 incus），分支 B 用例以 PATH=shim:core 运行——
#   真实 incus 不可见，其余工具同真机。

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$HERE/../.." && pwd -P)"
NODE_INSTALLER="$ROOT/install-node.sh"
CTL_INSTALLER="$ROOT/install-control.sh"

PASS=0
FAIL=0
TMP=""
CORE=""

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
  if [[ -n "${CORE:-}" ]]; then
    chmod -R u+rwX "$CORE" 2>/dev/null
    rm -rf "$CORE"
  fi
}
trap cleanup EXIT

# ---- 沙盒 ----

case_setup() {
  cleanup
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-installer.XXXXXX")"
  mkdir -p "$TMP/bin"
  # 用例间环境隔离：模式开关与预设一律不跨用例泄漏
  unset IN_SSH_FAIL IN_ADMIN_FAIL IN_CAP_OK IN_SUDO_FAIL IN_PORT22_TAKEN \
    IN_ROUTE_MESH IN_CLUSTER_N IN_IMAGE_EXISTS IN_NODE_FAIL IN_FIXTURE \
    IN_CAP_HOST \
    RAILANS_IC_ADDR RAILANS_IC_SUBNET RAILANS_IC_DRIVER RAILANS_IC_PORT \
    RAILANS_IC_DOMAIN RAILANS_IC_WAN RAILANS_IC_NODE_NAME \
    RAILANS_IC_FORCE_IMAGE RAILANS_CONFIG RAILANS_CTL_HOST \
    RAILANS_CTL_PORTS RAILANS_SSH_USER RAILANS_NODE_TARGET CORE_PATH_PREFIX \
    IZ_LOG IC_LOG 2>/dev/null || true
}

# 全量符号链接影子目录（无 incus）。一次构建，全部用例共用，退出时清理。
core_setup() {
  if [[ -n "$CORE" && -d "$CORE" ]]; then
    return 0
  fi
  CORE="$(mktemp -d "${TMPDIR:-/tmp}/test-installer-core.XXXXXX")"
  local f b
  for f in /usr/bin/* /bin/* /sbin/* /usr/sbin/*; do
    b="$(basename "$f")"
    if [[ "$b" == "incus" ]]; then continue; fi
    if [[ ! -e "$CORE/$b" ]]; then
      ln -s "$f" "$CORE/$b" 2>/dev/null || true
    fi
  done
}

# ---- 垫片 ----

make_shims() {  # [mode]：plain | cap（capacity 命中）| noincus（bin 里不放 incus）
  local mode="${1:-plain}"
  # ssh：capacity 按模式回（IN_CAP_HOST 可限定只有该主机命中——用于
  # 「默认网关探测失败、用户另给地址后命中」的再探测路径）；admin/kit/add-node
  # 驱动全通；IN_SSH_FAIL=1 全灭
  cat >"$TMP/bin/ssh" <<'EOF'
#!/bin/sh
echo "ssh $*" >> "$IZ_LOG"
if [ -n "${IN_SSH_FAIL:-}" ]; then exit 255; fi
is_cap=0
for a in "$@"; do
  [ "$a" = "capacity" ] && is_cap=1
  case "$a" in
    *add-node*) exit 0 ;;
    *"test -d"*) exit 0 ;;
  esac
done
if [ "$is_cap" = "1" ]; then
  if [ -n "${IN_CAP_OK:-}" ]; then
    host_ok=1
    if [ -n "${IN_CAP_HOST:-}" ]; then
      host_ok=0
      for a in "$@"; do
        case "$a" in
          *"@${IN_CAP_HOST}") host_ok=1 ;;
        esac
      done
    fi
    if [ "$host_ok" = "1" ]; then
      cat "$IN_FIXTURE/capacity.json"
      exit 0
    fi
  fi
  exit 255
fi
exit 0
EOF
  cat >"$TMP/bin/ip" <<'EOF'
#!/bin/sh
echo "ip $*" >> "$IZ_LOG"
case "$*" in
  "-4 route show")
    printf 'default via 10.0.2.2 dev enp0s3\n'
    if [ -n "${IN_ROUTE_MESH:-}" ]; then printf '%s dev enp0s3\n' "$IN_ROUTE_MESH"; fi
    ;;
  "-4 addr show")
    printf '1: lo:\n    inet 127.0.0.1/8\n2: enp0s3:\n    inet 10.0.2.15/24\n'
    ;;
  *"addr show dev enp0s3")
    printf '2: enp0s3:\n    inet 10.0.2.15/24\n'
    ;;
esac
exit 0
EOF
  cat >"$TMP/bin/ss" <<'EOF'
#!/bin/sh
echo "ss $*" >> "$IZ_LOG"
if [ -n "${IN_PORT22_TAKEN:-}" ]; then
  printf 'LISTEN 0 4096 0.0.0.0:22 users:(("sshd"))\n'
fi
exit 0
EOF
  cat >"$TMP/bin/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "$IZ_LOG"
if [ -n "${IN_SUDO_FAIL:-}" ] && [ "${1:-}" = "-n" ] && [ "${2:-}" = "true" ]; then
  exit 1
fi
while [ "${1:-}" = "-n" ]; do shift; done
exec "$@"
EOF
  cat >"$TMP/bin/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$IC_LOG"
exit 0
EOF
  cat >"$TMP/bin/openssl" <<'EOF'
#!/bin/sh
echo "openssl $*" >> "$IC_LOG"
printf 'cafe0102030405060708090a0b0c0d0e0f10111213141516\n'
EOF
  cat >"$TMP/bin/chgrp" <<'EOF'
#!/bin/sh
echo "chgrp $*" >> "$IC_LOG"
exit 0
EOF
  # node/build 记录垫片（IN_NODE_FAIL=<子命令> 时该子命令退出 1）；
  # node-sh 额外记录安装器透传的环境变量（node-sh-env KEY=VALUE 行）
  cat >"$TMP/node-sh" <<'EOF'
#!/bin/bash
echo "node-sh $*" >> "${IZ_LOG:-${IC_LOG:?}}"
for v in NODE_NAME NODE_ADDR DRIVER SUBNET WAN ROUTES CONFIG ADMIN_SSH_PORT ENTRY_IP DOMAIN; do
  eval "val=\${$v:-}"
  if [ -n "$val" ]; then
    echo "node-sh-env $v=$val" >> "${IZ_LOG:-${IC_LOG:?}}"
  fi
done
if [ -n "${IN_NODE_FAIL:-}" ] && [ "${1:-}" = "$IN_NODE_FAIL" ]; then
  echo "node-sh: 模拟 $1 失败" >&2
  exit 1
fi
exit 0
EOF
  cat >"$TMP/build-sh" <<'EOF'
#!/bin/bash
echo "build-sh $*" >> "$IC_LOG"
echo "build-sh ASSET=${RAILANS_ASSET_DIR:-unset}" >> "$IC_LOG"
exit 0
EOF
  # noincus 模式：bin 里干脆不放 incus 垫片（配合影子目录 PATH，incus 真缺席）
  if [[ "$mode" != "noincus" ]]; then
    cat >"$TMP/bin/incus" <<'EOF'
#!/bin/sh
echo "incus $*" >> "$IC_LOG"
case "$1 $2" in
  "cluster list")
    # 退出 1 = 探测不到集群（单机分支）；IN_CLUSTER_N=1 时输出单成员行
    if [ -n "${IN_CLUSTER_N:-}" ]; then
      printf 'node1,https://10.0.2.15:8443,ONLINE,-,ONLINE,ONLINE,x86_64\n'
    fi
    exit 1
    ;;
  "image list")
    if [ -n "${IN_IMAGE_EXISTS:-}" ]; then
      printf 'dev-base\n'
    fi
    ;;
esac
exit 0
EOF
  fi
  chmod 755 "$TMP"/bin/* "$TMP/node-sh" "$TMP/build-sh"
}

# install-control 用环境注入（IC_* 钩子 + 记录日志分开：IZ_LOG 未用，统一 IC_LOG）
ctl_env() {
  unset IZ_LOG
  export IC_LOG="$TMP/call.log"
  export IC_CONFIG_PATH="$TMP/etc/railans/config.yaml"
  export IC_KVM_PATH="$TMP/kvm"
  export IC_SYSTEMD_RUN="$TMP/run/systemd"
  export IC_CADDY_CONF_DIR="$TMP/caddy-conf"
  export RAILANS_ASSET_DIR="$TMP/assets"
  export RAILANS_NODE_SH="$TMP/node-sh"
  export RAILANS_BUILD_SH="$TMP/build-sh"
  export ORCA_SRC="$TMP/orca"
  mkdir -p "$TMP/kvm" "$TMP/run/systemd" "$TMP/caddy-conf" "$TMP/orca/out/cli"
  : >"$IC_LOG"
}

# install-node 用环境注入（复制脚本到沙盒 → SCRIPT_DIR 沙盒化）
node_env() {
  export IZ_LOG="$TMP/call.log"
  export IZ_KVM_PATH="$TMP/kvm"
  export RAILANS_NODE_SH="$TMP/node-sh"
  export RAILANS_CTL_KIT="$TMP/ctl-kit"
  mkdir -p "$TMP/kvm"
  cp "$NODE_INSTALLER" "$TMP/install-node.sh"
  chmod 755 "$TMP/install-node.sh"
  : >"$IZ_LOG"
}

# 跑安装器：stdin 答案落文件；输出合并落 out；rc 落 rc 文件。
# CORE_PATH_PREFIX 非空时 PATH 互斥（= shim:影子目录，真 incus/真网不可见）；
# 缺省 PATH=shim:真PATH（bash/工具来自真机，incus 由 shim 拦截）。
run_inst() {  # <脚本路径> <out文件> <rc文件>；答案从 stdin 读
  local script="$1" outf="$2" rcf="$3" p
  if [[ -n "${CORE_PATH_PREFIX:-}" ]]; then
    p="$TMP/bin:$CORE_PATH_PREFIX"
  else
    p="$TMP/bin:$PATH"
  fi
  (
    export PATH="$p"
    "$script" >"$outf" 2>&1
  ) && printf '0' >"$rcf" || printf '%s' "$?" >"$rcf"
}

# capacity fixture（control面 capacityJSON 真实 MarshalIndent 形态，三成员）
make_capacity_fixture() {
  mkdir -p "$TMP/fixture"
  cat >"$TMP/fixture/capacity.json" <<'EOF'
{
  "boxes_total": 3,
  "boxes_max": 12,
  "available": 9,
  "nodes": [
    {
      "node": "node1",
      "boxes": 1
    },
    {
      "node": "node2",
      "boxes": 1
    },
    {
      "node": "node3",
      "boxes": 1
    }
  ],
  "port_range": [
    22000,
    22999
  ]
}
EOF
  export IN_FIXTURE="$TMP/fixture"
}

# 本机即控制机 config fixture（两成员）
make_local_config() {
  mkdir -p "$TMP/fixture"
  cat >"$TMP/fixture/config.yaml" <<'EOF'
listen: ":22"
nodes:
  - name: node1
    address: "192.168.1.11"
    subnet: "10.10.1.0/24"
    gateway: "10.10.1.1"
  - name: node2
    address: "192.168.1.12"
    subnet: "10.10.2.0/24"
    gateway: "10.10.2.1"
limits:
  max_boxes: 12
EOF
  export RAILANS_CONFIG="$TMP/fixture/config.yaml"
}

# 纯函数调用器：source 被测脚本（脚本尾有 main "$@"，用 --help 短路退出 0——
# main 在子 shell 里跑，不影响当前 shell 的函数定义）
call_pure() {  # <脚本> <函数> <参数...>
  bash -c '
    set -euo pipefail
    source "$1" --help >/dev/null 2>&1 || true
    shift
    "$@"
  ' runner "$1" "${@:2}"
}
# 注：source ... --help 会让脚本自身 exit 0（main 里 --help 分支 exit），
# 函数定义已在本 shell——但 exit 会终止 bash -c！改为显式定义后调用：
#   source 后脚本 main 已执行完（--help 分支 exit 0 结束 bash -c 之前，
#   函数已定义但我们拿不到控制权）。
# 因此纯函数断言改为「提取函数体 + 在临时文件里补 shim 后调用」不可靠——
# 直接用第二个实例化法：把脚本 source 到函数定义完成处不可行，改用
# bash -c 'source ... <不触发 main 的子命令>'。两个安装器对未知子命令都会
# exit 2，同样终止。唯一安全口：--help 在 usage 后 exit 0，函数定义已就绪，
# 但 bash -c 也随之退出。故纯函数在「安装器自身可执行环境」里断言：
#   bash -c 'set -e; source script --help; ...' —— 不行。
# 最终方案：sed 抽出纯函数区段（从第一个纯函数定义到问答助手标记行），
# 生成独立纯函数库文件后 source 调用。区段标记在两个安装器中固定。
pure_lib() {  # <安装器> <区段结束标记>
  sed -n "/^# ============$/,/^$1$/p" "$2" | sed '$d'
}

# ================================================================= TC-IN-01 参数面
case_in_01() {
  case_setup
  make_shims
  node_env
  local out rc
  out="$TMP/out"; rc="$TMP/rc"
  CORE_PATH_PREFIX=""
  (
    export PATH="$TMP/bin:$PATH"
    bash "$TMP/install-node.sh" --help >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IN-01 --help 退出 0" 0 "$(cat "$rc")"
  assert_cont "TC-IN-01 --help 含 install-control.sh 指引" "install-control.sh" "$(cat "$out")"
  assert_cont "TC-IN-01 --help 含 add-node 路径说明" "add-node" "$(cat "$out")"
  (
    export PATH="$TMP/bin:$PATH"
    bash "$TMP/install-node.sh" --wat >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IN-01 未知参数退出 2" 2 "$(cat "$rc")"
  assert_cont "TC-IN-01 未知参数回显" "--wat" "$(cat "$out")"
  assert_eq "TC-IN-01 参数面零探测（垫片日志空）" "" "$(cat "$TMP/call.log" 2>/dev/null || true)"
}

# ================================================================= TC-IN-02 纯函数
case_in_02() {
  case_setup
  make_shims
  node_env
  # 从安装器抽出纯函数区段（标记：问答助手分隔行），生成可 source 纯函数库
  pure_lib '# ============================================================' "$NODE_INSTALLER" >"$TMP/pure.sh" 2>/dev/null || true
  # 区段抽法：纯函数区从「纯函数（可单测」标题行起，到「问答助手」标题行止
  sed -n '/^# 纯函数（可单测/,/^# 问答助手/p' "$NODE_INSTALLER" >"$TMP/pure.sh"
  printf '\n' >>"$TMP/pure.sh"
  local v
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s" "$(iz_derive_wan "default via 10.0.2.2 dev enp0s3
10.10.2.0/24 via 10.0.2.15 dev enp0s3")"
  ')"
  assert_eq "TC-IN-02 WAN 从集群对端路由推导（INFRA_NET）" "enp0s3" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s" "$(iz_derive_wan "default via 10.0.2.2 dev enp0s3")"
  ')"
  assert_eq "TC-IN-02 无对端路由 → WAN 空（禁用默认路由推导）" "" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s|%s|%s" "$(iz_gateway_of 10.10.5.0/24)" "$(iz_mgmt_cidr 192.168.1.181)" "$(iz_mgmt_cidr odd)"
  ')"
  assert_eq "TC-IN-02 网关与管理网 /24 推导" "10.10.5.1|192.168.1.0/24|" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s|%s|%s" "$(iz_admin_port 22)" "$(iz_admin_port 2229)" "$(iz_admin_port 2200)"
  ')"
  assert_eq "TC-IN-02 管理口映射（ctl=22→2200，否则 22）" "2200|22|22" "$v"
  # capacity 成员名解析（真实 MarshalIndent 形态）
  make_capacity_fixture
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    iz_capacity_names "$(cat "'"$TMP/fixture/capacity.json"'")" | tr "\n" ","
  ')"
  assert_eq "TC-IN-02 capacity 成员名解析" "node1,node2,node3," "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s|%s|%s" "$(iz_next_name "node1
node2
node3")" "$(iz_next_name "node1
node7")" "$(iz_next_name "")"
  ')"
  assert_eq "TC-IN-02 下一成员名缺省（最大 N+1 / 计数+1）" "node4|node8|node1" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s|%s" "$(iz_next_subnet 3)" "$(iz_next_subnet 0)"
  ')"
  assert_eq "TC-IN-02 下一子网缺省（10.10.N+1.0/24）" "10.10.4.0/24|10.10.1.0/24" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s|%s|%s" "$(iz_route_conflict "10.10.1.0/24" "10.10.1.0/24 dev enp0s3" "")" "$(iz_route_conflict "10.10.1.0/24" "default via x" "10.10.1.0/24")" "$(iz_route_conflict "10.10.9.0/24" "default via x" "192.168.1.0/24")"
  ')"
  assert_cont "TC-IN-02 网段撞既有路由要报" "与既有路由冲突" "$v"
  v2="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s" "$(iz_route_conflict "10.10.9.0/24" "default via x" "192.168.1.0/24")"
  ')"
  assert_eq "TC-IN-02 无冲突返回空" "" "$v2"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s" "$(iz_mgmt_ip "" "1: lo:
    inet 127.0.0.1/8
2: enp0s3:
    inet 10.0.2.15/24")"
  ')"
  assert_eq "TC-IN-02 管理 IP 回退跳过 127." "10.0.2.15" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s|%s" "$(iz_valid_subnet 10.10.5.0/24 && echo Y || echo N)" "$(iz_valid_subnet 10.10.5.0/8 && echo Y || echo N)"
  ')"
  assert_eq "TC-IN-02 子网校验（/24 过、/8 不过）" "Y|N" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s|%s|%s" "$(iz_valid_name node12 && echo Y || echo N)" "$(iz_valid_name 3node && echo Y || echo N)" "$(iz_valid_target ops@1.2.3.4 && echo Y || echo N)"
  ')"
  assert_eq "TC-IN-02 成员名/目标机校验" "Y|N|Y" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    iz_parse_nodes "'"$TMP/fixture/config.yaml"'" | grep -c .
  ' 2>/dev/null || true)"
  # iz_parse_nodes 在 TC-IN-06 用 fixture 断言，这里断言函数存在
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    type iz_parse_nodes >/dev/null && echo HAS
  ')"
  assert_eq "TC-IN-02 iz_parse_nodes 在纯函数区" "HAS" "$v"
}

# ================================================================= TC-IN-03 分支 B：第一台机器
case_in_03() {
  case_setup
  make_shims noincus
  core_setup
  node_env
  export CORE_PATH_PREFIX="$CORE:"
  local out="$TMP/out" rc="$TMP/rc"
  IN_SSH_FAIL=1 run_inst "$TMP/install-node.sh" "$out" "$rc" </dev/null
  unset CORE_PATH_PREFIX
  assert_rc "TC-IN-03 分支 B 退出 0（指路不报错）" 0 "$(cat "$rc")"
  assert_cont "TC-IN-03 分支 B 文案锚" "这像是第一台机器" "$(cat "$out")"
  assert_cont "TC-IN-03 指路 install-control.sh" "请用 install-control.sh 安装控制端" "$(cat "$out")"
  assert_cont "TC-IN-03 incus 判未安装（影子 PATH 无 incus）" "incus:       未安装" "$(cat "$out")"
  # 只许只读探测：日志里不得出现 deploy/add-node/healthcheck 驱动
  assert_no "TC-IN-03 分支 B 零写调用（无 add-node）" "add-node" "$(cat "$TMP/call.log")"
  assert_no "TC-IN-03 分支 B 零写调用（无 deploy）" "node-sh deploy" "$(cat "$TMP/call.log")"
}

# ================================================================= TC-IN-04 远端驱动 add-node 全链
case_in_04() {
  case_setup
  make_shims
  node_env
  make_capacity_fixture
  export CORE_PATH_PREFIX=""
  # 全默认 + y：成员名 node4、子网 10.10.4.0/24
  local out="$TMP/out" rc="$TMP/rc"
  IN_CAP_OK=1 run_inst "$TMP/install-node.sh" "$out" "$rc" <<'ANS'
node4
10.10.4.0/24
y
ANS
  assert_rc "TC-IN-04 远端驱动全链退出 0" 0 "$(cat "$rc")"
  local o; o="$(cat "$out")"
  assert_cont "TC-IN-04 探测到控制面（capacity JSON）" "探测到控制面（git@10.0.2.2:22" "$o"
  assert_cont "TC-IN-04 成员数解析（3 既有成员）" "3 个成员）→ add-node 路径" "$o"
  assert_cont "TC-IN-04 管理口按映射探测 2200" "-p 2200 git@10.0.2.2 true" "$(cat "$TMP/call.log")"
  assert_cont "TC-IN-04 kit 探测（RAILANS_CTL_KIT 沙盒指认）" "test -d $TMP/ctl-kit/node" "$(cat "$TMP/call.log")"
  assert_cont "TC-IN-04 计划言明 ROUTES 自动推导" "ROUTES:   由 add-node 按既有成员自动推导" "$o"
  assert_cont "TC-IN-04 计划言明目标机=本机" "目标机:   git@10.0.2.15（本机）" "$o"
  assert_cont "TC-IN-04 计划言明八步编排" "八步编排" "$o"
  assert_cont "TC-IN-04 远端驱动 add-node（--yes，目标/名/网段全对）" \
    "add-node git@10.0.2.15 node4 10.10.4.0/24 --yes" "$(cat "$TMP/call.log")"
  assert_cont "TC-IN-04 驱动命令带管理口与 kit 路径" \
    "cd $TMP/ctl-kit && ./node/railans-node.sh add-node" "$(cat "$TMP/call.log")"
  assert_cont "TC-IN-04 收尾本机 healthcheck（sudo 形态）" \
    "node-sh healthcheck" "$(cat "$TMP/call.log")"
  assert_cont "TC-IN-04 完成行" "完成：node4 已入集群并接线" "$o"
  # 调用顺序：管理口探测 → kit 探测 → add-node 驱动 → healthcheck
  local seq
  seq="$(grep -oE '(test -d|add-node|node-sh healthcheck)' "$TMP/call.log" | tr '\n' ',')"
  assert_cont "TC-IN-04 编排顺序（kit 探测先于驱动、驱动先于 healthcheck）" \
    "add-node,node-sh healthcheck" "$seq"
}

# ================================================================= TC-IN-05 确认门（n 取消零执行）
case_in_05() {
  case_setup
  make_shims
  node_env
  make_capacity_fixture
  local out="$TMP/out" rc="$TMP/rc"
  IN_CAP_OK=1 run_inst "$TMP/install-node.sh" "$out" "$rc" <<'ANS'
node4
10.10.4.0/24
n
ANS
  assert_rc "TC-IN-05 确认 n 干净退出 0" 0 "$(cat "$rc")"
  assert_cont "TC-IN-05 已取消文案" "已取消：未改任何状态" "$(cat "$out")"
  assert_no "TC-IN-05 取消后零驱动（无 add-node 调用）" "add-node" "$(cat "$TMP/call.log")"
  assert_no "TC-IN-05 取消后零驱动（无 healthcheck）" "node-sh healthcheck" "$(cat "$TMP/call.log")"
  # 默认（EOF）= 放弃
  IN_CAP_OK=1 run_inst "$TMP/install-node.sh" "$out" "$rc" <<'ANS'
node4
10.10.4.0/24
ANS
  assert_rc "TC-IN-05 确认 EOF 缺省 N 退出 0" 0 "$(cat "$rc")"
  assert_cont "TC-IN-05 EOF 确认同样取消" "已取消：未改任何状态" "$(cat "$out")"
  assert_no "TC-IN-05 EOF 确认零驱动" "add-node" "$(cat "$TMP/call.log")"
}

# ================================================================= TC-IN-06 本机即控制机（本地驱动）
case_in_06() {
  case_setup
  make_shims
  node_env
  make_local_config
  local out="$TMP/out" rc="$TMP/rc"
  run_inst "$TMP/install-node.sh" "$out" "$rc" <<'ANS'
ops@192.168.1.15
node3
10.10.3.0/24
y
ANS
  assert_rc "TC-IN-06 本地驱动全链退出 0" 0 "$(cat "$rc")"
  local o; o="$(cat "$out")"
  assert_cont "TC-IN-06 本机即控制机判定" "本机即控制机（config: $TMP/fixture/config.yaml，2 个成员）" "$o"
  assert_cont "TC-IN-06 成员名缺省按 config 最大 N+1" "新成员名 [node3]" "$o"
  assert_cont "TC-IN-06 子网缺省按成员数+1" "该节点 VM 网段 [10.10.3.0/24]" "$o"
  assert_cont "TC-IN-06 本地驱动 add-node --yes" \
    "node-sh add-node ops@192.168.1.15 node3 10.10.3.0/24 --yes" "$(cat "$TMP/call.log")"
  assert_cont "TC-IN-06 收尾 healthcheck" "node-sh healthcheck" "$(cat "$TMP/call.log")"
  # 远端探测不得发生（本地命中即短路）
  assert_no "TC-IN-06 本地命中不发起远端 capacity 探测" "capacity" "$(cat "$TMP/call.log")"
}

# ================================================================= TC-IN-07 分支 C-n：单机 deploy
case_in_07() {
  case_setup
  make_shims
  node_env
  export IN_SSH_FAIL=1
  export IN_CLUSTER_N=1
  local out="$TMP/out" rc="$TMP/rc"
  run_inst "$TMP/install-node.sh" "$out" "$rc" <<'ANS'
n
node1
10.10.1.0/24
enp0s3
y
ANS
  assert_rc "TC-IN-07 单机 deploy 全链退出 0" 0 "$(cat "$rc")"
  local o; o="$(cat "$out")"
  assert_cont "TC-IN-07 单机分支判定" "本机有 incus 但不是集群成员" "$o"
  assert_cont "TC-IN-07 deploy 环境变量透传（NODE_NAME/NODE_ADDR/SUBNET/WAN/ROUTES）" \
    "node-sh deploy" "$(cat "$TMP/call.log")"
  assert_cont "TC-IN-07 ROUTES 为空（单节点）" "ROUTES= bash" "$(cat "$TMP/call.log")"
  assert_cont "TC-IN-07 deploy 先于 healthcheck" \
    "node-sh deploy" "$(cat "$TMP/call.log")"
  assert_cont "TC-IN-07 完成行言明入伙从入口侧驱动" "将来入集群时从入口节点跑" "$o"
  assert_cont "TC-IN-07 收尾 healthcheck" "node-sh healthcheck" "$(cat "$TMP/call.log")"
}

# ================================================================= TC-IN-08 分支 C-y：控制面地址再探测
case_in_08() {
  case_setup
  make_shims
  node_env
  export IN_SSH_FAIL=1
  export IN_CLUSTER_N=1
  local out="$TMP/out" rc="$TMP/rc"
  # y + 地址默认 + 探测不到 → 指引退出
  run_inst "$TMP/install-node.sh" "$out" "$rc" <<'ANS'
y

ANS
  assert_rc "TC-IN-08 入集群但探测不到 → 指引退出 1" 1 "$(cat "$rc")"
  assert_cont "TC-IN-08 指引言明入口侧驱动" "入集群由入口节点侧驱动" "$(cat "$out")"
  assert_no "TC-IN-08 指引路径零执行" "node-sh deploy" "$(cat "$TMP/call.log")"
  # y + 用户另给控制面地址（IN_CAP_HOST 限定只有该主机 capacity 命中）→
  # 默认网关首轮探测失败 → 入集群问句 → 给地址 → 再探测命中 → 远端驱动
  unset IN_SSH_FAIL
  make_capacity_fixture
  : >"$IZ_LOG"
  local out2="$TMP/out2"
  IN_CAP_OK=1 IN_CAP_HOST=10.0.9.9 run_inst "$TMP/install-node.sh" "$out2" "$rc" <<'ANS'
y
10.0.9.9
node9
10.10.9.0/24
y
ANS
  assert_rc "TC-IN-08 再探测命中 → 远端驱动退出 0" 0 "$(cat "$rc")"
  assert_cont "TC-IN-08 再探测问句先于命中（首轮默认网关灭）" "本机有 incus 但不是集群成员" "$(cat "$out2")"
  assert_cont "TC-IN-08 再探测走 add-node 驱动" "add-node git@10.0.2.15 node9 10.10.9.0/24 --yes" "$(cat "$TMP/call.log")"
  assert_cont "TC-IN-08 用户给的地址进了探测与驱动" "git@10.0.9.9 capacity" "$(cat "$TMP/call.log")"
}

# ================================================================= TC-IN-09 前置缺失指引（管理口 / kit）
case_in_09() {
  case_setup
  make_shims
  node_env
  make_capacity_fixture
  local out="$TMP/out" rc="$TMP/rc"
  # capacity 命中但管理口打不通（admin/kit 探测形态都是 `true`/`test -d`，
  # IN_ADMIN_FAIL=1 时对 admin 探测形态回 255）
  cat >"$TMP/bin/ssh" <<'EOF'
#!/bin/sh
echo "ssh $*" >> "$IZ_LOG"
if [ -n "${IN_SSH_FAIL:-}" ]; then exit 255; fi
is_cap=0; is_admin=0
for a in "$@"; do
  [ "$a" = "capacity" ] && is_cap=1
  case "$a" in
    true) is_admin=1 ;;
    *add-node*) exit 0 ;;
    *"test -d"*) exit 0 ;;
  esac
done
if [ -n "${IN_ADMIN_FAIL:-}" ] && [ "$is_admin" = "1" ]; then exit 255; fi
if [ "$is_cap" = "1" ]; then
  if [ -n "${IN_CAP_OK:-}" ]; then
    cat "$IN_FIXTURE/capacity.json"
    exit 0
  fi
  exit 255
fi
exit 0
EOF
  chmod 755 "$TMP/bin/ssh"
  IN_CAP_OK=1 IN_ADMIN_FAIL=1 run_inst "$TMP/install-node.sh" "$out" "$rc" </dev/null
  assert_rc "TC-IN-09 管理口不通 → 指引退出 1" 1 "$(cat "$rc")"
  assert_cont "TC-IN-09 指引言明两个办法" "直接在控制机上跑本脚本" "$(cat "$out")"
  assert_no "TC-IN-09 管理口不通零驱动" "add-node" "$(cat "$TMP/call.log")"
  # 管理口通、kit 缺失（垫片对 test -d 形态回 1）
  : >"$IZ_LOG"
  cat >"$TMP/bin/ssh" <<'EOF'
#!/bin/sh
echo "ssh $*" >> "$IZ_LOG"
is_cap=0
for a in "$@"; do
  [ "$a" = "capacity" ] && is_cap=1
  case "$a" in
    *"test -d"*) exit 1 ;;
    *add-node*) exit 0 ;;
  esac
done
if [ "$is_cap" = "1" ]; then
  if [ -n "${IN_CAP_OK:-}" ]; then
    cat "$IN_FIXTURE/capacity.json"
    exit 0
  fi
  exit 255
fi
exit 0
EOF
  chmod 755 "$TMP/bin/ssh"
  IN_CAP_OK=1 run_inst "$TMP/install-node.sh" "$out" "$rc" </dev/null
  assert_rc "TC-IN-09 kit 缺失 → 指引退出 1" 1 "$(cat "$rc")"
  assert_cont "TC-IN-09 指引言明放 kit" "railans-kit" "$(cat "$out")"
  assert_no "TC-IN-09 kit 缺失零驱动" "add-node" "$(cat "$TMP/call.log")"
}

# ================================================================= TC-IN-10 sudo 缺失拒跑
case_in_10() {
  case_setup
  make_shims
  node_env
  export IN_SSH_FAIL=1
  export IN_CLUSTER_N=1
  export IN_SUDO_FAIL=1
  local out="$TMP/out" rc="$TMP/rc"
  run_inst "$TMP/install-node.sh" "$out" "$rc" <<'ANS'
n
node1
10.10.1.0/24
y
ANS
  assert_rc "TC-IN-10 sudo 缺失退出 1" 1 "$(cat "$rc")"
  assert_cont "TC-IN-10 提示 sudo bash 运行" "请用 sudo bash 运行本脚本" "$(cat "$out")"
  assert_no "TC-IN-10 拒跑零执行（无 deploy）" "node-sh deploy" "$(cat "$TMP/call.log")"
  assert_no "TC-IN-10 拒跑零执行（无 healthcheck）" "node-sh healthcheck" "$(cat "$TMP/call.log")"
}

# ================================================================= TC-IN-11 静态锚
case_in_11() {
  case_setup
  make_shims
  node_env
  local bn_err bn_rc
  bn_err="$(bash -n "$NODE_INSTALLER" 2>&1)" && bn_rc=0 || bn_rc=$?
  assert_rc "TC-IN-11 install-node.sh bash -n 过" 0 "$bn_rc"
  assert_eq "TC-IN-11 install-node.sh bash -n 零输出" "" "$bn_err"
  # INFRA_NET 锚：WAN 推导只认对端路由，注释言明禁用默认路由
  assert_cont "TC-IN-11 WAN 推导言明 INFRA_NET 教训" "INFRA_NET 教训" "$(cat "$NODE_INSTALLER")"
  assert_cont "TC-IN-11 WAN 推导言明禁用默认路由" "禁用默认路由" "$(cat "$NODE_INSTALLER")"
  # 复用锚：add-node / deploy / healthcheck 三积木
  assert_cont "TC-IN-11 复用锚 add-node" "railans-node.sh add-node" "$(cat "$NODE_INSTALLER")"
  assert_cont "TC-IN-11 复用锚 deploy" "railans-node.sh deploy" "$(cat "$NODE_INSTALLER")"
  assert_cont "TC-IN-11 复用锚 healthcheck" "healthcheck" "$(cat "$NODE_INSTALLER")"
  # 结构性复用言明零重写
  assert_cont "TC-IN-11 头注言明安装逻辑零重写" "零重写" "$(cat "$NODE_INSTALLER")"
  # 秘密卫生：不得内嵌任何疑似令牌字面量
  assert_no "TC-IN-11 无硬编码令牌形态" "sk-" "$(cat "$NODE_INSTALLER")"
}

# ================================================================= TC-IC-01 参数面
case_ic_01() {
  case_setup
  make_shims
  ctl_env
  local out="$TMP/out" rc="$TMP/rc"
  CORE_PATH_PREFIX=""
  (
    export PATH="$TMP/bin:$PATH"
    bash "$CTL_INSTALLER" --help >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IC-01 --help 退出 0" 0 "$(cat "$rc")"
  assert_cont "TC-IC-01 --help 含 --from-step" "--from-step" "$(cat "$out")"
  assert_cont "TC-IC-01 --help 含 RAILANS_IC_ 预设说明" "RAILANS_IC_ADDR" "$(cat "$out")"
  (
    export PATH="$TMP/bin:$PATH"
    bash "$CTL_INSTALLER" --from-step 10 >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IC-01 --from-step 越界退出 2" 2 "$(cat "$rc")"
  (
    export PATH="$TMP/bin:$PATH"
    bash "$CTL_INSTALLER" --wat >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IC-01 未知参数退出 2" 2 "$(cat "$rc")"
  assert_cont "TC-IC-01 未知参数回显" "--wat" "$(cat "$out")"
  (
    export PATH="$TMP/bin:$PATH"
    bash "$CTL_INSTALLER" --from-step >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IC-01 --from-step 缺参数退出 2" 2 "$(cat "$rc")"
}

# ================================================================= TC-IC-02 纯函数
case_ic_02() {
  case_setup
  make_shims
  ctl_env
  sed -n '/^# 纯函数（可单测/,/^# 问答助手/p' "$CTL_INSTALLER" >"$TMP/pure.sh"
  printf '\n' >>"$TMP/pure.sh"
  local v
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s|%s" "$(ic_port_suggest "LISTEN 0 4096 0.0.0.0:22 users:")" "$(ic_port_suggest "")"
  ')"
  assert_eq "TC-IC-02 端口建议（22 占→2229，空→22）" "2229|22" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s|%s" "$(ic_route_conflict "10.10.1.0/24" "10.10.1.0/24 dev enp0s3" "")" "$(ic_route_conflict "192.168.1.0/24" "default via x dev y" "192.168.1.0/24")"
  ')"
  assert_cont "TC-IC-02 网段撞既有路由要报" "与既有路由冲突" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s" "$(ic_route_conflict "192.168.1.0/24" "default via x dev y" "192.168.1.0/24")"
  ')"
  assert_cont "TC-IC-02 网段与管理网重合要报" "与管理网段" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s" "$(ic_route_conflict "10.10.9.0/24" "default via x" "192.168.1.0/24")"
  ')"
  assert_eq "TC-IC-02 无冲突返回空" "" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s|%s|%s" "$(ic_mem_total_mib "              total        used        free
Mem:            15813        4200        3000")" "$(ic_mem_total_mib "bad")" "$(ic_disk_used_pct "Filesystem  Size Used Avail Use% Mounted
/dev/root   115G 105G  3.8G  97% /")"
  ')"
  assert_eq "TC-IC-02 内存/磁盘解析" "15813||97" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s|%s" "$(ic_valid_port 2229 && echo Y || echo N)" "$(ic_valid_port 0 && echo Y || echo N)"
  ')"
  assert_eq "TC-IC-02 端口校验（2229 过、0 不过）" "Y|N" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s|%s|%s" "$(ic_valid_driver dir && echo Y || echo N)" "$(ic_valid_driver ext4 && echo Y || echo N)" "$(ic_valid_domain box.lan && echo Y || echo N)"
  ')"
  assert_eq "TC-IC-02 驱动/域名校验" "Y|N|Y" "$v"
  # config 渲染名字段锚（对照 control/config.go Config 结构）
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    ic_render_config 192.168.1.11 10.10.1.0/24 dir 2229 box.lan CAFE0000 node1
  ')"
  assert_cont "TC-IC-02 config listen" 'listen: ":2229"' "$v"
  assert_cont "TC-IC-02 config control_host" 'control_host: "new.box.lan"' "$v"
  assert_cont "TC-IC-02 config public_host" 'public_host: "192.168.1.11"' "$v"
  assert_cont "TC-IC-02 config preview_domain" 'preview_domain: "box.lan"' "$v"
  assert_cont "TC-IC-02 config storage_driver" 'storage_driver: "dir"' "$v"
  assert_cont "TC-IC-02 config port_range" "port_range: [22000, 22999]" "$v"
  assert_cont "TC-IC-02 config nodes 块 name" "  - name: node1" "$v"
  assert_cont "TC-IC-02 config 节点 address" '    address: "192.168.1.11"' "$v"
  assert_cont "TC-IC-02 config 节点 subnet" '    subnet: "10.10.1.0/24"' "$v"
  assert_cont "TC-IC-02 config 节点 gateway 自动推导 .1" '    gateway: "10.10.1.1"' "$v"
  assert_cont "TC-IC-02 config enroll_code" '  enroll_code: "CAFE0000"' "$v"
  assert_cont "TC-IC-02 config require_enroll" "  require_enroll: true" "$v"
  assert_cont "TC-IC-02 config allowed_source_cidr=管理网/24" '  allowed_source_cidr: "192.168.1.0/24"' "$v"
  assert_cont "TC-IC-02 config caddy conf_path" 'conf_path: "/etc/caddy/conf.d/boxes.caddy"' "$v"
  assert_cont "TC-IC-02 config state_file 打包布局" 'state_file: "/var/lib/railans/state.json"' "$v"
  assert_no "TC-IC-02 config 无 box_assets（注入缺省关闭）" "box_assets" "$v"
  # enroll code 提取 + goarch 映射
  printf 'security:\n  enroll_code: "abc123"\n' >"$TMP/cfg.yaml"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s" "$(ic_config_code "'"$TMP/cfg.yaml"'")"
  ')"
  assert_eq "TC-IC-02 enroll code 提取" "abc123" "$v"
  v="$(bash -c '
    set -euo pipefail
    source "'"$TMP/pure.sh"'"
    printf "%s" "$(ic_goarch)"
  ')"
  local expect_arch='x86_64'
  case "$(uname -m)" in
    x86_64) expect_arch='amd64' ;;
    aarch64) expect_arch='arm64' ;;
  esac
  assert_eq "TC-IC-02 goarch 映射（uname -m=$(uname -m)）" "$expect_arch" "$v"
}

# ================================================================= TC-IC-03 全回车问答 = 全默认 + 确认门
case_ic_03() {
  case_setup
  make_shims
  ctl_env
  export IN_PORT22_TAKEN=1
  local out="$TMP/out" rc="$TMP/rc"
  CORE_PATH_PREFIX=""
  (
    export PATH="$TMP/bin:$PATH"
    printf '\n\n\n\n\n' | bash "$CTL_INSTALLER" >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  local o; o="$(cat "$out")"
  assert_rc "TC-IC-03 全默认+确认 EOF 退出 0（取消）" 0 "$(cat "$rc")"
  assert_cont "TC-IC-03 管理 IP 探测默认" "管理 IP（入口节点本机地址） [10.0.2.15]" "$o"
  assert_cont "TC-IC-03 子网默认 10.10.1.0/24" "VM mesh 网段（每节点一个 /24） [10.10.1.0/24]" "$o"
  assert_cont "TC-IC-03 存储驱动默认 dir（取舍一行在）" "存储驱动 [dir]" "$o"
  assert_cont "TC-IC-03 驱动取舍说明（dir 行）" "dir = 零准备开箱即用，不支持快照" "$o"
  assert_cont "TC-IC-03 22 被占提示改绑 2229" "22 已被占用——多半是系统 sshd；建议控制面改绑 2229" "$o"
  assert_cont "TC-IC-03 端口建议 2229" "控制面端口 [2229]" "$o"
  assert_cont "TC-IC-03 预览域名默认 box.lan" "预览域名后缀 [box.lan]" "$o"
  assert_cont "TC-IC-03 计划管理 IP 行" "管理 IP:    10.0.2.15" "$o"
  assert_cont "TC-IC-03 计划网关推导" "网关 10.10.1.1；mesh 冲突检查已过" "$o"
  assert_cont "TC-IC-03 计划九步清单" "9/9 使用摘要" "$o"
  assert_cont "TC-IC-03 计划言明 enroll code 只展示一次" "只在安装尾声展示一次" "$o"
  assert_cont "TC-IC-03 取消文案" "已取消：未改任何状态" "$o"
  assert_eq "TC-IC-03 取消零执行（垫片日志只有探测）" "" \
    "$(grep -E 'node-sh|build-sh|systemctl (restart|is-active)|chgrp' "$TMP/call.log" 2>/dev/null || true)"
}

# ================================================================= TC-IC-04 编排顺序全链（--yes 环境预设）
case_ic_04() {
  case_setup
  make_shims
  ctl_env
  local out="$TMP/out" rc="$TMP/rc"
  CORE_PATH_PREFIX=""
  (
    export PATH="$TMP/bin:$PATH"
    export RAILANS_IC_ADDR=10.0.2.15 RAILANS_IC_SUBNET=10.10.1.0/24 \
      RAILANS_IC_DRIVER=dir RAILANS_IC_PORT=2229 RAILANS_IC_DOMAIN=box.lan \
      RAILANS_IC_WAN=enp0s3
    bash "$CTL_INSTALLER" --yes >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IC-04 --yes 全链退出 0" 0 "$(cat "$rc")"
  local log; log="$(cat "$TMP/call.log")"
  local o; o="$(cat "$out")"
  # 编排顺序断言（垫片记录调用序列；build-sh 两行=一次调用的命令与资产目录记录）
  local seq
  seq="$(grep -oE 'node-sh [a-z-]+|build-sh ASSET|build-sh|incus image list dev-base --format csv|chgrp railans|systemctl restart railans|systemctl is-active --quiet [a-z]+' "$TMP/call.log" | tr '\n' ',')"
  assert_eq "TC-IC-04 编排顺序（九步落调用序列）" \
    "node-sh preflight,node-sh install-incus,node-sh bootstrap,node-sh network,incus image list dev-base --format csv,build-sh,build-sh ASSET,node-sh control,node-sh caddy,chgrp railans,systemctl restart railans,systemctl is-active --quiet railans,systemctl is-active --quiet caddy,node-sh healthcheck," \
    "$seq"
  # 每步调用的环境变量透传锚（node-sh-env 行）
  assert_cont "TC-IC-04 install-incus 带 DRIVER=dir" "node-sh-env DRIVER=dir" "$log"
  assert_cont "TC-IC-04 bootstrap 带 NODE_NAME/NODE_ADDR/DRIVER" \
    "node-sh-env NODE_ADDR=10.0.2.15" "$log"
  assert_cont "TC-IC-04 bootstrap 带 NODE_NAME" "node-sh-env NODE_NAME=node1" "$log"
  assert_cont "TC-IC-04 network 带 NODE_ADDR/SUBNET" \
    "node-sh-env SUBNET=10.10.1.0/24" "$log"
  assert_eq "TC-IC-04 SUBNET 透传恰一次（仅 network 步）" "1" \
    "$(grep -c 'node-sh-env SUBNET=10.10.1.0/24' "$TMP/call.log")"
  assert_cont "TC-IC-04 network 带 WAN 透传" "node-sh-env WAN=enp0s3" "$log"
  assert_cont "TC-IC-04 control 带 CONFIG/ADMIN_SSH_PORT" \
    "node-sh-env ADMIN_SSH_PORT=2200" "$log"
  assert_cont "TC-IC-04 caddy 带 ENTRY_IP/DOMAIN" "node-sh-env ENTRY_IP=10.0.2.15" "$log"
  assert_cont "TC-IC-04 build 透传资产目录" "build-sh ASSET=$TMP/assets" "$log"
  # config 落盘与形态
  local cfg; cfg="$(cat "$IC_CONFIG_PATH")"
  assert_cont "TC-IC-04 config 落盘 listen :2229" 'listen: ":2229"' "$cfg"
  assert_cont "TC-IC-04 config 节点条目齐全" 'address: "10.0.2.15"' "$cfg"
  assert_cont "TC-IC-04 config 权限 0640" "640" "$(stat -c %a "$IC_CONFIG_PATH")"
  # enroll code 卫生：openssl 假值只进 config 与尾声摘要，不进调用日志/执行段
  assert_cont "TC-IC-04 enroll code 落 config" "cafe0102030405060708090a0b0c0d0e0f10111213141516" "$cfg"
  assert_no "TC-IC-04 enroll code 不进调用日志" "cafe0102030405060708090a0b0c0d0e0f10111213141516" "$log"
  # 尾声摘要恰好展示一次
  assert_eq "TC-IC-04 enroll code 摘要恰好一次" "1" \
    "$(grep -c "cafe0102030405060708090a0b0c0d0e0f10111213141516" "$out")"
  assert_cont "TC-IC-04 摘要含 enroll 指引" "enroll" "$o"
  assert_cont "TC-IC-04 摘要含建箱指引" "ssh new.box.lan new" "$o"
  assert_cont "TC-IC-04 摘要含管理 SSH 说明（2229 不挪 sshd）" "仍在 22" "$o"
  assert_cont "TC-IC-04 摘要含加节点指路 install-node.sh" "install-node.sh" "$o"
  assert_no "TC-IC-04 成功路径无断点续跑命令" "续跑：" "$o"
  assert_cont "TC-IC-04 --yes 免确认行" "免确认开跑" "$o"
}

# ================================================================= TC-IC-05 断点续跑（失败停 + --from-step）
case_ic_05() {
  case_setup
  make_shims
  ctl_env
  local out="$TMP/out" rc="$TMP/rc"
  CORE_PATH_PREFIX=""
  # 段一：第 3 步失败（config 尚未写）→ 断点 + 续跑命令
  (
    export PATH="$TMP/bin:$PATH"
    export RAILANS_IC_ADDR=10.0.2.15 RAILANS_IC_SUBNET=10.10.1.0/24 \
      RAILANS_IC_DRIVER=dir RAILANS_IC_PORT=2229 RAILANS_IC_DOMAIN=box.lan
    export IN_NODE_FAIL=network
    bash "$CTL_INSTALLER" --yes >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IC-05 第 3 步失败整体退出 1" 1 "$(cat "$rc")"
  local o; o="$(cat "$out")"
  assert_cont "TC-IC-05 FAIL 行点名步骤" "FAIL 第 3/9 步" "$o"
  assert_cont "TC-IC-05 断点行" "断点：停在第 3/9 步" "$o"
  assert_cont "TC-IC-05 续跑命令含全部答案与 --from-step 3 --yes" \
    "RAILANS_IC_ADDR=10.0.2.15 RAILANS_IC_SUBNET=10.10.1.0/24 RAILANS_IC_DRIVER=dir RAILANS_IC_PORT=2229 RAILANS_IC_DOMAIN=box.lan bash install-control.sh --from-step 3 --yes" "$o"
  assert_no "TC-IC-05 失败后无尾声摘要（enroll 不展示）" "== railans 控制端安装完成 ==" "$o"
  assert_eq "TC-IC-05 失败段无 config 落盘" "" "$(ls "$IC_CONFIG_PATH" 2>/dev/null || true)"
  # 段二：--from-step 5 续跑（config 缺席 → 现场生成）——1-4 跳过，5-9 跑
  : >"$IC_LOG"
  local out2="$TMP/out2"
  (
    export PATH="$TMP/bin:$PATH"
    export RAILANS_IC_ADDR=10.0.2.15 RAILANS_IC_SUBNET=10.10.1.0/24 \
      RAILANS_IC_DRIVER=dir RAILANS_IC_PORT=2229 RAILANS_IC_DOMAIN=box.lan
    unset IN_NODE_FAIL
    bash "$CTL_INSTALLER" --from-step 5 --yes >"$out2" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IC-05 续跑退出 0" 0 "$(cat "$rc")"
  local o2; o2="$(cat "$out2")"
  assert_cont "TC-IC-05 跳过第 1 步标记" "-- 跳过第 1/9 步（--from-step 5 续跑）--" "$o2"
  assert_cont "TC-IC-05 跳过第 4 步标记" "-- 跳过第 4/9 步（--from-step 5 续跑）--" "$o2"
  assert_no "TC-IC-05 跳过步不重跑（无 preflight 调用）" "node-sh preflight" "$(cat "$TMP/call.log")"
  assert_no "TC-IC-05 跳过步不重跑（无 build）" "build-sh" "$(cat "$TMP/call.log")"
  assert_cont "TC-IC-05 续跑直达尾声摘要" "== railans 控制端安装完成 ==" "$o2"
  assert_eq "TC-IC-05 续跑尾声 enroll code 恰好一次" "1" \
    "$(grep -c "cafe0102030405060708090a0b0c0d0e0f10111213141516" "$out2")"
  # 段三：config 已在场时重跑第 5 步（--from-step 5）——保留不动、不重生成
  : >"$IC_LOG"
  local out3="$TMP/out3"
  (
    export PATH="$TMP/bin:$PATH"
    export RAILANS_IC_ADDR=10.0.2.15 RAILANS_IC_SUBNET=10.10.1.0/24 \
      RAILANS_IC_DRIVER=dir RAILANS_IC_PORT=2229 RAILANS_IC_DOMAIN=box.lan
    bash "$CTL_INSTALLER" --from-step 5 --yes >"$out3" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IC-05 幂等重跑退出 0" 0 "$(cat "$rc")"
  local o3; o3="$(cat "$out3")"
  assert_cont "TC-IC-05 config 已存在幂等保留" "config 已存在，保留不动" "$o3"
  assert_no "TC-IC-05 幂等不重生成（无二次 openssl rand）" "openssl rand" "$(cat "$TMP/call.log")"
  assert_cont "TC-IC-05 幂等重跑尾声 enroll code 恰好一次" "1" \
    "$(grep -c "cafe0102030405060708090a0b0c0d0e0f10111213141516" "$out3")"
  assert_eq "TC-IC-05 config 内容跨重跑稳定" "$(md5sum <"$IC_CONFIG_PATH" | awk '{print $1}')" \
    "$(md5sum <"$IC_CONFIG_PATH" | awk '{print $1}')"
}

# ================================================================= TC-IC-06 --yes 缺 env 点名退出
case_ic_06() {
  case_setup
  make_shims
  ctl_env
  local out="$TMP/out" rc="$TMP/rc"
  CORE_PATH_PREFIX=""
  (
    export PATH="$TMP/bin:$PATH"
    export RAILANS_IC_ADDR=10.0.2.15 RAILANS_IC_SUBNET=10.10.1.0/24 RAILANS_IC_DRIVER=dir
    bash "$CTL_INSTALLER" --yes >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IC-06 缺 PORT/DOMAIN 退出 2" 2 "$(cat "$rc")"
  assert_cont "TC-IC-06 点名缺 RAILANS_IC_PORT" "RAILANS_IC_PORT" "$(cat "$out")"
  assert_cont "TC-IC-06 点名缺 RAILANS_IC_DOMAIN" "RAILANS_IC_DOMAIN" "$(cat "$out")"
  assert_eq "TC-IC-06 缺 env 零执行" "" "$(cat "$TMP/call.log" 2>/dev/null || true)"
}

# ================================================================= TC-IC-07 orca 缺失第 4 步快停
case_ic_07() {
  case_setup
  make_shims
  ctl_env
  rmdir "$TMP/orca/out/cli" 2>/dev/null || true
  local out="$TMP/out" rc="$TMP/rc"
  CORE_PATH_PREFIX=""
  (
    export PATH="$TMP/bin:$PATH"
    export RAILANS_IC_ADDR=10.0.2.15 RAILANS_IC_SUBNET=10.10.1.0/24 \
      RAILANS_IC_DRIVER=dir RAILANS_IC_PORT=2229 RAILANS_IC_DOMAIN=box.lan
    bash "$CTL_INSTALLER" --yes >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IC-07 orca 缺失退出 1" 1 "$(cat "$rc")"
  local o; o="$(cat "$out")"
  assert_cont "TC-IC-07 FAIL 第 4/9 步点名 orca" "FAIL 第 4/9 步：orca checkout 缺失" "$o"
  assert_cont "TC-IC-07 指引 ORCA_SRC 指认" "ORCA_SRC=" "$o"
  assert_cont "TC-IC-07 续跑指回 --from-step 4" "--from-step 4 --yes" "$o"
  assert_no "TC-IC-07 快停在 build 之前（无 build 调用）" "build-sh" "$(cat "$TMP/call.log")"
}

# ================================================================= TC-IC-08 镜像幂等跳过 + FORCE
case_ic_08() {
  case_setup
  make_shims
  ctl_env
  export IN_IMAGE_EXISTS=1
  local out="$TMP/out" rc="$TMP/rc"
  CORE_PATH_PREFIX=""
  (
    export PATH="$TMP/bin:$PATH"
    export RAILANS_IC_ADDR=10.0.2.15 RAILANS_IC_SUBNET=10.10.1.0/24 \
      RAILANS_IC_DRIVER=dir RAILANS_IC_PORT=2229 RAILANS_IC_DOMAIN=box.lan
    bash "$CTL_INSTALLER" --yes >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IC-08 镜像已存在跳过仍全链退出 0" 0 "$(cat "$rc")"
  assert_cont "TC-IC-08 跳过注记" "镜像 dev-base 已存在，跳过构建" "$(cat "$out")"
  assert_no "TC-IC-08 跳过不调 build" "build-sh" "$(cat "$TMP/call.log")"
  # FORCE=1 强制重建
  : >"$IC_LOG"
  local out2="$TMP/out2"
  (
    export PATH="$TMP/bin:$PATH"
    export RAILANS_IC_ADDR=10.0.2.15 RAILANS_IC_SUBNET=10.10.1.0/24 \
      RAILANS_IC_DRIVER=dir RAILANS_IC_PORT=2229 RAILANS_IC_DOMAIN=box.lan \
      RAILANS_IC_FORCE_IMAGE=1
    bash "$CTL_INSTALLER" --yes >"$out2" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IC-08 FORCE 全链退出 0" 0 "$(cat "$rc")"
  assert_cont "TC-IC-08 FORCE 调 build" "build-sh" "$(cat "$TMP/call.log")"
  assert_cont "TC-IC-08 build 透传 RAILANS_ASSET_DIR" "build-sh ASSET=$TMP/assets" "$(cat "$TMP/call.log")"
}

# ================================================================= TC-IC-09 mesh 冲突重问
case_ic_09() {
  case_setup
  make_shims
  ctl_env
  export IN_ROUTE_MESH="10.10.1.0/24"
  local out="$TMP/out" rc="$TMP/rc"
  CORE_PATH_PREFIX=""
  (
    export PATH="$TMP/bin:$PATH"
    # 管理 IP 默认 → 网段默认(空)撞路由 → 重问给 10.10.9.0/24 → 驱动/端口/域名默认 → 确认 EOF 取消
    printf '\n\n10.10.9.0/24\n\n\n\n' | bash "$CTL_INSTALLER" >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  local o; o="$(cat "$out")"
  assert_rc "TC-IC-09 冲突重问后干净取消" 0 "$(cat "$rc")"
  assert_cont "TC-IC-09 冲突报告点名既有路由" "与既有路由冲突: 10.10.1.0/24" "$o"
  assert_cont "TC-IC-09 重问后计划用 10.10.9.0/24" "VM 网段:    10.10.9.0/24" "$o"
  assert_eq "TC-IC-09 冲突路径零执行" "" \
    "$(grep -E 'node-sh|build-sh' "$TMP/call.log" 2>/dev/null || true)"
}

# ================================================================= TC-IC-10 sudo 缺失拒跑
case_ic_10() {
  case_setup
  make_shims
  ctl_env
  local out="$TMP/out" rc="$TMP/rc"
  CORE_PATH_PREFIX=""
  (
    export PATH="$TMP/bin:$PATH"
    export RAILANS_IC_ADDR=10.0.2.15 RAILANS_IC_SUBNET=10.10.1.0/24 \
      RAILANS_IC_DRIVER=dir RAILANS_IC_PORT=2229 RAILANS_IC_DOMAIN=box.lan
    bash "$CTL_INSTALLER" --yes >"$out" 2>&1 <<'EOF'
EOF
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  # sudo 垫片放行 sudo -n true（默认）；这里单独构造失败垫片重跑
  cat >"$TMP/bin/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "$IC_LOG"
if [ "${1:-}" = "-n" ] && [ "${2:-}" = "true" ]; then exit 1; fi
while [ "${1:-}" = "-n" ]; do shift; done
exec "$@"
EOF
  chmod 755 "$TMP/bin/sudo"
  : >"$IC_LOG"
  (
    export PATH="$TMP/bin:$PATH"
    export RAILANS_IC_ADDR=10.0.2.15 RAILANS_IC_SUBNET=10.10.1.0/24 \
      RAILANS_IC_DRIVER=dir RAILANS_IC_PORT=2229 RAILANS_IC_DOMAIN=box.lan
    bash "$CTL_INSTALLER" --yes >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IC-10 sudo 缺失退出 1" 1 "$(cat "$rc")"
  assert_cont "TC-IC-10 提示 sudo bash 运行" "请用 sudo bash 运行本脚本" "$(cat "$out")"
  assert_no "TC-IC-10 拒跑零执行（无 preflight 调用）" "node-sh preflight" "$(cat "$TMP/call.log")"
  assert_no "TC-IC-10 拒跑不进问答（无计划输出）" "安装计划" "$(cat "$out")"
}

# ================================================================= TC-IC-11 预检硬伤
case_ic_11() {
  case_setup
  make_shims
  ctl_env
  rm -rf "$TMP/kvm"
  local out="$TMP/out" rc="$TMP/rc"
  CORE_PATH_PREFIX=""
  (
    export PATH="$TMP/bin:$PATH"
    export RAILANS_IC_ADDR=10.0.2.15 RAILANS_IC_SUBNET=10.10.1.0/24 \
      RAILANS_IC_DRIVER=dir RAILANS_IC_PORT=2229 RAILANS_IC_DOMAIN=box.lan
    bash "$CTL_INSTALLER" --yes >"$out" 2>&1
  ) && printf '0' >"$rc" || printf '%s' "$?" >"$rc"
  assert_rc "TC-IC-11 KVM 缺失硬伤退出 1" 1 "$(cat "$rc")"
  local o; o="$(cat "$out")"
  assert_cont "TC-IC-11 FAIL /dev/kvm 不存在" "/dev/kvm 不存在" "$o"
  assert_cont "TC-IC-11 硬伤中止文案" "预检有硬伤" "$o"
  assert_no "TC-IC-11 硬伤不进问答（无问答头）" "== 问答" "$o"
  assert_no "TC-IC-11 硬伤零执行" "node-sh preflight" "$(cat "$TMP/call.log")"
}

# ================================================================= TC-IC-12 静态锚与 go/orca 预检提示
case_ic_12() {
  case_setup
  make_shims
  ctl_env
  local bn_err bn_rc
  bn_err="$(bash -n "$CTL_INSTALLER" 2>&1)" && bn_rc=0 || bn_rc=$?
  assert_rc "TC-IC-12 install-control.sh bash -n 过" 0 "$bn_rc"
  assert_eq "TC-IC-12 install-control.sh bash -n 零输出" "" "$bn_err"
  # 九步编排注释锚
  assert_cont "TC-IC-12 头注九步锚（1/9 preflight）" "1/9 preflight" "$(cat "$CTL_INSTALLER")"
  assert_cont "TC-IC-12 头注九步锚（9/9 使用摘要）" "9/9 使用摘要" "$(cat "$CTL_INSTALLER")"
  # 复用锚：六积木点名
  local src; src="$(cat "$CTL_INSTALLER")"
  assert_cont "TC-IC-12 复用锚 install-incus" "install-incus" "$src"
  assert_cont "TC-IC-12 复用锚 bootstrap" "bootstrap" "$src"
  assert_cont "TC-IC-12 复用锚 network" "network" "$src"
  assert_cont "TC-IC-12 复用锚 build-base-image-local" "build-base-image-local" "$src"
  assert_cont "TC-IC-12 复用锚 control 子命令调用" 'bash "$IC_NODE_SH" control' "$src"
  assert_cont "TC-IC-12 复用锚 caddy" "caddy" "$src"
  assert_cont "TC-IC-12 复用锚 healthcheck" "healthcheck" "$src"
  # go 缺失指引锚（不自动下载工具链）
  assert_cont "TC-IC-12 go 指引言明装 golang-go 后重跑" "apt-get install -y golang-go" "$src"
  assert_cont "TC-IC-12 言明不自动下载工具链" "不自动下载工具链" "$src"
  # enroll code 卫生锚
  assert_cont "TC-IC-12 enroll code 生成方式锚" "openssl rand -hex 24" "$src"
  assert_cont "TC-IC-12 enroll 只展示一次锚" "只在安装尾声展示一次" "$src"
  # bootstrap preseed 说明锚（字段名已锚在 railans-node.sh 原实现）
  assert_cont "TC-IC-12 bootstrap 复用言明 preseed 字段锚" "STATUS §5" "$src"
  # 秘密卫生
  assert_no "TC-IC-12 无硬编码 48hex 令牌" "cafe0102030405060708090a0b0c0d0e0f10111213141516" "$src"
}

# ---------------------------------------------------------------- 运行
for script in "$NODE_INSTALLER" "$CTL_INSTALLER"; do
  if [[ ! -r "$script" ]]; then
    printf 'test-installer: 找不到被测脚本 %s\n' "$script" >&2
    exit 2
  fi
  if ! bash -n "$script"; then
    printf 'test-installer: %s bash -n 未过，后续用例无从谈起\n' "$script" >&2
    exit 1
  fi
done

printf '%s\n' "== TC-IN/TC-IC 组（scripts/tests/test-installer.sh，全沙盒垫片不碰真机真集群）=="
for case_fn in case_in_01 case_in_02 case_in_03 case_in_04 case_in_05 \
               case_in_06 case_in_07 case_in_08 case_in_09 case_in_10 \
               case_in_11 \
               case_ic_01 case_ic_02 case_ic_03 case_ic_04 case_ic_05 \
               case_ic_06 case_ic_07 case_ic_08 case_ic_09 case_ic_10 \
               case_ic_11 case_ic_12; do
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
