# railans — 局域网里的“私有 Railway”

把几台物理机变成一个自托管的开发沙箱池：

```bash
ssh <入口> new                        # → 一台 2C/2G 的 Ubuntu VM（Incus 虚机，非容器）
ssh -p 22xxx dev@<入口>               # → 原生 SSH 进 box：scp / sftp / -L 全部可用
https://box-xxxxxx.box.lan            # → box 里 $PORT=8080 的预览地址（Caddy + 内网 CA）
```

没有公网依赖、没有账号系统、没有 VLAN。身份就是 SSH 公钥（指纹即身份，
`enroll` 邀请码准入）。设计取向与取舍见 [docs/architecture.md](docs/architecture.md)。

## 三条最快路径

| 你想做 | 走哪节 |
|---|---|
| 把一台物理机变成集群**节点**（node 侧） | [§2 装一个节点](#2-装一个节点node-侧) |
| 搭**控制端**（入口节点：控制面 + Caddy + DNS） | [§3 搭控制端](#3-搭控制端控制侧) |
| **用箱**（领一台 VM 干活，人或 agent） | [§4 用箱](#4-用箱) |

示例约定（**全部按自己环境替换**）：管理网 `192.168.1.0/24`（入口 node1 = `.11`，
节点 `.11-.14`）、VM mesh 网段 `10.10.0.0/16`（每节点一个 /24）、局域网域名 `box.lan`、
运维账号名 `ops`。

---

## 1. 架构一图

```text
                       局域网 192.168.1.0/24（无 VLAN）
   ssh new.box.lan                    https://box-xxxxxx.box.lan
          │                                    │
          ▼                                    ▼
   ┌────────────────┐                 ┌──────────────────┐
   │ SSH 控制面      │                 │ Caddy + 内网 CA   │
   │ :22 (Go)       │                 │ :443             │
   │ 端口池 22000+   │                 │ 反代 VM:8080      │
   └───────┬────────┘                 └────────┬─────────┘
           │ Incus API / CLI                   │
   ┌───────┴───────────────────────────────────┴─────────┐
   │                Incus cluster（3-4 节点）              │
   │  node1 .11          node2 .12          node3 .13     │
   │  br-vm 10.10.1.1/24 10.10.2.1/24     10.10.3.1/24   │
   │  box 10.10.1.x      box 10.10.2.x     box ...       │
   └──────────────────────────────────────────────────────┘
```

- **VM 在 NAT 后**：局域网不能主动连 box；nftables 阻断 box 访问管理网，只放 mesh 互通与出公网。
- **数据面不终止**：网关在 `22000-22999` 上做纯 TCP 转发到 `VM:22`，SSH 端到端、host key 可校验。
- **预览走 Caddy**：`*.box.lan → 网关`，按 Host 反代 `VM:8080`；未 `share` 前只允许创建者 IP。
- **没有 VLAN**，隔离 = NAT + 端口池 + nftables 三件事，细节见 docs/security.md。

---

## 2. 装一个节点（node 侧）

### 物理前提

| 项 | 要求 |
|---|---|
| 机器 | 物理机（QEMU/KVM 虚拟化，BIOS 开 VT-x/AMD-V），Ubuntu 24.04+ |
| 网络 | 同局域网，可配静态管理 IP；nftables / netplan（Ubuntu 自带） |
| 账号 | 一个运维账号（下称 `ops`）：能 sudo，最好免密（非交互 ssh 无法输 sudo 密码） |
| 磁盘 | 本地盘即可（LVM loop 文件 / 独立空盘 / dir 池，见下） |

### 一条命令上架

在本机（目标节点）没有 kit 时，从控制机用 `deploy-remote` 送过去并上架；
或者先把仓库放到目标机，直接跑 `deploy`：

```bash
# 方式 A：在目标节点上直接执行（kit 已在本机）
sudo env NODE_NAME=node2 NODE_ADDR=192.168.1.12 SUBNET=10.10.2.0/24 \
  ROUTES="10.10.1.0/24 via 192.168.1.11;10.10.3.0/24 via 192.168.1.13" \
  ./node/railans-node.sh deploy

# 方式 B：从控制机一条命令（缺省干跑打印计划，--yes 才执行）
./node/railans-node.sh deploy-remote ops@192.168.1.12 \
  NODE_NAME=node2 NODE_ADDR=192.168.1.12 SUBNET=10.10.2.0/24 \
  ROUTES="10.10.1.0/24 via 192.168.1.11;10.10.3.0/24 via 192.168.1.13" --yes
```

### `deploy` 环境变量

| 变量 | 必填 | 说明 |
|---|---|---|
| `NODE_NAME` | ✅ | 节点名，如 `node2` |
| `NODE_ADDR` | ✅ | 本机管理网 IP，如 `192.168.1.12` |
| `SUBNET` | ✅ | 本机 VM 网段，如 `10.10.2.0/24`（网关默认取 `.1`） |
| `ROUTES` | — | 到其他节点 VM 网段的路由，分号分隔：`10.10.1.0/24 via 192.168.1.11;…`（单节点可省） |
| `WAN` | — | 物理上联网卡名（缺省取默认路由网卡） |
| `GATEWAY` | — | VM 网段网关（缺省 `SUBNET` 的 `.1`） |
| `BRIDGE` | — | 网桥名（缺省 `br-vm`） |
| `KIT_SRC` | — | 本机没有 `/tmp/railans-kit` 时的拉取源（scp 形态 `ops@node1:~/railans-kit`） |

`deploy` 做的事：装 Incus（Zabbly apt 源）→ incus 用户入 kvm 组 → 运维账号入
incus-admin → rootless podman subuid/subgid（可选）→ 渲染并加载 br-vm 网桥 +
nftables 隔离规则 + 跨节点路由。之后 `join` 入集群由入口节点侧驱动（见 §3，
或一条命令 `add-node`，见 [docs/runbook.md](docs/runbook.md) §5.1）。

### 上架后自检

```bash
sudo ./node/railans-node.sh healthcheck        # 本机逐项 PASS/WARN/FAIL，FAIL 退出非 0
sudo ./node/railans-node.sh healthcheck --all  # 从入口节点 ssh 各成员汇总（只读）
```

healthcheck 会查 Incus 的 VM 能力（`incus query /1.0` 的 driver 必须含 `qemu`），
只确认 `/dev/kvm` 存在不够。磁盘剩余 <15% WARN、<5% FAIL。

---

## 3. 搭控制端（控制侧）

> 目录划分：**node 侧 = `node/`**（`railans-node.sh` + `deploy/` 资产）；
> **控制端 = `control/`（Go 控制面）+ `mcp/` + `client/` + `scripts/`**。

完整顺序如下（逐命令详解与排错见 [docs/runbook.md](docs/runbook.md) §0）：

```bash
# 0) 三台都做：预检 + 装 Incus
sudo ./node/railans-node.sh preflight
sudo ./node/railans-node.sh install-incus

# 1) node1 初始化集群（打印 node2/node3 的 join token）
sudo NODE_NAME=node1 NODE_ADDR=192.168.1.11 DRIVER=lvm SIZE=100GiB \
  ./node/railans-node.sh bootstrap node2 node3
# node2/node3 分别执行（交互式：Join existing cluster → 粘贴 token）
sudo ./node/railans-node.sh join
incus cluster list     # 三台都 Online 再继续

# 2) 三台都配 VM 网络（ROUTES 写全另外两个网段）
sudo NODE_ADDR=192.168.1.11 SUBNET=10.10.1.0/24 WAN=eno1 \
  ROUTES="10.10.2.0/24 via 192.168.1.12;10.10.3.0/24 via 192.168.1.13" \
  ./node/railans-node.sh network

# 3) node1 构建基础镜像 dev-base（控制端脚本；普通用户跑，需 incus-admin 组）
./scripts/build-base-image-local.sh

# 4) node1 安装控制面（自动编译 control/ 或用预编译二进制；
#    生成随机 enroll_code 并打印；系统 sshd 若占 22 会被挪到 2200）
sudo ./node/railans-node.sh control
sudo vi /etc/railans/config.yaml      # 核对 IP/网段/预览域名，示例见 node/deploy/config.example.yaml
sudo systemctl restart railans

# 5) node1 安装 Caddy + dnsmasq
sudo ENTRY_IP=192.168.1.11 ./node/railans-node.sh caddy

# 6) 发身份：拿到 enroll_code 的人自助准入（§4 用箱的第一步）
```

要点：

- **存储不要求 ZFS**：`DRIVER=lvm`（默认，ext4 上建 loop 文件当 PV，支持快照）、
  `zfs`（性能更好）、`dir`（零准备，无快照）。有独立空盘加 `DEVICE=/dev/sdX`。
- 控制面监听 `:22` 时系统 OpenSSH 自动挪到 `2200`（管理 SSH 走 `-p 2200`）；
  不想动系统 sshd 就把 config 的 `listen` 改 `":2229"`。
- 客户端 DNS：把 `new.box.lan` / `*.box.lan` 指向入口 IP
  （模板见 `node/deploy/dnsmasq-railans.conf`）。

---

## 4. 用箱

### 裸 SSH 两跳

```bash
ssh new.box.lan enroll <enroll_code> my-laptop   # 第一跳：公钥准入（一次性）
ssh new.box.lan new                              # 第二跳：创建并返回连接信息
# → box:     box-7f3a2b (running on node2)
#   ssh:     ssh -p 22013 dev@new.box.lan
#   preview: https://box-7f3a2b.box.lan
```

### 或者用客户端封装（一条命令）

```bash
install -m755 client/newbox.sh /usr/local/bin/newbox
newbox                # 创建（或复用自己的 box）并直接进入
newbox ls             # 列出自己的 box
newbox stop|start|rm|snapshot|share box-7f3a2b
```

### 常用命令（控制面 SSH 命令，`= newbox 子命令`）

| 命令 | 作用 |
|---|---|
| `new` | 创建 / 复用自己的 box（同 key 幂等） |
| `ls` / `info <box>` | 列表 / 单台详情 |
| `stop` / `start <box>` | 停机（磁盘保留）/ 拉起 |
| `rm <box>` | 销毁（磁盘不可恢复） |
| `snapshot <box>` | 存储快照（lvm/zfs 池支持） |
| `share <box>` | 预览解除来源 IP 门禁 |
| `enroll <code> <label>` | 公钥准入 |
| `capacity` | 集群余量（JSON） |
| `wizard` | 分场景操作向导（new/daily/recover/tunnel/cleanup） |

生命周期：空闲 30 分钟自动停机（磁盘保留，重连自动拉起）；TTL 7 天到期销毁；
每 key 默认 1 台、全集群默认 12 台、每 IP 每天限创建 3 次。

### agent / MCP 接入

`mcp/server.mjs` 提供标准 stdio MCP server（create/list/…/remove 共 10 工具），
Claude Code 等 MCP 客户端可直接管理集群；身份仍走 SSH 公钥 + enroll，不引入新认证面。
接入步骤与环境变量见 **[docs/mcp.md](docs/mcp.md)**。

---

## 5. 仓库结构与文档索引

```text
node/                node 侧：railans-node.sh（节点全生命周期单一入口）+ deploy/ 资产
                     （systemd unit / Caddyfile / dnsmasq / nftables 模板 / config 示例）
control/             Go 控制面（SSH 网关 + 端口池转发 + Caddy 配置生成 + TTL/空闲回收）
scripts/             控制端脚本：build-base-image-local.sh（镜像唯一构建入口）、
                     refresh-base-monthly.sh、backup-monthly.sh、tests/（五套静态断言）
client/newbox.sh     客户端一条命令封装
mcp/                 stdio MCP server（控制面 CLI 包装）
docs/                架构 / 运维 / 安全 / MCP / 验收手册
```

| 文档 | 内容 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | 设计取舍、网络与状态模型、扩展点 |
| [docs/runbook.md](docs/runbook.md) | 部署顺序、日常检查、故障表、扩容、安全事件响应 |
| [docs/security.md](docs/security.md) | 威胁模型、隔离强度、密钥管理、已知限制（§8） |
| [docs/mcp.md](docs/mcp.md) | MCP 接入：enroll → 客户端注册 → 排障 |
| [docs/verify-manual.md](docs/verify-manual.md) | 单节点环境亲手验收手册（每步带预期输出） |
| [docs/ecosystem.md](docs/ecosystem.md) | LXC/Incus 家族生态背景科普 |

---

## 6. 安全边界与已知限制

- box 在 NAT 后、控制面默认 enroll 邀请码、每 box 独立 host key、审计 JSONL 落地；
  完整威胁模型见 [docs/security.md](docs/security.md)。
- 已知限制（入口单点、无带宽限制、TOFU 未做等）见
  [docs/security.md §8](docs/security.md#8-已知限制)——先用先知道。

## 7. 测试

```bash
bash scripts/tests/test-build-gate.sh   # 镜像构建闸
bash scripts/tests/test-nft-render.sh   # 防火墙渲染与规则序
bash scripts/tests/test-subid.sh        # rootless podman subid 兼容
bash scripts/tests/test-node-sec.sh     # 节点安全断言
bash scripts/tests/test-add-node.sh     # add-node 八步编排
cd control && go vet ./... && go test ./...
```

五套均为静态断言/垫片测试，仓库根直接跑、零副作用，不碰真机真集群。

## 8. License

[MIT](LICENSE) © 2026 youyouhe
