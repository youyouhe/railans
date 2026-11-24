#!/usr/bin/env bash
# 镜像构建 runner —— dev-base 基础镜像的唯一构建入口
# （node 版构建子命令已弃用，railans-node.sh image 只会快速失败并指路本脚本）。
# 本变体不以 root 跑（incus-admin 组驱动），供开发机自建镜像用。
set -euo pipefail

NODE=node1
BASE_IP=10.10.1.250
POOL=default
IMAGE="${IMAGE:-noble-cloud-vm}"   # 默认本地化源镜像，绕开 v6 下载抖动（可 IMAGE=images:ubuntu/24.04/cloud 覆盖）
IMAGE_ALIAS=dev-base
PROFILE=dev
BRIDGE=br-vm
CPUS=2
MEMORY=2GiB
DISK=20GiB
# orca 上游 checkout（打包 orca CLI 最小包用；按实际路径以环境变量覆盖）
ORCA_SRC="${ORCA_SRC:-$HOME/orca}"
NAME=railans-base-build

# 异常退出兜底：构建半路死掉（set -e 触发/被杀）时停掉遗留的构建 VM——
# 2026-11-14 教训：一次构建 11/12 半路死掉，VM 空转两天烧 CPU。只停不删，保留现场排障；
# 下次运行的"2/7 清理同名构建实例"本来就会先强删同名实例。
build_vm_guard() {
  local rc=$?
  if [[ ${rc} -ne 0 ]] && incus list "${NAME}" --format csv 2>/dev/null | grep -q .; then
    echo "WARN: 构建异常退出(rc=${rc})，停掉遗留的 ${NAME}（实例保留供排障）" >&2
    incus stop "${NAME}" --timeout=60 2>/dev/null || incus stop "${NAME}" --force 2>/dev/null || true
  fi
}
trap build_vm_guard EXIT

PREFIX_IP="$(awk -F. '{print $1"."$2"."$3".1"}' <<<"${BASE_IP}")"

echo "==> 1/7 profile ${PROFILE} 已就绪（前置步骤已建）"

echo "==> 2/7 清理同名构建实例"
incus delete "${NAME}" --force >/dev/null 2>&1 || true

echo "==> 3/7 启动模板 VM（${IMAGE} -> ${NAME} on ${NODE}）"
NETCFG="$(cat <<EOF
version: 2
ethernets:
  nic0:
    match:
      name: "en*"
    dhcp4: false
    addresses:
      - ${BASE_IP}/24
    routes:
      - to: default
        via: ${PREFIX_IP}
    nameservers:
      addresses: [223.5.5.5, 119.29.29.29]
EOF
)"
incus launch "${IMAGE}" "${NAME}" \
  --vm \
  --profile "${PROFILE}" \
  --target "${NODE}" \
  --config "cloud-init.network-config=${NETCFG}"

echo "==> 4/7 等待 Incus agent 就绪"
for i in $(seq 1 60); do
  if incus exec "${NAME}" -- true >/dev/null 2>&1; then
    echo "    ready after ~$((i * 10))s"
    break
  fi
  if [[ ${i} -eq 60 ]]; then
    echo "模板 VM 10 分钟未就绪。检查：incus info ${NAME} --show-log" >&2
    exit 1
  fi
  sleep 10
done

echo "==> 5/7 安装开发环境"
# 经 stdin 流式喂脚本会在长命令期间被 vsock 中继截断（build #11 实测：
# apt 之后的 provision 全部丢失但退出码为 0）。改为文件推送 + 文件执行。
cat >/tmp/railans-guest.sh <<'GUEST'
export DEBIAN_FRONTEND=noninteractive
# 2026-11-22:首启 cloud-init 自带 apt 更新会占 /var/lib/apt/lists/lock(实测 rc=100),
# 且可能重写 sources.list——等它收尾、锁释放后再切国内源
cloud-init status --wait >/dev/null 2>&1 || true
for i in $(seq 1 120); do
  flock -n /var/lib/apt/lists/lock -c true 2>/dev/null && break
  sleep 5
done
# guest apt 源切国内镜像(archive.ubuntu.com 国际路径慢/挂起实测)
sed -i 's|http://archive.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g; s|http://security.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
apt-get update
apt-get install -y --no-install-recommends \
  openssh-server ca-certificates curl git jq unzip \
  build-essential pkg-config \
  python3 python3-venv python3-pip \
  nodejs npm \
  ripgrep tmux htop less vim-tiny \
  net-tools dnsutils auditd \
  podman
# gh CLI 延后：出口降速期 cli.github.com 装不上，gh apt 源注入本次不入镜像（ops#468）

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

# ubuntu→dev 改名路径不触发 cloud-init 的用户创建，sudoers 永远不会被写；
# dev 的密码又是锁死的，等于 box 里拿不到 root。显式给免密 sudo (F1)。
echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-railans-dev
chmod 440 /etc/sudoers.d/90-railans-dev

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
#     L2 后首启 cloud-init 不再重写该文件（default_user.sudo=false），此处只清构建 VM 自己的首启遗留。
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
#   来源限内网管理段+box 段：同节点网关=10.10.N.1，跨节点经入口 SNAT=192.168.1.11（192.168.1.0/24）
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
# 凭据与 orca 包不进镜像，由控制面 ensureBox 按箱注入。
# 镜像保持零凭据——发布前自检闸断言镜像内无 cc-switch.db / orca wrapper。
install -d -o dev -g dev -m 700 /home/dev/.cc-switch   # 控制面注入目标目录（保留）
echo "== AI 工具链 =="
# 供应链固定：安装器/发布包一律 digest pin——升级走人工变更：
# 换 digest/tag 需改码复核后提交，禁止回切 latest/浮动源。digest 抓取日期见行尾注释。
CLAUDE_INSTALL_SH_SHA256='2c5506d110560bf618bbe88f678f2c2a0047c86a9c6585fc84976120b1de0b44'   # 2026-11-24 抓取
CC_SWITCH_TAG='v5.11.4'
CC_SWITCH_TAR_SHA256='6c165ca6461f200aea1f739e4dad3be3ebacd21de864895679046ca99cd44024'       # 2026-11-24 抓取，与该 release checksums.txt 交叉核对一致
# claude-code：官方原生安装器，落文件 + sha256 校验过再执行（不得回切管道直跑）；
# 以 dev 运行 → /home/dev/.local/bin/claude
curl -4 -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh
echo "${CLAUDE_INSTALL_SH_SHA256}  /tmp/claude-install.sh" | sha256sum -c - \
  || { echo "FATAL: claude installer sha256 不匹配（上游已更新或内容被篡改）。升级走人工变更：换 CLAUDE_INSTALL_SH_SHA256 常量需改码复核" >&2; exit 1; }
sudo -u dev bash /tmp/claude-install.sh >/dev/null 2>&1 \
  || echo "WARN: claude-code 安装失败"
rm -f /tmp/claude-install.sh
# opencode（anomalyco fork，npm 全局 → /usr/local/bin/opencode）
npm install -g @opencode/cli >/dev/null 2>&1 \
  || echo "WARN: opencode 安装失败"
# cc-switch-cli（SaladDay fork，固定 tag + digest，tar 落文件校验后解包 → /usr/local/bin/cc-switch）
curl -4 -fsSL "https://github.com/SaladDay/cc-switch-cli/releases/download/${CC_SWITCH_TAG}/cc-switch-cli-linux-x64.tar.gz" \
  -o /tmp/cc-switch-cli-linux-x64.tar.gz
echo "${CC_SWITCH_TAR_SHA256}  /tmp/cc-switch-cli-linux-x64.tar.gz" | sha256sum -c - \
  || { echo "FATAL: cc-switch tar sha256 不匹配（上游已更新或内容被篡改）。升级走人工变更：换 CC_SWITCH_TAG/CC_SWITCH_TAR_SHA256 常量需改码复核" >&2; exit 1; }
tar -xzf /tmp/cc-switch-cli-linux-x64.tar.gz -C /usr/local/bin cc-switch
chmod 755 /usr/local/bin/cc-switch
rm -f /tmp/cc-switch-cli-linux-x64.tar.gz
# 工具自检（缺失仅告警，不阻断）
sudo -u dev bash -lc 'claude --version' 2>/dev/null | head -1 || echo "WARN: claude 不可用"
opencode --version 2>/dev/null | head -1 || echo "WARN: opencode 不可用"
cc-switch --version 2>/dev/null | head -1 || echo "WARN: cc-switch 不可用"
# （orca 不再进镜像：镜像内无 /usr/local/bin/orca，由控制面按箱注入）
# 开箱件硬校验：podman 缺失即构建失败（新箱验收要求，不允许静默降级）
command -v podman >/dev/null || { echo "FATAL: podman 未安装" >&2; exit 1; }
podman --version

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

# sudo 去重：default_user.sudo 显式 false——首启 cloud-init 不再为 dev
# 写 sudoers 条目，消除「90-cloud-init-users 重复 NOPASSWD → 靠 retire-cloudinit 兜底收敛」
# 的首启重复 sudoers 窗口（原先的 sed 修正方案作用于尚未生成的文件已删，见 d33993d）。
# 免密 sudo 唯一来源=90-railans-dev（上方 provision 显式写入），sudo 模型不变。
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
# 末两条为零凭据闸：镜像内出现 cc-switch.db / orca wrapper 即构建失败；
# 末条为 sudo 模型闸：99-railans.cfg 必须是 sudo:false（首启不留重复 sudoers 窗口）
incus exec "${NAME}" -- bash -c 'id dev >/dev/null && test -f /etc/sudoers.d/90-railans-dev && test -f /etc/cloud/cloud.cfg.d/99-railans.cfg && test -f /etc/ssh/sshd_config.d/99-railans.conf && ufw status | grep -q active && test ! -e /home/dev/.cc-switch/cc-switch.db && test ! -e /usr/local/bin/orca && grep -q "sudo: false" /etc/cloud/cloud.cfg.d/99-railans.cfg'

echo "==> 5b/7 orca CLI 包资产化（不进镜像，落宿主资产目录，由控制面按箱注入）"
# cc-switch.db 与 orca tar 一律不再 push 进模板 VM。
# orca CLI 最小包（宿主 checkout 的 out/cli+shared+persistence+依赖闭包，42MB）
# 打包逻辑保留，产物落宿主资产目录：
#   - 路径取 RAILANS_ASSET_DIR，缺省 /var/lib/railans/assets；
#   - 目录 700 / 文件 640，随附 .sha256 供变更窗口核对；
#   - 控制面经 box_assets.orca_tar 指向该文件按箱注入。
ORCA_CLI_TAR=/tmp/orca-cli.tar.gz
rm -rf /tmp/orca-cli-pack && mkdir -p /tmp/orca-cli-pack/packages /tmp/orca-cli-pack/node_modules/@orca
cp -r "${ORCA_SRC}/out/cli" /tmp/orca-cli-pack/cli
cp -r "${ORCA_SRC}/out/shared" /tmp/orca-cli-pack/shared
cp "${ORCA_SRC}/out/package.json" /tmp/orca-cli-pack/package.json
mkdir -p /tmp/orca-cli-pack/main && cp -r "${ORCA_SRC}/out/main/persistence" /tmp/orca-cli-pack/main/persistence 2>/dev/null || true
cp -rL "${ORCA_SRC}/src/packages/process-host" /tmp/orca-cli-pack/node_modules/@orca/process-host
cp -rL "${ORCA_SRC}/node_modules/zod" /tmp/orca-cli-pack/node_modules/zod
ln -sf /home/dev/mincli/cli/index.js /tmp/orca-cli-pack/orca
tar -czf "$ORCA_CLI_TAR" -C /tmp/orca-cli-pack .
ASSET_DIR="${RAILANS_ASSET_DIR:-/var/lib/railans/assets}"
if ! install -d -m 700 "${ASSET_DIR}" 2>/dev/null; then
  echo "FATAL: orca 资产目录 ${ASSET_DIR} 不可建（orca 资产化落点）。修复：sudo install -d -m 700 \"${ASSET_DIR}\" && sudo chown \"$(id -un)\" \"${ASSET_DIR}\"（首次建目录需 sudo）" >&2
  exit 1
fi
if [[ ! -w "${ASSET_DIR}" ]]; then
  echo "FATAL: orca 资产目录 ${ASSET_DIR} 不可写。修复：sudo chown \"$(id -un)\" \"${ASSET_DIR}\"" >&2
  exit 1
fi
install -m 640 "${ORCA_CLI_TAR}" "${ASSET_DIR}/orca-cli.tar.gz"
( cd "${ASSET_DIR}" && sha256sum orca-cli.tar.gz > orca-cli.tar.gz.sha256 )
rm -f "$ORCA_CLI_TAR"
echo "    orca CLI 包已落 ${ASSET_DIR}/orca-cli.tar.gz（含 .sha256）"

echo "==> 6/7 停机并 publish 成 ${IMAGE_ALIAS}"
incus stop "${NAME}" --timeout=60 2>/dev/null || incus stop "${NAME}" --force
incus image delete "${IMAGE_ALIAS}" >/dev/null 2>&1 || true
incus publish "${NAME}" --alias "${IMAGE_ALIAS}" --reuse

echo "==> 7/7 清理构建实例"
incus delete "${NAME}" --force

echo
echo "完成："
incus image list "${IMAGE_ALIAS}"
