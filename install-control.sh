#!/usr/bin/env bash
# install-control.sh — railans 控制端（入口节点）问答式安装器（唯一入口）
#
# 目标：用户跑 `sudo bash install-control.sh`，问答几个问题（有默认值、能探测的
# 绝不问），完成控制端整侧安装。本脚本只做前端：预检 → 问答 → 计划摘要+确认门
# → 按序编排。安装逻辑零重写，全部落在现成积木上：
#   node/railans-node.sh preflight/install-incus/bootstrap/network/control/caddy/
#     healthcheck（bootstrap/control 内部 --preseed 字段名已锚 STATUS §5；
#     join 侧 cluster_token 等锚由 add-node 负责，首台机器不涉及）
#   scripts/build-base-image-local.sh（dev-base 镜像唯一构建入口；
#     RAILANS_ASSET_DIR=/var/lib/railans/assets 先建）
#   node/deploy/railans.service（M4 低权 unit，由 control 子命令落位）
#
# 九步编排（每步幂等，失败停住打印 --from-step 断点续跑命令）：
#   1/9 preflight          node 侧只读体检
#   2/9 incus + bootstrap  装 Incus（按存储驱动装依赖）→ 本机初始化成集群首成员
#   3/9 network            br-vm 网桥 + ip_forward + nftables（单节点 ROUTES 为空）
#   4/9 镜像构建           dev-base（幂等：已有镜像且未 RAILANS_IC_FORCE_IMAGE=1 则跳过）
#   5/9 控制面             config 渲染落盘（含 enroll code）→ railans-node.sh control
#                          （go 缺失时 control 自带指引：装 golang-go 后重跑，不自动下载工具链）
#   6/9 caddy + dnsmasq    预览反代 + 内网 DNS
#   7/9 systemd 收尾       补 /etc/caddy/conf.d 属组（control 的既定指引）→ 重启 → 断言双 unit active
#   8/9 healthcheck        断言式体检，全绿门槛
#   9/9 使用摘要           enroll / 建第一只箱指引；enroll code 只在此展示一次
#
# 用法：
#   sudo bash install-control.sh                # 问答式（每问回车=默认）
#   无人值守（答案全走环境变量 + --yes；可重定向日志）：
#     RAILANS_IC_ADDR=192.168.1.11 RAILANS_IC_SUBNET=10.10.1.0/24 \
#     RAILANS_IC_DRIVER=dir RAILANS_IC_PORT=22 RAILANS_IC_DOMAIN=box.lan \
#       sudo -E bash install-control.sh --yes
#   断点续跑（对齐 add-node --from-step 语义；答案仍走环境变量）：
#     RAILANS_IC_ADDR=... ... sudo -E bash install-control.sh --from-step 5 --yes
#
# 环境变量：
#   RAILANS_IC_ADDR / RAILANS_IC_SUBNET / RAILANS_IC_DRIVER / RAILANS_IC_PORT /
#     RAILANS_IC_DOMAIN   五问预设（--yes 时必填；交互模式预设了就跳过该问）
#   RAILANS_IC_WAN        WAN 网卡预设（缺省探测默认路由网卡；仅用于展示与透传）
#   RAILANS_IC_NODE_NAME  首成员名（缺省 node1）
#   RAILANS_IC_FORCE_IMAGE=1  跳过镜像幂等判定，强制重建 dev-base
#   ORCA_SRC              orca checkout（缺省 $HOME/orca；镜像构建第 5b 步需要）
# 测试钩子（env，测试注入沙盒路径用）：
#   IC_CONFIG_PATH / IC_KVM_PATH / IC_SYSTEMD_RUN / IC_CADDY_CONF_DIR
#   RAILANS_NODE_SH / RAILANS_BUILD_SH / RAILANS_ASSET_DIR
#
# 测试：scripts/tests/test-installer.sh（stdin 喂答案 / fake ip·ss·openssl·shim
# 垫片，编排顺序与断点全沙盒断言）。

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || printf '%s' "${PWD}")"

if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'
else
  C_RST=''; C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''
fi

IC_NODE_SH="${RAILANS_NODE_SH:-${SCRIPT_DIR}/node/railans-node.sh}"
IC_BUILD_SH="${RAILANS_BUILD_SH:-${SCRIPT_DIR}/scripts/build-base-image-local.sh}"
IC_CONFIG_PATH="${IC_CONFIG_PATH:-/etc/railans/config.yaml}"
IC_KVM_PATH="${IC_KVM_PATH:-/dev/kvm}"
IC_SYSTEMD_RUN="${IC_SYSTEMD_RUN:-/run/systemd/system}"
IC_CADDY_CONF_DIR="${IC_CADDY_CONF_DIR:-/etc/caddy/conf.d}"
IC_ASSET_DIR="${RAILANS_ASSET_DIR:-/var/lib/railans/assets}"
IC_FROM_STEP=1
IC_YES=0

# ============================================================
# 纯函数（可单测：输入全部来自参数/文本，不做任何系统调用）
# ============================================================

ic_gateway_of() {
  awk -F. '{print $1"."$2"."$3".1"}' <<<"${1%/*}"
}

# a.b.c.d → a.b.c.0/24（形态异常返回空）。
ic_mgmt_cidr() {
  local cidr="${1%.*}.0/24"
  if [[ "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.0/24$ ]]; then
    printf '%s' "$cidr"
  fi
}

ic_valid_addr() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

ic_valid_subnet() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){2}\.0/24$ ]]
}

ic_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

ic_valid_port() {
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    if ((10#$1 >= 1 && 10#$1 <= 65535)); then
      return 0
    fi
  fi
  return 1
}

ic_valid_driver() {
  case "$1" in
    dir | lvm | zfs) return 0 ;;
    *) return 1 ;;
  esac
}

ic_valid_nic() {
  [[ -n "$1" ]]
}

# 管理网卡：默认路由 dev 优先，回退第一个非 lo 网卡名。
ic_mgmt_nic() {
  local dev=''
  dev="$(awk '/default/ {print $5; exit}' <<<"$1")"
  if [[ -z "$dev" ]]; then
    dev="$(sed -n 's/^[0-9]*:[[:space:]]*\([^@[:space:]]*\):.*/\1/p' <<<"$2" | grep -vx 'lo' | head -1)"
  fi
  printf '%s' "$dev"
}

ic_ip_from_addr() {
  sed -n 's/.*inet[[:space:]]\+\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/p' <<<"$1" | head -1
}

# 管理 IP：<网卡> addr 输出优先，回退全量 addr 输出第一个非 127. 地址。
ic_mgmt_ip() {
  local ip=''
  ip="$(ic_ip_from_addr "$1")"
  if [[ -z "$ip" ]]; then
    ip="$(sed -n 's/.*inet[[:space:]]\+\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/p' <<<"$2" \
      | grep -v '^127\.' | head -1)"
  fi
  printf '%s' "$ip"
}

# WAN 探测：默认路由 dev（控制端首机无集群对端路由，此处与 network 子命令缺省
# 同源；INFRA_NET 教训影响的是节点侧跨节点流量路径，由 network/guest 内部处理）。
ic_derive_wan() {
  awk '/default/ {print $5; exit}' <<<"$1"
}

# 端口建议（纯函数，输入=ss 抓取文本）：22 被占 → 建议 2229；空闲 → 22。
ic_port_suggest() {
  if grep -q . <<<"$1"; then
    printf '2229'
  else
    printf '22'
  fi
}

# mesh 网段冲突：与既有路由或管理网 /24 相撞返回冲突描述，无冲突返回空。
ic_route_conflict() {
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

# `free -m` 输出 → Mem total MiB（拿不到返回空）。
ic_mem_total_mib() {
  awk '/^Mem:/ {print $2; exit}' <<<"$1"
}

# `df -P <挂载点>` 输出 → 已用百分比（拿不到返回空）。
ic_disk_used_pct() {
  awk 'NR == 2 {gsub(/%/, "", $5); print $5}' <<<"$1"
}

# uname -m → goarch（与 railans-node.sh control 同款映射）。
ic_goarch() {
  case "$(uname -m)" in
    x86_64) printf 'amd64' ;;
    aarch64) printf 'arm64' ;;
    *) uname -m ;;
  esac
}

# config.yaml enroll_code 提取（尾声展示 / 幂等复用）。
ic_config_code() {
  sed -n 's/^[[:space:]]*enroll_code:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}

# enroll code 生成：openssl 优先，urandom 兜底（与 railans-node.sh control 同款）。
ic_gen_code() {
  local c=''
  c="$(openssl rand -hex 24 2>/dev/null || true)"
  if [[ ! "$c" =~ ^[0-9a-f]{48}$ ]]; then
    c="$(head -c 24 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || true)"
  fi
  printf '%s' "$c"
}

# config.yaml 渲染（stdout；字段名锚 control/config.go Config 结构与
# config.example.yaml，满足 LoadConfig 的 validate()）。
ic_render_config() {  # <addr> <subnet> <driver> <port> <domain> <code> <node_name>
  local addr="$1" subnet="$2" driver="$3" port="$4" domain="$5" code="$6" node_name="$7"
  local gw mgmt
  gw="$(ic_gateway_of "$subnet")"
  mgmt="$(ic_mgmt_cidr "$addr")"
  cat <<EOF
listen: ":${port}"

# 控制面域名（客户端 ssh 这个）
control_host: "new.${domain}"

# 入口节点的管理 IP（客户端实际连这个）
public_host: "${addr}"

# 预览域名后缀，Caddy 会生成 box-xxxxxx.<domain>
preview_domain: "${domain}"
preview_port: 8080

state_file: "/var/lib/railans/state.json"
host_key_file: "/var/lib/railans/ssh_host_ed25519_key"

incus_bin: "incus"
base_image: "dev-base"
profile: "dev"
bridge: "br-vm"

# 建集群时用的存储驱动：lvm（推荐，ext4 也能用）/ zfs / dir
# dir 不支持快照，snapshot 命令会直接提示
storage_driver: "${driver}"

# SSH 数据面端口池，每台 box 一个
port_range: [22000, 22999]

nodes:
  - name: ${node_name}
    address: "${addr}"
    subnet: "${subnet}"
    gateway: "${gw}"

vm:
  cpus: 2
  memory: "2GiB"
  disk: "20GiB"

limits:
  box_ttl: "168h"
  idle_stop: "30m"
  max_boxes: 12
  max_boxes_per_key: 1
  max_creates_per_ip_per_day: 3

security:
  # 由 install-control.sh 生成（openssl rand -hex 24）
  enroll_code: "${code}"
  require_enroll: true
  allowed_source_cidr: "${mgmt}"

caddy:
  conf_path: "/etc/caddy/conf.d/boxes.caddy"
  reload_cmd: ["systemctl", "reload", "caddy"]
EOF
}

# ============================================================
# 问答助手（stdin 喂答案；EOF 取默认；与 install-node.sh 同款约定）
# ============================================================

IC_EOF=0

ic_ask() {
  local ans=''
  printf '%s [%s]: ' "$1" "$2" >&2
  IC_EOF=0
  if ! IFS= read -r ans; then
    IC_EOF=1
    ans=''
  fi
  ans="${ans%$'\r'}"
  if [[ -z "$ans" ]]; then
    ans="$2"
  fi
  printf '%s' "$ans"
}

ic_ask_checked() {  # <提示> <默认> <校验函数名> <错误说明>
  local v
  while :; do
    v="$(ic_ask "$1" "$2")"
    if "$3" "$v"; then
      printf '%s' "$v"
      return 0
    fi
    if ((IC_EOF == 1)); then
      { printf '\n'; printf '输入流已结束且默认值不可用（%s），中止。\n' "$4"; } >&2
      exit 2
    fi
    printf '  %s!%s %s\n' "$C_WARN" "$C_RST" "$4" >&2
  done
}

ic_confirm() {
  local ans=''
  printf '%s [y/N]: ' "$1" >&2
  if ! IFS= read -r ans; then ans=''; fi
  ans="${ans%$'\r'}"
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# ============================================================
# 预检（硬伤直接报；WARN 不阻断）
# ============================================================

ic_preflight() {
  local hard=0 mem='' used='' goarch='' bin=''
  echo "== 预检（控制端 / 入口节点）=="
  if [[ -d "$IC_SYSTEMD_RUN" ]]; then
    printf '  %sPASS%s systemd 在跑\n' "$C_OK" "$C_RST"
  else
    printf '  %sFAIL%s systemd 不可用（%s 不存在）——railans/caddy/dnsmasq 全靠 systemd 编排\n' "$C_ERR" "$C_RST" "$IC_SYSTEMD_RUN"
    hard=1
  fi
  if [[ -e "$IC_KVM_PATH" ]]; then
    printf '  %sPASS%s /dev/kvm 在\n' "$C_OK" "$C_RST"
  else
    printf '  %sFAIL%s /dev/kvm 不存在——物理机需 BIOS 开 VT-x/AMD-V；虚机需嵌套虚拟化透传\n' "$C_ERR" "$C_RST"
    hard=1
  fi
  mem="$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || true)"
  if [[ -n "$mem" ]] && ((mem < 15360)); then
    printf '  %sWARN%s 内存 %s MiB（建议 ≥15GiB：控制面 + incus + 镜像构建 VM 同机）\n' "$C_WARN" "$C_RST" "$mem"
  else
    printf '  %sPASS%s 内存 %s MiB\n' "$C_OK" "$C_RST" "${mem:-未知}"
  fi
  used="$(df -P / 2>/dev/null | awk 'NR == 2 {gsub(/%/, "", $5); print $5}' || true)"
  local free_pct='未知'
  if [[ -n "$used" ]]; then
    free_pct="$((100 - used))"
  fi
  if [[ -n "$used" ]] && ((100 - used < 15)); then
    printf '  %sWARN%s 磁盘 / 剩余 %s%%（<15%%，incus 池会吃盘）\n' "$C_WARN" "$C_RST" "$free_pct"
  else
    printf '  %sPASS%s 磁盘 / 剩余 %s%%\n' "$C_OK" "$C_RST" "$free_pct"
  fi
  goarch="$(ic_goarch)"
  bin="${SCRIPT_DIR}/bin/railans-linux-${goarch}"
  if command -v go >/dev/null 2>&1; then
    printf '  %sPASS%s go 在场（%s），第 5 步可现场编译控制面\n' "$C_OK" "$C_RST" "$(go version | awk '{print $3}')"
  elif [[ -f "$bin" ]]; then
    printf '  %sPASS%s 预编译二进制在场（%s）\n' "$C_OK" "$C_RST" "$bin"
  else
    printf '  %sWARN%s 无 go 且无预编译二进制——第 5 步 control 会停住。先装：apt-get install -y golang-go（脚本不自动下载工具链），装好后重跑\n' "$C_WARN" "$C_RST"
  fi
  local orca_src="${ORCA_SRC:-$HOME/orca}"
  if [[ ! -d "$orca_src/out/cli" ]]; then
    printf '  %sWARN%s orca checkout 缺失（ORCA_SRC=%s）——第 4 步镜像构建的 orca 资产化会停住；装好或 ORCA_SRC=<路径> 指认后重跑\n' "$C_WARN" "$C_RST" "$orca_src"
  fi
  if [[ -f "$IC_CONFIG_PATH" ]]; then
    printf '  %sNOTE%s config 已存在（%s）——将保留不动，enroll code 不重生成\n' "$C_DIM" "$C_RST" "$IC_CONFIG_PATH"
  fi
  if ((hard == 1)); then
    printf '\n%s预检有硬伤，中止安装。修复上列 FAIL 后重跑。%s\n' "$C_ERR" "$C_RST"
    exit 1
  fi
  printf '  预检通过（WARN 不阻断）\n'
}

# ============================================================
# 问答（答案收集完毕才进执行；执行阶段零交互）
# ============================================================

ic_collect_answers() {
  local route_out='' addr_all='' nic_out='' nic='' ip='' ss22='' wan='' conflicts=''
  route_out="$(ip -4 route show 2>/dev/null || true)"
  addr_all="$(ip -4 addr show 2>/dev/null || true)"
  nic="$(ic_mgmt_nic "$route_out" "$addr_all")"
  nic_out=''
  if [[ -n "$nic" ]]; then
    nic_out="$(ip -4 addr show dev "$nic" 2>/dev/null || true)"
  fi
  ip="$(ic_mgmt_ip "$nic_out" "$addr_all")"
  ss22="$(ss -lntH 'sport = :22' 2>/dev/null || true)"
  wan="$(ic_derive_wan "$route_out")"

  echo
  echo "== 问答（回车 = 接受默认；全部答完才开跑）=="
  if [[ -n "${RAILANS_IC_ADDR:-}" ]]; then
    IC_ADDR="$RAILANS_IC_ADDR"
    echo "管理 IP: 预设 ${IC_ADDR}"
  else
    IC_ADDR="$(ic_ask_checked '管理 IP（入口节点本机地址）' "$ip" ic_valid_addr '管理 IP 要是点分 IPv4（例 192.168.1.11）')"
  fi

  if [[ -n "${RAILANS_IC_SUBNET:-}" ]]; then
    IC_SUBNET="$RAILANS_IC_SUBNET"
    echo "VM 网段: 预设 ${IC_SUBNET}"
  else
    while :; do
      IC_SUBNET="$(ic_ask_checked 'VM mesh 网段（每节点一个 /24）' '10.10.1.0/24' ic_valid_subnet '网段要写成 x.x.x.0/24（例 10.10.1.0/24）')"
      conflicts="$(ic_route_conflict "$IC_SUBNET" "$route_out" "$(ic_mgmt_cidr "$IC_ADDR")")"
      if [[ -z "$conflicts" ]]; then
        break
      fi
      printf '  %s!%s %s——换一个网段\n' "$C_WARN" "$C_RST" "$conflicts"
      if ((IC_EOF == 1)); then
        echo "输入流已结束且网段冲突无法解决，中止。" >&2
        exit 2
      fi
    done
  fi

  if [[ -n "${RAILANS_IC_DRIVER:-}" ]]; then
    IC_DRIVER="$RAILANS_IC_DRIVER"
    echo "存储驱动: 预设 ${IC_DRIVER}"
  else
    cat >&2 <<'DRIVERHELP'
  存储驱动取舍：dir = 零准备开箱即用，不支持快照；lvm = ext4 上 loop 建池，支持快照；
  zfs = 性能最好，依赖内核模块（升级内核可能要重装）。不确定就回车用 dir。
DRIVERHELP
    IC_DRIVER="$(ic_ask_checked '存储驱动' 'dir' ic_valid_driver '存储驱动只支持 dir / lvm / zfs')"
  fi

  if [[ -n "${RAILANS_IC_PORT:-}" ]]; then
    IC_PORT="$RAILANS_IC_PORT"
    echo "控制面端口: 预设 ${IC_PORT}"
  else
    if grep -q . <<<"$ss22"; then
      echo "（22 已被占用——多半是系统 sshd；建议控制面改绑 2229，sshd 不动）"
    else
      echo "（22 空闲：控制面占 22，客户端 ssh new.<预览域名> 才能不带端口）"
    fi
    IC_PORT="$(ic_ask_checked '控制面端口' "$(ic_port_suggest "$ss22")" ic_valid_port '端口要是 1-65535 的数字')"
  fi

  if [[ -n "${RAILANS_IC_DOMAIN:-}" ]]; then
    IC_DOMAIN="$RAILANS_IC_DOMAIN"
    echo "预览域名: 预设 ${IC_DOMAIN}"
  else
    IC_DOMAIN="$(ic_ask_checked '预览域名后缀' 'box.lan' ic_valid_domain '域名要像 box.lan / boxes.example.org（字母数字连字符与点）')"
  fi

  if [[ -n "${RAILANS_IC_WAN:-}" ]]; then
    IC_WAN="$RAILANS_IC_WAN"
  else
    IC_WAN="$wan"
  fi
  if [[ -n "$IC_WAN" ]]; then
    echo "WAN: ${IC_WAN}（探测默认；RAILANS_IC_WAN 可覆盖）"
  else
    echo "WAN: 探测不到——第 3 步 network 会自行再推导"
  fi

  IC_NODE_NAME="${RAILANS_IC_NODE_NAME:-node1}"
  IC_NIC_DISPLAY="$nic"
  echo "首成员名: ${IC_NODE_NAME}（RAILANS_IC_NODE_NAME 可覆盖）"
}

# ============================================================
# 计划摘要 + 确认门
# ============================================================

ic_plan() {
  local driver_note='' port_note=''
  case "$IC_DRIVER" in
    dir) driver_note='零准备开箱即用；不支持快照' ;;
    lvm) driver_note='ext4 上 loop 建池（100GiB），支持快照' ;;
    zfs) driver_note='性能最好；依赖内核模块，升级内核可能要重装' ;;
  esac
  if [[ "$IC_PORT" == "22" ]]; then
    port_note='（系统 sshd 若占 22 会被挪到 2200，管理 SSH 改走 -p 2200）'
  else
    port_note='（系统 sshd 不动）'
  fi
  cat <<EOF

== 安装计划（控制端 / 入口节点）==
  管理 IP:    ${IC_ADDR}（网卡 ${IC_NIC_DISPLAY:-?}）
  VM 网段:    ${IC_SUBNET}（网关 $(ic_gateway_of "$IC_SUBNET")；mesh 冲突检查已过）
  存储驱动:   ${IC_DRIVER} — ${driver_note}
  控制面端口: ${IC_PORT} ${port_note}
  预览域名:   ${IC_DOMAIN}（客户端 DNS：new.${IC_DOMAIN} / *.${IC_DOMAIN} → ${IC_ADDR}）
  WAN:        ${IC_WAN:-<network 子命令自行推导>}
  首成员名:   ${IC_NODE_NAME}
  enroll code: 自动生成（openssl rand -hex 24），只在安装尾声展示一次
将按序执行 9 步（每步幂等；失败停住给 --from-step 断点）:
  1/9 preflight  2/9 incus+bootstrap  3/9 network     4/9 镜像构建   5/9 控制面
  6/9 caddy+dns  7/9 systemd 收尾     8/9 healthcheck 9/9 使用摘要
EOF
}

# ============================================================
# 编排（1-9 步，每步幂等；失败停住给断点）
# ============================================================

ic_fail_step() {  # <step> <msg>
  local step="$1" msg="$2" resume=''
  resume="RAILANS_IC_ADDR=${IC_ADDR} RAILANS_IC_SUBNET=${IC_SUBNET} RAILANS_IC_DRIVER=${IC_DRIVER} RAILANS_IC_PORT=${IC_PORT} RAILANS_IC_DOMAIN=${IC_DOMAIN} bash install-control.sh --from-step ${step} --yes"
  printf '\n%sFAIL%s 第 %s/9 步：%s\n' "$C_ERR" "$C_RST" "$step" "$msg" >&2
  printf '断点：停在第 %s/9 步；前面已完成步骤均幂等，重放安全。\n' "$step" >&2
  printf '%s续跑：%s%s\n' "$C_WARN" "$resume" "$C_RST" >&2
  exit 1
}

# node 侧脚本调用约定：直接 `env VAR=... bash "$IC_NODE_SH" <子命令>`（env 透传
# 环境给 bash 子进程；不能经 shell 函数中转）。测试经 RAILANS_NODE_SH /
# RAILANS_BUILD_SH 指到垫片，与生产同一调用形态。

ic_step1_preflight() {
  echo "== 1/9 preflight（node 侧只读体检）=="
  bash "$IC_NODE_SH" preflight || ic_fail_step 1 "railans-node.sh preflight 返回非 0（见上方输出）"
}

ic_step2_bootstrap() {
  echo "== 2/9 incus + bootstrap（首成员初始化；bootstrap 内置 5 秒倒计时）=="
  env "DRIVER=${IC_DRIVER}" bash "$IC_NODE_SH" install-incus \
    || ic_fail_step 2 "install-incus 失败（apt/snap 源问题？修好后续跑）"
  env "NODE_NAME=${IC_NODE_NAME}" "NODE_ADDR=${IC_ADDR}" "DRIVER=${IC_DRIVER}" \
    bash "$IC_NODE_SH" bootstrap \
    || ic_fail_step 2 "bootstrap 失败（见上方输出；本机已有集群时 bootstrap 幂等跳过）"
}

ic_step3_network() {
  echo "== 3/9 network（br-vm 网桥 + ip_forward + nftables；单节点 ROUTES 为空）=="
  local -a pre=("NODE_ADDR=${IC_ADDR}" "SUBNET=${IC_SUBNET}" "ROUTES=")
  if [[ -n "$IC_WAN" ]]; then
    pre+=("WAN=${IC_WAN}")
  fi
  env "${pre[@]}" bash "$IC_NODE_SH" network \
    || ic_fail_step 3 "network 失败（宿主有 Docker 会自动装 DOCKER-USER helper；详见上方输出）"
}

ic_step4_image() {
  echo "== 4/9 镜像构建（dev-base；资产目录 ${IC_ASSET_DIR}）=="
  if incus image list dev-base --format csv 2>/dev/null | grep -q . && [[ "${RAILANS_IC_FORCE_IMAGE:-0}" != "1" ]]; then
    echo "  镜像 dev-base 已存在，跳过构建（强制重建：RAILANS_IC_FORCE_IMAGE=1）"
    return 0
  fi
  # orca 资产化预检：build-base-image-local.sh 第 5b 步需要 orca checkout；
  # 缺失会在 provision 跑完（约 10 分钟）后才失败——先停下来给指引，别白跑。
  local src="${ORCA_SRC:-$HOME/orca}"
  if [[ ! -d "$src/out/cli" ]]; then
    ic_fail_step 4 "orca checkout 缺失（ORCA_SRC=${src} 下无 out/cli）——先准备 orca 源码或 ORCA_SRC=<路径> 指认，再续跑"
  fi
  install -d -m 700 "$IC_ASSET_DIR" || ic_fail_step 4 "资产目录 ${IC_ASSET_DIR} 建不了"
  env "RAILANS_ASSET_DIR=${IC_ASSET_DIR}" bash "$IC_BUILD_SH" \
    || ic_fail_step 4 "镜像构建失败（build-base-image-local.sh；遗留构建 VM 已被其兜底停止）"
}

ic_step5_control() {
  echo "== 5/9 控制面（config 渲染 + railans-node.sh control）=="
  if [[ -f "$IC_CONFIG_PATH" ]]; then
    echo "  config 已存在，保留不动：${IC_CONFIG_PATH}（enroll code 不重生成）"
  else
    local code=''
    code="$(ic_gen_code)"
    if [[ ! "$code" =~ ^[0-9a-f]{48}$ ]]; then
      ic_fail_step 5 "enroll code 生成失败（openssl / urandom 都不可用？）"
    fi
    install -d -m 755 "$(dirname "$IC_CONFIG_PATH")" || ic_fail_step 5 "$(dirname "$IC_CONFIG_PATH") 建不了"
    # umask 177 落盘（中途 0600 root:root，control 落位后转 0640 root:railans）；
    # code 只进 config，不回显、不进日志
    ( umask 177; ic_render_config "$IC_ADDR" "$IC_SUBNET" "$IC_DRIVER" "$IC_PORT" "$IC_DOMAIN" "$code" "$IC_NODE_NAME" >"$IC_CONFIG_PATH" ) \
      || ic_fail_step 5 "config 渲染落盘失败（${IC_CONFIG_PATH}）"
    chmod 0640 "$IC_CONFIG_PATH"
    echo "  config 已渲染：${IC_CONFIG_PATH}（enroll code 收尾统一展示，不落日志）"
  fi
  env "CONFIG=${IC_CONFIG_PATH}" "ADMIN_SSH_PORT=2200" bash "$IC_NODE_SH" control \
    || ic_fail_step 5 "control 失败——若无 go：apt-get install -y golang-go 后续跑（脚本不自动下载工具链）；其余看上方输出"
}

ic_step6_caddy() {
  echo "== 6/9 caddy + dnsmasq（预览反代 + 内网 DNS）=="
  env "ENTRY_IP=${IC_ADDR}" "DOMAIN=${IC_DOMAIN}" bash "$IC_NODE_SH" caddy \
    || ic_fail_step 6 "caddy/dnsmasq 安装失败（80/443/53 端口冲突？详见上方输出与 STATUS §5-6）"
}

ic_step7_units() {
  echo "== 7/9 systemd 收尾（补 conf.d 属组 + 重启 + 断言双 unit active）=="
  # railans-node.sh control 的既定指引：caddy 装在后，conf.d 属组要回头补
  # （caddy.go 以 railans 用户写站点文件，需要 g+w + 属组 railans）
  if [[ -d "$IC_CADDY_CONF_DIR" ]]; then
    chgrp railans "$IC_CADDY_CONF_DIR" || ic_fail_step 7 "chgrp railans ${IC_CADDY_CONF_DIR} 失败（railans 用户/组没建好？第 5 步是否真过）"
    chmod g+w "$IC_CADDY_CONF_DIR"
    echo "  ${IC_CADDY_CONF_DIR} 属组 railans + g+w 已补"
  else
    ic_fail_step 7 "${IC_CADDY_CONF_DIR} 不存在——第 6 步 caddy 未成功？先修第 6 步"
  fi
  systemctl restart railans || ic_fail_step 7 "systemctl restart railans 失败（journalctl -u railans -n 50）"
  local u
  for u in railans caddy; do
    systemctl is-active --quiet "$u" || ic_fail_step 7 "$u.service 未运行（systemctl status $u / journalctl -u $u -n 50）"
    printf '  %sPASS%s %s.service active\n' "$C_OK" "$C_RST" "$u"
  done
}

ic_step8_healthcheck() {
  echo "== 8/9 healthcheck（断言式体检，全绿门槛）=="
  bash "$IC_NODE_SH" healthcheck || ic_fail_step 8 "healthcheck 有 FAIL（按输出逐项排障后续跑）"
}

ic_step9_summary() {
  echo "== 9/9 使用摘要 =="
  local code='' ssh_note='' code_note=''
  code="$(ic_config_code "$IC_CONFIG_PATH" || true)"
  if [[ "$IC_PORT" == "22" ]]; then
    ssh_note="系统 sshd 已挪到 2200：ssh -p 2200 root@${IC_ADDR}"
  else
    ssh_note="仍在 22：ssh root@${IC_ADDR}"
  fi
  if [[ -n "$code" ]]; then
    code_note="$code"
  else
    code_note="<读不到——查 ${IC_CONFIG_PATH} 的 security.enroll_code>"
  fi
  cat <<EOF

${C_OK}== railans 控制端安装完成 ==${C_RST}
  控制面:  listen :${IC_PORT}（config ${IC_CONFIG_PATH}）
  入口:    ${IC_ADDR}；预览 https://box-xxxxxx.${IC_DOMAIN}
  管理 SSH: ${ssh_note}

下一步：
  1) 客户端 DNS 把 new.${IC_DOMAIN} / *.${IC_DOMAIN} 指向 ${IC_ADDR}
     （本机 dnsmasq 已在 :53，局域网客户端 DNS 可直接指向它）
  2) enroll code ——只展示这一次，请立即保存（重看需查 ${IC_CONFIG_PATH}，0640）：
       ${code_note}
     保存好再继续！
  3) 领第一只箱：
       ssh new.${IC_DOMAIN} enroll <enroll_code> my-laptop   # 公钥准入（一次性）
       ssh new.${IC_DOMAIN} new                              # 创建并返回连接信息
  4) 加更多节点：在目标机上跑  sudo bash install-node.sh
     （或从本机 railans-node.sh add-node <user@host> <name> <subnet> --yes）
EOF
}

ic_orchestrate() {
  local s
  local -a steps=(ic_step1_preflight ic_step2_bootstrap ic_step3_network ic_step4_image \
    ic_step5_control ic_step6_caddy ic_step7_units ic_step8_healthcheck ic_step9_summary)
  for s in 1 2 3 4 5 6 7 8 9; do
    if ((s < IC_FROM_STEP)); then
      printf '%s-- 跳过第 %s/9 步（--from-step %s 续跑）--%s\n' "$C_DIM" "$s" "$IC_FROM_STEP" "$C_RST"
      continue
    fi
    "${steps[$((s - 1))]}"
  done
}

# ============================================================
# 入口
# ============================================================

ic_usage() {
  cat <<'USAGE'
用法: sudo bash install-control.sh [--from-step 1-9] [--yes]

问答式安装 railans 控制端（入口节点：incus 集群首成员 + dev-base 镜像 +
SSH 控制面 + Caddy/dnsmasq）。每问有探测默认值，回车即接受；全部答案收完
才开跑，执行阶段零交互（可重定向日志）。

  --from-step N   从第 N/9 步续跑（失败断点续跑；前序步骤幂等）
  --yes           免确认执行；无人值守需 RAILANS_IC_ADDR/SUBNET/DRIVER/PORT/DOMAIN
                  全部经环境变量预设（缺任一则退出并点名）
  --help          本说明

九步编排与续跑示例见脚本头注。
USAGE
}

main() {
  while (($#)); do
    case "$1" in
      --from-step)
        [[ -n "${2:-}" ]] || { echo "install-control.sh: --from-step 需要步骤号（1-9）" >&2; exit 2; }
        if [[ ! "$2" =~ ^[1-9]$ ]]; then
          echo "install-control.sh: --from-step '${2}' 越界（1-9）" >&2
          exit 2
        fi
        IC_FROM_STEP="$2"
        shift 2
        ;;
      --yes | -y)
        IC_YES=1
        shift
        ;;
      --help | -h)
        ic_usage
        exit 0
        ;;
      *)
        echo "install-control.sh: 不认识的参数 '${1}'（支持 --from-step / --yes / --help）" >&2
        exit 2
        ;;
    esac
  done

  # sudo 自检（非 root 且 sudo -n 不过 → 指路退出）
  if [[ ${EUID} -ne 0 ]] && ! sudo -n true >/dev/null 2>&1; then
    echo "请用 sudo bash 运行本脚本（后续步骤需要 root：装 incus / 写 /etc+railans 目录 / systemd）。" >&2
    exit 1
  fi

  # --yes 无人值守：五问必须全部经环境变量预设（缺任一则退出并点名）
  if ((IC_YES == 1)); then
    local v='' missing=()
    for v in RAILANS_IC_ADDR RAILANS_IC_SUBNET RAILANS_IC_DRIVER RAILANS_IC_PORT RAILANS_IC_DOMAIN; do
      if [[ -z "${!v:-}" ]]; then
        missing+=("$v")
      fi
    done
    if ((${#missing[@]} > 0)); then
      echo "--yes 无人值守需要全部答案经环境变量预设；缺：${missing[*]}" >&2
      exit 2
    fi
  fi

  ic_preflight
  ic_collect_answers
  ic_plan

  if ((IC_YES == 1)); then
    echo
    echo "--yes：免确认开跑（答案已全部收完，以下无人值守）"
  else
    if ! ic_confirm "确认按以上计划执行?"; then
      echo "已取消：未改任何状态。重跑本脚本可重新开始。"
      exit 0
    fi
  fi

  ic_orchestrate
}

main "$@"
