#!/usr/bin/env bash
# install-node.sh — railans 节点侧问答式安装器（唯一入口）
#
# 目标：用户跑 `sudo bash install-node.sh`，问答几个问题（有默认值、能探测的绝不
# 问），完成节点侧整侧安装。本脚本只做前端：环境探测 → 分流 → 计划摘要+确认门
# → 调用既有子命令。安装逻辑零重写，全部落在现成积木上：
#   node/railans-node.sh add-node   已有集群时节点侧首选路径（八步编排，含
#                                   deploy-remote 上架 + 集群入伙 + 镜像分发 +
#                                   控制面接线 + 老节点路由补全 + healthcheck --all）
#   node/railans-node.sh deploy     单机待命路径（装 incus + kvm 组 + 网络）
#   node/railans-node.sh healthcheck  收尾体检
#
# 分流（探测先行，能探测的绝不问）：
#   A. 已有控制面 → add-node 路径
#      - 本机即控制机（本机可读 config 且含 nodes 块）→ 本机直接 add-node（问目标机）
#      - 否则探测远端控制面（ssh -p <ctl> <user>@<gw> capacity，BatchMode）→
#        可达则经控制机管理 SSH 远端驱动 add-node（目标机=本机）
#   B. 无控制面且无集群 → 「这像是第一台机器，请用 install-control.sh」退出
#   C. 有 incus 但单机 → 问「是否入集群」：
#      - 是 → 给控制面地址再探测（探测不到给指引退出）
#      - 否 → 本地 deploy 单机待命 + healthcheck 收尾
#
# 环境变量（全部可选；前缀 IZ_ 为内部探测钩子，RAILANS_ 为用户预设）：
#   RAILANS_CTL_HOST    控制面地址（缺省探测：本机默认网关）
#   RAILANS_CTL_PORTS   控制面端口候选（缺省 "22 2229"）
#   RAILANS_ADMIN_PORT  控制机管理 SSH 端口（缺省按映射：ctl=22→2200，否则 22）
#   RAILANS_SSH_USER    ssh 探测/驱动用户（缺省候选 SUDO_USER/当前用户/git/ops）
#   RAILANS_CTL_KIT     控制机上 kit 路径（缺省探测 /tmp/railans-kit、~/railans-kit）
#   RAILANS_NODE_TARGET add-node 目标机（缺省 <sudo用户>@<本机管理IP>）
#   IZ_KVM_PATH         KVM 探测路径钩子（缺省 /dev/kvm，测试用）
#
# 测试：scripts/tests/test-installer.sh（stdin 喂答案 / fake ip·route·ssh 垫片，
# 不碰真机真集群）。问答探测纯函数（iz_ 前缀）可独立断言。

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || printf '%s' "${PWD}")"

if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'
else
  C_RST=''; C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''
fi

IZ_NODE_SH="${RAILANS_NODE_SH:-${SCRIPT_DIR}/node/railans-node.sh}"
IZ_KVM_PATH="${IZ_KVM_PATH:-/dev/kvm}"

# ============================================================
# 纯函数（可单测：输入全部来自参数/文本，不做任何系统调用）
# ============================================================

# 从 `ip -4 addr show dev <nic>` 输出取第一个 IPv4（无则空）。
iz_ip_from_addr() {
  sed -n 's/.*inet[[:space:]]\+\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/p' <<<"$1" | head -1
}

# 管理网卡：默认路由 dev 优先（`ip route` 输出），回退输出里第一个 inet 的归属网卡。
iz_mgmt_nic() {
  local dev=''
  dev="$(awk '/default/ {print $5; exit}' <<<"$1")"
  [[ -n "$dev" ]] || dev="$(sed -n 's/^[0-9]*:[[:space:]]*\([^@[:space:]]*\):.*/\1/p' <<<"$2" | grep -vx 'lo' | head -1)"
  printf '%s' "$dev"
}

# 管理 IP：<网卡> 的 addr 输出优先，回退全量 addr 输出里第一个非 127. 地址。
iz_mgmt_ip() {
  local nic_out="$1" all_out="$2" ip=''
  ip="$(iz_ip_from_addr "$nic_out")"
  if [[ -z "$ip" ]]; then
    ip="$(sed -n 's/.*inet[[:space:]]\+\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/p' <<<"$all_out" \
      | grep -v '^127\.' | head -1)"
  fi
  printf '%s' "$ip"
}

# WAN 网卡推导（INFRA_NET 教训：只用集群对端路由，禁用默认路由推导）。
# 参数：<`ip -4 route show` 输出>（找形如 "<cidr> via <gw> dev <nic>" 的对端
# 路由取 dev；default 行一律跳过）。无对端路由 → 空串（调用方转为提问，
# 绝不静默拿默认路由网卡充当 WAN）。
iz_derive_wan() {
  local rl='' dev=''
  while IFS= read -r rl; do
    if [[ "$rl" == "default"* ]]; then continue; fi
    if [[ "$rl" != *" via "* ]]; then continue; fi
    dev="$(sed -nE 's/.*[[:space:]]dev[[:space:]]([^[:space:]]+).*/\1/p' <<<"$rl" | head -1)"
    if [[ -n "$dev" ]]; then
      printf '%s' "$dev"
      return 0
    fi
  done <<<"$1"
  printf '%s'
}

# 子网网关：x.x.x.0/24 → x.x.x.1（%.* 去尾段）。
iz_gateway_of() {
  awk -F. '{print $1"."$2"."$3".1"}' <<<"${1%/*}"
}

# 管理网 /24：a.b.c.d → a.b.c.0/24（形态异常返回空）。
iz_mgmt_cidr() {
  local cidr="${1%.*}.0/24"
  if [[ "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.0/24$ ]]; then
    printf '%s' "$cidr"
  fi
}

iz_valid_subnet() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){2}\.0/24$ ]]
}

iz_valid_name() {
  [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,62}$ ]]
}

iz_valid_target() {
  [[ "$1" == *@* && "$1" != *[[:space:]]* ]]
}

iz_valid_nic() {
  [[ -n "$1" ]]
}

# mesh 网段冲突：与既有路由（`ip -4 route show` 输出）或管理网 /24 相撞则返回
# 冲突描述，无冲突返回空。
iz_route_conflict() {
  local subnet="$1" routes="$2" mgmt="$3" rl=''
  if [[ -n "$mgmt" && "$subnet" == "$mgmt" ]]; then
    printf '与管理网段 %s 重合（VM mesh 不能复用管理网）' "$mgmt"
    return 0
  fi
  while IFS= read -r rl; do
    [[ "$rl" == "$subnet "* ]] || continue
    printf '与既有路由冲突: %s' "$rl"
    return 0
  done <<<"$routes"
  printf '%s'
}

# control面 端口 → 控制机管理 sshd 端口映射（install-control 同款行为：
# 占 22 则系统 sshd 挪 2200；控制面不在 22 则 sshd 留在 22）。
iz_admin_port() {
  if [[ "$1" == "22" ]]; then printf '2200'; else printf '22'; fi
}

# capacity JSON（控制面 CLI 输出）→ 成员名清单（每行一个）。
iz_capacity_names() {
  sed -n 's/^[[:space:]]*"node"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$1"
}

# 成员名清单 → 下一成员名缺省（node<N> 形态取最大 N+1；否则按成员数+1）。
iz_next_name() {
  local names="$1" max=0 n num
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    num=''
    if [[ "$n" =~ ^node([0-9]+)$ ]]; then
      num="${BASH_REMATCH[1]}"
    fi
    if [[ -n "$num" ]] && ((num > max)); then
      max="$num"
    fi
  done <<<"$names"
  local count=0
  count="$(grep -c . <<<"$names" 2>/dev/null || true)"
  if ((max > 0)); then
    printf 'node%s' "$((max + 1))"
  else
    printf 'node%s' "$((count + 1))"
  fi
}

# 成员数 → 下一 mesh 子网缺省：10.10.<N+1>.0/24（README 约定：每节点一个 /24）。
iz_next_subnet() {
  local count="$1"
  printf '10.10.%s.0/24' "$((count + 1))"
}

# config.yaml nodes 块 → "name<TAB>addr<TAB>subnet<TAB>gw" 行流（与
# railans-node.sh addnode_parse_config_nodes 同款只读解析）。
iz_parse_nodes() {
  awk '
    /^nodes:[[:space:]]*(#.*)?$/ { inb = 1; next }
    inb && /^[[:space:]]*#/ { next }
    inb && /^[A-Za-z_]/ { exit }
    inb && /^  - name:/ {
      if (n != "") printf "%s\t%s\t%s\t%s\n", n, a, s, g
      n = $0; sub(/^  - name:[[:space:]]*/, "", n); gsub(/"/, "", n)
      a = ""; s = ""; g = ""
      next
    }
    inb && /^    address:/ { a = $0; sub(/^    address:[[:space:]]*/, "", a); gsub(/"/, "", a); next }
    inb && /^    subnet:/  { s = $0; sub(/^    subnet:[[:space:]]*/, "", s);  gsub(/"/, "", s);  next }
    inb && /^    gateway:/ { g = $0; sub(/^    gateway:[[:space:]]*/, "", g); gsub(/"/, "", g); next }
    END { if (inb && n != "") printf "%s\t%s\t%s\t%s\n", n, a, s, g }
  ' "$1" 2>/dev/null
}

# ============================================================
# 问答助手（stdin 喂答案；EOF 取默认，绝不定死）
# ============================================================

IZ_EOF=0

# iz_ask <提示> <默认值> → stdout 输出选定值；提示走 stderr。
iz_ask() {
  local ans=''
  printf '%s [%s]: ' "$1" "$2" >&2
  IZ_EOF=0
  if ! IFS= read -r ans; then
    IZ_EOF=1
    ans=''
  fi
  ans="${ans%$'\r'}"
  if [[ -z "$ans" ]]; then
    ans="$2"
  fi
  printf '%s' "$ans"
}

# 带校验循环：非法输入重问；EOF 后仍非法则报错退出（绝不死循环）。
iz_ask_checked() {  # <提示> <默认> <校验函数名> <错误说明>
  local v
  while :; do
    v="$(iz_ask "$1" "$2")"
    if "$3" "$v"; then
      printf '%s' "$v"
      return 0
    fi
    if ((IZ_EOF == 1)); then
      { printf '\n'; printf '输入流已结束且默认值不可用（%s），中止。\n' "$4"; } >&2
      exit 2
    fi
    printf '  %s!%s %s\n' "$C_WARN" "$C_RST" "$4" >&2
  done
}

# 确认门：回车=放弃（缺省 N），仅 y/Y 通过。
iz_confirm() {
  local ans=''
  printf '%s [y/N]: ' "$1" >&2
  if ! IFS= read -r ans; then ans=''; fi
  ans="${ans%$'\r'}"
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# ============================================================
# 探测（只读；ssh 探测全程 BatchMode，绝不弹密码）
# ============================================================

# ssh 以发起用户的身份跑（sudo bash 场景借 SUDO_USER 的 HOME 找钥匙）。
iz_ssh() {
  local home=''
  if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then
    home="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || true)"
    if [[ -n "$home" ]]; then
      HOME="$home" exec ssh "$@"
    fi
  fi
  ssh "$@"
}

# ssh 用户候选链（与 healthcheck 的候选链同源）。
iz_ssh_users() {
  local u
  for u in "${RAILANS_SSH_USER:-}" "${SUDO_USER:-}" "$(id -un)" git ops; do
    if [[ -n "$u" ]]; then
      printf '%s\n' "$u"
    fi
  done | awk '!seen[$0]++'
}

# 控制面探测：ssh -p <port> <user>@<host> capacity（BatchMode）。
# 命中 → 全局 IZ_CTL_PORT / IZ_CTL_USER / IZ_CAP_JSON，返回 0。
iz_probe_control() {
  local host="$1" port='' user='' out=''
  for port in ${RAILANS_CTL_PORTS:-22 2229}; do
    for user in $(iz_ssh_users); do
      if out="$(iz_ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        -p "$port" "${user}@${host}" capacity 2>/dev/null </dev/null)" \
        && grep -q '"available"' <<<"$out"; then
        IZ_CTL_PORT="$port"
        IZ_CTL_USER="$user"
        IZ_CAP_JSON="$out"
        return 0
      fi
    done
  done
  return 1
}

# 控制机管理 SSH 探测（远端驱动 add-node 的通道；与控制面 CLI 是两个端口面）。
# 命中 → 全局 IZ_ADMIN_PORT / IZ_ADMIN_USER，返回 0。
iz_probe_admin() {
  local host="$1" ports=() port='' user=''
  if [[ -n "${RAILANS_ADMIN_PORT:-}" ]]; then
    ports=("${RAILANS_ADMIN_PORT}")
  else
    mapfile -t ports < <(printf '%s\n' 2200 22)
  fi
  for port in "${ports[@]}"; do
    for user in $(iz_ssh_users); do
      if iz_ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        -p "$port" "${user}@${host}" true >/dev/null 2>&1 </dev/null; then
        IZ_ADMIN_PORT="$port"
        IZ_ADMIN_USER="$user"
        return 0
      fi
    done
  done
  return 1
}

# 控制机上 kit 路径探测。命中 → 全局 IZ_CTL_KIT，返回 0。
iz_probe_kit() {
  local host="$1" port="$2" k
  for k in "${RAILANS_CTL_KIT:-}" /tmp/railans-kit '~/railans-kit'; do
    [[ -n "$k" ]] || continue
    if iz_ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      -p "$port" "${IZ_ADMIN_USER}@${host}" "test -d ${k}/node" >/dev/null 2>&1 </dev/null; then
      IZ_CTL_KIT="$k"
      return 0
    fi
  done
  return 1
}

# 本机即控制机判定：可读 config 且含 nodes 块（RAILANS_CONFIG > /etc/railans >
# <kit>/.local-test，与 add-node an_find_config 同候选）。命中 → 全局 IZ_LOCAL_CONFIG。
iz_find_local_config() {
  local c
  for c in "${RAILANS_CONFIG:-}" /etc/railans/config.yaml "${SCRIPT_DIR}/.local-test/config.yaml"; do
    [[ -n "$c" && -r "$c" ]] || continue
    if [[ -n "$(iz_parse_nodes "$c")" ]]; then
      IZ_LOCAL_CONFIG="$c"
      return 0
    fi
  done
  return 1
}

# 环境探测报告（免提，全只读）。副作用：全局 IZ_MGMT_NIC / IZ_MGMT_IP / IZ_WAN /
# IZ_HAS_INCUS / IZ_ROUTE_OUT。
iz_probe_env() {
  local route_out='' addr_all='' nic_out='' mem="" disk_used='' kvm='no'
  route_out="$(ip -4 route show 2>/dev/null || true)"
  addr_all="$(ip -4 addr show 2>/dev/null || true)"
  IZ_ROUTE_OUT="$route_out"
  IZ_MGMT_NIC="$(iz_mgmt_nic "$route_out" "$addr_all")"
  nic_out=''
  if [[ -n "$IZ_MGMT_NIC" ]]; then
    nic_out="$(ip -4 addr show dev "$IZ_MGMT_NIC" 2>/dev/null || true)"
  fi
  IZ_MGMT_IP="$(iz_mgmt_ip "$nic_out" "$addr_all")"
  # WAN：仅认集群对端路由（INFRA_NET 教训，禁用默认路由推导）；无 → 空（转入提问）
  IZ_WAN="$(iz_derive_wan "$route_out")"
  if [[ -e "$IZ_KVM_PATH" ]]; then
    kvm='yes'
  fi
  IZ_HAS_INCUS=0
  if command -v incus >/dev/null 2>&1; then
    IZ_HAS_INCUS=1
  fi
  mem="$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || true)"
  disk_used="$(df -P / 2>/dev/null | awk 'NR == 2 {gsub(/%/, "", $5); print $5}' || true)"
  echo "== 环境探测（免提）=="
  printf '  KVM:         %s\n' "$kvm"
  printf '  内存:        %s MiB\n' "${mem:-未知}"
  printf '  磁盘 /:      已用 %s%%\n' "${disk_used:-未知}"
  printf '  管理网卡:    %s（%s）\n' "${IZ_MGMT_NIC:-未知}" "${IZ_MGMT_IP:-未知}"
  printf '  WAN(对端路由推导): %s\n' "${IZ_WAN:-（未探测到，后续按需提问）}"
  if ((IZ_HAS_INCUS == 1)); then
    printf '  incus:       已安装\n'
  else
    printf '  incus:       未安装\n'
  fi
}

# ============================================================
# 分流与主流程
# ============================================================

iz_branch_first_machine() {
  cat <<EOF
${C_WARN}这像是第一台机器${C_RST}（探测不到可达控制面，本机也无集群）：
请用 install-control.sh 安装控制端（入口节点），之后再回来跑本脚本加节点。

  sudo bash install-control.sh

提示：若集群其实已存在，多半是本机公钥还没在控制面 enroll——
先在控制面 enroll 本机公钥，或在控制机上直接跑 add-node。
EOF
  exit 0
}

# sudo 自检（brief 第 3 步）：非 root 且 sudo -n 不过 → 提示后退出。
iz_require_sudo() {
  if [[ ${EUID} -eq 0 ]]; then
    return 0
  fi
  if sudo -n true >/dev/null 2>&1; then
    return 0
  fi
  echo "请用 sudo bash 运行本脚本（后续步骤需要 root：装 incus / 配网络 / healthcheck）。" >&2
  exit 1
}

# 计划摘要 + 确认门；放弃 → exit 0（干净取消，零副作用）。
iz_plan_and_confirm() {
  local mode="$1"
  echo
  echo "== 安装计划（${mode}）=="
  cat <<<"$2"
  echo
  if ! iz_confirm "确认按以上计划执行?"; then
    echo "已取消：未改任何状态。重跑本脚本可重新开始。"
    exit 0
  fi
}

# 收尾：本机 healthcheck（提醒性质；权威门槛是 add-node 第 7 步的 --all）。
iz_final_healthcheck() {
  local sh="$IZ_NODE_SH"
  if [[ ! -r "$sh" && -r /tmp/railans-kit/node/railans-node.sh ]]; then
    sh=/tmp/railans-kit/node/railans-node.sh
  fi
  if [[ ! -r "$sh" ]]; then
    echo "（跳过本机 healthcheck：找不到 railans-node.sh）"
    return 0
  fi
  echo
  echo "== 收尾：本机 healthcheck（只读；入口侧 healthcheck --all 为准）=="
  if [[ ${EUID} -eq 0 ]]; then
    bash "$sh" healthcheck || { printf '%sWARN%s 本机 healthcheck 有 FAIL（见上；按输出排障）。\n' "$C_WARN" "$C_RST"; return 0; }
  else
    sudo -n bash "$sh" healthcheck || { printf '%sWARN%s 本机 healthcheck 有 FAIL（见上；按输出排障）。\n' "$C_WARN" "$C_RST"; return 0; }
  fi
}

# ---- 路径 A：add-node（本机即控制机 → 本机驱动）----
iz_path_addnode_local() {
  local target='' name='' subnet='' rows='' count=0
  rows="$(iz_parse_nodes "$IZ_LOCAL_CONFIG")"
  count="$(grep -c . <<<"$rows" || true)"
  iz_require_sudo
  echo
  echo "本机即控制机（config: ${IZ_LOCAL_CONFIG}，${count} 个成员）→ add-node 路径。"
  target="$(iz_ask_checked '目标机 user@host（例 ops@192.168.1.15）' '' iz_valid_target '目标机要写成 user@host（例 ops@192.168.1.15）')"
  name="$(iz_ask_checked '新成员名' "$(iz_next_name "$(cut -f1 <<<"$rows")")" iz_valid_name '成员名要字母开头、字母数字-_、≤63')"
  subnet="$(iz_ask_checked '该节点 VM 网段' "$(iz_next_subnet "$count")" iz_valid_subnet '网段要写成 x.x.x.0/24（例 10.10.5.0/24）')"
  iz_plan_and_confirm "add-node（本机驱动）" "
  目标机:   ${target}
  成员名:   ${name}
  VM 网段:  ${subnet}（网关 $(iz_gateway_of "$subnet")）
  ROUTES:   由 add-node 按既有成员自动推导（不用手写）
  将执行:   bash node/railans-node.sh add-node ${target} ${name} ${subnet} --yes
            （八步编排：预检→deploy-remote 上架→集群入伙→镜像分发→控制面接线
             →老节点路由补全→healthcheck --all→汇总）"
  echo
  bash "$IZ_NODE_SH" add-node "$target" "$name" "$subnet" --yes
  iz_final_healthcheck
  echo
  echo "完成：${name} 已入集群并接线（详细汇总见上方 add-node 第 8/8 步）。"
}

# ---- 路径 A：add-node（远端控制机驱动，目标机=本机）----
iz_path_addnode_remote() {  local name='' subnet='' target='' count=0 names=''
  iz_require_sudo
  names="$(iz_capacity_names "$IZ_CAP_JSON")"
  count="$(grep -c . <<<"$names" || true)"
  echo
  echo "探测到控制面（${IZ_CTL_USER}@${IZ_CTL_HOST}:${IZ_CTL_PORT}，${count} 个成员）→ add-node 路径（经控制机远端驱动）。"
  target="${RAILANS_NODE_TARGET:-${SUDO_USER:-$(id -un)}@${IZ_MGMT_IP}}"
  name="$(iz_ask_checked '新成员名（本机在集群里的名字）' "$(iz_next_name "$names")" iz_valid_name '成员名要字母开头、字母数字-_、≤63')"
  subnet="$(iz_ask_checked '本节点 VM 网段' "$(iz_next_subnet "$count")" iz_valid_subnet '网段要写成 x.x.x.0/24（例 10.10.5.0/24）')"
  iz_plan_and_confirm "add-node（远端驱动：控制机 = ${IZ_ADMIN_USER}@<gw>:${IZ_ADMIN_PORT}，kit = ${IZ_CTL_KIT}）" "
  目标机:   ${target}（本机）
  成员名:   ${name}
  VM 网段:  ${subnet}（网关 $(iz_gateway_of "$subnet")）
  ROUTES:   由 add-node 按既有成员自动推导（不用手写）
  将执行:   ssh -p ${IZ_ADMIN_PORT} ${IZ_ADMIN_USER}@${IZ_CTL_HOST} \\
              'cd ${IZ_CTL_KIT} && ./node/railans-node.sh add-node ${target} ${name} ${subnet} --yes'
            （八步编排同本机驱动；控制机→本机需 SSH 公钥免密 + 免密 sudo，
             add-node 预检会断言并给断点指引）"
  echo
  iz_ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -p "$IZ_ADMIN_PORT" "${IZ_ADMIN_USER}@${IZ_CTL_HOST}" \
    "cd ${IZ_CTL_KIT} && ./node/railans-node.sh add-node ${target} ${name} ${subnet} --yes"
  iz_final_healthcheck
  echo
  echo "完成：${name} 已入集群并接线（详细汇总见上方 add-node 第 8/8 步）。"
}

# ---- 路径 C：单机待命（本地 deploy + healthcheck 收尾）----
iz_path_standalone() {
  local name='' subnet='' wan=''
  iz_require_sudo
  echo
  name="$(iz_ask_checked '节点名（单机待命，将来入集群沿用）' 'node1' iz_valid_name '成员名要字母开头、字母数字-_、≤63')"
  subnet="$(iz_ask_checked '本节点 VM 网段' '10.10.1.0/24' iz_valid_subnet '网段要写成 x.x.x.0/24（例 10.10.1.0/24）')"
  wan="$IZ_WAN"
  if [[ -z "$wan" ]]; then
    wan="$(iz_ask_checked '物理上联网卡（WAN）' "$(iz_mgmt_nic "$IZ_ROUTE_OUT" '')" iz_valid_nic '网卡名不能为空')"
  fi
  iz_plan_and_confirm "单机待命（本地 deploy；ROUTES 为空，将来入集群从入口侧驱动）" "
  节点名:   ${name}
  管理 IP:  ${IZ_MGMT_IP:-（deploy 会自行校验）}
  VM 网段:  ${subnet}（网关 $(iz_gateway_of "$subnet")）
  WAN:      ${wan}
  ROUTES:   （空——单节点）
  将执行:   env NODE_NAME=${name} NODE_ADDR=${IZ_MGMT_IP} SUBNET=${subnet} WAN=${wan} \\
              bash node/railans-node.sh deploy
            （装 incus[Zabbly]→incus 入 kvm 组→运维账号入 incus-admin→subuid
             →br-vm 网桥 + nftables 隔离 + 跨节点路由）"
  echo
  local -a pre=("NODE_NAME=${name}" "NODE_ADDR=${IZ_MGMT_IP}" "SUBNET=${subnet}" "WAN=${wan}" "ROUTES=")
  if [[ ${EUID} -eq 0 ]]; then
    env "${pre[@]}" bash "$IZ_NODE_SH" deploy
  else
    sudo -n env "${pre[@]}" bash "$IZ_NODE_SH" deploy
  fi
  iz_final_healthcheck
  echo
  echo "完成：${name} 单机待命就绪。将来入集群时从入口节点跑 install-node.sh / add-node 即可"
  echo "（deploy 各步幂等，入伙编排会复用本机现场）。"
}

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --help | -h)
        sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *)
        echo "install-node.sh: 不认识的参数 ${arg}（本脚本问答式，无需参数；--help 看说明）" >&2
        exit 2
        ;;
    esac
  done

  iz_probe_env

  # ---- 分流判定 ----
  if iz_find_local_config; then
    iz_path_addnode_local
    return 0
  fi

  IZ_CTL_HOST="${RAILANS_CTL_HOST:-$(awk '/default/ {print $3; exit}' <<<"${IZ_ROUTE_OUT:-}")}"
  if [[ -n "$IZ_CTL_HOST" ]] && iz_probe_control "$IZ_CTL_HOST"; then
    # 控制面 CLI 可达 → 远端驱动还需管理 SSH 通道 + 控制机上的 kit
    if ! iz_probe_admin "$IZ_CTL_HOST"; then
      cat >&2 <<EOF
${C_ERR}控制面可达（${IZ_CTL_USER}@${IZ_CTL_HOST}:${IZ_CTL_PORT}），但控制机管理 SSH 打不通。${C_RST}
远端驱动 add-node 需要：ssh -p <管理端口> <运维用户>@${IZ_CTL_HOST} 可公钥登录。
两个办法：
  a) 打通后重跑本脚本（管理端口缺省按 ${IZ_CTL_PORT} 映射：$(iz_admin_port "$IZ_CTL_PORT")）
  b) 直接在控制机上跑本脚本（本机即控制机 → 本机驱动 add-node）
EOF
      exit 1
    fi
    if ! iz_probe_kit "$IZ_CTL_HOST" "$IZ_ADMIN_PORT"; then
      cat >&2 <<EOF
${C_ERR}控制机 ${IZ_CTL_HOST} 上找不到 kit（试过 ${RAILANS_CTL_KIT:-/tmp/railans-kit、~/railans-kit}）。${C_RST}
add-node 在控制机上跑，需要 railans-kit 在场：先把 kit 放过去（RAILANS_CTL_KIT=<路径> 指认）。
EOF
      exit 1
    fi
    iz_path_addnode_remote
    return 0
  fi

  # ---- 无控制面 ----
  if ((IZ_HAS_INCUS == 0)); then
    iz_branch_first_machine
  fi

  # ---- 有 incus：单机？已是集群成员？ ----
  local members=''
  members="$(incus cluster list --format csv 2>/dev/null | grep -c . || true)"
  if ((members > 1)); then
    echo "本机已是集群成员（incus cluster list ${members} 成员）→ 无需安装。"
    echo "体检：sudo bash ${IZ_NODE_SH} healthcheck"
    exit 0
  fi

  echo
  echo "本机有 incus 但不是集群成员（单机）。"
  local join=''
  join="$(iz_ask '是否入集群（需要入口节点侧配合）?' 'y')"
  if [[ "$join" == "y" || "$join" == "Y" ]]; then
    local host=''
    host="$(iz_ask '控制面地址（入口节点 IP）' "$IZ_CTL_HOST")"
    IZ_CTL_HOST="$host"
    if iz_probe_control "$host"; then
      if ! iz_probe_admin "$host"; then
        cat >&2 <<EOF
${C_ERR}控制面可达，但控制机管理 SSH 打不通（远端驱动 add-node 需要它）。${C_RST}
打通 ssh -p $(iz_admin_port "$IZ_CTL_PORT") <运维用户>@${host} 后重跑；或在控制机上直接跑本脚本。
EOF
        exit 1
      fi
      if ! iz_probe_kit "$host" "$IZ_ADMIN_PORT"; then
        cat >&2 <<EOF
${C_ERR}控制机 ${host} 上找不到 kit——先把 railans-kit 放过去（RAILANS_CTL_KIT=<路径>）再重跑。${C_RST}
EOF
        exit 1
      fi
      iz_path_addnode_remote
      return 0
    fi
    cat >&2 <<EOF
${C_WARN}${host:-<控制面地址>} 上探测不到控制面（ssh capacity 不通）。${C_RST}
入集群由入口节点侧驱动：在入口节点跑 add-node / install-node.sh；
或核对控制面地址后重跑本脚本。本机先做单机待命部署也可以（下面选 n）。
EOF
    exit 1
  fi

  iz_path_standalone
}

main "$@"
