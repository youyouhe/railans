#!/usr/bin/env bash
# railans-node.sh — railans 节点生命周期单一入口
#
# 用法：
#   sudo ./node/railans-node.sh <subcommand> [args]
#
# 子命令（与原编号脚本一一对应，逻辑逐段照搬）：
#   preflight        环境预检（原 00-preflight.sh）
#   install-incus    只装 Incus，不初始化（原 01-install-incus.sh）
#   bootstrap        把本机初始化成集群第一个成员（原 02-cluster-bootstrap.sh）
#   join             把本机加入现有集群（原 03-cluster-join.sh）
#   network          br-vm 网桥 + ip_forward + nftables + 跨节点路由（原 04-node-network.sh）
#   image            建模板 VM 并 publish 成基础镜像（已弃用→用 build-base-image-local.sh；原 05-build-base-image.sh）
#   control          在入口节点安装 SSH 控制面（原 06-install-control.sh）
#   caddy            在入口节点安装 Caddy + dnsmasq（原 07-install-caddy-dns.sh）
#   deploy           新节点上架一条龙：装 incus + kvm 组 + 网络 + 待命（原 deploy-node.sh）
#   deploy-remote    控制机侧一条命令：rsync kit 到目标机 + 远端 deploy（缺省干跑，--yes 才执行）
#   healthcheck      断言式节点体检（只读；有 FAIL 即非 0 退出；--all 汇总各节点）
#   verify-nft       nftables 变更复验（baseline 采集 / verify 比对 / 箱内探针清单）
#   setup-subuid     给目标用户写 rootless podman 的 subuid/subgid 段（幂等；无 podman 跳过）
#   add-node         一条命令把新物理机变集群成员（八步编排；缺省干跑，--yes 才执行）
#
# 每个子命令的环境变量与用法见函数上方注释（与原脚本一致）。
#
# healthcheck 说明：
#   只做读取（incus query / ip / nft list / systemctl / df / timedatectl / ping），
#   不创建、不修改任何东西。状态词 PASS / WARN / FAIL / SKIP：
#     FAIL -> 退出码 1；WARN/SKIP 不影响退出码。
#   无 root 时读不到 nft 规则集，改用 railans-nftables.service 状态判定并注明；
#   需要 root 才能判定的项降级为 SKIP，不假装通过。
#   `healthcheck --all` 从当前节点逐台 ssh 各集群成员执行本脚本的 healthcheck
#   （脚本经 stdin 送入对端 `bash -s`，不在对端落任何文件）；ssh 用户依次尝试
#   RAILANS_SSH_USER / SUDO_USER / 当前用户 / ops。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || printf '%s' "${PWD}")"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." 2>/dev/null && pwd -P || printf '%s' "${PWD}")"

if [[ -t 1 ]]; then
  C_RST=$'\033[0m'
  C_OK=$'\033[32m'
  C_WARN=$'\033[33m'
  C_ERR=$'\033[31m'
  C_DIM=$'\033[2m'
else
  C_RST=''
  C_OK=''
  C_WARN=''
  C_ERR=''
  C_DIM=''
fi

usage() {
  cat <<'USAGE'
用法: railans-node.sh <subcommand> [args]

子命令:
  preflight        环境预检（只读）
  install-incus    只装 Incus，不初始化
  bootstrap        把本机初始化成集群第一个成员（参数: [node2] [node3]）
  join             把本机加入现有集群（交互式）
  network          br-vm 网桥 + ip_forward + nftables + 跨节点路由
  image            建模板 VM 并 publish 成基础镜像(已弃用→用 build-base-image-local.sh)
  control          在入口节点安装 SSH 控制面
  caddy            在入口节点安装 Caddy + dnsmasq
  deploy           新节点上架一条龙（装 incus + kvm 组 + 网络 + 待命）
  deploy-remote    把 kit 送到目标机并远端上架（缺省干跑，--yes 才执行）
  healthcheck      断言式节点体检（只读；--all 汇总各集群成员）
  verify-nft       nftables 变更复验（--baseline 采集 / --verify 比对 / --print-box-probes 清单）
  setup-subuid     给目标用户写 rootless podman 的 subuid/subgid 段（幂等；无 podman SKIP）
  add-node         一条命令把新物理机变集群成员（八步编排；缺省干跑，--yes 才执行）
  help             打印本清单
USAGE
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "请用 sudo 运行" >&2
    exit 1
  fi
}

# ===== subcommand: preflight（原 scripts/00-preflight.sh）=====
# 00-preflight.sh — 在 3 台物理机上分别执行
subcmd_preflight() {
echo "== OS =="
. /etc/os-release
echo "${PRETTY_NAME:-unknown}  $(uname -r)"

echo
echo "== 虚拟化 =="
systemd-detect-virt || true
if [[ -e /dev/kvm ]]; then
  echo "KVM: yes"
else
  echo "KVM: NO  <-- 必须是物理机且 BIOS 开启 VT-x/AMD-V"
fi
lscpu | grep -iE 'virtualization|model name' || true

echo
echo "== 资源 =="
nproc
free -h
df -h / /var 2>/dev/null || true

echo
echo "== 网络 =="
ip -4 -brief addr
ip route | grep default || true
echo "默认网卡: $(ip route | awk '/default/ {print $5; exit}')"

echo
echo "== 端口占用 =="
ss -lntp | grep -E ':(22|80|443|22000)\b' || true

echo
echo "== Incus =="
if command -v incus >/dev/null 2>&1; then
  incus --version
else
  echo "incus 未安装"
fi

echo
echo "== 时间同步 =="
timedatectl | grep -E 'System clock synchronized|NTP service' || true

echo
echo "下一步：sudo ./node/railans-node.sh install-incus"
}

# ===== subcommand: install-incus（原 scripts/01-install-incus.sh）=====
# 01-install-incus.sh — 在 3 台机器上分别执行
#
# 只装 Incus，不初始化。集群初始化在 02（bootstrap）/03（join）里做。
#
# 环境变量：
#   DRIVER   存储驱动，决定额外装什么（默认 lvm）
#            lvm  -> 装 lvm2（推荐：ext4 主机也能用，支持快照）
#            zfs  -> 装 zfsutils-linux（需要内核模块，升级内核后可能要重编）
#            dir  -> 什么都不用装（最简单，但不支持快照）
subcmd_install_incus() {
  require_root
DRIVER="${DRIVER:-lvm}"

if ! command -v incus >/dev/null 2>&1; then
  echo "==> 安装 Incus"
  apt-get update
  apt-get install -y snapd
  snap install incus --channel=latest/stable
else
  echo "==> Incus 已安装: $(incus --version)"
fi

echo "==> 安装 VM 依赖"
apt-get install -y qemu-system-x86 ovmf

echo "==> 安装存储依赖 (DRIVER=${DRIVER})"
case "${DRIVER}" in
  lvm)
    apt-get install -y lvm2
    ;;
  zfs)
    apt-get install -y zfsutils-linux
    if ! modprobe zfs >/dev/null 2>&1; then
      echo "警告：zfs 内核模块加载失败。内核升级后可能需要重装 zfsutils-linux 或改用 DRIVER=lvm" >&2
    fi
    ;;
  dir)
    echo "    dir 驱动不需要额外软件包"
    ;;
  *)
    echo "未知 DRIVER=${DRIVER}（支持 lvm / zfs / dir）" >&2
    exit 1
    ;;
esac

# 让日常用户能用 incus（重新登录后生效）
if [[ -n "${SUDO_USER:-}" ]]; then
  usermod -aG incus-admin "${SUDO_USER}" || true
fi

echo
echo "Incus 版本: $(incus --version)"
echo "状态: $(systemctl is-active snap.incus.daemon 2>/dev/null || echo unknown)"
echo
echo "下一步："
echo "  node1:  sudo NODE_NAME=node1 NODE_ADDR=192.168.1.11 DRIVER=${DRIVER} ./node/railans-node.sh bootstrap node2 node3"
echo "  node2:  sudo ./node/railans-node.sh join"
echo "  node3:  sudo ./node/railans-node.sh join"
}

# ===== subcommand: bootstrap（原 scripts/02-cluster-bootstrap.sh）=====
# 02-cluster-bootstrap.sh — 在 node1 上把本机初始化成集群的第一个成员
#
# 用法：
#   sudo NODE_NAME=node1 NODE_ADDR=192.168.1.11 \
#     ./node/railans-node.sh bootstrap node2 node3
#
# 环境变量：
#   NODE_NAME  本机在集群里的名字（默认 node1）
#   NODE_ADDR  其它节点能访问到的本机 IP（必填，不能是 0.0.0.0）
#   DRIVER     存储驱动：lvm（默认）/ zfs / dir
#                - lvm：在 ext4 上也能用，建一个 loop 文件当 PV，支持快照（推荐）
#                - zfs：性能最好，但依赖内核模块，升级内核后可能要重新编译
#                - dir：零准备，VM 磁盘是普通文件，不支持快照
#   POOL       存储池名（默认 default）
#   SIZE       loop 文件大小，仅 lvm/zfs 用（默认 100GiB）
#   DEVICE     可选：直接给一块空盘/分区（如 /dev/sdb），不建 loop 文件
subcmd_bootstrap() {
  require_root
NODE_NAME="${NODE_NAME:-node1}"
NODE_ADDR="${NODE_ADDR:?必须设置 NODE_ADDR，例如 192.168.1.11}"
DRIVER="${DRIVER:-lvm}"
POOL="${POOL:-default}"
SIZE="${SIZE:-100GiB}"
DEVICE="${DEVICE:-}"
NODE2="${1:-}"
NODE3="${2:-}"

if ! command -v incus >/dev/null 2>&1; then
  echo "incus 未安装，先运行 node/railans-node.sh install-incus" >&2
  exit 1
fi

if incus cluster list >/dev/null 2>&1; then
  echo "本机已经是集群成员："
  incus cluster list
  echo
  echo "如果只是想为新节点生成 token，直接执行：incus cluster add <name>"
  exit 0
fi

# 存储驱动的预检与 preseed 片段（缩进 6 空格，挂在 config: 下）
POOL_CONFIG=""
case "${DRIVER}" in
  lvm)
    if ! command -v vgcreate >/dev/null 2>&1; then
      echo "lvm2 未安装：apt-get install -y lvm2  （或先跑 railans-node.sh install-incus）" >&2
      exit 1
    fi
    if [[ -n "${DEVICE}" ]]; then
      POOL_CONFIG="      source: ${DEVICE}
      size: ${SIZE}"
    else
      POOL_CONFIG="      size: ${SIZE}"
    fi
    ;;
  zfs)
    if ! modprobe zfs >/dev/null 2>&1; then
      echo "zfs 内核模块不可用。ext4 主机建议直接用 DRIVER=lvm；" >&2
      echo "坚持用 zfs 就先 apt-get install -y zfsutils-linux" >&2
      exit 1
    fi
    if [[ -n "${DEVICE}" ]]; then
      POOL_CONFIG="      source: ${DEVICE}"
    else
      POOL_CONFIG="      size: ${SIZE}"
    fi
    ;;
  dir)
    POOL_CONFIG=""
    ;;
  *)
    echo "未知 DRIVER=${DRIVER}（支持 lvm / zfs / dir）" >&2
    exit 1
    ;;
esac

echo "==> 1/3 以 ${NODE_NAME} (${NODE_ADDR}) 初始化集群 bootstrap 节点"
echo "    存储驱动: ${DRIVER}"
echo "    存储池:   ${POOL}"
if [[ "${DRIVER}" != "dir" ]]; then
  if [[ -n "${DEVICE}" ]]; then
    echo "    后端设备: ${DEVICE}"
  else
    echo "    loop 文件: ${SIZE}（放在 /var/lib/incus/disks/）"
  fi
fi
echo "    这会清空本机现有 Incus 数据。5 秒后开始，Ctrl-C 取消。"
sleep 5

{
  cat <<EOF
config:
  core.https_address: ${NODE_ADDR}:8443
  images.auto_update_interval: 24
storage_pools:
  - name: ${POOL}
    driver: ${DRIVER}
EOF
  if [[ -n "${POOL_CONFIG}" ]]; then
    printf '    config:\n%s\n' "${POOL_CONFIG}"
  fi
  cat <<EOF
profiles:
  - name: default
    devices:
      root:
        path: /
        pool: ${POOL}
        type: disk
cluster:
  server_name: ${NODE_NAME}
  enabled: true
EOF
} | incus admin init --preseed

echo
echo "==> 2/3 集群状态"
incus cluster list
incus storage list

echo
echo "==> 3/3 生成加入 token"
for n in ${NODE2} ${NODE3}; do
  echo
  echo "--- ${n} ---"
  incus cluster add "${n}"
done

cat <<'EOF'

把每个 token 拿到对应机器上，执行：

  sudo ./node/railans-node.sh join

交互式回答：
  Would you like to use Incus clustering?            -> yes
  What IP address ... to reach this server?          -> 本机管理 IP
  Are you joining an existing cluster?               -> yes
  Do you have a join token?                          -> yes，粘贴 token
  All existing data is lost when joining a cluster?  -> yes

存储提示：
  * lvm/zfs 池在加入节点时会问这个节点上的后端（loop 文件大小或空盘路径），
    三台各自独立，不共享 —— 这正是本方案要的本地存储。
  * 用 dir 驱动时不会问这些，直接回车即可。

注意：token 一次性使用，生成后尽快用。
EOF
}

# ===== subcommand: join（原 scripts/03-cluster-join.sh）=====
# 03-cluster-join.sh — 在 node2 / node3 上把本机加入 node1 的集群
#
# 用法：
#   sudo ./node/railans-node.sh join
#
# 需要 node1 上执行过：incus cluster add <本机名>
# token 一次性有效。
subcmd_join() {
  require_root
if ! command -v incus >/dev/null 2>&1; then
  echo "incus 未安装，先运行 node/railans-node.sh install-incus" >&2
  exit 1
fi

if incus cluster list >/dev/null 2>&1; then
  echo "本机已经是集群成员："
  incus cluster list
  exit 0
fi

NODE_ADDR="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
if [[ -z "${NODE_ADDR}" ]]; then
  echo "无法自动确定本机管理 IP，请手动设置（脚本里改 NODE_ADDR）" >&2
  exit 1
fi

cat <<EOF

即将把本机加入现有集群，本机所有现有 Incus 数据会被清空。

如果本机不是全新安装的 Incus，先执行：
  incus admin init --minimal >/dev/null 2>&1 || true   # 仅确保目录结构存在
  # 或者直接删掉 /var/lib/incus 下的旧数据（危险，确认后再做）

交互式回答（按顺序）：

  Would you like to use Incus clustering?            -> yes
  What IP address or DNS name ...?                   -> ${NODE_ADDR}   （或直接回车用默认值）
  Are you joining an existing cluster?               -> yes
  Do you have a join token?                          -> yes
  Please provide join token:                         -> 粘贴 node1 给的 token
  All existing data is lost ... continue?            -> yes
  Choose "size"/"source"/"zfs.pool_name" ...         -> 直接回车用默认值

EOF
read -r -p "按 Enter 进入 incus admin init（Ctrl-C 取消）..." _

incus admin init

echo
incus cluster list

cat <<'EOF'

如果成员列表里本机显示 Offline，等 10-30 秒再看；
仍 Offline 就把 node1 上的 `incus cluster list` 和本机
`journalctl -u snap.incus.daemon -n 100` 一起看。
EOF
}

# ===== subcommand: network（原 scripts/04-node-network.sh）=====
# 04-node-network.sh — 在每台物理节点执行一次
#
# 作用：
#   1. 创建 br-vm 网桥（Incus VM 挂在这里），网关地址 = VM 网段的 .1
#   2. 打开 ip_forward
#   3. 加载 nftables：VM NAT 出网 + 阻止 VM 访问管理网
#   4. 添加跨节点 VM 网段路由（让 node1 的转发/Caddy 能到 node2/3 的 box）
#
# 用法（node1）：
#   sudo NODE_ADDR=192.168.1.11 SUBNET=10.10.1.0/24 WAN=eno1 \
#     ROUTES="10.10.2.0/24 via 192.168.1.12;10.10.3.0/24 via 192.168.1.13" \
#     ./node/railans-node.sh network
#
# 用法（node2）：
#   sudo NODE_ADDR=192.168.1.12 SUBNET=10.10.2.0/24 WAN=eno1 \
#     ROUTES="10.10.1.0/24 via 192.168.1.11;10.10.3.0/24 via 192.168.1.13" \
#     ./node/railans-node.sh network
#
# ROUTES 可以为空（单节点部署时）。

# ===== nft 模板渲染（network 加载用；verify-nft 与 test-nft-render.sh 经 source 复用）=====

# 从 NODE_ADDR 推导管理网 /24 CIDR（模板 __MGMT__ 的渲染值）。
# NODE_ADDR 形态异常（非点分 IPv4）时 loud fail——绝不渲染半成品规则集。
# 用法：MGMT_CIDR="$(derive_mgmt_cidr "$NODE_ADDR")"（set -e 下失败即中止）
derive_mgmt_cidr() {
  local addr="${1:-}" cidr=''
  cidr="${addr%.*}.0/24"
  if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.0/24$ ]]; then
    echo "错误：无法从 NODE_ADDR='${addr}' 推导管理网 /24（__MGMT__ 渲染中止），请检查 NODE_ADDR" >&2
    return 1
  fi
  printf '%s\n' "$cidr"
}

# 渲染 node/deploy/nftables-railans.nft 三占位符（__WAN__/__MGMT__/__GWMESH__）到目标文件。
# sed 用 | 定界：MGMT 值形如 192.168.1.0/24 含斜杠，不能用 / 定界。
# 用法：render_nft_template <输出文件> <WAN网卡> <MGMT_CIDR> <GWMESH地址>
render_nft_template() {
  local out="$1" wan="$2" mgmt="$3" gwmesh="$4"
  sed -e "s|__WAN__|${wan}|g" \
      -e "s|__MGMT__|${mgmt}|g" \
      -e "s|__GWMESH__|${gwmesh}|g" \
      "${SCRIPT_DIR}/deploy/nftables-railans.nft" >"${out}"
}

subcmd_network() {
  require_root
NODE_ADDR="${NODE_ADDR:?必须设置 NODE_ADDR（本机管理网 IP，例如 192.168.1.11）}"
SUBNET="${SUBNET:?必须设置 SUBNET（VM 网段，例如 10.10.1.0/24）}"
GATEWAY="${GATEWAY:-$(awk -F. '{print $1"."$2"."$3".1"}' <<<"${SUBNET%/*}")}"
WAN="${WAN:-$(ip route | awk '/default/ {print $5; exit}')}"
ROUTES="${ROUTES:-}"
BRIDGE="${BRIDGE:-br-vm}"

if [[ -z "${WAN}" ]]; then
  echo "找不到默认网卡，请显式设置 WAN=eno1" >&2
  exit 1
fi
if ! ip -4 -o addr show dev "${WAN}" | grep -q "${NODE_ADDR}"; then
  echo "警告：${WAN} 上没有 ${NODE_ADDR}，请确认 NODE_ADDR/WAN 是否正确" >&2
fi

echo "==> 1/5 创建 ${BRIDGE} (${GATEWAY}/24)"
cat >/etc/netplan/90-railans-br-vm.yaml <<EOF
network:
  version: 2
  bridges:
    ${BRIDGE}:
      dhcp4: false
      addresses: ["${GATEWAY}/24"]
      parameters:
        stp: false
        forward-delay: 0
EOF
chmod 600 /etc/netplan/90-railans-br-vm.yaml
netplan apply

echo "==> 2/5 打开 IP 转发"
cat >/etc/sysctl.d/99-railans.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
EOF
sysctl --system >/dev/null
echo "    net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward)"

echo "==> 3/5 编译 nftables 规则"
if ! command -v nft >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y nftables
fi
mkdir -p /etc/nftables.d
# 三占位符渲染：__MGMT__ 由 NODE_ADDR 推导 /24（derive 失败 loud fail）、
# __GWMESH__=GATEWAY（上方已由 SUBNET 推导）、__WAN__=WAN
MGMT_CIDR="$(derive_mgmt_cidr "${NODE_ADDR}")"
render_nft_template "/etc/nftables.d/railans.nft" "${WAN}" "${MGMT_CIDR}" "${GATEWAY}"

echo "==> 3b/5 Docker 共存 helper（先装 helper 再起服务，否则 ExecStartPost 必失败）"
# Docker 会把 FORWARD 链默认策略设为 DROP，br-vm 的转发流量（VM 出网、
# 跨节点 VM 互访）会被它吞掉。放行规则必须插进 Docker 官方用户钩子
# DOCKER-USER（该链在 FORWARD 里最先处理，且 docker 重载不会覆盖）。
mkdir -p /usr/local/sbin
cat >/usr/local/sbin/railans-docker-accept.sh <<EOS
#!/usr/bin/env bash
# 用法: railans-docker-accept.sh [bridge]  （默认 br-vm）
# 把 bridge 的转发流量在 DOCKER-USER 里放行（幂等）。DOCKER-USER 链由
# docker 创建；开机时本脚本可能先于 docker 运行，故最多等 60s。
set -u
BR="\${1:-br-vm}"
for _ in \$(seq 1 30); do
  if iptables -nL DOCKER-USER >/dev/null 2>&1; then
    iptables -C DOCKER-USER -i "\$BR" -j ACCEPT 2>/dev/null || \\
      iptables -I DOCKER-USER 1 -i "\$BR" -j ACCEPT
    iptables -C DOCKER-USER -o "\$BR" -j ACCEPT 2>/dev/null || \\
      iptables -I DOCKER-USER 1 -o "\$BR" -j ACCEPT
    exit 0
  fi
  sleep 2
done
echo "DOCKER-USER 链不存在（docker 未启用 iptables？）跳过" >&2
exit 0
EOS
chmod 755 /usr/local/sbin/railans-docker-accept.sh

cat >/etc/systemd/system/railans-nftables.service <<EOF
[Unit]
Description=railans nftables rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/nftables.d/railans.nft
ExecStartPost=/usr/local/sbin/railans-docker-accept.sh ${BRIDGE}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable railans-nftables.service
systemctl restart railans-nftables.service
if systemctl is-active --quiet docker 2>/dev/null; then
  echo "    docker 在跑：DOCKER-USER 已放行 ${BRIDGE}"
else
  echo "    本机无 docker 服务（helper 已装好，装了 docker 也会自动生效）"
fi

echo "==> 4/5 跨节点路由"
mkdir -p /usr/local/sbin
: >/usr/local/sbin/railans-routes.sh
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  if [[ -n "${ROUTES}" ]]; then
    IFS=';' read -ra entries <<<"${ROUTES}"
    for entry in "${entries[@]}"; do
      entry="$(echo "${entry}" | xargs)"
      [[ -z "${entry}" ]] && continue
      # 形如 "10.10.2.0/24 via 192.168.1.12"
      echo "ip route replace ${entry}"
    done
  else
    echo 'exit 0'
  fi
} >/usr/local/sbin/railans-routes.sh
chmod 755 /usr/local/sbin/railans-routes.sh

cat >/etc/systemd/system/railans-routes.service <<'EOF'
[Unit]
Description=railans cross-node VM routes
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/railans-routes.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable railans-routes.service
systemctl restart railans-routes.service

echo "==> 5/5 结果"
ip -4 -brief addr show "${BRIDGE}"
echo
ip route | grep -E '10\.10\.' || echo "    (无跨节点路由)"
echo
nft list table inet railans | sed 's/^/    /'

cat <<EOF

完成。本机：
  NODE_ADDR = ${NODE_ADDR}
  SUBNET    = ${SUBNET}
  GATEWAY   = ${GATEWAY}
  WAN       = ${WAN}

下一步：
  * node1: sudo NODE=node1 BASE_IP=${GATEWAY%.*}.250 ./node/railans-node.sh image
  * 客户端 DNS 指向入口节点后，ssh new.box.lan 才有意义。
EOF
}

# ===== subcommand: image（原 scripts/05-build-base-image.sh）=====
# 05-build-base-image.sh — 建一台模板 VM，装好开发环境，publish 成 dev-base 镜像
#
# 只会在一台节点上执行（默认 node1），产物是集群共享镜像 + dev profile。
#
# 用法：
#   sudo NODE=node1 BASE_IP=10.10.1.250 ./node/railans-node.sh image
#
# 环境变量：
#   NODE      目标节点名（默认 node1）
#   BASE_IP   模板 VM 的临时静态 IP（必填，需在 br-vm 网段内且未被占用）
#   POOL      Incus 存储池（默认 default）
#   IMAGE     上游镜像（默认 images:ubuntu/24.04/cloud）
#   IMAGE_ALIAS 产出镜像别名（默认 dev-base）
#   PROFILE   profile 名（默认 dev）
#   CPUS / MEMORY / DISK  VM 规格（默认 2 / 2GiB / 20GiB）
subcmd_image() {
  # node 版构建路径弃用：
  # 快速失败（exit 非零），绝不带病往下跑——guest 段缺 90-railans-dev 写入，真构建必 loud fail。
  cat >&2 <<'DEPRECATED'
[image] 已弃用：node 版构建路径已弃用（缺 /etc/sudoers.d/90-railans-dev 写入且不再维护，真构建必失败）。
[image] 统一走 scripts/build-base-image-local.sh 构建镜像；分发照旧：incus image copy dev-base local: --target <node>。
DEPRECATED
  return 1

  # ⚠ 已弃用（见 subcmd_image 开头），以下保留仅供参照，不构成可用路径
  require_root
NODE="${NODE:-node1}"
BASE_IP="${BASE_IP:?必须设置 BASE_IP，例如 10.10.1.250}"
POOL="${POOL:-default}"
IMAGE="${IMAGE:-images:ubuntu/24.04/cloud}"
IMAGE_ALIAS="${IMAGE_ALIAS:-dev-base}"
PROFILE="${PROFILE:-dev}"
BRIDGE="${BRIDGE:-br-vm}"
CPUS="${CPUS:-2}"
MEMORY="${MEMORY:-2GiB}"
DISK="${DISK:-20GiB}"
NAME="railans-base-build"

# 异常退出兜底：构建半路死掉时停掉遗留的构建 VM（只停不删，保留现场排障；
# 下次运行的"2/7 清理同名构建实例"本来就会先强删同名实例）。2026-11-14 余烬教训。
vm_exit_guard() {
  local rc=$?
  if [[ ${rc} -ne 0 ]] && incus list "${NAME}" --format csv 2>/dev/null | grep -q .; then
    echo "WARN: 构建异常退出(rc=${rc})，停掉遗留的 ${NAME}（实例保留供排障）" >&2
    incus stop "${NAME}" --timeout=60 2>/dev/null || incus stop "${NAME}" --force 2>/dev/null || true
  fi
}
trap vm_exit_guard EXIT

if ! command -v incus >/dev/null 2>&1; then
  echo "incus 未安装，先运行 node/railans-node.sh install-incus" >&2
  exit 1
fi
if ! ip link show "${BRIDGE}" >/dev/null 2>&1; then
  echo "${BRIDGE} 不存在，先运行 node/railans-node.sh network" >&2
  exit 1
fi

PREFIX_IP="$(awk -F. '{print $1"."$2"."$3".1"}' <<<"${BASE_IP}")"

echo "==> 1/7 创建 ${PROFILE} profile"
incus profile show "${PROFILE}" >/dev/null 2>&1 || incus profile create "${PROFILE}"
incus profile set "${PROFILE}" limits.cpu "${CPUS}"
incus profile set "${PROFILE}" limits.memory "${MEMORY}"
incus profile device remove "${PROFILE}" eth0  >/dev/null 2>&1 || true
incus profile device remove "${PROFILE}" root  >/dev/null 2>&1 || true
incus profile device add "${PROFILE}" eth0 nic nictype=bridged parent="${BRIDGE}" name=eth0
incus profile device add "${PROFILE}" root disk path=/ pool="${POOL}" size="${DISK}"

echo "==> 2/7 清理同名构建实例"
incus delete "${NAME}" --force >/dev/null 2>&1 || true

echo "==> 3/7 启动模板 VM（${IMAGE} -> ${NAME} on ${NODE}）"
NETCFG="$(cat <<EOF
version: 2
ethernets:
  eth0:
    match:
      name: "en*"
    set-name: eth0
    dhcp4: false
    addresses:
      - ${BASE_IP}/24
    routes:
      - to: default
        via: ${PREFIX_IP}
    nameservers:
      addresses: [1.1.1.1, 8.8.8.8]
EOF
)"
incus launch "${IMAGE}" "${NAME}" \
  --vm \
  --profile "${PROFILE}" \
  --target "${NODE}" \
  --config "cloud-init.network-config=${NETCFG}"

echo "==> 4/7 等待 Incus agent 就绪"
for i in $(seq 1 120); do
  if incus exec "${NAME}" -- true >/dev/null 2>&1; then
    echo "    ready after ${i}0s"
    break
  fi
  if [[ ${i} -eq 120 ]]; then
    echo "模板 VM 8 分钟未就绪。检查：incus info ${NAME} --show-log" >&2
    exit 1
  fi
  sleep 10
done

echo "==> 5/7 安装开发环境"
# 经 stdin 流式喂脚本会在长命令期间被 vsock 中继截断（build #11 实测：
# apt 之后的 provision 全部丢失但退出码为 0）。改为文件推送 + 文件执行。
cat >/tmp/railans-guest.sh <<'GUEST'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  openssh-server ca-certificates curl git jq unzip \
  build-essential pkg-config \
  python3 python3-venv python3-pip \
  nodejs npm \
  ripgrep tmux htop less vim-tiny \
  net-tools dnsutils auditd

# 把 cloud 镜像自带的 ubuntu 用户改名为 dev，保留 uid/gid 1000
if id ubuntu >/dev/null 2>&1 && ! id dev >/dev/null 2>&1; then
  usermod -l dev ubuntu
  if getent group ubuntu >/dev/null 2>&1; then
    groupmod -n dev ubuntu 2>/dev/null || true
  fi
  usermod -d /home/dev -m dev
fi
if ! id dev >/dev/null 2>&1; then
  useradd -m -s /bin/bash -u 1000 dev
fi
if ! getent group dev >/dev/null 2>&1; then
  groupadd dev
fi
usermod -g dev dev
usermod -aG sudo dev 2>/dev/null || true

install -d -o dev -g dev -m 700 /home/dev/.ssh

# 让 cloud-init 把 dev 当默认用户，避免 clone 首启又建一个 ubuntu 账号
# 断线重连自动回到 tmux 现场（仅交互式 shell；scp/exec 不受影响）
if grep -q "railans-tmux-hook" /home/dev/.bashrc 2>/dev/null; then :; else
cat >>/home/dev/.bashrc <<'TMUXHOOK'

# railans-tmux-hook: 有存活的 tmux 会话就自动 attach（重连即回现场）
if [ -z "$TMUX" ] && command -v tmux >/dev/null 2>&1 && tmux ls >/dev/null 2>&1; then
  exec tmux attach
fi
TMUXHOOK
fi

# ---- 安全基线（Lynis 探测响应：R2 悬空 sudoers / R3 lxd 组 / R6-R7 sysctl / R1 box 侧防火墙）----
# R2: 90-cloud-init-users 是改名前 cloud-init 写的，含悬空的 "ubuntu NOPASSWD" 规则
#     （ubuntu 用户已不存在）——将来任何途径创建 ubuntu 即得免密 root，删之；
#     box 首启 cloud-init 会按新 default_user 重写为 dev-only。
rm -f /etc/sudoers.d/90-cloud-init-users
# R3: 云镜像遗留的 lxd 组（guest 内无 lxd 套接字，但减面无害）
deluser dev lxd >/dev/null 2>&1 || true
# R6/R7: 内核基线收紧（对开发机无感知）
cat >/etc/sysctl.d/90-railans-hardening.conf <<'HARD'
kernel.sysrq = 0
net.core.bpf_jit_harden = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
fs.protected_fifos = 2
dev.tty.ldisc_autoload = 0
HARD
sysctl --system >/dev/null 2>&1 || true
# R1: box 侧默认拒绝入站；放行 SSH 与预览端口。
#   来源限内网管理段+box 段：同节点网关=10.10.N.1，跨节点经入口 SNAT=192.168.1.11（192.168.1.0/24 示例段）
if command -v ufw >/dev/null 2>&1 || apt-get install -y ufw >/dev/null 2>&1; then
  ufw default deny incoming >/dev/null
  ufw allow from 10.10.0.0/16 to any port 22 proto tcp >/dev/null
  ufw allow from "${INFRA_NET}" to any port 22 proto tcp >/dev/null
  ufw allow from 10.10.0.0/16 to any port 8080 proto tcp >/dev/null
  ufw allow from "${INFRA_NET}" to any port 8080 proto tcp >/dev/null
  ufw --force enable >/dev/null
  echo "box firewall: ufw enabled (deny incoming; 22+8080 from 10.10/16 + ${INFRA_NET})"
fi

# ---- AI 开发工具链（claude-code / opencode / cc-switch-cli）----
# 凭据与 orca 包不进镜像；由控制面 ensureBox 按箱注入。镜像保持零凭据。
# /home/dev/.cc-switch 只建空目录作为 push 目标
install -d -o dev -g dev -m 700 /home/dev/.cc-switch
echo "== AI 工具链 =="
# claude-code：官方原生安装器，以 dev 运行 → /home/dev/.local/bin/claude
sudo -u dev bash -c 'curl -fsSL https://claude.ai/install.sh | bash' >/dev/null 2>&1 \
  || echo "WARN: claude-code 安装失败"
# opencode（anomalyco fork，npm 全局 → /usr/local/bin/opencode）
npm install -g @opencode/cli >/dev/null 2>&1 \
  || echo "WARN: opencode 安装失败"
# cc-switch-cli（SaladDay fork，GitHub release 二进制 → /usr/local/bin/cc-switch）
curl -4 -fsSL "https://github.com/SaladDay/cc-switch-cli/releases/latest/download/cc-switch-cli-linux-x64.tar.gz" \
  | tar -xz -C /usr/local/bin cc-switch
chmod 755 /usr/local/bin/cc-switch
# 工具自检（缺失仅告警，不阻断）
sudo -u dev bash -lc 'claude --version' 2>/dev/null | head -1 || echo "WARN: claude 不可用"
opencode --version 2>/dev/null | head -1 || echo "WARN: opencode 不可用"
cc-switch --version 2>/dev/null | head -1 || echo "WARN: cc-switch 不可用"

# ---- 安全基线 v2（opencode 审计响应：R2 审计 / R3 tmp / R5 rp_filter / R6 core / R7 cloud-init 退役）----
# R3: /tmp,/var/tmp 防设备/防 suid（/tmp 保留 exec：gcc/npm 工具链偶尔从 tmp 执行，开发机不做 noexec）
grep -q "^/tmp" /etc/fstab || cat >>/etc/fstab <<'FSTAB'
/tmp      /tmp      none  bind,nosuid,nodev         0 0
/var/tmp  /var/tmp  none  bind,nosuid,nodev,noexec  0 0
FSTAB
mount -a 2>/dev/null || true
# R6: 崩溃内存不落盘
echo "kernel.core_pattern = |/bin/false" > /etc/sysctl.d/90-railans-core.conf
# R5: 反向路径严格模式（单网卡 VM 无副作用）
echo "net.ipv4.conf.default.rp_filter = 1" >> /etc/sysctl.d/90-railans-hardening.conf
sed -i 's/^net.ipv4.conf.all.rp_filter.*/net.ipv4.conf.all.rp_filter = 1/' /etc/sysctl.d/90-railans-hardening.conf 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || true
# R7: 首启完成即退役 cloud-init（网络/用户已固化；防实例元数据重写配置）
cat >/etc/systemd/system/railans-retire-cloudinit.service <<'UNIT'
[Unit]
Description=Retire cloud-init after first boot completes
After=cloud-final.service
ConditionPathExists=/var/lib/cloud/instance
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'systemctl disable cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service >/dev/null 2>&1 || true; rm -f /etc/sudoers.d/90-cloud-init-users; exit 0'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable railans-retire-cloudinit.service >/dev/null 2>&1
# R2: auditd 基线审计（默认规则即可；规则细化按需）
systemctl enable --now auditd >/dev/null 2>&1 || true
# ---- 安全基线 v2 结束 ----

# R2 去重：default_user 不写 sudoers（NOPASSWD 由 90-railans-dev 提供；sudo 组成员来自 provision），
# 首启 cloud-init 不再落悬空/重复的 sudoers 规则
cat >/etc/cloud/cloud.cfg.d/99-railans.cfg <<'EOF'
system_info:
  default_user:
    name: dev
    gecos: dev
    shell: /bin/bash
    groups: [adm, sudo]
    sudo: false
    lock_passwd: true
EOF

cat >/etc/ssh/sshd_config.d/99-railans.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowAgentForwarding yes
ClientAliveInterval 30
ClientAliveCountMax 120
EOF
systemctl enable ssh
systemctl restart ssh

# 给每次 clone 一个干净身份
truncate -s 0 /etc/machine-id
cloud-init clean --logs || true
apt-get clean
rm -rf /var/lib/apt/lists/*

sync
echo "guest provisioning done"
GUEST
incus file push /tmp/railans-guest.sh "${NAME}/tmp/railans-guest.sh"
rm -f /tmp/railans-guest.sh
# 从"到集群对端的路由"推导基础设施网段——与跨节点流量的真实来源路径一致；
# 不能用默认路由（VPN 接管默认路由时会推出错网段，INFRA_NET 实测教训）
INFRA_NET="$(ip -4 route get 10.10.2.10 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | cut -d. -f1-3).0/24"
[ -z "${INFRA_NET:-}" ] && INFRA_NET="$(ip -4 route get 1.1.1.1 | grep -oE 'src [0-9.]+' | awk '{print $2}' | cut -d. -f1-3).0/24"
incus exec "${NAME}" -- env DEBIAN_FRONTEND=noninteractive INFRA_NET="${INFRA_NET}" bash -euo pipefail /tmp/railans-guest.sh
# 发布前自检闸：provision 关键产物缺失 = 上游被截断，大声失败；
# 后三闸 = 零凭据/orca 出镜像 + sudo 模型意图真实
incus exec "${NAME}" -- bash -c 'id dev >/dev/null && test -f /etc/sudoers.d/90-railans-dev && test -f /etc/cloud/cloud.cfg.d/99-railans.cfg && test -f /etc/ssh/sshd_config.d/99-railans.conf && ufw status | grep -q active && test ! -e /home/dev/.cc-switch/cc-switch.db && test ! -e /usr/local/bin/orca && grep -q "sudo: false" /etc/cloud/cloud.cfg.d/99-railans.cfg'

echo "==> 6/7 停机并 publish 成 ${IMAGE_ALIAS}"
incus stop "${NAME}" --timeout=60 2>/dev/null || incus stop "${NAME}" --force
incus image delete "${IMAGE_ALIAS}" >/dev/null 2>&1 || true
incus publish "${NAME}" --alias "${IMAGE_ALIAS}" --reuse

echo "==> 7/7 清理构建实例"
incus delete "${NAME}" --force

echo
echo "完成："
incus image list "${IMAGE_ALIAS}"
echo
echo "profile ${PROFILE}:"
incus profile show "${PROFILE}" | sed 's/^/  /'
echo
echo "下单命令（在 node1）：ssh new.box.lan new"
}

# ===== subcommand: control（原 scripts/06-install-control.sh）=====
# 06-install-control.sh — 在入口节点（node1）安装 SSH 控制面
#
# 用法：
#   sudo ./node/railans-node.sh control
#
# 环境变量：
#   BIN             指定二进制路径（默认 bin/railans-linux-<arch>，没有就用本机 go 编译）
#   CONFIG          配置路径（默认 /etc/railans/config.yaml）
#   ADMIN_SSH_PORT  控制面占用 22 时，系统 sshd 挪到哪个端口（默认 2200）
#
# 注意：控制面默认监听 :22，所以入口节点的 OpenSSH 会被挪到 ADMIN_SSH_PORT。
#       这是有意的：ssh new.box.lan 才能不带端口。
# 装 unit 前落低权前置——railans 系统用户（incus-admin 组）、
# /var/lib/railans 0700 属 railans、config 属组 railans、conf.d 属组、polkit 授权
# reload caddy（unit NoNewPrivileges 排除 sudo 路线）。沙箱本体见 node/deploy/railans.service。
subcmd_control() {
  require_root
CONFIG="${CONFIG:-/etc/railans/config.yaml}"
ADMIN_SSH_PORT="${ADMIN_SSH_PORT:-2200}"

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  GOARCH=amd64 ;;
  aarch64) GOARCH=arm64 ;;
  *)       GOARCH="${ARCH}" ;;
esac

BIN="${BIN:-${ROOT_DIR}/bin/railans-linux-${GOARCH}}"
if [[ ! -f "${BIN}" ]]; then
  echo "==> 没找到预编译二进制 ${BIN}，尝试用本机 go 编译"
  if ! command -v go >/dev/null 2>&1; then
    echo "没有 go，也没有预编译二进制。两种办法：" >&2
    echo "  a) apt-get install -y golang-go   # Ubuntu 24.04 自带 1.22，够用" >&2
    echo "  b) 在有 Go 的机器上执行：" >&2
    echo "     cd control && GOOS=linux GOARCH=${GOARCH} go build -o ../bin/railans-linux-${GOARCH} ." >&2
    exit 1
  fi
  ( cd "${ROOT_DIR}/control" && GOOS=linux GOARCH="${GOARCH}" go build -o "${BIN}" . )
fi

echo "==> 1/5 安装二进制"
install -d /etc/railans /var/lib/railans
install -m 0755 "${BIN}" /usr/local/bin/railans

echo "==> 2/5 安装配置"
if [[ ! -f "${CONFIG}" ]]; then
  install -m 0640 "${SCRIPT_DIR}/deploy/config.example.yaml" "${CONFIG}"
  CODE="$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  sed -i "s/^  enroll_code: .*/  enroll_code: \"${CODE}\"/" "${CONFIG}"
  echo "    已生成随机 enroll_code:"
  echo "      ${CODE}"
  echo "    保存好：客户端执行 ssh new.box.lan enroll <code> <label>"
else
  echo "    配置已存在，保留不动：${CONFIG}"
fi

LISTEN_PORT="$(awk -F: '/^listen:/ {gsub(/[^0-9]/,"",$NF); print $NF}' "${CONFIG}")"
LISTEN_PORT="${LISTEN_PORT:-22}"
echo "    控制面监听端口: ${LISTEN_PORT}"

echo "==> 3/5 处理 22 端口冲突"
if [[ "${LISTEN_PORT}" == "22" ]] && ss -lntH 'sport = :22' 2>/dev/null | grep -q .; then
  echo "    22 已被占用（多半是 OpenSSH），把系统 sshd 挪到 ${ADMIN_SSH_PORT}"
  if systemctl is-active --quiet ssh.socket; then
    systemctl disable --now ssh.socket
  fi
  sed -i -E 's/^[[:space:]]*Port[[:space:]]+22[[:space:]]*$/# Port 22 moved to railans admin port/' /etc/ssh/sshd_config
  cat >/etc/ssh/sshd_config.d/99-railans-admin-port.conf <<EOF
# 由 railans 安装脚本生成：22 让给 railans 控制面
Port ${ADMIN_SSH_PORT}
EOF
  sshd -t
  systemctl enable ssh
  systemctl restart ssh
  sleep 1
  if ! ss -lntH "sport = :${ADMIN_SSH_PORT}" | grep -q .; then
    echo "系统 sshd 没能在 ${ADMIN_SSH_PORT} 起来，停止安装以免失去管理通道" >&2
    exit 1
  fi
  echo "    管理 SSH 现在是：ssh -p ${ADMIN_SSH_PORT} root@<entry>"
else
  echo "    无需处理"
fi

echo "==> 4/5 安装 systemd 服务（M4：专用低权用户 + 沙箱前置）"
# 1) railans 系统用户 + incus-admin 组（incus 调用走 unix socket 组权限，无需 root）
if ! id railans >/dev/null 2>&1; then
  groupadd -r railans 2>/dev/null || true   # 部分发行版 useradd -r 不自动建同名组
  useradd -r -g railans -s /usr/sbin/nologin railans
  echo "    已创建系统用户 railans"
fi
if getent group incus-admin >/dev/null 2>&1; then
  usermod -aG incus-admin railans
else
  echo "    WARN: incus-admin 组不存在（先跑 install-incus/deploy），装好后重跑本命令入组" >&2
fi
# 2) 数据目录 0700 属 railans（存量 state/host key 属主一并迁移，幂等）
install -d -o railans -g railans -m 700 /var/lib/railans
chown -R railans:railans /var/lib/railans
# 3) config 属组 railans 保 0640（unit Group=railans 靠属组可读；config 只读不进 ReadWritePaths）
chown root:railans "${CONFIG}"
chmod 0640 "${CONFIG}"
# 4) caddy conf.d 属组 railans + g+w（caddy.go 写站点文件；caddy 未装则装完重跑本命令补上）
if [[ -d /etc/caddy/conf.d ]]; then
  chgrp railans /etc/caddy/conf.d
  chmod g+w /etc/caddy/conf.d
else
  echo "    /etc/caddy/conf.d 不存在（caddy 未装？）：装完 caddy 后重跑本命令补属组"
fi
# 5) polkit drop-in：授权 railans 用户管理 caddy.service（reload 走 D-Bus，不用 sudo）
install -d -m 755 /etc/polkit-1/rules.d
cat >/etc/polkit-1/rules.d/49-railans-caddy-reload.rules <<'POLKIT'
// 由 railans-node.sh control 生成（M4）：仅授权 railans 用户管理 caddy.service，
// 其余 unit 与操作一律不授权
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        subject.user == "railans" &&
        action.lookup("unit") == "caddy.service") {
        return polkit.Result.YES;
    }
});
POLKIT
# 6) 装 unit + enable
install -m 0644 "${SCRIPT_DIR}/deploy/railans.service" /etc/systemd/system/railans.service
systemctl daemon-reload
systemctl enable railans.service

echo "==> 5/5 启动"
systemctl restart railans.service
sleep 2
systemctl --no-pager --lines=20 status railans.service || true

cat <<EOF

完成。检查：
  journalctl -u railans -f
  ss -lntp | grep -E ':${LISTEN_PORT}\b'

第一次使用前：
  1) 确认 ${CONFIG} 里的 nodes/subnet/gateway 与真实网络一致
  2) 客户端 DNS 能解析 new.box.lan -> 入口 IP
  3) ssh new.box.lan enroll <enroll_code> <label>
  4) ssh new.box.lan new

管理机自己的 SSH（如果被挪过）：ssh -p ${ADMIN_SSH_PORT} root@<entry>

改完配置后：systemctl restart railans
EOF
}

# ===== subcommand: caddy（原 scripts/07-install-caddy-dns.sh）=====
# 07-install-caddy-dns.sh — 在入口节点安装 Caddy（预览反代）和 dnsmasq（内网 DNS）
#
# 用法：
#   sudo ENTRY_IP=192.168.1.11 ./node/railans-node.sh caddy
#
# 环境变量：
#   ENTRY_IP  局域网里指向入口节点的 IP（默认取本机第一个非回环 IPv4）
#   DOMAIN    预览域名后缀（默认 box.lan）
#   UPSTREAM  dnsmasq 上游 DNS（默认 1.1.1.1,8.8.8.8）
subcmd_caddy() {
  require_root
ENTRY_IP="${ENTRY_IP:-$(hostname -I | awk '{print $1}')}"
DOMAIN="${DOMAIN:-box.lan}"
UPSTREAM="${UPSTREAM:-1.1.1.1,8.8.8.8}"

if [[ -z "${ENTRY_IP}" ]]; then
  echo "无法确定 ENTRY_IP，请显式设置" >&2
  exit 1
fi

echo "==> 1/4 安装 Caddy"
if ! command -v caddy >/dev/null 2>&1; then
  if ! apt-get install -y caddy >/dev/null 2>&1; then
    echo "    发行版仓库没有 caddy，改用官方 apt 源"
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg >/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y caddy
  fi
fi
caddy version

echo "==> 2/4 写 Caddyfile"
install -d /etc/caddy/conf.d
if [[ -f /etc/caddy/Caddyfile ]] && ! grep -q 'railans' /etc/caddy/Caddyfile; then
  cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%s)"
fi
install -m 0644 "${SCRIPT_DIR}/deploy/Caddyfile" /etc/caddy/Caddyfile
# import 的 glob 必须有文件，否则 caddy 会报错；控制面会原子覆盖它
if [[ ! -f /etc/caddy/conf.d/boxes.caddy ]]; then
  printf '# managed by railans; do not edit\n' >/etc/caddy/conf.d/boxes.caddy
fi
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl enable caddy
systemctl restart caddy

echo "==> 3/4 安装 dnsmasq"
apt-get update -qq
apt-get install -y dnsmasq

# 只监听入口 IP，避免和 systemd-resolved 的 127.0.0.53:53 冲突
cat >/etc/dnsmasq.d/railans.conf <<EOF
# 由 railans 安装脚本生成
listen-address=127.0.0.1,${ENTRY_IP}
bind-interfaces
no-resolv
server=$(echo "${UPSTREAM}" | cut -d, -f1)
server=$(echo "${UPSTREAM}" | cut -d, -f2)
address=/${DOMAIN}/${ENTRY_IP}
local-ttl=30
EOF
systemctl enable dnsmasq
systemctl restart dnsmasq

echo "==> 4/4 自检"
ss -lntup | grep -E ':53\b|:443\b' || true
dig +short "new.${DOMAIN}" @"${ENTRY_IP}" || true

cat <<EOF

完成。

客户端 DNS 指向 ${ENTRY_IP} 后：
  new.${DOMAIN}       -> ${ENTRY_IP}
  *.${DOMAIN}         -> ${ENTRY_IP}

Caddy 用内部 CA 签 HTTPS 证书。客户端要信任它，需要把
  /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
安装到系统/浏览器信任库。命令示例：

  # Linux
  sudo cp root.crt /usr/local/share/ca-certificates/railans-caddy.crt
  sudo update-ca-certificates

  # macOS
  sudo security add-trusted-cert -d -r trustRoot \\
    -k /Library/Keychains/System.keychain root.crt

  # Windows（管理员 PowerShell）
  Import-Certificate -FilePath root.crt -CertStoreLocation Cert:\\LocalMachine\\Root

注意：
  * 预览地址是 https://box-xxxxxx.${DOMAIN}
  * 未执行 share 前，Caddy 只允许创建者 IP 访问
  * 如果 53 端口被占用：systemctl status dnsmasq 看具体冲突
EOF
}

# ===== subcommand: deploy（原 scripts/deploy-node.sh）=====
# railans 集群节点上架脚本 —— 多节点扩展用（node2/3/4…，或入口节点刷新路由）
#
# 用法（在目标机器上，以能 sudo 的用户执行）：
#   0) 先把 kit 拷到本机（脚本按 KIT_SRC 自动以原用户身份拉取，也可手动）：
##      scp -r <user>@<kit 所在主机>:~/railans-kit /tmp/railans-kit
#   1) sudo env NODE_NAME=node2 NODE_ADDR=192.168.1.12 \
#        SUBNET=10.10.2.0/24 \
#        ROUTES="10.10.1.0/24 via 192.168.1.11;10.10.3.0/24 via 192.168.1.13;10.10.4.0/24 via 192.168.1.14" \
#        bash /tmp/railans-kit/node/railans-node.sh deploy
#
# 做五件事：
#   1. Zabbly apt 仓安装 incus（幂等；已装则跳过）
#   2. incus 用户加入 kvm 组（Zabbly deb 装法必需，见 STATUS §5-2）
#   3. 调用用户加入 incus-admin 组（后续集群 join 由入口节点远程驱动）
#   4. 运行 kit 的 04-node-network.sh：br-vm 网桥 + nftables 隔离 +
#      跨节点路由（ROUTES）+ Docker 共存 helper（有 Docker 自动处理）
#   5. 输出 join 待命状态（join 由入口节点侧生成 token + preseed 完成，无需本机操作）
#
# 环境变量：NODE_NAME / NODE_ADDR / SUBNET / ROUTES 必填或按机器定；GATEWAY/WAN/BRIDGE 可覆盖
subcmd_deploy() {
  require_root
NODE_NAME="${NODE_NAME:?必须设置 NODE_NAME，例如 node2}"
NODE_ADDR="${NODE_ADDR:?必须设置 NODE_ADDR，例如 192.168.1.12}"
SUBNET="${SUBNET:?必须设置 SUBNET，例如 10.10.2.0/24}"
ROUTES="${ROUTES:-}"
KIT="/tmp/railans-kit"
KIT_SRC="${KIT_SRC:-}"   # kit 源（scp 形态 <user>@<kit主机>:<路径>，例 ops@node1:~/railans-kit）

echo "== 0/4 拉取 kit（若本机没有）=="
if [[ ! -d ${KIT}/node ]]; then
  SU="${SUDO_USER:-}"
  if [[ -z "${KIT_SRC}" ]]; then
    echo "找不到 ${KIT}：设 KIT_SRC=<user@host:路径>（kit 仓所在位置）后重跑，或手动 scp -r <kit 仓> ${KIT}" >&2
    exit 1
  fi
  if [[ -n ${SU} ]]; then
    sudo -u "${SU}" scp -q -r "${KIT_SRC}" "${KIT}" \
      || { echo "kit 拉取失败：手动执行 scp -r ${KIT_SRC} ${KIT} 后重跑" >&2; exit 1; }
  else
    echo "找不到 ${KIT} 且无法推断原用户，请先手动 scp kit" >&2
    exit 1
  fi
fi

echo "== 1/4 安装 incus（Zabbly apt 仓，幂等）=="
if command -v incus >/dev/null 2>&1; then
  echo "    incus 已安装: $(incus --version 2>/dev/null || incus version 2>/dev/null | head -1)"
else
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
  . /etc/os-release
  cat > /etc/apt/sources.list.d/zabbly-incus-stable.sources <<ZEOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: ${VERSION_CODENAME}
Components: main
Signed-By: /etc/apt/keyrings/zabbly.asc
ZEOF
  apt-get update -qq
  apt-get install -y incus
fi
incus --version 2>/dev/null || incus version | head -1

echo "== 2/4 incus 用户加入 kvm 组（QEMU 需要 /dev/kvm 访问权）=="
usermod -aG kvm incus
getent group kvm | grep -q incus || { echo "入组失败" >&2; exit 1; }

echo "== 3/5 ${SUDO_USER:-} 加入 incus-admin 组 =="
if [[ -n ${SUDO_USER:-} ]]; then
  usermod -aG incus-admin "${SUDO_USER}"
  echo "    ${SUDO_USER} 已入 incus-admin（join 由入口节点远程驱动）"
fi

echo "== 3b/4 rootless podman subuid/subgid =="
# 与 VM 创建链路无依赖：失败只 WARN 不阻断上架（|| 兜住 set -e），可稍后单独补跑
subcmd_setup_subuid || echo "WARN: rootless podman subuid/subgid 配置失败（不阻断上架），可稍后重跑：sudo ./node/railans-node.sh setup-subuid"

echo "== 4/4 VM 网络（kit 04：网桥/nftables/路由/Docker 共存）=="
NODE_ADDR="${NODE_ADDR}" SUBNET="${SUBNET}" WAN="${WAN:-}" \
  GATEWAY="${GATEWAY:-}" BRIDGE="${BRIDGE:-br-vm}" ROUTES="${ROUTES}" \
  bash "${KIT}/node/railans-node.sh" network

echo
echo "== 完成：${NODE_NAME}（${NODE_ADDR}）已就绪，等待入口节点侧驱动 join =="
echo "   集群成员名单与 join 状态由维护者在入口节点上确认：incus cluster list"
}
# ===== subcommand: setup-subuid（新增：rootless podman 前置依赖纳管钩子）=====
#
# 用法（节点本机，root）：
#   sudo ./node/railans-node.sh setup-subuid
#
# 语义：给节点宿主上跑 rootless podman 的目标用户写 /etc/subuid、/etc/subgid 的
# subordinate ID 段条目（<user>:<start>:<count>）。幂等、追加式：
#   - 目标用户已有任意条目（^<user>:）→ 跳过不动（不破坏既有映射优先于补大范围）；
#   - 「检查+写入」整段进 flock 临界区（锁文件与目标文件同目录），并发双跑恰好一行；
#   - 本机没有 podman → SKIP 退出 0，不写任何文件（node3 场景）；
#   - subuid / subgid 各自独立判定与写入（可能一有一无）。
#
# 环境变量：
#   SUBID_USER                    目标用户（缺省链 SUBID_USER > SUDO_USER > ops，
#                                 与 healthcheck 的 ssh 用户候选链同源）
#   SUBUID_START / SUBUID_COUNT   subuid 段起点/长度（缺省 100000/65536，useradd 惯例默认段）
#   SUBGID_START / SUBGID_COUNT   subgid 段起点/长度（缺省同上）
#   SUBUID_FILE / SUBGID_FILE     目标文件（可测性钩子，缺省 /etc/subuid、/etc/subgid）
#
# deploy 一条龙在 3b/4 步挂本子命令（失败只 WARN 不阻断，可单独补跑）。

su_pass() { printf '  %sPASS%s %s\n' "$C_OK" "$C_RST" "$*"; }
su_fail() { printf '  %sFAIL%s %s\n' "$C_ERR" "$C_RST" "$*"; }
su_skip() { printf '  %sSKIP%s %s\n' "$C_DIM" "$C_RST" "$*"; }

subcmd_setup_subuid() {
  require_root

  # node3 场景：无 podman 即无需配置；此处返回前绝不落任何文件（含锁文件）
  if ! command -v podman >/dev/null 2>&1; then
    su_skip "本机没有 podman，rootless podman 的 subuid/subgid 无需配置；装上 podman 后可补跑：sudo ./node/railans-node.sh setup-subuid"
    return 0
  fi

  local su_user="${SUBID_USER:-${SUDO_USER:-ops}}"
  local su_uid_start="${SUBUID_START:-100000}" su_uid_count="${SUBUID_COUNT:-65536}"
  local su_gid_start="${SUBGID_START:-100000}" su_gid_count="${SUBGID_COUNT:-65536}"
  local su_uid_file="${SUBUID_FILE:-/etc/subuid}" su_gid_file="${SUBGID_FILE:-/etc/subgid}"
  local su_failed=0 su_kind su_file su_start su_count su_line su_have su_existed

  # 「检查+写入」整段进 flock 临界区：锁文件与目标文件同目录（root 可写）。
  # 锁创建不了/等锁超时都按 FAIL 退出非 0，绝不无锁直写。
  if ! touch "${su_uid_file}.lock" 2>/dev/null; then
    su_fail "无法创建锁文件 ${su_uid_file}.lock（目录不可写？）"
    return 1
  fi
  exec 9>"${su_uid_file}.lock"
  if ! flock -w 30 9; then
    su_fail "等 ${su_uid_file}.lock 超 30s（并发 setup-subuid 卡住？）"
    return 1
  fi

  for su_kind in subuid subgid; do
    if [[ "$su_kind" == "subuid" ]]; then
      su_file="$su_uid_file"
      su_start="$su_uid_start"
      su_count="$su_uid_count"
    else
      su_file="$su_gid_file"
      su_start="$su_gid_start"
      su_count="$su_gid_count"
    fi
    su_line="${su_user}:${su_start}:${su_count}"

    # 已有任意条目 → 跳过不动（哪怕范围更小），只回显现有范围
    if [[ -f "$su_file" ]] && grep -q "^${su_user}:" "$su_file"; then
      su_have="$(grep -m1 "^${su_user}:" "$su_file" || true)"
      su_pass "${su_kind}：${su_user} 已存在条目（${su_have}），跳过不动（不破坏既有映射）"
      continue
    fi

    su_existed=0
    if [[ -e "$su_file" ]]; then
      su_existed=1
    fi
    # 文件不存在 → 以 mode 600 创建后追加；存在则原文件与原 mode 不动，只追加一行
    if ( umask 177; printf '%s\n' "$su_line" >> "$su_file" ) 2>/dev/null; then
      if [[ "$su_existed" -eq 1 ]]; then
        su_pass "${su_kind}：已写入 ${su_line}（追加）"
      else
        su_pass "${su_kind}：已创建 ${su_file}（mode 600）；已写入 ${su_line}"
      fi
    else
      su_fail "${su_kind}：写入 ${su_file} 失败（目录不可写/磁盘满？）"
      su_failed=1
    fi
  done

  if [[ "$su_failed" -eq 1 ]]; then
    su_fail "setup-subuid：subuid/subgid 未全部就绪（处理后可重跑 sudo ./node/railans-node.sh setup-subuid）"
    return 1
  fi
}
# ===== subcommand: deploy-remote（新增：控制机侧一条命令把 kit 送到目标机并上架）=====
#
# 用法（在控制机/入口节点上执行，本机普通用户即可）：
#   ./node/railans-node.sh deploy-remote <user@host> \
#     NODE_NAME=node5 NODE_ADDR=192.168.1.15 SUBNET=10.10.5.0/24 \
#     [ROUTES="10.10.1.0/24 via 192.168.1.11;..."] [GATEWAY=...] [WAN=...] [BRIDGE=...] \
#     [--yes]
#
# 行为：
#   1. rsync 本仓库到目标机 /tmp/railans-kit（排除 .git/、.local-test/）
#   2. ssh 目标机执行 sudo env <全部变量> bash /tmp/railans-kit/node/railans-node.sh deploy
#
# 缺省是干跑：只打印目标、变量与两条完整命令，不连目标机。带 --yes 才真的执行。
# 变量原样透传给 deploy 子命令（NODE_NAME / NODE_ADDR / SUBNET 必填）。
# 远端 ssh 在本地是交互终端时分配 tty，sudo 可以输密码；非交互时需目标机免密 sudo。
#
# 这是全脚本唯一的跨节点写操作入口；跨节点只读入口是 healthcheck --all。

DEPLOY_REMOTE_REQUIRED=(NODE_NAME NODE_ADDR SUBNET)
DEPLOY_REMOTE_ALLOWED=(NODE_NAME NODE_ADDR SUBNET ROUTES GATEWAY WAN BRIDGE)

subcmd_deploy_remote() {
  local target='' yes=0 arg='' key='' name='' kv='' found=0
  local remote_cmd='sudo env'
  local -a pairs=() missing=() ssh_opts=() rsync_args=()
  for arg in "$@"; do
    case "$arg" in
      --yes | -y)
        yes=1
        ;;
      -*)
        echo "deploy-remote：不认识的选项 ${arg}（只支持 --yes）" >&2
        return 2
        ;;
      *=*)
        key="${arg%%=*}"
        if [[ " ${DEPLOY_REMOTE_ALLOWED[*]} " != *" ${key} "* ]]; then
          echo "deploy-remote：不支持的变量 ${key}（可用：${DEPLOY_REMOTE_ALLOWED[*]}）" >&2
          return 2
        fi
        if [[ -z "${arg#*=}" ]]; then
          echo "deploy-remote：变量 ${key} 的值是空的" >&2
          return 2
        fi
        pairs+=("$arg")
        ;;
      *)
        if [[ -n "$target" ]]; then
          echo "deploy-remote：只接受一个目标机，多余的参数是 ${arg}" >&2
          return 2
        fi
        target="$arg"
        ;;
    esac
  done

  if [[ -z "$target" ]]; then
    echo "用法: railans-node.sh deploy-remote <user@host> NODE_NAME=... NODE_ADDR=... SUBNET=... [ROUTES=...] [GATEWAY=...] [WAN=...] [BRIDGE=...] [--yes]" >&2
    return 2
  fi
  if [[ "$target" != *@* || "$target" == *[[:space:]]* ]]; then
    echo "deploy-remote：目标机要写成 user@host（例如 ops@192.168.1.15），收到 '${target}'" >&2
    return 2
  fi

  for name in "${DEPLOY_REMOTE_REQUIRED[@]}"; do
    found=0
    for kv in "${pairs[@]}"; do
      if [[ "${kv%%=*}" == "$name" ]]; then
        found=1
        break
      fi
    done
    if ((found == 0)); then
      missing+=("$name")
    fi
  done
  if ((${#missing[@]} > 0)); then
    echo "deploy-remote：缺必填变量 ${missing[*]}" >&2
    return 2
  fi

  for kv in "${pairs[@]}"; do
    remote_cmd+=" $(printf '%q' "$kv")"
  done
  remote_cmd+=" bash /tmp/railans-kit/node/railans-node.sh deploy"

  ssh_opts=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
  rsync_args=(-az --exclude .git --exclude .local-test -e "ssh ${ssh_opts[*]}")

  echo "== deploy-remote 计划 =="
  echo "  目标机:   ${target}"
  echo "  远端目录: /tmp/railans-kit"
  echo "  本地仓库: ${ROOT_DIR}（排除 .git/、.local-test/）"
  echo "  变量:"
  for kv in "${pairs[@]}"; do
    echo "    ${kv}"
  done
  echo "  将执行:"
  echo "    1) ssh ${target} 'mkdir -p /tmp/railans-kit'"
  echo "    2) rsync ${rsync_args[*]} '${ROOT_DIR}/' '${target}:/tmp/railans-kit/'"
  if [[ -t 0 && -t 1 ]]; then
    echo "    3) ssh -t ${target} '${remote_cmd}'   # tty：sudo 可输密码"
  else
    echo "    3) ssh ${target} '${remote_cmd}'   # 非交互：需目标机免密 sudo"
  fi

  if ((yes == 0)); then
    echo
    echo "干跑：未带 --yes，没有连目标机、也没改任何东西。"
    echo "确认无误后重跑上面这条命令并加 --yes。"
    return 0
  fi

  echo
  echo "== 1/2 rsync → ${target}:/tmp/railans-kit =="
  ssh "${ssh_opts[@]}" "$target" 'mkdir -p /tmp/railans-kit'
  rsync "${rsync_args[@]}" "${ROOT_DIR}/" "${target}:/tmp/railans-kit/"

  echo
  echo "== 2/2 远端上架：railans-node.sh deploy =="
  if [[ -t 0 && -t 1 ]]; then
    ssh -t "${ssh_opts[@]}" "$target" "$remote_cmd"
  else
    ssh "${ssh_opts[@]}" "$target" "$remote_cmd"
  fi
  echo
  echo "完成：${target} 侧 deploy 已返回。集群成员与 join 状态在 node1 上确认："
  echo "  sudo ./node/railans-node.sh healthcheck --all"
}
# ===== subcommand: healthcheck（新增，断言式节点体检）=====
#
# 用法：
#   sudo ./node/railans-node.sh healthcheck          # 只查本机
#        ./node/railans-node.sh healthcheck --all    # 从本机逐台 ssh 各成员汇总
#
# 只读：除 ping / ssh（执行对端的同一个 healthcheck）外不发起任何动作，
# 不创建实例、不写文件、不改网络与防火墙。
#
# 断言项（逐项 PASS/WARN/FAIL/SKIP）：
#   /dev/kvm 存在；incus 用户在 kvm 组
#   VM 真能力：incus query /1.0 的 driver 必须含 qemu
#     （#1 事故的坑：feature checks 失败时 qemu driver 不注册，launch --vm 报
#      Instance type "virtual-machine" is not supported: QEMU failed to run feature checks）
#   incus cluster list：本机在册且全部成员 ONLINE
#   br-vm 网桥在；nftables inet railans 表已加载；到各 peer 子网路由在且网关可达
#   railans / caddy 服务 active（未安装则 SKIP：非入口节点）
#   磁盘 / 与 /var 剩余 <15% WARN、<5% FAIL；时间同步 NTPSynchronized=yes
#   控制面文件权限（M1）：kit .local-test/ 与打包 /etc/railans+/var/lib/railans 布局按存在才查；
#   enroll code 与 config 超宽 FAIL，目录/日志/state/host key 超宽 WARN（hc_control_perms）
#
# 退出码：有 FAIL -> 1；否则 0（WARN/SKIP 不影响）。

HC_FAILS=0
HC_WARNS=0
HC_MEMBERS=""
HC_SELF=""
HC_SSH_USER=""

hc_pass() { printf '  %sPASS%s %s\n' "$C_OK" "$C_RST" "$*"; }
hc_warn() { HC_WARNS=$((HC_WARNS + 1)); printf '  %sWARN%s %s\n' "$C_WARN" "$C_RST" "$*"; }
hc_fail() { HC_FAILS=$((HC_FAILS + 1)); printf '  %sFAIL%s %s\n' "$C_ERR" "$C_RST" "$*"; }
hc_skip() { printf '  %sSKIP%s %s\n' "$C_DIM" "$C_RST" "$*"; }

# 只读 incus 调用；当前会话未刷 newgrp 时回退到 sg incus-admin（不交互要密码）
hc_incus() {
  local out='' cmd='incus' a
  if out="$(incus "$@" 2>&1)"; then
    printf '%s\n' "$out"
    return 0
  fi
  if command -v sg >/dev/null 2>&1 &&
    getent group incus-admin 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | grep -qx "$(id -un)"; then
    for a in "$@"; do cmd+=" $(printf '%q' "$a")"; done
    if out="$(sg incus-admin -c "$cmd" 2>&1)"; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  printf '%s\n' "$out"
  return 1
}

# 集群成员：name<TAB>url-host<TAB>status
hc_members() {
  local raw=''
  raw="$(hc_incus cluster list --format csv 2>/dev/null)" || return 0
  awk -F, 'NF >= 7 && $1 != "" {
    u = $2; sub(/^[a-z]+:\/\//, "", u); sub(/:[0-9]+$/, "", u);
    printf "%s\t%s\t%s\n", $1, u, $(NF - 1)
  }' <<<"$raw"
}

hc_self_name() {
  local out=''
  out="$(hc_incus query /1.0 2>/dev/null)" || return 0
  sed -n 's/^[[:space:]]*"server_name":[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$out" | head -1
}

hc_kvm() {
  local g=''
  if [[ -e /dev/kvm ]]; then
    hc_pass "/dev/kvm 存在"
  else
    hc_fail "/dev/kvm 不存在：物理机需 BIOS 开 VT-x/AMD-V；嵌套 VM 需透传 kvm"
  fi
  g="$(getent group kvm 2>/dev/null || true)"
  if [[ -z "$g" ]]; then
    hc_fail "kvm 组不存在（/dev/kvm 的属组）：确认内核 KVM 模块已加载"
  elif awk -F: '{print $4}' <<<"$g" | tr ',' '\n' | grep -qx incus; then
    hc_pass "incus 用户在 kvm 组"
  else
    hc_fail "incus 用户不在 kvm 组：usermod -aG kvm incus && systemctl restart incus"
  fi
}

hc_vm_capability() {
  local out='' drv='' ver='' hit=''
  if ! out="$(hc_incus query /1.0 2>&1)"; then
    if grep -qiE 'not supported|QEMU failed' <<<"$out"; then
      hit="$(grep -iE 'not supported|QEMU failed' <<<"$out" | head -1 | cut -c1-240)"
      hc_fail "VM 能力（${HC_SELF:-本机}）：Incus 拒绝 VM —— ${hit}"
    else
      hc_fail "VM 能力（${HC_SELF:-本机}）：查不到 Incus API —— $(head -1 <<<"$out" | cut -c1-200)"
    fi
    return 0
  fi
  hit="$(grep -iE 'not supported|QEMU failed' <<<"$out" | head -1 || true)"
  if [[ -n "$hit" ]]; then
    hc_fail "VM 能力（${HC_SELF:-本机}）：命中 Incus 原文 —— $(cut -c1-240 <<<"$hit")"
    return 0
  fi
  drv="$(sed -n 's/^[[:space:]]*"driver":[[:space:]]*"\(.*\)",\{0,1\}$/\1/p' <<<"$out" | head -1)"
  ver="$(sed -n 's/^[[:space:]]*"driver_version":[[:space:]]*"\(.*\)",\{0,1\}$/\1/p' <<<"$out" | head -1)"
  if [[ "$drv" == *qemu* ]]; then
    hc_pass "VM 能力：qemu driver 已加载（driver=${drv}，driver_version=${ver:-unknown}）"
  else
    hc_fail "VM 能力（${HC_SELF:-本机}）：Incus 只加载了 ${drv:-unknown}，没有 qemu —— launch --vm 会报 virtual-machine not supported / QEMU failed to run feature checks"
  fi
}

hc_cluster() {
  local line='' name='' host='' status='' bad=0 total=0
  if [[ -z "$HC_MEMBERS" ]]; then
    hc_fail "集群：incus cluster list 无输出（本机未加入集群，或 incusd 不可用）"
    return 0
  fi
  if [[ -z "$HC_SELF" ]]; then
    hc_fail "集群：取不到本机成员名（incus query /1.0 的 server_name）"
  elif awk -F'\t' -v s="$HC_SELF" '$1 == s {found = 1} END {exit !found}' <<<"$HC_MEMBERS"; then
    hc_pass "集群：本机 ${HC_SELF} 在册"
  else
    hc_fail "集群：本机 ${HC_SELF} 不在成员列表里"
  fi
  while IFS=$'\t' read -r name host status; do
    [[ -n "$name" ]] || continue
    total=$((total + 1))
    if [[ "${status^^}" != ONLINE ]]; then
      bad=$((bad + 1))
      hc_fail "集群：成员 ${name}（${host}）状态 ${status} —— 看 incus cluster list 的 MESSAGE 与 journalctl -u incus"
    fi
  done <<<"$HC_MEMBERS"
  if ((bad == 0)); then
    hc_pass "集群：${total} 个成员全部 ONLINE"
  fi
}

hc_bridge() {
  local br="${BRIDGE:-br-vm}" addrs=''
  if ! ip link show "$br" >/dev/null 2>&1; then
    hc_fail "网桥 ${br} 不存在：先跑 railans-node.sh network"
    return 0
  fi
  addrs="$(ip -4 -brief addr show "$br" 2>/dev/null | awk '{print $3}' | head -1)"
  if [[ -n "$addrs" ]]; then
    hc_pass "网桥 ${br} 在，IPv4 ${addrs}"
  else
    hc_fail "网桥 ${br} 在但没有 IPv4 地址（VM 网关缺失）"
  fi
}

hc_nftables() {
  local nft_bin='' out='' c=''
  nft_bin="$(command -v nft 2>/dev/null || true)"
  if [[ -z "$nft_bin" ]]; then
    for c in /usr/sbin/nft /sbin/nft /usr/bin/nft; do
      if [[ -x "$c" ]]; then
        nft_bin="$c"
        break
      fi
    done
  fi
  if [[ -n "$nft_bin" ]] && out="$("$nft_bin" list table inet railans 2>&1)"; then
    if grep -q 'chain' <<<"$out"; then
      hc_pass "nftables inet railans 表已加载"
    else
      hc_fail "nftables inet railans 表存在但没有规则链"
    fi
    return 0
  fi
  # 读不到规则集（无 root / nft 不在 PATH）：退回 unit 状态判定，并在输出里注明
  if ! systemctl cat railans-nftables.service >/dev/null 2>&1; then
    if [[ -z "$nft_bin" ]]; then
      hc_fail "nftables：nft 未安装，也没有 railans-nftables.service（先跑 railans-node.sh network）"
    else
      hc_skip "nftables：无 root 读不到规则集，本机也没有 railans-nftables.service，无法判定"
    fi
    return 0
  fi
  if systemctl is-active --quiet railans-nftables.service; then
    hc_pass "nftables：按 railans-nftables.service=active 判定（未直接读规则集）"
  else
    hc_fail "railans-nftables.service 未运行：规则可能没加载，systemctl status railans-nftables"
  fi
}

hc_routes() {
  local br="${BRIDGE:-br-vm}" prefix='' p='' entry='' dst='' gw='' gwvm='' line='' cross=''
  local found=0 expected=0 members=0
  prefix="$(ip -4 -brief addr show "$br" 2>/dev/null | awk '{print $3}' | head -1 | cut -d. -f1-2)"
  if [[ -z "$prefix" ]]; then
    hc_skip "跨节点路由：${br} 无 IPv4 地址，无法判定 VM 网段前缀"
    return 0
  fi
  p="${prefix//./\\.}"
  if [[ -n "${ROUTES:-}" ]]; then
    local IFS=';'
    for entry in ${ROUTES}; do
      entry="$(echo "$entry" | xargs)"
      [[ -n "$entry" ]] || continue
      dst="${entry%% *}"
      gw="$(awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}' <<<"$entry")"
      found=$((found + 1))
      if ip -4 route show "$dst" 2>/dev/null | grep -q .; then
        gwvm="$(sed -E 's#^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/.*#\1.1#' <<<"$dst")"
        if ping -c 1 -W 1 "$gwvm" >/dev/null 2>&1; then
          hc_pass "路由 ${dst} via ${gw:-?} 在，网关 ${gwvm} 可达"
        else
          hc_fail "路由 ${dst} via ${gw:-?} 在，但 ${gwvm} ping 不通（对端网桥/防火墙/路由丢失）"
        fi
      else
        hc_fail "路由 ${dst} via ${gw:-?} 缺失（ROUTES 声明了但路由表里没有）"
      fi
    done
    return 0
  fi
  cross="$(ip -4 route show | grep -E "^${p}\.[0-9]+\.[0-9]+/" | grep -v "dev ${br}\b" || true)"
  if [[ -n "$cross" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      dst="${line%% *}"
      gw="$(awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}' <<<"$line")"
      found=$((found + 1))
      gwvm="$(sed -E 's#^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/.*#\1.1#' <<<"$dst")"
      if ping -c 1 -W 1 "$gwvm" >/dev/null 2>&1; then
        hc_pass "跨节点路由 ${dst} via ${gw:-?}，网关 ${gwvm} 可达"
      else
        hc_fail "跨节点路由 ${dst} via ${gw:-?} 在，但 ${gwvm} ping 不通（对端网桥/防火墙/路由丢失）"
      fi
    done <<<"$cross"
  fi
  members="$(printf '%s\n' "${HC_MEMBERS:-}" | grep -c . || true)"
  if ((members > 1)); then
    expected=$((members - 1))
    if ((found < expected)); then
      hc_fail "跨节点路由：集群 ${members} 成员，期望 ${expected} 条 ${prefix}.x 路由，实际 ${found} 条（systemctl restart railans-routes；或用 ROUTES=... 重跑 railans-node.sh network）"
    fi
  elif ((found > 0)); then
    hc_pass "跨节点路由：${found} 条（取不到集群成员数，不做数量断言）"
  fi
  if ((found == 0 && expected == 0)); then
    hc_skip "跨节点路由：单节点集群或取不到成员数，跳过"
  fi
}

hc_units() {
  local unit='' role=''
  for unit in railans caddy; do
    case "$unit" in
      railans) role="入口节点的控制面" ;;
      *) role="入口节点的预览反代" ;;
    esac
    if ! systemctl cat "${unit}.service" >/dev/null 2>&1; then
      hc_skip "${unit}.service 未安装（本机不是${role}）"
      continue
    fi
    if systemctl is-active --quiet "${unit}.service"; then
      hc_pass "${unit}.service active"
    else
      hc_fail "${unit}.service 未运行：systemctl status ${unit} / journalctl -u ${unit} -n 50"
    fi
  done
}

hc_disk() {
  local mount='' used=0 avail=0 label='' root_dev='' var_dev=''
  root_dev="$(stat -c %d / 2>/dev/null || true)"
  var_dev="$(stat -c %d /var 2>/dev/null || true)"
  local -a mounts=(/)
  if [[ -z "$var_dev" || "$var_dev" != "$root_dev" ]]; then
    mounts+=(/var)
  fi
  for mount in "${mounts[@]}"; do
    label="$mount"
    if [[ "$var_dev" == "$root_dev" ]]; then
      label="/ 与 /var（同一文件系统）"
    fi
    used="$(df -P "$mount" 2>/dev/null | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
    if [[ -z "$used" ]]; then
      hc_skip "磁盘 ${label}：df 无输出（挂载点不存在？）"
      continue
    fi
    avail=$((100 - used))
    if ((avail < 5)); then
      hc_fail "磁盘 ${label} 剩余 ${avail}%（<5%）：清 box / 扩容 / 清 /var/lib/incus"
    elif ((avail < 15)); then
      hc_warn "磁盘 ${label} 剩余 ${avail}%（<15%）"
    else
      hc_pass "磁盘 ${label} 剩余 ${avail}%"
    fi
  done
}

hc_time() {
  local sync=''
  sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [[ "$sync" == "yes" ]]; then
    hc_pass "时间同步：NTPSynchronized=yes"
  elif [[ -z "$sync" ]]; then
    hc_skip "时间同步：拿不到 NTPSynchronized（没有 timedatectl / systemd-timesyncd？）"
  else
    hc_fail "时间同步：NTPSynchronized=${sync}（timedatectl set-ntp true 后复查）"
  fi
}

# 控制面文件权限断言：两套布局按存在才查，路径不存在整布局 SKIP 不误伤纯节点。
# 判级：enroll code 与 config 超宽 = FAIL（M1 实质）；目录/日志/state/host key 超宽 = WARN。
# 路径钩子（供 test-node-sec.sh 注入临时目录，不碰真路径）：
#   HC_PERMS_KIT_DIR    kit 仓库根（缺省 ROOT_DIR，查 <dir>/.local-test/）
#   HC_PERMS_ETC_CONFIG 打包布局配置（缺省 /etc/railans/config.yaml，期望 ≤0640）
#   HC_PERMS_DATA_DIR   打包布局数据目录（缺省 /var/lib/railans，期望 0700）
hc_perm_too_wide() {  # <mode> <期望mode上限> -> 超宽返回 0（按八进制位比较）
  (( (8#$1) & ~(8#$2) )) 2>/dev/null
}

hc_control_perms() {
  local kit_dir="${HC_PERMS_KIT_DIR:-${ROOT_DIR}}"
  local etc_config="${HC_PERMS_ETC_CONFIG:-/etc/railans/config.yaml}"
  local data_dir="${HC_PERMS_DATA_DIR:-/var/lib/railans}"
  local mode=''

  perm_item() {  # <路径> <期望上限> <FAIL|WARN> <名目>
    if [[ ! -e "$1" ]]; then
      hc_skip "$4 不存在（未安装/未落盘），跳过"
      return 0
    fi
    if ! mode="$(stat -c %a "$1" 2>/dev/null)"; then
      hc_skip "$4 拿不到权限位（无权 stat，需 root）"
      return 0
    fi
    if hc_perm_too_wide "$mode" "$2"; then
      if [[ "$3" == FAIL ]]; then
        hc_fail "$4 权限超宽：现 0$mode 期望 ≤0$2 —— chmod 0$2 $1"
      else
        hc_warn "$4 权限超宽：现 0$mode 期望 ≤0$2 —— 建议 chmod 0$2 $1"
      fi
    else
      hc_pass "$4 权限 0$mode（期望 ≤0$2）"
    fi
  }

  # kit 运行时布局：<kit>/.local-test/
  if [[ ! -d "${kit_dir}/.local-test" ]]; then
    hc_skip "kit 布局：${kit_dir}/.local-test 不存在（本机不是控制面工作目录），跳过"
  else
    perm_item "${kit_dir}/.local-test" 750 WARN "kit 布局 .local-test/ 目录"
    perm_item "${kit_dir}/.local-test/config.yaml" 600 FAIL "kit 布局 config.yaml（含 enroll code）"
    perm_item "${kit_dir}/.local-test/enroll_code.txt" 600 FAIL "kit 布局 enroll_code.txt"
    perm_item "${kit_dir}/.local-test/state.json" 600 WARN "kit 布局 state.json"
    perm_item "${kit_dir}/.local-test/railans.log" 600 WARN "kit 布局 railans.log"
  fi

  # 打包布局：/etc/railans/config.yaml + /var/lib/railans/
  if [[ ! -e "$etc_config" && ! -d "$data_dir" ]]; then
    hc_skip "打包布局：${etc_config} 与 ${data_dir} 均不存在（非打包安装），跳过"
  else
    perm_item "$etc_config" 640 FAIL "打包布局 config.yaml（含 enroll code）"
    perm_item "$data_dir" 700 WARN "打包布局数据目录"
    perm_item "${data_dir}/state.json" 600 WARN "打包布局 state.json"
    perm_item "${data_dir}/ssh_host_ed25519_key" 600 WARN "打包布局 host key"
  fi
}

# 依次尝试候选 ssh 用户（只在 BatchMode 下试，绝不弹密码）；成功的用户由调用方记入 HC_SSH_USER 复用
hc_ssh_user() {
  local host="$1" u='' cands=()
  if [[ -n "${HC_SSH_USER:-}" ]]; then
    cands+=("$HC_SSH_USER")
  fi
  if [[ -n "${RAILANS_SSH_USER:-}" ]]; then
    cands+=("$RAILANS_SSH_USER")
  fi
  if [[ -n "${SUDO_USER:-}" ]]; then
    cands+=("$SUDO_USER")
  fi
  cands+=("$(id -un)" ops)
  for u in "${cands[@]}"; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "$u@$host" true >/dev/null 2>&1 </dev/null; then
      printf '%s' "$u"
      return 0
    fi
  done
  return 1
}

hc_all() {
  local self='' name='' host='' status='' user='' out='' rc=0
  local total=0 fails=0 failed='' self_path=''
  self_path="${BASH_SOURCE[0]:-$0}"
  if [[ ! -r "$self_path" ]]; then
    hc_fail "--all：读不到本脚本路径（${self_path}），无法送到对端执行"
    return 1
  fi
  self="$(hc_self_name)"
  if [[ -z "$HC_MEMBERS" ]]; then
    hc_fail "--all：incus cluster list 无输出，无从汇总"
    return 1
  fi
  while IFS=$'\t' read -r name host status; do
    [[ -n "$host" ]] || continue
    total=$((total + 1))
    printf '\n%s==== %s（%s）====%s\n' "$C_DIM" "$name" "$host" "$C_RST"
    if [[ "$name" == "$self" ]]; then
      if ! subcmd_healthcheck </dev/null; then
        fails=$((fails + 1))
        failed+=" $name"
      fi
      continue
    fi
    if ! user="$(hc_ssh_user "$host")"; then
      hc_fail "ssh ${host}：BatchMode 下没有可用用户（试过 RAILANS_SSH_USER/SUDO_USER/$(id -un)/ops），用 RAILANS_SSH_USER=... 指定"
      fails=$((fails + 1))
      failed+=" $name"
      continue
    fi
    HC_SSH_USER="$user"
    if out="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$user@$host" 'bash -s -- healthcheck' <"$self_path" 2>&1)"; then
      rc=0
    else
      rc=$?
    fi
    printf '%s\n' "$out"
    if ((rc != 0)); then
      fails=$((fails + 1))
      failed+=" $name"
    fi
  done <<<"$HC_MEMBERS"
  printf '\n== 汇总：%d 台检查，%d 台有 FAIL ==\n' "$total" "$fails"
  if ((fails > 0)); then
    printf '%s汇总失败节点:%s%s\n' "$C_ERR" "$C_RST" "$failed"
    return 1
  fi
  printf '%s汇总：全部 PASS（WARN/SKIP 不算失败）%s\n' "$C_OK" "$C_RST"
  return 0
}

subcmd_healthcheck() {
  HC_FAILS=0
  HC_WARNS=0
  HC_MEMBERS="$(hc_members)"
  HC_SELF="$(hc_self_name)"
  if [[ "${1:-}" == "--all" || "${1:-}" == "all" ]]; then
    if hc_all; then return 0; else return 1; fi
  fi
  echo "== railans 节点体检：$(hostname)（${HC_SELF:-未入集群}）=="
  echo "   只读检查，不改任何状态"
  hc_control_perms
  hc_kvm
  hc_vm_capability
  hc_cluster
  hc_bridge
  hc_nftables
  hc_routes
  hc_units
  hc_disk
  hc_time
  echo
  if ((HC_FAILS > 0)); then
    printf '结论：%sFAIL%s（%d 项失败，%d 项警告）\n' "$C_ERR" "$C_RST" "$HC_FAILS" "$HC_WARNS"
    return 1
  fi
  printf '结论：%sPASS%s（0 项失败，%d 项警告）\n' "$C_OK" "$C_RST" "$HC_WARNS"
  return 0
}

# ===== subcommand: verify-nft（H1+W5 防火墙变更复验）=====
# 用法（每节点各跑一轮；节点本机自足，零 ssh 依赖）：
#   sudo env NODE_ADDR=<本机管理IP> SUBNET=10.10.N.0/24 WAN=<网卡> \
#     ./node/railans-node.sh verify-nft                       # 断言+探针
#   sudo ... verify-nft --baseline /tmp/nft-baseline-nodeN.json              # 变更前采集
#   sudo ... verify-nft --verify --baseline /tmp/nft-baseline-nodeN.json    # 变更后比对
#   sudo ... verify-nft --print-box-probes                       # 箱内探针清单（箱内粘贴执行）
#
# 五段结构（输出对齐 healthcheck 的 PASS/WARN/FAIL 风格）：
#   0. 运行态采集：nft list ruleset 全量 dump；与 /etc/nftables.d/railans.nft 逐链比对；
#      专项核查 postrouting 是否存在「LAN 方向不 masquerade」豁免（有则提示固化进模板，
#      防下次重渲染静默抹掉；无豁免记 WARN 不阻断）
#   1. 静态断言：established accept；W5 4092 在 br-vm drop 之前；10.10/16 允许面两条
#      + 限面 drop 一条；forward 管理网 drop 与 10/8 兜底；占位符残留即 FAIL
#   2. 本机源探针：在册节点管理网 IP 的 22/8443 预期通（不误伤）；mesh 网关 ping 自身
#   3. 箱内探针清单与比对：--print-box-probes 生成清单，箱内执行后按清单文末说明把
#      结果 JSON 回填 <baseline>.probes.json（变更前）/<baseline>.probes.after.json
#      （变更后），--verify 对两份 JSON 比对：放行面「改前通→改后断」非预期项=FAIL、
#      阻断面改后仍通=FAIL
#   4. 汇总：PASS/WARN/FAIL 计数；FAIL 退出非 0 并附回滚指引
#
# 只读命令（nft list / /dev/tcp 探测 / ping / incus query），不改任何状态。
# baseline JSON 形态（脚本写出；dump 经 base64 内嵌，零 jq/python 依赖）：
#   { "node": "...", "collected_at": "...", "dump_b64": "..." }

vnft_nft_bin() {
  local c
  if command -v nft >/dev/null 2>&1; then
    command -v nft
    return 0
  fi
  for c in /usr/sbin/nft /sbin/nft /usr/bin/nft; do
    if [[ -x "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# dump 或持久化文件 → `table inet railans { ... }` 块（stdin→stdout）
vnft_extract_table() {
  awk '/^table inet railans \{/{f=1} f{print} f&&/^\}$/{exit}'
}

# 表块 → 指定链的块（stdin→stdout；链名 $1）
vnft_chain_block() {
  awk -v name="$1" '
    $0 ~ "^[[:space:]]*chain " name " \\{[[:space:]]*$" {f = 1; next}
    f && /^[[:space:]]*\}[[:space:]]*$/ {exit}
    f {print}'
}

# 链块 → 归一化规则行（去注释/链声明/空白压平；供运行态与持久化文件比对、静态断言）
vnft_norm_rules() {
  sed -e 's/[[:space:]]*#.*$//' \
      -e '/^[[:space:]]*$/d' \
      -e '/^[[:space:]]*type[[:space:]].*hook/d' \
      -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      -e 's/[[:space:]][[:space:]]*/ /g'
}

# 链块 → 链声明行（type ... hook ...; policy ...;）
vnft_norm_decl() {
  sed -n '/^[[:space:]]*type[[:space:]].*hook/p' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/ /g'
}

# 第 0 步：运行态 dump 与持久化渲染文件逐链比对（TC-H1-04 自动逻辑）。
# 一致 rc=0 无输出；不一致 stdout 打印逐链差异、rc=1。
vnft_compare_persisted() {
  local dump="$1" persist="$2" chain='' d='' bad=1
  bad=0
  for chain in input forward postrouting; do
    if ! d="$(diff \
        <(vnft_extract_table <"$persist" | vnft_chain_block "$chain" | vnft_norm_rules) \
        <(vnft_extract_table <"$dump" | vnft_chain_block "$chain" | vnft_norm_rules) 2>&1)"; then
      printf 'chain %s 规则差异：\n%s\n' "$chain" "$d"
      bad=1
    fi
    if ! d="$(diff \
        <(vnft_extract_table <"$persist" | vnft_chain_block "$chain" | vnft_norm_decl) \
        <(vnft_extract_table <"$dump" | vnft_chain_block "$chain" | vnft_norm_decl) 2>&1)"; then
      printf 'chain %s 链声明差异：\n%s\n' "$chain" "$d"
      bad=1
    fi
  done
  return "$bad"
}

# postrouting 中「LAN 方向不 masquerade」豁免行（daddr 管理网即豁免形态）。
# stdout 打印命中的归一化规则行；无豁免输出空。$1=dump/持久化文件 $2=管理网 CIDR
vnft_postrouting_exempt() {
  local file="$1" mgmt="$2"
  vnft_extract_table <"$file" | vnft_chain_block "postrouting" | vnft_norm_rules \
    | grep -F "ip daddr ${mgmt}" || true
}

# 第 1 段：静态断言（对运行态 dump）。结论经 hc_pass/hc_fail 落账。
# 用法：vnft_static_asserts <dump文件> <WAN> <MGMT_CIDR> <GWMESH>
vnft_static_asserts() {
  local dump="$1" wan="$2" mgmt="$3" gwmesh="$4"
  local tbl='' tbl_in='' tbl_fwd='' tbl_pst=''
  local line4092="iifname \"br-vm\" ip daddr ${gwmesh} tcp dport 4092 accept"
  local idx4092=0 idxdrop=0 residue=''
  tbl="$(vnft_extract_table <"$dump")"
  tbl_in="$(vnft_chain_block "input" <<<"$tbl" | vnft_norm_rules)"
  tbl_fwd="$(vnft_chain_block "forward" <<<"$tbl" | vnft_norm_rules)"
  tbl_pst="$(vnft_chain_block "postrouting" <<<"$tbl" | vnft_norm_rules)"

  if grep -Fx 'ct state established,related accept' <<<"$tbl_in" >/dev/null; then
    hc_pass "input：established,related accept 在位（宿主→VM 回包）"
  else
    hc_fail "input：缺 ct state established,related accept——宿主机主动连 VM 的回包会断"
  fi

  if grep -Fx "$line4092" <<<"$tbl_in" >/dev/null; then
    idx4092="$(grep -Fn "$line4092" <<<"$tbl_in" | head -1 | cut -d: -f1)"
    idxdrop="$(grep -Fx 'iifname "br-vm" drop' <<<"$tbl_in" | head -1 | cut -d: -f1)"
    if [[ -n "$idxdrop" && "$idx4092" -lt "$idxdrop" ]]; then
      hc_pass "input：W5 门面 4092 accept 位于 br-vm drop 之前（第 ${idx4092} 条规则）"
    else
      hc_fail "input：W5 4092 accept 必须在 iifname \"br-vm\" drop 之前（门面开闸须先于 drop；4092@${idx4092:-无} drop@${idxdrop:-无}）"
    fi
  else
    hc_fail "input：缺 W5 门面规则（${line4092}）——本地箱→门面 4092 不通"
  fi

  if grep -Fx "iifname \"${wan}\" ip saddr 10.10.0.0/16 tcp dport 22000-22999 accept" <<<"$tbl_in" >/dev/null; then
    hc_pass "input：H1-允许面 数据面端口 22000-22999 在位"
  else
    hc_fail "input：缺 H1-允许面 22000-22999——跨节点箱数据面会断"
  fi

  if grep -Fx "iifname \"${wan}\" ip saddr 10.10.0.0/16 ip daddr ${gwmesh} tcp dport 4092 accept" <<<"$tbl_in" >/dev/null; then
    hc_pass "input：H1-允许面 跨节点箱→门面 4092 在位"
  else
    hc_fail "input：缺 H1-允许面 跨节点箱→门面 4092（W5 跨节点路径）"
  fi

  if grep -Fx "iifname \"${wan}\" ip saddr 10.10.0.0/16 drop" <<<"$tbl_in" >/dev/null; then
    hc_pass "input：H1-限面 跨节点箱源 drop 在位"
  else
    hc_fail "input：缺 H1-限面 跨节点箱源 drop"
  fi

  if grep -Fx "iifname \"br-vm\" ip daddr ${mgmt} drop" <<<"$tbl_fwd" >/dev/null; then
    hc_pass "forward：管理网 ${mgmt} drop 在位（H1 主修复）"
  else
    hc_fail "forward：缺管理网 ${mgmt} drop——H1 主修复缺失（箱可直达管理网）"
  fi

  if grep -Fx 'iifname "br-vm" ip daddr 10.0.0.0/8 drop' <<<"$tbl_fwd" >/dev/null; then
    hc_pass "forward：10/8 兜底 drop 保留在位"
  else
    hc_fail "forward：10/8 兜底 drop 丢失（规划期兜底被删，网段迁移时会静默失效）"
  fi

  if grep -Fx "ip saddr 10.10.0.0/16 oifname \"${wan}\" masquerade" <<<"$tbl_pst" >/dev/null; then
    hc_pass "postrouting：VM 出网 masquerade 在位"
  else
    hc_fail "postrouting：缺 masquerade——VM 出公网会断"
  fi

  residue="$(grep -Eo '__[A-Z_]+__' <<<"$tbl" | sort -u | tr '\n' ' ' || true)"
  if [[ -n "$residue" ]]; then
    hc_fail "dump 内有占位符残留（渲染漏替换）：${residue}"
  else
    hc_pass "dump 无占位符残留"
  fi
}

# TCP 探测：rc=0 通；rc=124 超时（防火墙 drop）；其余 rc=拒接/不可达
vnft_probe_tcp() {
  local ip="$1" port="$2"
  timeout 3 bash -c "exec 3<>/dev/tcp/${ip}/${port}" 2>/dev/null
}

# 第 2 段：本机源探针（节点互访不误伤 + br-vm 在场）
vnft_node_probes() {
  local members='' name='' host='' status='' port=0
  members="$(hc_members)"
  if [[ -z "$members" ]]; then
    hc_skip "节点互访探针：incus cluster list 无输出（本机未入集群），跳过"
  else
    while IFS=$'\t' read -r name host status; do
      [[ -n "$host" ]] || continue
      if [[ ! "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        hc_warn "节点互访探针：${name} 的地址 '${host}' 非 IPv4，跳过"
        continue
      fi
      for port in 22 8443; do
        if vnft_probe_tcp "$host" "$port"; then
          hc_pass "节点互访：${name}（${host}:${port}）通（源=本机管理网 IP，未命中限面）"
        else
          hc_fail "节点互访：${name}（${host}:${port}）不通——节点互访不应被限面误伤（核对箱源限面白名单）"
        fi
      done
    done <<<"$members"
  fi
  if ping -c 1 -W 2 "${GWMESH}" >/dev/null 2>&1; then
    hc_pass "mesh 网关 ${GWMESH} ping 自身通（br-vm 在场）"
  else
    hc_fail "mesh 网关 ${GWMESH} ping 不通——br-vm 未配置或未 UP（先跑 railans-node.sh network）"
  fi
}

# 第 3 段（--print-box-probes）：箱内探针清单生成（TC-H1-05）。
# 清单在【箱内】粘贴执行（节点本机不进箱）；结果 JSON 按文末说明回填 sidecar 文件。
vnft_print_box_probes() {
  local members='' name='' host='' status='' ip='' own_facade=0
  members="$(hc_members)"
  echo "== 箱内探针清单（在任一台箱内以 root 粘贴执行；生成于 $(hostname)）=="
  echo "# 结果语义：open=连通  blocked=超时（防火墙 drop）  refused=拒接（可达但无监听）"
  echo "# 执行完毕：把打印出的 JSON 原样存盘——"
  echo "#   变更前 → <baseline 文件>.probes.json（如 /tmp/nft-baseline-nodeN.json.probes.json）"
  echo "#   变更后 → <baseline 文件>.probes.after.json"
  echo "# 比对由对应节点的 verify-nft --verify 完成；跨节点箱探针需 BOX_PEER/BOX_PORT 两变量"
  cat <<'RXEOF'

# ---- 箱内执行段（从这里开始复制）----
probe(){ timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; echo $?; }
res(){ case "$1" in 0) echo open;; 124) echo blocked;; *) echo refused;; esac; }
rows="$(mktemp /tmp/nft-box-probes.XXXXXX)"
add(){ printf '%s\t%s\n' "$1" "$(res "$(probe "$2" "$3")")" >> "$rows"; }
# 阻断面：箱 -> 各节点管理网 IP（预期全部 blocked=超时；H1 修复后必须全断）
RXEOF
  if [[ -z "$members" ]]; then
    echo "# 注意：生成时未取得集群成员清单，请手工补 add \"block-<管理网IP>-<端口>\" <管理网IP> <端口> 行"
  else
    while IFS=$'\t' read -r name host status; do
      [[ -n "$host" ]] || continue
      [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || continue
      for port in 22 8443 443; do
        printf 'add "block-%s-%s" %s %s\n' "$host" "$port" "$host" "$port"
      done
    done <<<"$members"
  fi
  cat <<'RXEOF'
# 放行面：箱 -> 公网 DNS（预期 open）
add "allow-dns-223.5.5.5-53" 223.5.5.5 53
# 放行面：箱 -> 跨节点箱数据面（BOX_PEER=对端箱 mesh IP、BOX_PORT=其 22000-22999 监听端口；预期 open）
BOX_PEER="${BOX_PEER:-}"; BOX_PORT="${BOX_PORT:-}"
if [[ "$BOX_PEER" =~ ^[0-9.]+$ && "$BOX_PORT" =~ ^[0-9]+$ ]]; then
  add "allow-peer-${BOX_PEER}-${BOX_PORT}" "$BOX_PEER" "$BOX_PORT"
else
  echo "# SKIP allow-peer：BOX_PEER/BOX_PORT 未填（跳过跨节点箱探针）" >&2
fi
# 放行面：箱 -> 入口节点网格门面（预期 open；W5）
add "allow-facade-10.10.1.1-4092" 10.10.1.1 4092
RXEOF
  if [[ -n "${GWMESH:-}" ]] && command -v ss >/dev/null 2>&1 \
    && ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ':4092$'; then
    printf '# 放行面：箱 -> 本节点网格门面（本机 %s:4092 在监听；预期 open）\n' "$GWMESH"
    printf 'add "allow-facade-%s-4092" %s 4092\n' "$GWMESH" "$GWMESH"
  fi
  cat <<'RXEOF'
# 打印结果 JSON（原样存盘到对应 sidecar 文件）
echo '{'
echo '  "box_probes": {'
if [[ -s "$rows" ]]; then
  n=$(wc -l < "$rows"); i=0
  while IFS=$'\t' read -r id r; do
    i=$((i+1))
    if [[ "$i" -eq "$n" ]]; then c=''; else c=','; fi
    printf '    "%s": "%s"%s\n' "$id" "$r" "$c"
  done < "$rows"
fi
echo '  }'
echo '}'
rm -f "$rows"
# ---- 箱内执行段结束 ----
RXEOF
}

# 探针结果 sidecar JSON → "id<TAB>result" 行（结果枚举 open|blocked|refused）
vnft_read_probes() {
  sed -n '/"box_probes"[[:space:]]*:[[:space:]]*{/,/}/s/^[[:space:]]*"\([^"]*\)"[[:space:]]*:[[:space:]]*"\(open\|blocked\|refused\)"[[:space:]]*,\{0,1\}$/\1\t\2/p' "$1"
}

# baseline JSON 写出（dump base64 内嵌，单行无转义风险；零 jq/python 依赖）
vnft_write_baseline() {
  local out="$1" node="$2" dumpfile="$3"
  {
    printf '{\n'
    printf '  "node": "%s",\n' "$node"
    printf '  "collected_at": "%s",\n' "$(date -Is)"
    printf '  "dump_b64": "%s"\n' "$(base64 -w0 <"$dumpfile")"
    printf '}\n'
  } >"$out"
}

# baseline JSON → dump 文本（stdout）
vnft_read_baseline_dump() {
  sed -n 's/^  "dump_b64": "\(.*\)"$/\1/p' "$1" | base64 -d
}

# 第 3 段比对（--verify）：baseline/after 探针 sidecar JSON 比对。
# 用法：vnft_compare_box_probes <baseline文件路径>
vnft_compare_box_probes() {
  local base="$1" id='' res='' r=0
  local -A A=( )
  if [[ -z "$base" ]]; then
    hc_skip "箱内探针比对：未提供 --baseline 路径，箱内探针结果无从比对"
    return 0
  fi
  local before_f="${base}.probes.json" after_f="${base}.probes.after.json"
  if [[ ! -f "$before_f" && ! -f "$after_f" ]]; then
    hc_skip "箱内探针比对：未找到 ${before_f} / ${after_f}（清单见 --print-box-probes，回填后重跑 --verify）"
    return 0
  fi
  while IFS=$'\t' read -r id res; do
    [[ -n "$id" ]] && A+=( ["$id"]="$res" )
  done < <(vnft_read_probes "$after_f" 2>/dev/null || true)
  if (( ${#A[@]} == 0 )); then
    hc_warn "箱内探针比对：${after_f} 不存在或没有可解析结果（格式见 --print-box-probes）"
    return 0
  fi
  for id in "${!A[@]}"; do
    res="${A[$id]}"
    case "$id" in
      block-*)
        case "$res" in
          blocked)
            hc_pass "阻断面 ${id}：blocked（预期；箱→管理网已断）"
            ;;
          open)
            hc_fail "阻断面 ${id} 变更后仍通——input 限面未生效（核对第 1 段断言与实际加载；必要时回滚）"
            r=1
            ;;
          *)
            hc_warn "阻断面 ${id}：${res}（预期 blocked=超时；refused 说明流量仍可达对端，人工核对）"
            ;;
        esac
        ;;
      allow-*)
        if [[ "$res" == "open" ]]; then
          hc_pass "放行面 ${id} 通"
        else
          hc_fail "放行面 ${id} 变更后 ${res}——「改前通→改后断」非预期项（疑似误伤，核对箱源限面白名单；必要时回滚）"
          r=1
        fi
        ;;
      *)
        hc_warn "探针 ${id}：结果 ${res}（非 block-/allow- 编号，人工核对）"
        ;;
    esac
  done
  return "$r"
}

# 第 4 段：汇总（PASS/WARN/FAIL 计数；FAIL 附回滚指引；rc=失败有无）
vnft_summary() {
  echo
  if ((HC_FAILS > 0)); then
    printf '结论：%sFAIL%s（%d 项失败，%d 项警告）\n' "$C_ERR" "$C_RST" "$HC_FAILS" "$HC_WARNS"
    echo "回滚：用变更前保留的旧渲染文件恢复 /etc/nftables.d/railans.nft，然后"
    echo "      systemctl restart railans-nftables（节点级秒级回滚；完整回滚步见变更单 §10-2）"
    return 1
  fi
  printf '结论：%sPASS%s（0 项失败，%d 项警告；WARN 不影响退出码）\n' "$C_OK" "$C_RST" "$HC_WARNS"
  return 0
}

subcmd_verify_nft() {
  HC_FAILS=0
  HC_WARNS=0
  local mode="check" baseline_file='' arg
  while (($#)); do
    case "$1" in
      --baseline)
        [[ -n "${2:-}" ]] || { echo "verify-nft: --baseline 需要 JSON 文件路径参数" >&2; exit 2; }
        mode="baseline"
        baseline_file="$2"
        shift 2
        ;;
      --verify)
        mode="verify"
        shift
        ;;
      --print-box-probes)
        mode="box-probes"
        shift
        ;;
      *)
        echo "verify-nft: 未知参数 '${1}'（支持 --baseline <file> / --verify / --print-box-probes）" >&2
        exit 2
        ;;
    esac
  done

  if [[ "$mode" == "box-probes" ]]; then
    # 清单生成零副作用、免 root：GWMESH 尽量从 br-vm 现值推导
    BRIDGE="${BRIDGE:-br-vm}"
    GWMESH="${GWMESH:-$(ip -4 -o addr show dev "${BRIDGE}" 2>/dev/null \
      | awk '{split($4, a, "/"); print a[1]; exit}')}"
    echo "== verify-nft（模式：box-probes；只生成清单，不改任何状态）=="
    vnft_print_box_probes
    return 0
  fi

  require_root
  NODE_ADDR="${NODE_ADDR:?必须设置 NODE_ADDR（本机管理网 IP，例如 192.168.1.12）}"
  SUBNET="${SUBNET:?必须设置 SUBNET（本节点 VM 网段，例如 10.10.1.0/24）}"
  WAN="${WAN:-$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')}"
  if [[ -z "$WAN" ]]; then
    echo "verify-nft：找不到默认网卡，请显式设置 WAN=eno1" >&2
    exit 1
  fi
  MGMT_CIDR="$(derive_mgmt_cidr "${NODE_ADDR}")"
  GWMESH="${GATEWAY:-$(awk -F. '{print $1"."$2"."$3".1"}' <<<"${SUBNET%/*}")}"
  if [[ ! "$GWMESH" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "verify-nft：GWMESH='${GWMESH}' 非 IPv4（检查 SUBNET/GATEWAY）" >&2
    exit 1
  fi

  echo "== verify-nft：$(hostname)（模式：${mode}；只读，不改任何状态）=="

  local nft_bin='' persist='/etc/nftables.d/railans.nft' dumpfile='' rc=0
  nft_bin="$(vnft_nft_bin)" || {
    hc_fail "nft 未安装（先跑 railans-node.sh network，或 apt-get install nftables）"
    vnft_summary || true
    return 1
  }
  if [[ "$mode" == "verify" && -n "$baseline_file" && ! -f "$baseline_file" ]]; then
    hc_warn "--verify：baseline 文件 ${baseline_file} 不存在（豁免回归与箱内探针比对跳过）"
  fi
  if [[ ! -r "$persist" ]]; then
    hc_fail "读不到 ${persist}——先跑 railans-node.sh network 渲染，或按变更单手工渲染后再验"
    vnft_summary || true
    return 1
  fi
  dumpfile="$(mktemp /tmp/verify-nft-dump.XXXXXX)"
  if ! "$nft_bin" list ruleset >"$dumpfile" 2>/dev/null; then
    hc_fail "nft list ruleset 失败（nftables 模块不可用？）"
    rm -f "$dumpfile"
    vnft_summary || true
    return 1
  fi

  echo "-- 第 0 步：运行态采集与持久化一致性 --"
  if vnft_compare_persisted "$dumpfile" "$persist"; then
    hc_pass "运行态 dump 与持久化 ${persist} 一致"
  else
    hc_fail "运行态与持久化文件不一致（运行态可能有模板外手工规则；差异见上）"
  fi

  local ex_dump='' ex_file='' ex_base=''
  ex_dump="$(vnft_postrouting_exempt "$dumpfile" "$MGMT_CIDR")"
  ex_file="$(vnft_postrouting_exempt "$persist" "$MGMT_CIDR")"
  if [[ -n "$ex_dump" && -n "$ex_file" ]]; then
    hc_pass "postrouting：LAN 方向豁免已在模板固化（$(tr '\n' ';' <<<"$ex_dump")）"
  elif [[ -n "$ex_dump" && -z "$ex_file" ]]; then
    hc_fail "postrouting：运行态存在 LAN 豁免（$(tr '\n' ';' <<<"$ex_dump")）但模板没有——固化进模板（postrouting 在 masquerade 前加 ip daddr __MGMT__ return 行）再继续，防下次重渲染静默抹掉"
  elif [[ -z "$ex_dump" && -n "$ex_file" ]]; then
    hc_warn "postrouting：模板有 LAN 豁免但运行态没有（重渲染后未重载？核对 systemctl restart railans-nftables）"
  else
    hc_warn "postrouting：无 LAN 方向豁免（模板字面=箱流量全 SNAT）——跨节点箱源是否保持 10.10.x 以箱内探针实测为准；无豁免记 WARN 不阻断"
  fi
  if [[ "$mode" == "verify" && -f "${baseline_file:-}" ]]; then
    ex_base="$(vnft_read_baseline_dump "$baseline_file" \
      | vnft_postrouting_exempt /dev/stdin "$MGMT_CIDR")"
    if [[ -n "$ex_base" && -z "$ex_dump" ]]; then
      hc_fail "postrouting：baseline 有 LAN 豁免、变更后运行态丢失（静默回归——固化进模板并重载）"
    fi
  fi

  echo "-- 第 1 段：静态断言 --"
  vnft_static_asserts "$dumpfile" "$WAN" "$MGMT_CIDR" "$GWMESH"

  echo "-- 第 2 段：本机源探针 --"
  vnft_node_probes

  if [[ "$mode" == "verify" ]]; then
    echo "-- 第 3 段：箱内探针 baseline 比对 --"
    vnft_compare_box_probes "$baseline_file" || true
    if [[ -n "$baseline_file" ]]; then
      vnft_write_baseline "${baseline_file}.verify.json" "$(hostname)" "$dumpfile"
      echo "   留档：变更后 dump 已写 ${baseline_file}.verify.json"
    else
      echo "   提示：未提供 --baseline，变更后 dump 未留档（建议补 --baseline 路径重跑）"
    fi
  fi

  rm -f "$dumpfile"
  echo "-- 第 4 段：汇总 --"
  vnft_summary || rc=$?
  return "$rc"
}
# ===== subcommand: add-node（一条命令把新物理机变集群成员）=====
#
# 用法（在控制机/入口节点上执行，本机普通用户即可）：
#   ./node/railans-node.sh add-node <user@host> <name> <subnet> [选项]
#     --addr <管理IP>    新节点管理网 IP（缺省：host 为 IPv4 字面量时直接用；
#                        hostname 场景执行期按「集群对端路由 src」推导——INFRA_NET
#                        教训：hysteria 分流下默认路由可能走隧道，禁用默认路由推导）
#     --pool-dir <路径>  新节点 dir 存储池路径（缺省 /var/lib/incus/storage-pools/default）
#     --max-boxes N      仅记为建议值（控制面 per-node 配额暂无字段，跳过并注明，不改全局）
#     --skip-verify      跳过第 7 步验收箱（healthcheck --all 仍跑）
#     --from-step N      从第 N 步续跑（失败断点续跑用；1-8；前序步骤全部幂等）
#     --yes              缺省干跑只打印计划；--yes 才执行（deploy-remote 同款语义）
#
# 八步编排（每步幂等、失败停住并打印断点与续跑命令）：
#   1 预检：ssh BatchMode / 免密 sudo / KVM / 磁盘余量（老 CPU hotplug 仅提示不自动判定，
#     STATUS §5-3：≤36 位物理地址需 limits.memory.hotplug=4GiB；AMD 48 位不受影响）
#   2 deploy-remote（送 kit+装 incus+kvm 组+入组+subuid+network 五步）；ROUTES 由本命令
#     按既有节点清单自动推导（别让用户手写）
#   3 集群入伙：本机 cluster add 取一次性 token → 生成 join preseed → scp → 远程
#     sg incus-admin incus admin init --preseed → 等 cluster list ONLINE
#     preseed 字段名锚（踩坑记）：cluster_token（不是
#     join_token/token）/ server_address / cluster_address —— 三者均为本新成员
#     自己的 <addr>:8443，不是 leader 地址（leader 地址已内嵌在 token 里）
#   4 镜像分发：incus image copy dev-base local: --target <name>（镜像统一
#     local 构建+copy 分发；构建走 build-base-image-local.sh）
#   5 控制面接线：config.yaml nodes 安全追加（备份+追加到临时文件+结构校验+原子替换
#     +重启控制面——systemd unit 在跑就 systemctl restart，ctl.sh 形态 loud fail 指路 runbook §4.1）
#   6 老节点路由补全：每老节点 ROUTES 追加新成员 /24 via 新机后重跑 network（WAN 从
#     该节点到其他成员的对端路由 dev 推导，同 INFRA_NET 教训；kit 先 rsync 刷新）
#   7 验收：healthcheck --all 全绿 +（无 --skip-verify 时）验收箱：new --json →
#     断言落在新节点 → 数据面 ssh-keyscan 抽测 → rm 验收箱（失败也删）
#   8 汇总：新节点信息 / 端口池余量（capacity，best effort）/ 后续手工事项（无则明说「无」）
#
# 复用 deploy-remote 的变量白名单 / %q 转义 / 干跑缺省；跨节点写操作仅本命令与
# deploy-remote（只读跨节点入口是 healthcheck --all，第 7 步用）。
# 环境变量：RAILANS_CONFIG（显式 config 路径）/ ADDNODE_IMAGE（缺省 dev-base）/
#   RAILANS_CTL_USER / RAILANS_CTL_HOST（控制面 CLI 连接，缺省 ops@127.0.0.1，端口
#   从 config listen 解析）/ BRIDGE（缺省 br-vm）。
# 测试：scripts/tests/test-add-node.sh（mock/垫片，不碰真机；真机路径属变更窗口）。

# ---- add-node 纯函数（scripts/tests/test-add-node.sh 经 source 复用）----

# config.yaml 的 nodes 块 → "name<TAB>addr<TAB>subnet<TAB>gw" 行流。
# 值可带引号；无 nodes 块 → 输出空（调用方判断）；条目缺字段输出带空列（调用方校验）。
addnode_parse_config_nodes() {
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
  ' "$1"
}

# 成员行流 → 新节点 ROUTES 串（既有各成员 subnet via addr，分号连接；跳过同网段行，
# 防重跑残留把新节点自己的网段写进路由）。可返回空串（单成员集群除自身外无对端）。
addnode_routes_for_new() {
  local rows="$1" new_subnet="$2" out='' name addr subnet gw
  while IFS=$'\t' read -r name addr subnet gw; do
    [[ -n "$subnet" && -n "$addr" ]] || continue
    [[ "$subnet" == "$new_subnet" ]] && continue
    if [[ -n "$out" ]]; then out+=";"; fi
    out+="${subnet} via ${addr}"
  done <<<"$rows"
  printf '%s' "$out"
}

# 单个老节点（按本机地址 excl 排除自身）的 ROUTES 串：其余老成员 + 新成员（追加在尾）。
addnode_routes_for_old() {
  local excl_addr="$1" rows="$2" new_subnet="$3" new_addr="$4" out='' name addr subnet gw
  while IFS=$'\t' read -r name addr subnet gw; do
    [[ -n "$subnet" && -n "$addr" ]] || continue
    [[ "$addr" == "$excl_addr" ]] && continue
    [[ "$subnet" == "$new_subnet" ]] && continue
    if [[ -n "$out" ]]; then out+=";"; fi
    out+="${subnet} via ${addr}"
  done <<<"$rows"
  if [[ -n "$out" ]]; then out+=";"; fi
  out+="${new_subnet} via ${new_addr}"
  printf '%s' "$out"
}

# join preseed 生成（stdout）。字段名按 STATUS §5 坑锚死：cluster_token /
# server_address / cluster_address（本成员自己的 <addr>:8443）。含 token 秘密，
# 调用方负责落盘脱敏（umask 177 + 用后即删 + 绝不打印）。
addnode_gen_preseed() {
  local name="$1" token="$2" addr="$3" pool_dir="$4"
  cat <<EOF
config: {}
storage_pools:
- name: default
  driver: dir
  config:
    source: ${pool_dir}
profiles: []
projects: []
cluster:
  server_name: ${name}
  enabled: true
  cluster_token: ${token}
  server_address: ${addr}:8443
  cluster_address: ${addr}:8443
EOF
}

# `ip -4 route get <对端>` 输出 → src 地址（管理地址推导；INFRA_NET 教训）。
addnode_src_from_route() {
  sed -nE 's/.*[[:space:]]src[[:space:]]([0-9.]+).*/\1/p' <<<"$1" | head -1
}

# 同上 → dev 网卡名（WAN 推导；禁用默认路由推导，隧道网卡不出现在对端路由里）。
addnode_dev_from_route() {
  sed -nE 's/.*[[:space:]]dev[[:space:]]([^[:space:]]+).*/\1/p' <<<"$1" | head -1
}

# 退路纯函数：本机 `ip -4 route show` 输出 + br-vm 地址 + 本机成员名 + 本机管理地址
# → 成员行流（自身行 + 各「<对端 /24> via <对端管理IP>」行）。对端路由是 healthcheck
# hc_routes 同源数据，全程只读本机，干跑亦可安全推导。注意自身行的地址必须是管理网
# IP（对端路由 src 推导），不能拿 br-vm 网关地址（10.10.x.1）充当路由网关。
addnode_members_from_routes() {
  local route_out="$1" br_addr="$2" self_name="${3:-}" self_addr="${4:-}" rl='' rsub='' rgw=''
  if [[ -z "$br_addr" || -z "$self_addr" ]]; then
    return 1
  fi
  local bip="${br_addr%%/*}"
  printf '%s\t%s\t%s\t%s\n' "${self_name:-$(hostname)}" "$self_addr" "${bip%.*}.0/24" "${bip%.*}.1"
  while IFS= read -r rl; do
    [[ -n "$rl" ]] || continue
    rsub="${rl%% *}"
    rgw="$(awk '{for (i=1;i<=NF;i++) if ($i=="via") print $(i+1); exit}' <<<"$rl")"
    [[ -n "$rsub" && -n "$rgw" ]] || continue
    printf '%s\t%s\t%s\t%s\n' "$rgw" "$rgw" "$rsub" "${rsub%.*}.1"
  done <<<"$route_out"
  return 0
}

# nodes 块里是否已有该成员（幂等判定；只认整行 `  - name: <name>`）。
addnode_config_has_node() {
  local file="$1" name="$2" found=0
  [[ -r "$file" ]] || return 1
  awk -v n="$name" '
    /^nodes:[[:space:]]*(#.*)?$/ { inb = 1; next }
    inb && /^[A-Za-z_]/ { exit }
    inb && $0 ~ ("^  - name:[[:space:]]*\"?" n "\"?[[:space:]]*$") { found = 1; exit }
    END { exit !found }
  ' "$file" && found=1
  return $((1 - found))
}

# YAML 结构校验：nodes 块中该成员条目的 address/subnet 与期望一致且 gateway 字段在位。
# 值比对用精确等值（引号两形态都认），不做正则点转义（免引号语义漂移）。
addnode_config_validate() {
  local file="$1" name="$2" addr="$3" subnet="$4" blk='' line='' a=0 s=0 g=0 gv=''
  blk="$(awk -v n="$name" '
    /^nodes:[[:space:]]*(#.*)?$/ { inb = 1; next }
    inb && /^[A-Za-z_]/ { exit }
    inb && $0 ~ ("^  - name:[[:space:]]*\"?" n "\"?[[:space:]]*$") { grab = 1; next }
    inb && grab && /^  - / { exit }
    inb && grab { print }
  ' "$file")"
  if [[ -z "$blk" ]]; then
    return 1
  fi
  while IFS= read -r line; do
    if [[ "$line" == "    address: \"${addr}\"" || "$line" == "    address: ${addr}" ]]; then
      a=1
    fi
    if [[ "$line" == "    subnet: \"${subnet}\"" || "$line" == "    subnet: ${subnet}" ]]; then
      s=1
    fi
    if [[ "$line" == "    gateway: "* ]]; then
      gv="${line#*gateway: }"
      gv="${gv%\"}"
      gv="${gv#\"}"
      if [[ "$gv" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        g=1
      fi
    fi
  done <<<"$blk"
  if [[ "$a" == 1 && "$s" == 1 && "$g" == 1 ]]; then
    return 0
  fi
  return 1
}

# 安全追加（文件→文件，不原地）：src 读，dst 写（含新成员条目，插在 nodes 块末行后）。
# 已有同名 → 非 0（幂等返回）；无 nodes 块 → 非 0。校验由调用方对 dst 复核后才替换。
addnode_config_append() {
  local src="$1" dst="$2" name="$3" addr="$4" subnet="$5" gw="$6"
  local insat=0
  addnode_config_has_node "$src" "$name" && return 1
  insat="$(awk '
    /^nodes:[[:space:]]*(#.*)?$/ { inb = 1; at = NR; next }
    inb && /^[A-Za-z_]/ { exit }
    inb && /^[[:space:]]*$/ { next }
    inb && /^[[:space:]]*#/ { next }
    inb { at = NR }
    END { print at + 0 }
  ' "$src" 2>/dev/null)" || insat=''
  if [[ -z "$insat" || "$insat" == "0" ]]; then
    return 1
  fi
  {
    head -n "$insat" "$src"
    printf '  - name: %s\n' "$name"
    printf '    address: "%s"\n' "$addr"
    printf '    subnet: "%s"\n' "$subnet"
    printf '    gateway: "%s"\n' "$gw"
    tail -n "+$((insat + 1))" "$src"
  } >"$dst"
  return 0
}

# config.yaml listen 行 → 控制面 CLI 端口（缺省 22）。
addnode_ctl_port() {
  local p=''
  p="$(awk -F: '/^listen:/ {gsub(/[^0-9]/, "", $NF); print $NF; exit}' "$1")"
  printf '%s' "${p:-22}"
}

# ---- add-node 编排本体 ----

AN_STEP_NAMES=("" "预检" "deploy-remote 上架" "集群入伙" "镜像分发" "控制面接线" "老节点路由补全" "验收" "汇总")
AN_TARGET='' AN_NAME='' AN_SUBNET='' AN_ADDR_OPT='' AN_POOL_DIR='' AN_MAXBOXES=''
AN_SKIP_VERIFY=0 AN_FROM_STEP=1 AN_DRY=1
AN_ADDR_RESOLVED='' AN_WAN_RESOLVED='' AN_GW='' AN_MEMBERS='' AN_MEMBERS_SRC=''
AN_PRESEED=''

an_usage_addnode() {
  cat >&2 <<'USAGE'
用法: railans-node.sh add-node <user@host> <name> <subnet> [--addr IP] [--pool-dir 路径] \
        [--max-boxes N] [--skip-verify] [--from-step N] [--yes]
  <user@host>  新节点（例 ops@192.168.1.15）；目标机需 SSH 公钥免密登录 + 免密 sudo（物理前提）
  <name>       集群成员名（例 node5）
  <subnet>     该节点 VM 网段 /24（例 10.10.5.0/24；网关自动取 .1）
缺省干跑只打印计划；--yes 才执行。失败停住打印断点与 --from-step 续跑命令。
USAGE
}

# 断点失败：打印断点与续跑命令后整体退出 1（不半途静默；前序步骤幂等可重放）
an_fail_step() {
  local step="$1" next="$2" msg="$3" cmd=''
  cmd="$(an_resume_cmd "$next")"
  printf '\n%sFAIL%s 第 %s/8 步（%s）：%s\n' "$C_ERR" "$C_RST" "$step" "${AN_STEP_NAMES[${step}]}" "$msg" >&2
  printf '断点：停在 第 %s/8 步；前面已完成步骤均有幂等保护，重放安全。\n' "$step" >&2
  printf '%s续跑：%s%s\n' "$C_WARN" "$cmd" "$C_RST" >&2
  exit 1
}

an_resume_cmd() {
  local next="$1" cmd=''
  cmd="${SCRIPT_DIR}/railans-node.sh add-node ${AN_TARGET} ${AN_NAME} ${AN_SUBNET}"
  [[ -n "${AN_ADDR_OPT}" ]] && cmd+=" --addr ${AN_ADDR_OPT}"
  [[ "${AN_POOL_DIR_SET:-0}" == 1 ]] && cmd+=" --pool-dir ${AN_POOL_DIR}"
  [[ -n "${AN_MAXBOXES}" ]] && cmd+=" --max-boxes ${AN_MAXBOXES}"
  [[ "${AN_SKIP_VERIFY}" == 1 ]] && cmd+=" --skip-verify"
  cmd+=" --from-step ${next} --yes"
  printf '%s' "$cmd"
}

# 控制面 config 发现：RAILANS_CONFIG 显式 > /etc/railans（打包布局）> <kit>/.local-test（kit 布局）
an_find_config() {
  local c
  for c in "${RAILANS_CONFIG:-}" /etc/railans/config.yaml "${ROOT_DIR}/.local-test/config.yaml"; do
    [[ -n "$c" && -r "$c" ]] || continue
    if addnode_parse_config_nodes "$c" | grep -q .; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

# 既有成员行流解析：优先控制面 config.yaml；退路本机路由表+集群成员（只读本机，
# 干跑亦可安全推导）。结果写 AN_MEMBERS / AN_MEMBERS_SRC；失败非 0。
an_members_rows() {
  local cfg='' rows=''
  if cfg="$(an_find_config)" && rows="$(addnode_parse_config_nodes "$cfg")" && [[ -n "$rows" ]]; then
    AN_MEMBERS="$rows"
    AN_MEMBERS_SRC="控制面 config.yaml（${cfg}）"
    return 0
  fi
  local route_out='' br_addr='' self_name='' first_peer='' self_addr=''
  route_out="$(ip -4 route show 2>/dev/null | awk '$1 ~ /\/24$/ && $2 == "via"')" || route_out=''
  br_addr="$(ip -4 -brief addr show "${BRIDGE:-br-vm}" 2>/dev/null | awk '{print $3; exit}')" || br_addr=''
  self_name="$(hc_self_name 2>/dev/null || true)"
  first_peer="$(awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}' <<<"$route_out")"
  if [[ -n "$first_peer" ]]; then
    self_addr="$(addnode_src_from_route "$(ip -4 route get "$first_peer" 2>/dev/null || true)")"
  fi
  if [[ -n "$route_out" && -n "$br_addr" && -n "$self_addr" ]] \
    && rows="$(addnode_members_from_routes "$route_out" "$br_addr" "$self_name" "$self_addr")"; then
    AN_MEMBERS="$rows"
    AN_MEMBERS_SRC="本机路由表+br-vm（healthcheck 同源只读推导）"
    return 0
  fi
  return 1
}

# 既有成员中第一个可用作推导锚的 IPv4 管理地址（excl 排除指定地址；同新网段行跳过）
an_first_peer_addr() {
  local rows="$1" excl="${2:-}" name addr subnet gw
  while IFS=$'\t' read -r name addr subnet gw; do
    if [[ ! "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then continue; fi
    if [[ -n "$excl" && "$addr" == "$excl" ]]; then continue; fi
    if [[ "$subnet" == "$AN_SUBNET" ]]; then continue; fi
    printf '%s' "$addr"
    return 0
  done <<<"$rows"
  return 1
}

# 本机需 root 的操作：EUID=0 直跑，否则 sudo -n（失败由调用方按断点处理）
an_root() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

# ---- 第 1 步：预检（只读）----
an_step1_preflight() {
  echo "== 1/8 预检：${AN_TARGET} =="
  if ((AN_DRY == 1)); then
    echo "  将执行: ssh BatchMode 探活 / sudo -n true / test -e /dev/kvm / df 余量 / lscpu 地址位宽（hotplug 仅提示）"
    return 0
  fi
  local out='' used=''
  if ! out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$AN_TARGET" true 2>&1 </dev/null)"; then
    an_fail_step 1 1 "ssh BatchMode 不通（公钥未授权/主机不可达）：${out:0:200}"
  fi
  hc_pass "ssh BatchMode 通（${AN_TARGET}）"
  if ! ssh -o BatchMode=yes "$AN_TARGET" 'sudo -n true' >/dev/null 2>&1 </dev/null; then
    an_fail_step 1 1 "免密 sudo 不可用——物理前提（目标机需 git 公钥 + 免密 sudo 的账号），脚本不自动化补齐"
  fi
  hc_pass "免密 sudo 可用（sudo -n true）"
  if ! ssh -o BatchMode=yes "$AN_TARGET" 'test -e /dev/kvm' >/dev/null 2>&1 </dev/null; then
    an_fail_step 1 1 "/dev/kvm 不存在——物理机需 BIOS 开 VT-x/AMD-V（STATUS §5-2）"
  fi
  hc_pass "/dev/kvm 存在"
  out="$(ssh -o BatchMode=yes "$AN_TARGET" 'df -P /' 2>/dev/null </dev/null || true)"
  used="$(awk 'NR == 2 {gsub(/%/, "", $5); print $5}' <<<"$out")"
  if [[ -z "$used" ]]; then
    hc_skip "磁盘余量：df 无输出，跳过判定"
  elif ((100 - used < 15)); then
    hc_warn "磁盘 / 剩余 $((100 - used))%（<15%，incus 池会吃盘）"
  else
    hc_pass "磁盘 / 剩余 $((100 - used))%"
  fi
  # 老 CPU hotplug 提示（不自动判定；STATUS §5-3：≤36 位物理地址需 profile 级
  # limits.memory.hotplug=4GiB，否则 OVMF 74GiB 地址空间超 36 位上限崩溃）
  out="$(ssh -o BatchMode=yes "$AN_TARGET" 'lscpu | grep -i "address sizes"' 2>/dev/null </dev/null || true)"
  local bits=''
  bits="$(sed -nE 's/.*[[:space:]]([0-9]+) bits physical.*/\1/p' <<<"$out" | head -1)"
  if [[ -z "$bits" ]]; then
    hc_skip "地址位宽：lscpu 无 Address sizes 行，跳过 hotplug 提示"
  elif ((bits <= 36)); then
    hc_warn "物理地址 ${bits} 位（≤36）：建集群前给 profile 配 limits.memory.hotplug=4GiB（STATUS §5-3；AMD 48 位不受影响）——人工确认，不自动判定"
  else
    hc_pass "物理地址 ${bits} 位（>36，hotplug 无需特调）"
  fi
}

# ---- 第 2 步：deploy-remote 上架（ROUTES 自动推导）----
an_step2_deploy() {
  echo "== 2/8 deploy-remote：送 kit + 装 incus + kvm 组 + subuid + network =="
  local routes=''
  routes="$(addnode_routes_for_new "$AN_MEMBERS" "$AN_SUBNET")"
  local peer=''
  peer="$(an_first_peer_addr "$AN_MEMBERS")"
  if [[ -z "${AN_ADDR_RESOLVED}" ]]; then
    # --addr 未给且 host 非 IPv4 字面量：执行期从集群对端路由推导（INFRA_NET 教训：
    # hysteria 分流下默认路由可能走隧道；对端路由恒走物理路径）
    if [[ -z "$peer" ]]; then
      an_fail_step 2 2 "无既有成员管理地址可作推导锚——请显式 --addr"
    fi
    if ((AN_DRY == 1)); then
      AN_ADDR_RESOLVED="<执行期从集群对端路由推导：ssh ${AN_TARGET} ip -4 route get ${peer} 取 src；或显式 --addr>"
      AN_WAN_RESOLVED="<同一路由取 dev>"
    else
      local routeline='' src=''
      routeline="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        "$AN_TARGET" "ip -4 route get ${peer}" 2>&1 </dev/null)" \
        || an_fail_step 2 2 "对端路由推导失败（ip -4 route get ${peer}）：${routeline:0:200}——请显式 --addr"
      src="$(addnode_src_from_route "$routeline")"
      if [[ -z "$src" ]]; then
        an_fail_step 2 2 "从『ip -4 route get ${peer}』推不出 src（输出：${routeline:0:120}）——INFRA_NET 教训：禁用默认路由推导，请显式 --addr"
      fi
      AN_ADDR_RESOLVED="$src"
      AN_WAN_RESOLVED="$(addnode_dev_from_route "$routeline")"
    fi
  elif ((AN_DRY == 0)); then
    # 地址来自 --addr/IPv4 字面量；WAN 仍从对端路由推导（INFRA_NET 教训：
    # hysteria 分流下默认路由可能走隧道，network 的 WAN 缺省推导不可信）
    if [[ -n "$peer" ]]; then
      local routeline2=''
      routeline2="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        "$AN_TARGET" "ip -4 route get ${peer}" 2>/dev/null </dev/null || true)"
      AN_WAN_RESOLVED="$(addnode_dev_from_route "$routeline2")"
    fi
  fi
  echo "  NODE_ADDR = ${AN_ADDR_RESOLVED}"
  echo "  ROUTES    = ${routes:-（无既有对端；单成员集群）}"
  echo "  WAN       = ${AN_WAN_RESOLVED:-<对端路由推导/缺省>}"
  if ((AN_DRY == 1)); then
    echo "  将执行: deploy-remote ${AN_TARGET} NODE_NAME=${AN_NAME} NODE_ADDR=${AN_ADDR_RESOLVED} SUBNET=${AN_SUBNET} ROUTES=${routes} WAN=${AN_WAN_RESOLVED:-<推导>} --yes"
    echo "    （变量白名单/%q 转义/干跑语义复用 deploy-remote 原实现，不经手复制）"
    return 0
  fi
  if [[ -z "${AN_WAN_RESOLVED}" ]]; then
    an_fail_step 2 2 "WAN 网卡从对端路由推不出（对端 ${peer:-无} 路由异常）——新节点物理前提缺失或网段错位；先手工核对 ip route 后用 deploy-remote 路径"
  fi
  if ! subcmd_deploy_remote "$AN_TARGET" "NODE_NAME=${AN_NAME}" "NODE_ADDR=${AN_ADDR_RESOLVED}" \
    "SUBNET=${AN_SUBNET}" "ROUTES=${routes}" "WAN=${AN_WAN_RESOLVED}" --yes; then
    an_fail_step 2 2 "deploy-remote 返回非 0（远端五步有失败；看上方输出定位）"
  fi
  hc_pass "deploy-remote 完成（${AN_NAME} 侧 deploy 返回 0）"
}

# ---- 第 3 步：集群入伙 ----
an_step3_join() {
  echo "== 3/8 集群入伙：${AN_NAME} =="
  if ((AN_DRY == 1)); then
    echo "  将执行: 本机 cluster add ${AN_NAME} 取一次性 token → 生成 join preseed"
    echo "    （字段名锚 cluster_token/server_address/cluster_address；server_address=${AN_ADDR_RESOLVED}:8443）"
    echo "    → scp /tmp/join-${AN_NAME}.yaml（0600，用后即删，token 不回显）"
    echo "    → ssh ${AN_TARGET} sg incus-admin -c 'incus admin init --preseed < …' → 等 cluster list ONLINE"
    return 0
  fi
  local csv='' token='' status='' i=''
  csv="$(hc_incus cluster list --format csv 2>/dev/null || true)"
  status="$(awk -F, -v n="$AN_NAME" 'NF >= 7 && $1 == n {print $(NF - 1); exit}' <<<"$csv")"
  if [[ "${status^^}" == "ONLINE" ]]; then
    hc_pass "成员 ${AN_NAME} 已 ONLINE（幂等跳过）"
    return 0
  fi
  if [[ -n "$status" ]]; then
    an_fail_step 3 3 "成员 ${AN_NAME} 在册但状态 ${status}（非 ONLINE）——先人工排障（incus cluster list / 对端 journalctl -u incus）再续跑"
  fi
  token="$(hc_incus cluster add "$AN_NAME" 2>/dev/null | tail -n 1 || true)"
  if [[ ! "$token" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    an_fail_step 3 3 "incus cluster add ${AN_NAME} 未取得一次性 token（手工生成后写 join preseed 续跑，或排障后重跑）"
  fi
  # preseed 经本机临时文件 → scp → 远程 admin init --preseed。
  # token 属秘密：umask 177 落盘 + 本机用后即删 + 远端随命令清理 + 绝不回显。
  AN_PRESEED="$(mktemp "${TMPDIR:-/tmp}/addnode-preseed.XXXXXX")"
  if ! ( umask 177; addnode_gen_preseed "$AN_NAME" "$token" "${AN_ADDR_RESOLVED}" "${AN_POOL_DIR}" >"$AN_PRESEED" ); then
    rm -f "$AN_PRESEED"
    an_fail_step 3 3 "join preseed 生成失败"
  fi
  if ! scp -q -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    "$AN_PRESEED" "${AN_TARGET}:/tmp/join-${AN_NAME}.yaml" 2>/dev/null </dev/null; then
    rm -f "$AN_PRESEED"
    AN_PRESEED=''
    an_fail_step 3 3 "preseed 传送 ${AN_TARGET}:/tmp/join-${AN_NAME}.yaml 失败（token 未消耗可重跑）"
  fi
  rm -f "$AN_PRESEED"
  AN_PRESEED=''
  hc_pass "join preseed 已生成并传送（cluster_token/server_address/cluster_address 锚位；本机文件已删，token 未回显）"
  local rjoin="chmod 600 /tmp/join-${AN_NAME}.yaml && sg incus-admin -c 'incus admin init --preseed < /tmp/join-${AN_NAME}.yaml' && rm -f /tmp/join-${AN_NAME}.yaml"
  local jout=''
  if ! jout="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$AN_TARGET" "$rjoin" 2>&1 </dev/null)"; then
    # 远端 token 文件兜底清理再报断点（token 已消耗，续跑会重新 cluster add）
    ssh -o BatchMode=yes "$AN_TARGET" "rm -f /tmp/join-${AN_NAME}.yaml" >/dev/null 2>&1 </dev/null || true
    an_fail_step 3 3 "远程 preseed join 失败：${jout:0:200}"
  fi
  hc_pass "远程 preseed join 已执行（incus admin init --preseed；远端 token 文件已删）"
  echo "  等待 ${AN_NAME} ONLINE（最长 2 分钟）…"
  for i in $(seq 1 24); do
    csv="$(hc_incus cluster list --format csv 2>/dev/null || true)"
    status="$(awk -F, -v n="$AN_NAME" 'NF >= 7 && $1 == n {print $(NF - 1); exit}' <<<"$csv")"
    if [[ "${status^^}" == "ONLINE" ]]; then
      hc_pass "成员 ${AN_NAME} ONLINE"
      return 0
    fi
    sleep 5
  done
  an_fail_step 3 3 "成员 ${AN_NAME} 2 分钟未 ONLINE（incus cluster list 手查；对端 journalctl -u incus；修好后 --from-step 3 续跑）"
}

# ---- 第 4 步：镜像分发 ----
an_step4_image() {
  echo "== 4/8 镜像分发 =="
  local image="${ADDNODE_IMAGE:-dev-base}"
  if ((AN_DRY == 1)); then
    echo "  将执行: incus image copy ${image} local: --target ${AN_NAME}（local 构建+copy 分发）"
    return 0
  fi
  if ! hc_incus image copy "$image" local: --target "$AN_NAME"; then
    an_fail_step 4 4 "镜像分发失败——先在本机构建：scripts/build-base-image-local.sh，再重跑"
  fi
  hc_pass "镜像 ${image} 已分发到 ${AN_NAME}"
}

# ---- 第 5 步：控制面接线（config 安全追加 + 重启）----
# 干跑对「config 缺席/形态异常」宽大处理（WARN 后继续出完整计划）；执行模式一律断点。
an_step5_config() {
  echo "== 5/8 控制面接线：config.yaml nodes 追加 ${AN_NAME} =="
  local cfg=''
  if ! cfg="$(an_find_config)"; then
    if ((AN_DRY == 1)); then
      hc_warn "config 未找到（候选：RAILANS_CONFIG > /etc/railans/config.yaml > <kit>/.local-test/config.yaml）——执行时第 5 步将在此停住；可用 RAILANS_CONFIG=<config.yaml> 指认"
      echo "  将执行: 备份 + 安全追加 ${AN_NAME}@${AN_ADDR_RESOLVED} → 原子替换 → 重启控制面（config 待指认）"
      return 0
    fi
    an_fail_step 5 5 "找不到控制面 config.yaml（候选：RAILANS_CONFIG > /etc/railans/config.yaml > <kit>/.local-test/config.yaml）"
  fi
  echo "  配置文件: ${cfg}"
  local gw="${AN_SUBNET%.*}.1"   # 同 AN_GW 推导（%.* 去尾段得 .1）
  if addnode_config_validate "$cfg" "$AN_NAME" "${AN_ADDR_RESOLVED}" "$AN_SUBNET"; then
    hc_pass "config 已含 ${AN_NAME} 且值一致（幂等跳过追加）"
  else
    if addnode_config_has_node "$cfg" "$AN_NAME"; then
      an_fail_step 5 5 "config 已有 ${AN_NAME} 条目但 address/subnet 不匹配——人工核对 ${cfg} 后续跑"
    fi
    local oldn=0 newn=0 tmpf='' bak=''
    oldn="$(addnode_parse_config_nodes "$cfg" | grep -c . || true)"
    tmpf="$(mktemp "${cfg}.addnode.XXXXXX" 2>/dev/null)" || tmpf=''
    if [[ -z "$tmpf" ]]; then
      an_fail_step 5 5 "无法在 ${cfg} 旁创建临时文件（目录不可写且 sudo -n 不可用？）——追加中止，${cfg} 未动"
    fi
    if ! addnode_config_append "$cfg" "$tmpf" "$AN_NAME" "${AN_ADDR_RESOLVED}" "$AN_SUBNET" "$gw"; then
      rm -f "$tmpf"
      if ((AN_DRY == 1)); then
        hc_warn "nodes 块缺失或形态异常（${cfg}）——执行时第 5 步将在此停住；请人工核对后重跑"
        return 0
      fi
      an_fail_step 5 5 "nodes 块缺失或形态异常（追加中止；${cfg} 未动）"
    fi
    newn="$(addnode_parse_config_nodes "$tmpf" | grep -c . || true)"
    if ((newn != oldn + 1)); then
      rm -f "$tmpf"
      an_fail_step 5 5 "追加后节点数校验不过（${oldn}→${newn}；${cfg} 未动）"
    fi
    if ! addnode_config_validate "$tmpf" "$AN_NAME" "${AN_ADDR_RESOLVED}" "$AN_SUBNET"; then
      rm -f "$tmpf"
      an_fail_step 5 5 "追加产物结构校验不过（${cfg} 未动）"
    fi
    if ((AN_DRY == 1)); then
      rm -f "$tmpf"
      echo "  将执行: 备份 ${cfg} → 原子替换（追加 ${AN_NAME}@${AN_ADDR_RESOLVED} ${AN_SUBNET} gw ${gw}）→ 重启控制面（探测 systemd/ctl.sh）"
      return 0
    fi
    bak="${cfg}.bak.$(date +%Y%m%d%H%M%S)"
    if ! an_root cp -p "$cfg" "$bak"; then
      rm -f "$tmpf"
      an_fail_step 5 5 "备份 ${cfg} 失败（sudo -n 可用？）"
    fi
    if ! an_root mv "$tmpf" "$cfg"; then
      rm -f "$tmpf"
      an_fail_step 5 5 "替换 ${cfg} 失败（目录不可写且 sudo -n 不可用？备份在 ${bak}）"
    fi
    hc_pass "config 已安全追加 ${AN_NAME}（原子替换；原文件备份 ${bak}）"
  fi
  if ((AN_DRY == 1)); then
    echo "  将执行: 控制面重启（systemctl cat railans.service 在→systemctl restart railans；ctl.sh 形态 loud fail 指路 runbook §4.1）"
    return 0
  fi
  if systemctl cat railans.service >/dev/null 2>&1; then
    if ! an_root systemctl restart railans; then
      an_fail_step 5 5 "systemctl restart railans 失败（journalctl -u railans -n 50；config 备份可回滚）"
    fi
    hc_pass "控制面已重启（systemd railans.service）"
  elif pgrep -x railans >/dev/null 2>&1; then
    an_fail_step 5 5 "控制面非 systemd 运行（ctl.sh 形态）——按 runbook §4.1 手动重启后 --from-step 5 续跑（config 追加已幂等跳过，续跑只重试重启探测）"
  else
    an_fail_step 5 5 "railans 控制面未在运行（unit 不在且无进程）——先确认控制面部署形态再续跑"
  fi
}

# ---- 第 6 步：老节点路由补全 ----
an_step6_routes() {
  echo "== 6/8 老节点路由补全（各老节点 ROUTES 追加 ${AN_SUBNET} via ${AN_ADDR_RESOLVED}）=="
  local name addr subnet gw routes_old='' any=0 out=''
  local rsync_args=(-az --exclude .git --exclude .local-test)
  local ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
  while IFS=$'\t' read -r name addr subnet gw; do
    if [[ -z "$addr" ]]; then continue; fi
    if [[ "$subnet" == "$AN_SUBNET" ]]; then continue; fi   # 新节点自身行（重跑残留）
    if [[ ! "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      hc_skip "老节点 ${name:-?}（地址 ${addr} 非 IPv4），跳过"
      continue
    fi
    any=1
    routes_old="$(addnode_routes_for_old "$addr" "$AN_MEMBERS" "$AN_SUBNET" "${AN_ADDR_RESOLVED}")"
    if ((AN_DRY == 1)); then
      echo "  将执行: ${name:-$addr}（${addr}）rsync kit + ROUTES=${routes_old} 重跑 network"
      continue
    fi
    local u='' peer='' routeline='' owan='' rcmd=''
    if ! u="$(hc_ssh_user "$addr")"; then
      an_fail_step 6 6 "老节点 ${name:-$addr}：BatchMode 下没有可用 ssh 用户（试过 RAILANS_SSH_USER/SUDO_USER/$(id -un)/ops）——人工补路由后续跑"
    fi
    peer="$(an_first_peer_addr "$AN_MEMBERS" "$addr")"
    if [[ -z "$peer" ]]; then
      peer="${AN_ADDR_RESOLVED}"
    fi
    routeline="$(ssh "${ssh_opts[@]}" "${u}@${addr}" "ip -4 route get ${peer}" 2>/dev/null </dev/null || true)"
    owan="$(addnode_dev_from_route "$routeline")"
    if [[ -z "$owan" ]]; then
      an_fail_step 6 6 "老节点 ${addr} 的 WAN 从对端路由（get ${peer}）推不出——INFRA_NET 教训：不从默认路由推导；人工核对后以 WAN=… 显式补跑"
    fi
    if ! rsync "${rsync_args[@]}" -e "ssh ${ssh_opts[*]}" "${ROOT_DIR}/" "${u}@${addr}:/tmp/railans-kit/"; then
      an_fail_step 6 6 "rsync kit → ${addr} 失败"
    fi
    # %q 转义（deploy-remote 同款）：ROUTES 含分号/空格，必须整体转义后进远端 env
    rcmd="sudo -n env"
    for out in "NODE_ADDR=${addr}" "SUBNET=${subnet}" "WAN=${owan}" "ROUTES=${routes_old}" "BRIDGE=${BRIDGE:-br-vm}"; do
      rcmd+=" $(printf '%q' "$out")"
    done
    rcmd+=" bash /tmp/railans-kit/node/railans-node.sh network"
    if ! ssh "${ssh_opts[@]}" "${u}@${addr}" "$rcmd" >/dev/null 2>&1 </dev/null; then
      an_fail_step 6 6 "老节点 ${addr} 路由重刷失败——手工路径：ssh ${u}@${addr} '${rcmd}' 后续跑"
    fi
    hc_pass "老节点 ${name:-$addr}（${addr}）已补 ${AN_SUBNET} via ${AN_ADDR_RESOLVED}（WAN=${owan}）"
  done <<<"$AN_MEMBERS"
  if ((any == 0)); then
    an_fail_step 6 6 "无老节点可补全（成员清单空/仅新节点）——成员来源 ${AN_MEMBERS_SRC}"
  fi
}

# ---- 第 7 步：验收 ----
an_verify_box() {
  local out='' box='' node='' port_n='' out2='' ok=1
  out="$(ssh -o BatchMode=yes -p "${AN_CTL_PORT}" "${AN_CTL_USER}@${AN_CTL_HOST}" new --json 2>&1 </dev/null)" || true
  box="$(sed -n 's/^[[:space:]]*"box":[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$out" | head -1)"
  node="$(sed -n 's/^[[:space:]]*"node":[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$out" | head -1)"
  port_n="$(sed -n 's/^[[:space:]]*"ssh_port":[[:space:]]*\([0-9]\{1,5\}\).*/\1/p' <<<"$out" | head -1)"
  if [[ -z "$box" ]]; then
    an_fail_step 7 7 "验收箱创建失败（new --json 无 box 字段）：${out:0:200}"
  fi
  if [[ "$node" != "$AN_NAME" ]]; then
    hc_fail "验收箱落在 ${node:-未知}（期望 ${AN_NAME}）——调度未落新节点"
    ok=0
  else
    hc_pass "验收箱 ${box} 落在 ${AN_NAME}"
  fi
  if [[ -n "$port_n" ]] && out2="$(ssh-keyscan -T 10 -p "$port_n" 127.0.0.1 2>/dev/null)" \
    && grep -q 'ssh-ed25519' <<<"$out2"; then
    hc_pass "数据面 SSH 抽测：:${port_n} 出 host key（入口→br-vm→box:22 链路通；登录级验证属主控复核）"
  else
    hc_fail "数据面 SSH 抽测不过（:${port_n:-?} keyscan 无 ssh-ed25519）——端口转发链路断"
    ok=0
  fi
  # 验收箱失败也要删（不留 TTL 孤儿）
  if ! ssh -o BatchMode=yes -p "${AN_CTL_PORT}" "${AN_CTL_USER}@${AN_CTL_HOST}" rm "$box" >/dev/null 2>&1 </dev/null; then
    hc_warn "rm 验收箱 ${box} 失败——手工：ssh -p ${AN_CTL_PORT} ${AN_CTL_USER}@${AN_CTL_HOST} rm ${box}"
  fi
  return $((1 - ok))
}

an_step7_verify() {
  echo "== 7/8 验收 =="
  if ((AN_DRY == 1)); then
    echo "  将执行: healthcheck --all（只读全绿门槛）"
    if [[ "${AN_SKIP_VERIFY}" == 1 ]]; then
      echo "  --skip-verify：验收箱段将跳过"
    else
      echo "  将执行: ssh -p <ctl端口> ${AN_CTL_USER}@${AN_CTL_HOST} new --json → 断言 node==${AN_NAME} → ssh-keyscan 数据面抽测 → rm 验收箱"
    fi
    return 0
  fi
  echo "-- 7a healthcheck --all --"
  if ! subcmd_healthcheck --all </dev/null; then
    an_fail_step 7 7 "healthcheck --all 有 FAIL（修正后 --from-step 7 重跑；节点级排障见 healthcheck 输出）"
  fi
  if [[ "${AN_SKIP_VERIFY}" == 1 ]]; then
    hc_skip "验收箱：--skip-verify 跳过（全链路登录/预览建议人工抽测）"
    return 0
  fi
  echo "-- 7b 验收箱（建 → 断言落 ${AN_NAME} → 数据面抽测 → rm）--"
  if ! an_verify_box; then
    an_fail_step 7 7 "验收箱断言不过（箱已删；调度/网络问题排障后 --from-step 7 重跑）"
  fi
}

# ---- 第 8 步：汇总 ----
an_step8_summary() {
  echo "== 8/8 汇总 =="
  if ((AN_DRY == 1)); then
    echo "  将输出: 新节点信息 / 端口池余量（capacity）/ 后续手工事项"
    return 0
  fi
  local members_n=0 cap='' avail='' bmax=''
  members_n="$(printf '%s\n' "$AN_MEMBERS" | grep -c . || true)"
  cap="$(ssh -o BatchMode=yes -p "${AN_CTL_PORT}" "${AN_CTL_USER}@${AN_CTL_HOST}" capacity 2>/dev/null </dev/null || true)"
  avail="$(sed -n 's/.*"available":[[:space:]]*\([0-9]\{1,\}\).*/\1/p' <<<"$cap" | head -1)"
  bmax="$(sed -n 's/.*"boxes_max":[[:space:]]*\([0-9]\{1,\}\).*/\1/p' <<<"$cap" | head -1)"
  cat <<EOF

新节点:
  成员名:   ${AN_NAME}
  管理地址: ${AN_ADDR_RESOLVED}
  VM 网段:  ${AN_SUBNET}（网关 ${AN_GW}，dir 池 ${AN_POOL_DIR}）
  集群规模: config 在册 ${members_n} 个成员（含本节点；运行态见 incus cluster list）
EOF
  if [[ -n "$avail" && -n "$bmax" ]]; then
    echo "  端口池余量: available=${avail} / boxes_max=${bmax}（全局端口池与 max_boxes 不因加节点变化）"
  else
    echo "  端口池余量: 取不到（capacity 命令失败，不阻断）"
  fi
  local -a notes=()
  if [[ -n "${AN_MAXBOXES}" ]]; then
    notes+=("控制面 per-node 配额暂无字段：--max-boxes ${AN_MAXBOXES} 仅记为建议值，未落 config（全局 max_boxes 未改）")
  fi
  if [[ "${AN_SKIP_VERIFY}" == 1 ]]; then
    notes+=("已 --skip-verify：未建验收箱，数据面登录/预览/L3 建议人工抽测")
  fi
  if ((${#notes[@]} == 0)); then
    echo "  后续手工事项: 无"
  else
    echo "  后续手工事项:"
    local n
    for n in "${notes[@]}"; do
      echo "    - ${n}"
    done
  fi
}

subcmd_add_node() {
  local target='' name='' subnet='' arg=''
  local -a positionals=()
  while (($#)); do
    arg="$1"
    case "$arg" in
      --addr)
        [[ -n "${2:-}" ]] || { echo "add-node：--addr 需要管理 IP 参数" >&2; return 2; }
        if [[ ! "$2" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
          echo "add-node：--addr '${2}' 非 IPv4" >&2
          return 2
        fi
        AN_ADDR_OPT="$2"
        shift 2
        ;;
      --pool-dir)
        [[ -n "${2:-}" ]] || { echo "add-node：--pool-dir 需要路径参数" >&2; return 2; }
        AN_POOL_DIR="$2"
        AN_POOL_DIR_SET=1
        shift 2
        ;;
      --max-boxes)
        [[ -n "${2:-}" ]] || { echo "add-node：--max-boxes 需要数字参数" >&2; return 2; }
        if [[ ! "$2" =~ ^[0-9]+$ ]]; then
          echo "add-node：--max-boxes '${2}' 非数字" >&2
          return 2
        fi
        AN_MAXBOXES="$2"
        shift 2
        ;;
      --skip-verify)
        AN_SKIP_VERIFY=1
        shift
        ;;
      --from-step)
        [[ -n "${2:-}" ]] || { echo "add-node：--from-step 需要步骤号（1-8）" >&2; return 2; }
        if [[ ! "$2" =~ ^[1-8]$ ]]; then
          echo "add-node：--from-step '${2}' 越界（1-8）" >&2
          return 2
        fi
        AN_FROM_STEP="$2"
        shift 2
        ;;
      --yes | -y)
        AN_DRY=0
        shift
        ;;
      --help | -h)
        an_usage_addnode
        return 0
        ;;
      -*)
        echo "add-node：不认识的选项 ${arg}（只支持 --addr/--pool-dir/--max-boxes/--skip-verify/--from-step/--yes/--help）" >&2
        return 2
        ;;
      *)
        positionals+=("$arg")
        shift
        ;;
    esac
  done

  if ((${#positionals[@]} != 3)); then
    an_usage_addnode
    return 2
  fi
  target="${positionals[0]}"
  name="${positionals[1]}"
  subnet="${positionals[2]}"
  if [[ "$target" != *@* || "$target" == *[[:space:]]* ]]; then
    echo "add-node：目标机要写成 user@host（例 ops@192.168.1.15），收到 '${target}'" >&2
    return 2
  fi
  if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,62}$ ]]; then
    echo "add-node：成员名 '${name}' 不合法（字母开头，字母数字-_，≤63）" >&2
    return 2
  fi
  if [[ ! "$subnet" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){2}\.0/24$ ]]; then
    echo "add-node：网段 '${subnet}' 要写成 x.x.x.0/24（例 10.10.5.0/24）" >&2
    return 2
  fi

  AN_TARGET="$target"
  AN_NAME="$name"
  AN_SUBNET="$subnet"
  AN_GW="${subnet%.*}.1"   # x.x.x.0/24 → x.x.x.1（%.* 去尾段，不是 %/*——那是留 .0 会得 x.x.x.0.1）
  AN_POOL_DIR="${AN_POOL_DIR:-${ADDNODE_POOL_DIR:-/var/lib/incus/storage-pools/default}}"
  AN_CTL_USER="${RAILANS_CTL_USER:-ops}"
  AN_CTL_HOST="${RAILANS_CTL_HOST:-127.0.0.1}"
  AN_CTL_PORT=22
  local cfg=''
  if cfg="$(an_find_config)"; then
    AN_CTL_PORT="$(addnode_ctl_port "$cfg")"
  fi

  # 管理地址：--addr > IPv4 字面量 host > 执行期对端路由推导（仅 --from-step ≤2 允许推迟）
  local hostpart="${AN_TARGET#*@}"
  if [[ -n "${AN_ADDR_OPT}" ]]; then
    AN_ADDR_RESOLVED="${AN_ADDR_OPT}"
  elif [[ "$hostpart" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    AN_ADDR_RESOLVED="$hostpart"
  elif ((AN_FROM_STEP > 2)); then
    echo "add-node：--from-step ${AN_FROM_STEP} 起需要确定的 NODE_ADDR——请显式 --addr（执行期对端路由推导只发生在第 2 步）" >&2
    return 2
  fi

  # 既有成员清单（只读本机；两路来源见 an_members_rows）
  if ! an_members_rows; then
    echo "add-node：推不出既有节点清单（无 config.yaml 且本机无集群路由）——在控制机上执行，或 RAILANS_CONFIG=<config.yaml> 指认" >&2
    return 2
  fi
  local members_n=0
  members_n="$(printf '%s\n' "$AN_MEMBERS" | grep -c . || true)"

  # token 落盘文件兜底清理（本实现已经 stdin 直送不留盘，此处为防未来改动回归）
  an_preseed_guard() { if [[ -n "${AN_PRESEED:-}" ]]; then rm -f "$AN_PRESEED"; fi; }
  trap an_preseed_guard EXIT

  local mode_desc="执行模式（--yes）"
  if ((AN_DRY == 1)); then
    mode_desc="干跑：未连任何节点、未改任何状态"
  fi
  echo "== add-node 计划（${mode_desc}；成员来源 ${AN_MEMBERS_SRC}，${members_n} 个既有成员）=="
  echo "  目标机:   ${AN_TARGET}"
  echo "  成员名:   ${AN_NAME}（VM 网段 ${AN_SUBNET}，网关 ${AN_GW}）"
  echo "  NODE_ADDR: ${AN_ADDR_RESOLVED:-<第 2 步推导>}"
  echo "  dir 池:   ${AN_POOL_DIR}"
  [[ -n "${AN_MAXBOXES}" ]] && echo "  --max-boxes ${AN_MAXBOXES}: 仅建议值（per-node 配额字段暂无，不落 config）"
  [[ "${AN_SKIP_VERIFY}" == 1 ]] && echo "  --skip-verify: 验收箱段将跳过（healthcheck --all 仍跑）"
  echo

  local s
  local -a step_fns=(an_step1_preflight an_step2_deploy an_step3_join an_step4_image \
    an_step5_config an_step6_routes an_step7_verify an_step8_summary)
  for s in 1 2 3 4 5 6 7 8; do
    if ((s < AN_FROM_STEP)); then
      printf '%s-- 跳过第 %s/8 步（--from-step %s 续跑）--%s\n' "$C_DIM" "$s" "$AN_FROM_STEP" "$C_RST"
      continue
    fi
    "${step_fns[$((s - 1))]}"
  done

  if ((AN_DRY == 1)); then
    echo
    echo "干跑结束：以上是完整计划，未连任何节点、未改任何状态。确认无误后重跑并加 --yes；"
    echo "失败断点可用 --from-step <N> --yes 续跑（各步幂等，前序步骤自动跳过/幂等重放）。"
  else
    echo
    echo "add-node 完成：${AN_NAME}（${AN_ADDR_RESOLVED}）已入集群并接线。"
  fi
}
# ===== 入口 =====
main() {
  local sub="${1:-}"
  case "$sub" in
    "")
      usage
      ;;
    help | -h | --help)
      usage
      ;;
    add-node)
      # 独立分支登记（不动既有合并 case 行——test-subid/test-nft-render 对
      # `| setup-subuid)` 等字面锚有零漂移断言）
      shift
      subcmd_add_node "$@"
      ;;
    preflight | install-incus | bootstrap | join | network | image | control | caddy | deploy | deploy-remote | healthcheck | verify-nft | setup-subuid)
      shift
      "subcmd_${sub//-/_}" "$@"
      ;;
    *)
      echo "railans-node.sh: 未知子命令 '${sub}'" >&2
      echo >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
