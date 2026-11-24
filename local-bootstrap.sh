#!/usr/bin/env bash
# railans 本机单节点验证 bootstrap —— 请手动执行：
#   sudo bash <kit-dir>/local-bootstrap.sh     # ADMIN_USER=<运维账号> 可覆盖，默认取当前 sudo 用户
#
# 做五件事（全部记录在此，可逆）：
#   1. apt 装 qemu-system-x86 / ovmf / caddy / nftables
#   2. 装 incus（优先 snap；本机 snap 商店无此包时落 Zabbly apt 仓）
#   3. 运维账号加入 incus-admin 组（后续 incus 操作免 sudo）
#   4. 跑 kit 的 railans-node.sh network：建 br-vm 网桥 10.10.1.1/24 +
#      ip_forward + nftables 隔离规则（单节点，无跨节点路由）
#   5. caddy：装 kit 的 Caddyfile + conf.d/boxes.caddy 空文件；
#      conf.d 目录属主临时给运维账号（测试期控制面以该身份写站点文件）
#
# 刻意不做的事：
#   * 不执行 railans-node.sh control（它会把系统 sshd 挪到 2200）——
#     测试控制面用 2229 端口，系统 sshd 保持 22 不动
#   * 不启用 dnsmasq 服务——预览验证用 curl --resolve，不接管局域网 DNS
#
# 回滚：
#   snap remove incus; apt-get purge caddy
#   rm /etc/netplan/90-railans-br-vm.yaml /etc/sysctl.d/99-railans.conf
#   rm /etc/nftables.d/railans.nft /etc/systemd/system/railans-{nftables,routes}.service
#   nft delete table inet railans; ip link del br-vm; netplan apply
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # kit 仓根 = 本脚本所在目录
ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-ops}}"        # 运维账号：默认取发起 sudo 的用户
if [[ ${EUID} -ne 0 ]]; then
  echo "请用 sudo 运行" >&2
  exit 1
fi
if [[ ! -e /dev/kvm ]]; then
  echo "/dev/kvm 不存在，先确认 BIOS VT-x 已开启" >&2
  exit 1
fi

echo "== 1/5 apt 依赖 =="
apt-get update -qq
apt-get install -y qemu-system-x86 ovmf nftables \
  debian-keyring debian-archive-keyring apt-transport-https curl gnupg

# caddy 不在 Ubuntu 源里，回退路径：官方 apt 源
if ! apt-get install -y caddy >/dev/null 2>&1; then
  echo "    Ubuntu 源没有 caddy，改用官方 apt 源（dl.cloudsmith.io）"
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y caddy
fi
caddy version

echo "== 2/5 安装 incus =="
if snap info incus >/dev/null 2>&1; then
  if snap list incus >/dev/null 2>&1; then
    echo "    incus 已安装（snap）"
  else
    snap install incus --channel=latest/stable
  fi
else
  # 本设备 snap 商店没有 incus（本机实测如此）→ 落 Zabbly apt 仓
  # （Incus 官方维护的 deb 源，Ubuntu 24.04 的标准安装路径）
  . /etc/os-release
  echo "    snap 商店无 incus，改用 Zabbly apt 仓（${VERSION_CODENAME}）"
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
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
incus version 2>/dev/null || incus --version

echo "== 3/5 ${ADMIN_USER} 加入 incus-admin 组 =="
usermod -aG incus-admin "${ADMIN_USER}"
id "${ADMIN_USER}" | tr ',' '\n' | grep incus-admin || { echo "入组失败" >&2; exit 1; }

echo "== 4/5 VM 网络（railans-node.sh network）=="
# 会：写 /etc/netplan/90-railans-br-vm.yaml 并 netplan apply（只新增网桥，不动现有网卡配置）
#     写 /etc/sysctl.d/99-railans.conf 开 ip_forward
#     渲染并加载 /etc/nftables.d/railans.nft（inet railans 表）
NODE_ADDR=192.168.1.11 SUBNET=10.10.1.0/24 WAN="${WAN:-eno1}" ROUTES="" \
  bash "$KIT/node/railans-node.sh" network

echo "== 5/5 caddy =="
install -d -o "${ADMIN_USER}" -g "${ADMIN_USER}" -m 755 /etc/caddy/conf.d
if [[ -f /etc/caddy/Caddyfile ]]; then
  cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.pre-railans.$(date +%s)"
fi
install -m 644 "$KIT/node/deploy/Caddyfile" /etc/caddy/Caddyfile
install -o "${ADMIN_USER}" -g "${ADMIN_USER}" -m 644 /dev/null /etc/caddy/conf.d/boxes.caddy
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl enable --now caddy
systemctl restart caddy
ss -lntp | grep ':443' || { echo "caddy 没有监听 443" >&2; exit 1; }

echo
echo "bootstrap 完成。"
echo "  - 系统 sshd 未被改动（22 仍归 OpenSSH）"
echo "  - 接下来由 ${ADMIN_USER} 会话继续：incus init → 建镜像 → 控制面 → 全链路测试"
