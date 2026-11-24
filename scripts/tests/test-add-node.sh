#!/usr/bin/env bash
# scripts/tests/test-add-node.sh — add-node 八步编排子命令断言组
#
# 唯一事实源：node/railans-node.sh 的 subcmd_add_node 实现 + docs/runbook.md §5.1 用法；
# 镜像统一 local 构建 + copy 分发。
#
# 隔离承诺（硬红线）：
#   - 不 ssh 真实节点、不碰真 incus：全部远端/集群调用经 PATH 沙盒垫片（$TMP/bin），
#     ssh/scp/rsync/incus/systemctl/sudo/ssh-keyscan/ip 一律落 $TMP/call.log；
#   - config.yaml 追加与备份只发生在 mktemp -d 沙盒文件上，绝不触碰
#     /etc/railans、<kit>/.local-test；
#   - 干跑用例断言调用日志为空（零接触）；真机路径（预检/编排真跑）属变更窗口，
#     本脚本不代跑；
#   - join preseed 的 token 是秘密：断言生成器形态用假 token，产物不外传。
#
# 垫片手法：
#   harness 经 `source railans-node.sh help`（只跑 usage，子命令不执行）取得被测函数，
#   与生产同源零复制；subcmd_add_node 在 PATH 沙盒下调用，incus 垫片有状态
#   （cluster add 落 AN_MOCK_STATE，cluster list 回放——覆盖 ONLINE 等待循环真路径）。
#
# 环境依赖注明：TC-AN-12（config 缺席退路）假设开发机无 /etc/railans/config.yaml 且
# worktree 无 .local-test/（若存在则 SKIP 注明，对齐 test-nft-render 的 nft SKIP 先例）。

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

# ---- 沙盒与垫片 ----

case_setup() {
  cleanup
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-add-node.XXXXXX")"
  mkdir -p "$TMP/bin"
}

# PATH 沙盒垫片：全部远端/集群调用落日志，绝不触真
make_shims() {  # [with_ip]  — 传 with_ip 时加 ip 垫片（TC-AN-12 退路用例）
  cat >"$TMP/bin/ssh" <<'EOF'
#!/bin/sh
echo "ssh $*" >> "$AN_LOG"
if [ -n "${AN_SSH_FAIL:-}" ]; then exit 1; fi
isnew=0
for a in "$@"; do
  case "$a" in
    capacity) cat "$AN_FIXTURE_DIR/capacity.json"; exit 0 ;;
    new) isnew=1 ;;
    --json) if [ "$isnew" = "1" ]; then cat "$AN_FIXTURE_DIR/newbox.json"; exit 0; fi ;;
  esac
done
case "$*" in
  *"ip -4 route get"*)
    echo "mock 192.168.1.254 via 192.168.1.1 dev mocketh0 src ${AN_MOCK_ROUTE_SRC:-192.168.1.15}"
    ;;
  *) exit 0 ;;
esac
exit 0
EOF
  cat >"$TMP/bin/scp" <<'EOF'
#!/bin/sh
echo "scp $*" >> "$AN_LOG"
exit 0
EOF
  cat >"$TMP/bin/rsync" <<'EOF'
#!/bin/sh
echo "rsync $*" >> "$AN_LOG"
exit 0
EOF
  cat >"$TMP/bin/incus" <<'EOF'
#!/bin/sh
echo "incus $*" >> "$AN_LOG"
case "$1 $2" in
  "cluster add")
    printf '%s\n' "$3" >> "$AN_MOCK_STATE"
    echo "mock-join-token-abc.def123"
    ;;
  "cluster list")
    printf 'node1,https://192.168.1.11:8443,ONLINE,LEADER,-,ONLINE,x86_64\n'
    printf 'node2,https://192.168.1.12:8443,ONLINE,-,ONLINE,ONLINE,x86_64\n'
    if [ -f "$AN_MOCK_STATE" ]; then
      while IFS= read -r n; do
        printf '%s,https://192.168.1.15:8443,ONLINE,-,ONLINE,ONLINE,x86_64\n' "$n"
      done < "$AN_MOCK_STATE"
    fi
    ;;
  "query /1.0")
    echo '{"config": {}, "server_name": "mock-self", "environment": {"driver": ["qemu"]}}'
    ;;
esac
  exit 0
EOF
  cat >"$TMP/bin/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$AN_LOG"
case "$1 $2" in
  "cat railans.service") echo "[Unit]"; echo "[Service]" ;;
  "is-active railans") echo active ;;
esac
exit 0
EOF
  cat >"$TMP/bin/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "$AN_LOG"
while [ "${1:-}" = "-n" ]; do shift; done
exec "$@"
EOF
  cat >"$TMP/bin/ssh-keyscan" <<'EOF'
#!/bin/sh
echo "ssh-keyscan $*" >> "$AN_LOG"
echo "[127.0.0.1]:22005 ssh-ed25519 AAAAmockhostkey"
EOF
  if [[ "${1:-}" == "with_ip" ]]; then
    cat >"$TMP/bin/ip" <<'EOF'
#!/bin/sh
echo "ip $*" >> "$AN_LOG"
case "$*" in
  "-4 route show")
    printf '10.10.2.0/24 via 192.168.1.12 dev enp3s0\n'
    printf '10.10.3.0/24 via 192.168.1.13 dev enp3s0\n'
    ;;
  *"-brief addr show br-vm"*)
    printf 'br-vm  UP  10.10.1.1/24\n'
    ;;
  *"-4 route get"*)
    printf '192.168.1.0/24 dev enp3s0 src 192.168.1.11\n'
    ;;
esac
exit 0
EOF
  fi
  chmod 755 "$TMP"/bin/*
}

# 控制面 config fixture（含 nodes 块后的顶层键，验 awk 块终止）
make_config_fixture() {  # [无listen] — 传 any 时 listen 行缺席
  cat >"$TMP/config.yaml" <<'EOF'
listen: ":2229"
control_host: "new.box.lan"
public_host: "192.168.1.11"
preview_domain: "box.lan"
state_file: "/var/lib/railans/state.json"
nodes:
  - name: node1
    address: "192.168.1.11"
    subnet: "10.10.1.0/24"
    gateway: "10.10.1.1"
  - name: node2
    address: "192.168.1.12"
    subnet: "10.10.2.0/24"
    gateway: "10.10.2.1"
  - name: node3
    address: "192.168.1.13"
    subnet: "10.10.3.0/24"
    gateway: "10.10.3.1"
limits:
  max_boxes: 12
EOF
}

make_json_fixtures() {
  cat >"$TMP/newbox.json" <<'EOF'
{
  "box": "box-mock001",
  "state": "running",
  "node": "node5",
  "vm_ip": "10.10.5.10",
  "ssh": "ssh -p 22005 dev@new.box.lan",
  "ssh_port": 22005,
  "ssh_host": "new.box.lan",
  "preview": "https://box-mock001.box.lan",
  "expires": "2026-12-01T00:00:00Z",
  "shared": false
}
EOF
  cat >"$TMP/newbox-wrongnode.json" <<'EOF'
{
  "box": "box-mock002",
  "state": "running",
  "node": "node1",
  "vm_ip": "10.10.1.10",
  "ssh": "ssh -p 22001 dev@new.box.lan",
  "ssh_port": 22001,
  "ssh_host": "new.box.lan",
  "preview": "https://box-mock002.box.lan",
  "expires": "2026-12-01T00:00:00Z",
  "shared": false
}
EOF
  cat >"$TMP/capacity.json" <<'EOF'
{
  "boxes_total": 3,
  "boxes_max": 12,
  "available": 9,
  "nodes": [],
  "port_range": [22000, 22999]
}
EOF
}

# 被测调用：subcmd_add_node 在 PATH 沙盒 + 环境注入下跑；输出/退出码落文件。
# 用法：run_addnode <输出文件> <rc文件> [add-node 参数...]（允许带字面量 add-node 头，
# 垫片会剥掉——用例读起来与 CLI 用法一致；函数直调不经过 main 分发）。
run_addnode() {
  local outf="$1" rcf="$2"
  shift 2
  local -a args=("$@")
  if [[ "${args[0]:-}" == "add-node" ]]; then
    args=("${args[@]:1}")
  fi
  (
    export PATH="$TMP/bin:$PATH"
    export TMPDIR="$TMP"
    export AN_LOG="$TMP/call.log" AN_FIXTURE_DIR="$TMP" AN_MOCK_STATE="$TMP/cluster-state"
    export RAILANS_CONFIG="${RAILANS_CONFIG:-$TMP/config.yaml}"
    : >"$AN_LOG"
    bash -c '
      set -euo pipefail
      source "$1" help >/dev/null
      subcmd_add_node "${@:2}"
    ' runner "$NODE_SCRIPT" "${args[@]}" >"$outf" 2>&1
  ) && printf '0' >"$rcf" || printf '%s' "$?" >"$rcf"
}

# add-node 区段源码（TC-AN-07/14 静态锚用；段界=add-node 头注 到 入口标记）
an_section() {
  sed -n '/^# ===== subcommand: add-node/,/^# ===== 入口 =====/p' "$NODE_SCRIPT"
}

# ================================================================= TC-AN-01 参数校验（usage/rc=2 契约）
case_an_01() {
  case_setup
  make_config_fixture
  make_shims
  local out rc
  run_addnode "$TMP/out" "$TMP/rc"
  assert_rc "TC-AN-01 零参数退出 2" 2 "$(cat "$TMP/rc")"
  assert_cont "TC-AN-01 零参数打印用法" "用法: railans-node.sh add-node" "$(cat "$TMP/out")"
  run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.15 node5
  assert_rc "TC-AN-01 两位置参数退出 2" 2 "$(cat "$TMP/rc")"
  run_addnode "$TMP/out" "$TMP/rc" add-node 192.168.1.15 node5 10.10.5.0/24
  assert_rc "TC-AN-01 目标机无 @ 退出 2" 2 "$(cat "$TMP/rc")"
  assert_cont "TC-AN-01 目标机报错点名 user@host" "user@host" "$(cat "$TMP/out")"
  run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.15 5node 10.10.5.0/24
  assert_rc "TC-AN-01 成员名数字开头退出 2" 2 "$(cat "$TMP/rc")"
  run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.15 node5 10.10.5.0/8
  assert_rc "TC-AN-01 网段非 /24 退出 2" 2 "$(cat "$TMP/rc")"
  assert_cont "TC-AN-01 网段报错点名 x.x.x.0/24" "x.x.x.0/24" "$(cat "$TMP/out")"
  run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.15 node5 10.10.5.0/24 --addr not-an-ip
  assert_rc "TC-AN-01 --addr 非 IPv4 退出 2" 2 "$(cat "$TMP/rc")"
  run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.15 node5 10.10.5.0/24 --from-step 9
  assert_rc "TC-AN-01 --from-step 越界退出 2" 2 "$(cat "$TMP/rc")"
  run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.15 node5 10.10.5.0/24 --wat
  assert_rc "TC-AN-01 未知选项退出 2" 2 "$(cat "$TMP/rc")"
  assert_cont "TC-AN-01 未知选项回显" "--wat" "$(cat "$TMP/out")"
  run_addnode "$TMP/out" "$TMP/rc" add-node --help
  assert_rc "TC-AN-01 --help 退出 0" 0 "$(cat "$TMP/rc")"
  assert_cont "TC-AN-01 --help 含 --from-step 说明" "--from-step" "$(cat "$TMP/out")"
  # 校验路径不发起任何连接（垫片日志必须为空）
  assert_eq "TC-AN-01 参数校验零调用（垫片日志空）" "" "$(cat "$TMP/call.log" 2>/dev/null || true)"
}

# ================================================================= TC-AN-02 干跑计划快照（零接触）
case_an_02() {
  case_setup
  make_config_fixture
  make_shims
  cp "$TMP/config.yaml" "$TMP/config.before"
  run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.15 node5 10.10.5.0/24
  local out; out="$(cat "$TMP/out")"
  assert_rc "TC-AN-02 干跑退出 0" 0 "$(cat "$TMP/rc")"
  assert_cont "TC-AN-02 计划头言明干跑零接触" "干跑：未连任何节点、未改任何状态" "$out"
  assert_cont "TC-AN-02 成员来源=config.yaml" "成员来源 控制面 config.yaml" "$out"
  assert_cont "TC-AN-02 目标机行" "目标机:   ops@192.168.1.15" "$out"
  assert_cont "TC-AN-02 NODE_ADDR 取 host IPv4 字面量" "NODE_ADDR: 192.168.1.15" "$out"
  assert_cont "TC-AN-02 网关推导 .1" "网关 10.10.5.1" "$out"
  assert_cont "TC-AN-02 第 1 步计划在" "== 1/8 预检" "$out"
  assert_cont "TC-AN-02 第 3 步 preseed 字段名锚" "cluster_token/server_address/cluster_address" "$out"
  assert_cont "TC-AN-02 第 3 步 server_address 形态" "server_address=192.168.1.15:8443" "$out"
  assert_cont "TC-AN-02 第 4 步镜像分发命令" \
    "incus image copy dev-base local: --target node5" "$out"
  assert_cont "TC-AN-02 第 5 步言明备份+原子替换+重启" "备份" "$out"
  assert_cont "TC-AN-02 第 6 步老节点全列" \
    "node2（192.168.1.12）rsync kit + ROUTES=10.10.1.0/24 via 192.168.1.11;10.10.3.0/24 via 192.168.1.13;10.10.5.0/24 via 192.168.1.15 重跑 network" "$out"
  assert_cont "TC-AN-02 第 7 步验收箱计划" "断言 node==node5" "$out"
  assert_cont "TC-AN-02 第 8 步汇总计划在" "== 8/8 汇总" "$out"
  assert_cont "TC-AN-02 干跑收尾" "干跑结束" "$out"
  # ROUTES 自动推导快照（别让用户手写）
  assert_cont "TC-AN-02 新节点 ROUTES 三对端全推导" \
    "ROUTES    = 10.10.1.0/24 via 192.168.1.11;10.10.2.0/24 via 192.168.1.12;10.10.3.0/24 via 192.168.1.13" "$out"
  # 零接触：垫片日志空
  assert_eq "TC-AN-02 干跑零调用（垫片日志空）" "" "$(cat "$TMP/call.log" 2>/dev/null || true)"
  cmp -s "$TMP/config.before" "$TMP/config.yaml" \
    && t_ok "TC-AN-02 干跑不改 config.yaml" \
    || t_fail "TC-AN-02 干跑动了 config.yaml"
  assert_eq "TC-AN-02 干跑不留 preseed/tmpf 残留" "" \
    "$(find "$TMP" -name 'addnode-preseed.*' -o -name '*.addnode.*' 2>/dev/null | head -1 || true)"
}

# ================================================================= TC-AN-03 preseed 生成器（字段名锚）
case_an_03() {
  case_setup
  make_shims
  local ps
  ps="$(bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_gen_preseed node5 "TOK.abc-123" 192.168.1.15 /var/lib/incus/storage-pools/default
  ' runner "$NODE_SCRIPT")"
  # 字段名坑锚（incus join preseed 实测）：cluster_token（非 join_token/token）
  assert_cont "TC-AN-03 server_name 锚" "server_name: node5" "$ps"
  assert_cont "TC-AN-03 cluster_token 字段名锚" "cluster_token: TOK.abc-123" "$ps"
  assert_no "TC-AN-03 无 join_token 错字段名" "join_token" "$ps"
  assert_cont "TC-AN-03 server_address=<本成员addr>:8443" "server_address: 192.168.1.15:8443" "$ps"
  assert_cont "TC-AN-03 cluster_address=<本成员addr>:8443" "cluster_address: 192.168.1.15:8443" "$ps"
  assert_cont "TC-AN-03 dir 池" "driver: dir" "$ps"
  assert_cont "TC-AN-03 dir 池缺省路径" "source: /var/lib/incus/storage-pools/default" "$ps"
  assert_cont "TC-AN-03 集群块 enabled" "enabled: true" "$ps"
  ps="$(bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_gen_preseed node9 "TOK" 192.168.1.16 /data/incus-pool
  ' runner "$NODE_SCRIPT")"
  assert_cont "TC-AN-03 --pool-dir 自定义路径落 source" "source: /data/incus-pool" "$ps"
  assert_cont "TC-AN-03 另一 addr 全落 8443" "server_address: 192.168.1.16:8443" "$ps"
}

# ================================================================= TC-AN-04 ROUTES 推导纯函数
case_an_04() {
  case_setup
  make_config_fixture
  make_shims
  local rows routes
  rows="$(bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_parse_config_nodes "'"$TMP/config.yaml"'"
  ' runner "$NODE_SCRIPT")"
  assert_eq "TC-AN-04 config 解析三行（含引号剥离）" \
    "node1	192.168.1.11	10.10.1.0/24	10.10.1.1
node2	192.168.1.12	10.10.2.0/24	10.10.2.1
node3	192.168.1.13	10.10.3.0/24	10.10.3.1" "$rows"
  routes="$(bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_routes_for_new "'"$rows"'" 10.10.5.0/24
  ' runner "$NODE_SCRIPT")"
  assert_eq "TC-AN-04 新节点 ROUTES（分号串、序=config 序）" \
    "10.10.1.0/24 via 192.168.1.11;10.10.2.0/24 via 192.168.1.12;10.10.3.0/24 via 192.168.1.13" "$routes"
  routes="$(bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_routes_for_old 192.168.1.12 "'"$rows"'" 10.10.5.0/24 192.168.1.15
  ' runner "$NODE_SCRIPT")"
  assert_eq "TC-AN-04 老节点 ROUTES（排除自身+新成员追加尾）" \
    "10.10.1.0/24 via 192.168.1.11;10.10.3.0/24 via 192.168.1.13;10.10.5.0/24 via 192.168.1.15" "$routes"
  # 退路成员表纯函数：自身行用管理地址（非 br-vm 网关地址）
  rows="$(bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_members_from_routes "10.10.2.0/24 via 192.168.1.12 dev enp3s0
10.10.3.0/24 via 192.168.1.13 dev enp3s0" 10.10.1.1/24 node1 192.168.1.11
  ' runner "$NODE_SCRIPT")"
  assert_eq "TC-AN-04 退路成员表：自身行=管理地址、对端行=路由表同源" \
    "node1	192.168.1.11	10.10.1.0/24	10.10.1.1
192.168.1.12	192.168.1.12	10.10.2.0/24	10.10.2.1
192.168.1.13	192.168.1.13	10.10.3.0/24	10.10.3.1" "$rows"
  rows="$(bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_members_from_routes "x" "" node1 "" && echo OK || echo EMPTY
  ' runner "$NODE_SCRIPT")"
  assert_eq "TC-AN-04 退路成员表：br 地址/自身地址缺失 loud fail" "EMPTY" "$rows"
  # 同网段行不进路由（重跑残留防）
  routes="$(bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_routes_for_new "node5	192.168.1.15	10.10.5.0/24	10.10.5.1" 10.10.5.0/24
  ' runner "$NODE_SCRIPT")"
  assert_eq "TC-AN-04 新网段残留行被剔除" "" "$routes"
}

# ================================================================= TC-AN-05 config 追加器（备份外置、校验、幂等）
case_an_05() {
  case_setup
  make_config_fixture
  make_shims
  cp "$TMP/config.yaml" "$TMP/config.before"
  bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_config_append "'"$TMP/config.yaml"'" "'"$TMP/config.new"'" node5 192.168.1.15 10.10.5.0/24 10.10.5.1
  ' runner "$NODE_SCRIPT" >/dev/null 2>&1
  assert_rc "TC-AN-05 追加退出 0" 0 "$?"
  cmp -s "$TMP/config.before" "$TMP/config.yaml" \
    && t_ok "TC-AN-05 原文件逐字节不动（文件→文件）" \
    || t_fail "TC-AN-05 原文件被改写"
  assert_cont "TC-AN-05 追加条目 name 行" "  - name: node5" "$(cat "$TMP/config.new")"
  assert_cont "TC-AN-05 追加条目 address 带引号" "    address: \"192.168.1.15\"" "$(cat "$TMP/config.new")"
  assert_cont "TC-AN-05 追加条目 subnet" "    subnet: \"10.10.5.0/24\"" "$(cat "$TMP/config.new")"
  assert_cont "TC-AN-05 追加条目 gateway" "    gateway: \"10.10.5.1\"" "$(cat "$TMP/config.new")"
  assert_eq "TC-AN-05 不传 max-boxes 条目无 max_boxes 行（旧形态逐字一致）" "0" \
    "$(grep -c '^    max_boxes' "$TMP/config.new" || true)"
  assert_cont "TC-AN-05 追加插在 nodes 块尾（limits 块仍在其后）" \
    "    gateway: \"10.10.3.1\"
  - name: node5
    address: \"192.168.1.15\"
    subnet: \"10.10.5.0/24\"
    gateway: \"10.10.5.1\"
limits:" "$(cat "$TMP/config.new")"
  # 带 --max-boxes 追加（内部任务单接线）：条目尾多一行 max_boxes
  bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_config_append "'"$TMP/config.yaml"'" "'"$TMP/config.mb"'" node6 192.168.1.16 10.10.6.0/24 10.10.6.1 6
  ' runner "$NODE_SCRIPT" >/dev/null 2>&1
  assert_cont "TC-AN-05 带 max_boxes 条目尾行" \
    "    gateway: \"10.10.6.1\"
    max_boxes: 6
limits:" "$(cat "$TMP/config.mb")"
  # 校验器（第 5 参 want_mb）：带期望→条目须含 max_boxes: N；不带→忽略该行（幂等兼容）
  bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_config_validate "'"$TMP/config.mb"'" node6 192.168.1.16 10.10.6.0/24 6
    addnode_config_validate "'"$TMP/config.mb"'" node6 192.168.1.16 10.10.6.0/24
  ' runner "$NODE_SCRIPT" >/dev/null 2>&1
  assert_rc "TC-AN-05 校验带期望 6 过" 0 "$?"
  bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_config_validate "'"$TMP/config.mb"'" node6 192.168.1.16 10.10.6.0/24 7
  ' runner "$NODE_SCRIPT" >/dev/null 2>&1
  assert_rc "TC-AN-05 校验期望 7 不过（值不符）" 1 "$?"
  bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_config_validate "'"$TMP/config.new"'" node5 192.168.1.15 10.10.5.0/24 6
  ' runner "$NODE_SCRIPT" >/dev/null 2>&1
  assert_rc "TC-AN-05 校验带期望但条目无 max_boxes 不过" 1 "$?"
  # 校验器：追加产物过、原文件不过、缺 gateway 不过
  bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_config_validate "'"$TMP/config.new"'" node5 192.168.1.15 10.10.5.0/24
  ' runner "$NODE_SCRIPT" >/dev/null 2>&1
  assert_rc "TC-AN-05 追加产物校验过" 0 "$?"
  bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_config_validate "'"$TMP/config.yaml"'" node5 192.168.1.15 10.10.5.0/24
  ' runner "$NODE_SCRIPT" >/dev/null 2>&1
  assert_rc "TC-AN-05 原文件（无 node5）校验不过" 1 "$?"
  grep -v 'gateway: "10.10.5.1"' "$TMP/config.new" >"$TMP/config.broken"
  bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_config_validate "'"$TMP/config.broken"'" node5 192.168.1.15 10.10.5.0/24
  ' runner "$NODE_SCRIPT" >/dev/null 2>&1
  assert_rc "TC-AN-05 缺 gateway 校验不过" 1 "$?"
  # 幂等：同名再追加非 0 且不产出（config.new 保留——上面首轮已写入 node5）
  bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_config_append "'"$TMP/config.new"'" "'"$TMP/config.new2"'" node5 192.168.1.15 10.10.5.0/24 10.10.5.1
  ' runner "$NODE_SCRIPT" >/dev/null 2>&1
  assert_rc "TC-AN-05 同名幂等非 0" 1 "$?"
  assert_eq "TC-AN-05 幂等失败不产出目标文件" "" \
    "$(cat "$TMP/config.new2" 2>/dev/null || true)"
  bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_config_append "'"$TMP/nonexistent.yaml"'" "'"$TMP/x"'" node9 1.2.3.4 10.10.9.0/24 10.10.9.1
  ' runner "$NODE_SCRIPT" >/dev/null 2>&1
  assert_rc "TC-AN-05 无 nodes 块文件追加非 0" 1 "$?"
  # has_node 与 ctl_port
  bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_config_has_node "'"$TMP/config.new"'" node5 && echo HAS
    addnode_config_has_node "'"$TMP/config.new"'" node9 || echo NO9
    addnode_ctl_port "'"$TMP/config.yaml"'"
  ' runner "$NODE_SCRIPT" >"$TMP/out" 2>&1
  assert_cont "TC-AN-05 has_node 命中" "HAS" "$(cat "$TMP/out")"
  assert_cont "TC-AN-05 has_node 未命中" "NO9" "$(cat "$TMP/out")"
  assert_cont "TC-AN-05 ctl_port 解析 :2229" "2229" "$(cat "$TMP/out")"
  printf 'listen: ":22"\nnodes:\n  - name: node1\n    address: "1.1.1.1"\n' >"$TMP/c22.yaml"
  assert_eq "TC-AN-05 ctl_port :22" "22" \
    "$(bash -c '
      set -euo pipefail
      source "$1" help >/dev/null
      addnode_ctl_port '"$TMP/c22.yaml"'
    ' runner "$NODE_SCRIPT")"
  printf 'nodes:\n  - name: n1\n    address: "1.1.1.1"\n' >"$TMP/cnol.yaml"
  assert_eq "TC-AN-05 ctl_port 缺 listen 缺省 22" "22" \
    "$(bash -c '
      set -euo pipefail
      source "$1" help >/dev/null
      addnode_ctl_port '"$TMP/cnol.yaml"'
    ' runner "$NODE_SCRIPT")"
}

# ================================================================= TC-AN-06 地址/WAN 推导（INFRA_NET 锚）
case_an_06() {
  case_setup
  make_shims
  local out
  out="$(bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    r="10.10.2.0/24 dev enp3s0 src 192.168.1.12"
    printf "src=%s\n" "$(addnode_src_from_route "$r")"
    printf "dev=%s\n" "$(addnode_dev_from_route "$r")"
    printf "empty_src=%s\n" "$(addnode_src_from_route "unreachable")"
  ' runner "$NODE_SCRIPT")"
  assert_cont "TC-AN-06 src 推导" "src=192.168.1.12" "$out"
  assert_cont "TC-AN-06 dev 推导" "dev=enp3s0" "$out"
  assert_cont "TC-AN-06 空输出得空 src" "empty_src=" "$out"
  # INFRA_NET 教训锚：add-node 区段从对端路由推导，全程禁默认路由（1.1.1.1/8.8.8.8）
  local sec; sec="$(an_section)"
  assert_cont "TC-AN-06 区段含对端路由推导" 'ip -4 route get' "$sec"
  assert_no "TC-AN-06 区段无 1.1.1.1 默认路由推导" "1.1.1.1" "$sec"
  assert_no "TC-AN-06 区段无 8.8.8.8 默认路由推导" "8.8.8.8" "$sec"
  assert_cont "TC-AN-06 区段言明禁用默认路由" "禁用默认路由" "$sec"
}

# ================================================================= TC-AN-07 失败中断与续跑提示
case_an_07() {
  case_setup
  make_config_fixture
  make_shims
  export AN_SSH_FAIL=1
  run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.15 node5 10.10.5.0/24 --yes
  unset AN_SSH_FAIL
  local out; out="$(cat "$TMP/out")"
  assert_rc "TC-AN-07 第 1 步 ssh 失败整体退出 1" 1 "$(cat "$TMP/rc")"
  assert_cont "TC-AN-07 FAIL 行点名步骤" "FAIL 第 1/8 步（预检）" "$out"
  assert_cont "TC-AN-07 断点行" "断点：停在 第 1/8 步" "$out"
  # 续跑语义=从失败步重放（该步幂等，前序步骤自动跳过）
  assert_cont "TC-AN-07 续跑命令含原参数且从失败步重放" \
    "railans-node.sh add-node ops@192.168.1.15 node5 10.10.5.0/24 --from-step 1 --yes" "$out"
  assert_cont "TC-AN-07 幂等保护说明" "前面已完成步骤均有幂等保护" "$out"
}

# ================================================================= TC-AN-08 全链执行（--yes，全垫片）
case_an_08() {
  case_setup
  make_config_fixture
  make_json_fixtures
  make_shims
  cp "$TMP/config.yaml" "$TMP/config.before"
  run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.15 node5 10.10.5.0/24 --yes
  local out rc; out="$(cat "$TMP/out")"; rc="$(cat "$TMP/rc")"
  assert_rc "TC-AN-08 全链退出 0" 0 "$rc"
  assert_cont "TC-AN-08 执行模式计划头" "执行模式（--yes）" "$out"
  # 第 1 步预检真实发生
  assert_cont "TC-AN-08 预检 ssh 探活已调" "ops@192.168.1.15 true" "$(cat "$TMP/call.log")"
  assert_cont "TC-AN-08 免密 sudo 探测已调" "ops@192.168.1.15 sudo -n true" "$(cat "$TMP/call.log")"
  assert_cont "TC-AN-08 预检 PASS 行" "PASS ssh BatchMode 通" "$out"
  # 第 2 步 deploy-remote 复用（白名单变量 + --yes）
  assert_cont "TC-AN-08 deploy-remote 侧 deploy 已调" \
    "sudo env NODE_NAME=node5" "$(cat "$TMP/call.log")"
  assert_cont "TC-AN-08 deploy-remote 后 PASS" "deploy-remote 完成" "$out"
  assert_cont "TC-AN-08 WAN 从对端路由推导（非缺省）" \
    "ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new ops@192.168.1.15 ip -4 route get 192.168.1.11" \
    "$(cat "$TMP/call.log")"
  # 第 3 步 preseed 链路
  assert_cont "TC-AN-08 cluster add 取 token 已调" "incus cluster add node5" "$(cat "$TMP/call.log")"
  assert_cont "TC-AN-08 preseed scp 至远端固定名" "join-node5.yaml" "$(cat "$TMP/call.log")"
  assert_cont "TC-AN-08 远程 admin init --preseed 已调" "admin init --preseed < /tmp/join-node5.yaml" "$(cat "$TMP/call.log")"
  assert_cont "TC-AN-08 远端 token 文件随命令清理" "rm -f /tmp/join-node5.yaml" "$(cat "$TMP/call.log")"
  assert_no "TC-AN-08 token 不回显进输出" "mock-join-token" "$out"
  assert_cont "TC-AN-08 ONLINE 等待 PASS" "成员 node5 ONLINE" "$out"
  # 第 4 步镜像分发
  assert_cont "TC-AN-08 image copy --target 已调" "incus image copy dev-base local: --target node5" "$(cat "$TMP/call.log")"
  # 第 5 步 config 安全追加 + 重启
  assert_cont "TC-AN-08 config 已追加 PASS" "config 已安全追加 node5" "$out"
  assert_cont "TC-AN-08 控制面重启（systemd）" "systemctl restart railans" "$(cat "$TMP/call.log")"
  assert_cont "TC-AN-08 config 含 node5 条目" "  - name: node5" "$(cat "$TMP/config.yaml")"
  assert_cont "TC-AN-08 config 含 subnet" "    subnet: \"10.10.5.0/24\"" "$(cat "$TMP/config.yaml")"
  assert_no "TC-AN-08 不传 --max-boxes 条目不落 max_boxes（旧形态兼容）" "max_boxes: " "$(grep '    max_boxes' "$TMP/config.yaml" 2>/dev/null || true)"
  assert_eq "TC-AN-08 节点数 3→4" "4" "$(bash -c '
    set -euo pipefail
    source "'"$NODE_SCRIPT"'" help >/dev/null
    addnode_parse_config_nodes "'"$TMP/config.yaml"'" | grep -c .
  ' runner "$NODE_SCRIPT")"
  assert_eq "TC-AN-08 备份文件恰好生成一份" "1" "$(find "$TMP" -maxdepth 1 -name 'config.yaml.bak.*' | wc -l)"
  assert_cont "TC-AN-08 备份内容=原文件" "max_boxes: 12" "$(cat "$TMP"/config.yaml.bak.*)"
  # 第 6 步老节点路由补全（ROUTES 经 %q 转义——空格变 \，字面判定用转义形态）
  assert_cont "TC-AN-08 老节点 network 重跑已调" "bash /tmp/railans-kit/node/railans-node.sh network" "$(cat "$TMP/call.log")"
  assert_cont "TC-AN-08 新网段进老节点 ROUTES（%q 后仍可判）" '10.10.5.0/24\ via\ 192.168.1.15' "$(cat "$TMP/call.log")"
  assert_cont "TC-AN-08 老节点补全 PASS（node1）" "老节点 node1（192.168.1.11）已补 10.10.5.0/24 via 192.168.1.15" "$out"
  assert_cont "TC-AN-08 老节点补全 PASS（node3）" "老节点 node3（192.168.1.13）已补 10.10.5.0/24 via 192.168.1.15" "$out"
  # 第 7 步验收
  assert_cont "TC-AN-08 healthcheck --all 汇总" "3 台检查，0 台有 FAIL" "$out"
  assert_cont "TC-AN-08 验收箱落新节点断言" "验收箱 box-mock001 落在 node5" "$out"
  assert_cont "TC-AN-08 数据面 keyscan 抽测已调" "ssh-keyscan -T 10 -p 22005 127.0.0.1" "$(cat "$TMP/call.log")"
  assert_cont "TC-AN-08 验收箱已删（rm）" "rm box-mock001" "$(cat "$TMP/call.log")"
  # 第 8 步汇总
  assert_cont "TC-AN-08 端口池余量（capacity）" "available=9 / boxes_max=12" "$out"
  assert_cont "TC-AN-08 后续手工事项=无" "后续手工事项: 无" "$out"
  assert_cont "TC-AN-08 完成行" "add-node 完成：node5（192.168.1.15）已入集群并接线" "$out"
  # 秘密与临时文件卫生
  assert_eq "TC-AN-08 无 preseed 本地残留" "" \
    "$(find "$TMP" -name 'addnode-preseed.*' 2>/dev/null | head -1 || true)"
  assert_eq "TC-AN-08 无 tmpf 残留（已 mv 成 config）" "" \
    "$(find "$TMP" -maxdepth 1 -name '*.addnode.*' 2>/dev/null | head -1 || true)"
}

# ================================================================= TC-AN-09 验收箱落错节点（负向，断言+清理+断点）
case_an_09() {
  case_setup
  make_config_fixture
  make_json_fixtures
  make_shims
  cp "$TMP/newbox-wrongnode.json" "$TMP/newbox.json"
  run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.15 node5 10.10.5.0/24 --yes
  local out; out="$(cat "$TMP/out")"
  assert_rc "TC-AN-09 验收箱落错节点整体退出 1" 1 "$(cat "$TMP/rc")"
  assert_cont "TC-AN-09 落点断言 FAIL 点名实际落点" "FAIL 验收箱落在 node1（期望 node5）" "$out"
  assert_cont "TC-AN-09 落错也走 rm 清理" "rm box-mock002" "$(cat "$TMP/call.log")"
  assert_cont "TC-AN-09 断点停在第 7 步" "FAIL 第 7/8 步（验收）" "$out"
  assert_cont "TC-AN-09 续跑指回 --from-step 7" "--from-step 7 --yes" "$(cat "$TMP/out")"
}

# ================================================================= TC-AN-10 --skip-verify + --max-boxes（接线落 config 并注明）
case_an_10() {
  case_setup
  make_config_fixture
  make_json_fixtures
  make_shims
  run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.15 node5 10.10.5.0/24 --yes --skip-verify --max-boxes 6
  local out; out="$(cat "$TMP/out")"
  assert_rc "TC-AN-10 跳验收 + 接线 quota 全链退出 0" 0 "$(cat "$TMP/rc")"
  assert_cont "TC-AN-10 计划言明 max-boxes 将落 config" \
    "--max-boxes 6: 将写入 config 节点条目 max_boxes 字段（per-node 静态上限；动态地板下是保底）" "$out"
  assert_cont "TC-AN-10 计划言明验收箱将跳过" "--skip-verify: 验收箱段将跳过" "$out"
  assert_cont "TC-AN-10 healthcheck 仍跑" "3 台检查，0 台有 FAIL" "$out"
  assert_no "TC-AN-10 验收箱未建（无 new --json）" "new --json" "$(cat "$TMP/call.log")"
  assert_no "TC-AN-10 验收箱未建（无 keyscan）" "ssh-keyscan" "$(cat "$TMP/call.log")"
  assert_cont "TC-AN-10 汇总注明跳过验收" "已 --skip-verify：未建验收箱" "$out"
  assert_cont "TC-AN-10 汇总注明 per-node 上限已落 config" \
    "per-node 上限: max_boxes=6（已落 config 节点条目；配了动态余量地板后静态上限是保底）" "$out"
  assert_cont "TC-AN-10 config 含 node5 条目" "  - name: node5" "$(cat "$TMP/config.yaml")"
  assert_cont "TC-AN-10 --max-boxes 落节点条目 max_boxes 字段" "    max_boxes: 6" "$(cat "$TMP/config.yaml")"
  assert_no "TC-AN-10 有事项时不得打「无」" "后续手工事项: 无" "$out"
}

# ================================================================= TC-AN-11 成员表退路（config 缺席→本机路由表）
case_an_11() {
  case_setup
  if [[ -r /etc/railans/config.yaml || -r "$HERE/../../.local-test/config.yaml" ]]; then
    t_ok "TC-AN-11 SKIP：开发机存在真 config（/etc/railans 或 .local-test），退路路径无法在沙盒隔离，注明不跑"
    return 0
  fi
  make_shims with_ip
  printf '# 无 nodes 块的占位配置（模拟 RAILANS_CONFIG 指到非控制面文件）\nlisten: ":22"\n' >"$TMP/no-nodes.yaml"
  RAILANS_CONFIG="$TMP/no-nodes.yaml" run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.15 node5 10.10.5.0/24
  local out; out="$(cat "$TMP/out")"
  # 干跑宽大语义：config 缺席只 WARN，计划走完全程（执行时第 5 步才会断点）
  assert_rc "TC-AN-11 退路干跑完整走完（rc 0）" 0 "$(cat "$TMP/rc")"
  assert_cont "TC-AN-11 成员来源=路由表" "成员来源 本机路由表+br-vm" "$out"
  assert_cont "TC-AN-11 退路 ROUTES 含对端两条（对端管理地址非 br 网关）" \
    "ROUTES    = 10.10.1.0/24 via 192.168.1.11;10.10.2.0/24 via 192.168.1.12;10.10.3.0/24 via 192.168.1.13" "$out"
  assert_cont "TC-AN-11 config 缺席 WARN（候选清单）" \
    "config 未找到（候选：RAILANS_CONFIG > /etc/railans/config.yaml > <kit>/.local-test/config.yaml）" "$out"
  assert_cont "TC-AN-11 WARN 言明执行时会停" "执行时第 5 步将在此停住" "$out"
  assert_cont "TC-AN-11 计划仍走完到第 8 步" "== 8/8 汇总" "$out"
  assert_cont "TC-AN-11 干跑收尾在" "干跑结束" "$out"
  assert_cont "TC-AN-11 ip 调用落日志（只读本机）" "ip -4 route show" "$(cat "$TMP/call.log")"
}

# ================================================================= TC-AN-12 --from-step 断点续跑（跳步+幂等）
case_an_12() {
  case_setup
  make_config_fixture
  make_json_fixtures
  make_shims
  # 模拟前四步已完成的现场：config 已含 node5、cluster state 已有 node5（ONLINE）
  bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_config_append "'"$TMP/config.yaml"'" "'"$TMP/config.new"'" node5 192.168.1.15 10.10.5.0/24 10.10.5.1 && mv "'"$TMP/config.new"'" "'"$TMP/config.yaml"'"
  ' runner "$NODE_SCRIPT" >/dev/null 2>&1
  printf 'node5\n' >"$TMP/cluster-state"
  run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.15 node5 10.10.5.0/24 --yes --from-step 5
  local out; out="$(cat "$TMP/out")"
  assert_rc "TC-AN-12 续跑退出 0" 0 "$(cat "$TMP/rc")"
  assert_cont "TC-AN-12 第 1 步标记跳过" "-- 跳过第 1/8 步（--from-step 5 续跑）--" "$out"
  assert_cont "TC-AN-12 第 3 步同样跳过（不重发 token/join）" "-- 跳过第 3/8 步（--from-step 5 续跑）--" "$out"
  assert_cont "TC-AN-12 第 4 步标记跳过" "-- 跳过第 4/8 步（--from-step 5 续跑）--" "$out"
  # 预检探活是唯一 ConnectTimeout=10 + target true 形态（healthcheck 探活是 =5，可区分）
  assert_no "TC-AN-12 跳过步不发起预检（无探活调用）" \
    "ConnectTimeout=10 -o StrictHostKeyChecking=accept-new ops@192.168.1.15 true" "$(cat "$TMP/call.log")"
  assert_no "TC-AN-12 跳过步不重复上架（无 deploy）" "railans-node.sh deploy" "$(cat "$TMP/call.log")"
  assert_cont "TC-AN-12 第 5 步幂等跳过追加" "config 已含 node5 且值一致（幂等跳过追加）" "$out"
  assert_cont "TC-AN-12 幂等跳过后控制面仍重启（接线生效）" "systemctl restart railans" "$(cat "$TMP/call.log")"
  assert_cont "TC-AN-12 续跑直达汇总" "add-node 完成：node5（192.168.1.15）已入集群并接线" "$out"
  assert_eq "TC-AN-12 node5 条目不重复" "1" "$(grep -c '^  - name: node5$' "$TMP/config.yaml")"
}

# ================================================================= TC-AN-13 门禁：登记完整性 + 既有锚零漂移
case_an_13() {
  case_setup
  make_shims
  local bn_err bn_rc help_out sec
  bn_err="$(bash -n "$NODE_SCRIPT" 2>&1)" && bn_rc=0 || bn_rc=$?
  assert_rc "TC-AN-13 bash -n 过" 0 "$bn_rc"
  assert_eq "TC-AN-13 bash -n 零输出" "" "$bn_err"
  help_out="$(PATH="$TMP/bin:$PATH" bash "$NODE_SCRIPT" help 2>&1)"
  assert_cont "TC-AN-13 help 清单含 add-node" "add-node" "$help_out"
  assert_cont "TC-AN-13 头部子命令注释表含 add-node" "add-node" "$(grep '^#   add-node' "$NODE_SCRIPT")"
  assert_cont "TC-AN-13 main 分发含独立 add-node 分支" \
    "    add-node)" "$(cat "$NODE_SCRIPT")"
  assert_cont "TC-AN-13 既有锚 | setup-subuid) 零漂移（test-subid TC-W4-10）" "| setup-subuid)" \
    "$(grep -F '| setup-subuid)' "$NODE_SCRIPT")"
  assert_cont "TC-AN-13 既有锚 | verify-nft | setup-subuid) 零漂移（test-nft-render TC-H1-06）" \
    "| verify-nft | setup-subuid)" "$(grep -F '| verify-nft | setup-subuid)' "$NODE_SCRIPT")"
  assert_eq "TC-AN-13 subcmd_add_node 定义恰一处" "1" \
    "$(grep -c '^subcmd_add_node()' "$NODE_SCRIPT" || true)"
  sec="$(an_section)"
  assert_cont "TC-AN-13 区段含 preseed 字段名锚 cluster_token" "cluster_token" "$sec"
  assert_cont "TC-AN-13 区段言明变量白名单/%q 复用" "%q" "$sec"
  assert_cont "TC-AN-13 区段言明 --yes 干跑语义" "--yes" "$sec"
  assert_eq "TC-AN-13 区段含八步编排注释" "8" \
    "$(grep -c '^#   [1-8] ' <<<"$sec")"
  unk_out="$(PATH="$TMP/bin:$PATH" bash "$NODE_SCRIPT" definitely-not-a-cmd 2>&1)" && unk_rc=0 || unk_rc=$?
  assert_rc "TC-AN-13 未知子命令退出 2（既有报错路径不回归）" 2 "$unk_rc"
  assert_cont "TC-AN-13 未知子命令报错不回归" "未知子命令" "$unk_out"
  assert_cont "TC-AN-13 add-node 分支接 subcmd_add_node" 'subcmd_add_node "$@"' "$(cat "$NODE_SCRIPT")"
}

# ================================================================= TC-AN-14 --max-boxes 接线幂等/失配（内部任务单）
case_an_14() {
  case_setup
  make_config_fixture
  make_json_fixtures
  make_shims
  # 现场一：config 已含 node5 条目且 max_boxes=6（上次带 --max-boxes 跑过）→ 同值重跑幂等跳过
  bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_config_append "'"$TMP/config.yaml"'" "'"$TMP/config.new"'" node5 192.168.1.15 10.10.5.0/24 10.10.5.1 6 && mv "'"$TMP/config.new"'" "'"$TMP/config.yaml"'"
  ' runner "$NODE_SCRIPT" >/dev/null 2>&1
  cp "$TMP/config.yaml" "$TMP/config.before"
  run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.15 node5 10.10.5.0/24 --yes --skip-verify --max-boxes 6
  local out; out="$(cat "$TMP/out")"
  assert_rc "TC-AN-14 同值重跑退出 0" 0 "$(cat "$TMP/rc")"
  assert_cont "TC-AN-14 同值重跑幂等跳过追加" "config 已含 node5 且值一致（幂等跳过追加）" "$out"
  assert_eq "TC-AN-14 幂等重跑 config 不重复不改动" "1" "$(grep -c '^  - name: node5$' "$TMP/config.yaml")"
  cmp -s "$TMP/config.before" "$TMP/config.yaml" \
    && t_ok "TC-AN-14 幂等重跑 config 逐字节不动" \
    || t_fail "TC-AN-14 幂等重跑动了 config"

  # 现场二：config 已含 node5 条目但无 max_boxes，--max-boxes 6 重跑 → 失配 loud fail，config 不动
  bash -c '
    set -euo pipefail
    source "$1" help >/dev/null
    addnode_config_append "'"$TMP/config.yaml"'" "'"$TMP/config.new"'" node6 192.168.1.16 10.10.6.0/24 10.10.6.1 && mv "'"$TMP/config.new"'" "'"$TMP/config.yaml"'"
  ' runner "$NODE_SCRIPT" >/dev/null 2>&1
  cp "$TMP/config.yaml" "$TMP/config.before6"
  run_addnode "$TMP/out" "$TMP/rc" add-node ops@192.168.1.16 node6 10.10.6.0/24 --yes --skip-verify --max-boxes 6
  out="$(cat "$TMP/out")"
  assert_rc "TC-AN-14 失配重跑退出 1" 1 "$(cat "$TMP/rc")"
  assert_cont "TC-AN-14 失配断点在第 5 步" "FAIL 第 5/8 步（控制面接线）" "$out"
  assert_cont "TC-AN-14 失配点名 max_boxes" "address/subnet/max_boxes 与期望不一致" "$out"
  cmp -s "$TMP/config.before6" "$TMP/config.yaml" \
    && t_ok "TC-AN-14 失配重跑 config 未动" \
    || t_fail "TC-AN-14 失配重跑动了 config"
}

# ---------------------------------------------------------------- 门禁 + 运行
if [[ ! -r "$NODE_SCRIPT" ]]; then
  printf 'test-add-node: 找不到被测脚本 %s\n' "$NODE_SCRIPT" >&2
  exit 2
fi
if ! bash -n "$NODE_SCRIPT"; then
  printf 'test-add-node: bash -n 未过，后续用例无从谈起\n' >&2
  exit 1
fi

printf '%s\n' "== TC-AN 组（scripts/tests/test-add-node.sh，全沙盒垫片不碰真机真集群）=="
for case_fn in case_an_01 case_an_02 case_an_03 case_an_04 case_an_05 \
               case_an_06 case_an_07 case_an_08 case_an_09 case_an_10 \
               case_an_11 case_an_12 case_an_13 case_an_14; do
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
