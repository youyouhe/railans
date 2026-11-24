# 安全说明

## 1. 信任边界

```text
[客户端] --局域网--> [入口节点 railans/Caddy] --管理网--> [node2/node3] --br-vm--> [VM]
```

- 客户端与入口之间：局域网，明文 TCP + SSH 自身的加密。局域网内可被嗅探到 SSH 密文与流量特征，但看不到内容。
- 入口与 VM 之间：同一台物理机或管理网，纯 TCP 转发，SSH 端到端。
- VM 与外界：NAT，只能出方向。

**入口节点是单点。** 它持有控制面私钥、Caddy 私钥、Incus 管理权限。拿下它等于拿下全部 box。这是本方案的主要风险，必须物理/系统层面保护好。

**控制面进程持 incus-admin 组 = 宿主 root 等价。** railans 通过 `incus` CLI（unix socket 组权限）管理 VM，两种运行形态——systemd unit（`SupplementaryGroups=incus-admin`）与 kit 布局的 ctl.sh/nohup——都以 incus-admin 组成员运行；incus-admin 可操作宿主全部实例、存储与设备，实际权限等价宿主 root。低权改造（专用系统用户、systemd 沙箱）收窄的是文件系统/系统调用攻击面，incus 这一面仍是 root 等价，属设计前提而非缺陷，此处在威胁模型显式声明。

## 2. 认证模型

| 对象 | 凭证 | 说明 |
|---|---|---|
| 控制面用户 | SSH 公钥 | 指纹即身份；`enroll` 邀请码控制谁能成为用户 |
| box | 同一个公钥 | 创建时写入 `/home/dev/.ssh/authorized_keys` |
| 入口 host key | `/var/lib/railans/ssh_host_ed25519_key` | 首次启动生成；**不要**和 box 复用 |
| box host key | VM 自带 | 每台独立；重建即变化 |

### 为什么默认要求 enroll

“任意公钥即账号”在公网是灾难，在局域网也不安全（访客 Wi-Fi、被入侵的开发机）。`enroll_code` 是一次性/可轮换的共享口令，保证只有拿到口令的人能创建 box。

`enroll_code` 应该：

- 至少 32 字符随机（`openssl rand -hex 24`）；
- 不写进 wiki/聊天记录；
- 泄露后立刻轮换（并清理 `state.json` 的 `keys`）。

### config.yaml 里另外两个安全相关键

- `audit_file`：命令级审计 JSONL 落点。**缺省 = state 文件同目录 `audit.jsonl`**（打包布局即 `/var/lib/railans/audit.jsonl`）；显式设为 `"off"` 关闭（testbed 安静模式）。记录 0600，detail 不含任何凭据（enroll 失败只记原因，不记被尝试的 code 本身）。
- `box_assets.cc_switch_db` / `box_assets.orca_tar`：宿主侧按箱注入的资产源（凭据与 orca 包不进镜像，由 `ensureBox` 交付前 `incus file push`）。**两键均缺省空 = 注入关闭**，零配置/testbed 行为不变；配置了但源文件缺失 → 创建箱时 loud fail（`asset_push_failed`），不会悄悄发出没有 keys 的箱。

生产是否落这两键由运维自行决策；示例值与注释见 `node/deploy/config.example.yaml`。

## 3. 隔离强度

### 3.1 有 VM，没有 VLAN

没有 VLAN 时，二层是通的。攻击者如果能给网卡配 `10.10.2.0/24` 的地址，理论上能直连 VM。缓解：

- 交换机端口安全 / 802.1X（如果有）；
- 管理网只允许已知 MAC；
- **不要**把 `br-vm` 桥接到物理网卡；
- 定期审计 ARP 表。

如果这些做不到，接受“同局域网内网段可被伪造”的残余风险。

### 3.2 VM 到管理网

模板 `node/deploy/nftables-railans.nft` 用三个占位符表达网卡与网段，由 `railans-node.sh network` 用本机真实值渲染到 `/etc/nftables.d/railans.nft` 后加载（早期版本按固定网段写死，管理网段迁移后会静默失效；现改为占位符渲染）：

- `__WAN__` ← 物理上联网卡（`WAN`，缺省取默认路由网卡）；
- `__MGMT__` ← 管理网 CIDR，由 `NODE_ADDR` 推导所在 /24（示例 `192.168.1.0/24`；推导失败 loud fail，绝不渲染半成品规则集）；
- `__GWMESH__` ← 本节点网格网关（`SUBNET` 的 `.1`，如 `10.10.1.1`）。

两侧防线（渲染后形态）：

```nft
# forward 链：VM 不能扫描管理网（本机管理网段 + 旧规划段 10/8 兜底并存，网段再迁移不静默失效）
iifname "br-vm" ip daddr 192.168.1.0/24 drop
iifname "br-vm" ip daddr 10.0.0.0/8 drop

# input 链（末条）：同节点箱连宿主机自身服务（incus / caddy admin 等）也不允许
iifname "br-vm" drop
```

input 链在 `br-vm drop` 之前有白名单（按序）：`ct state established,related accept`（宿主主动连 VM 的回包）；本地箱→门面 `tcp dport 4092`；跨节点箱源（`iif __WAN__ ip saddr 10.10.0.0/16`，LAN 方向无 SNAT 故源保持 10.10.x——豁免形态以实际运行态实测为准）只放行数据面端口池 `22000-22999` 与门面 `4092`，其余一律 drop。节点互访（集群 8443、跨节点 ssh、路由服务）源是节点管理网 IP，不命中箱源限面。

注意顺序：`10.0.0.0/8` 包含 `10.10.0.0/16`，forward 里 `accept 10.10.0.0/16` 两条先于 drop 规则。防火墙变更窗口用 `railans-node.sh verify-nft` 复验（运行态与持久化一致性、规则序断言、箱内探针比对），用法见 `docs/runbook.md` §1.1。

### 3.3 VM 到 VM

默认允许 `10.10.0.0/16` 互通。这是有意的（方便联调），代价是一台 box 被拿下可以横向扫描其他 box。要更严格：

```nft
iifname "br-vm" ip daddr 10.10.0.0/16 drop
```

然后只放行需要的端口。多数场景不需要做到这一步。

### 3.4 容器 vs VM

Incus 容器共享内核；`--vm` 才是真隔离。本方案的 `dev` profile 固定带 `--vm`，创建路径里也硬编码了 `--vm`。不要为了“快”改成容器。

## 4. 控制面攻击面

`railans` 只暴露 22/tcp，且只接受公钥。攻击面：

- `golang.org/x/crypto/ssh` 的解析器（保持依赖更新）；
- 命令解析（`parseArgs` 只做前缀匹配，无 shell）；
- `incus` 调用（参数来自服务端分配，不来自用户输入）；
- `state.json` 读写（路径固定）。

用户可控输入只有：命令名、box 名（用于查表）、enroll code。没有拼接进 shell，也没有拼接进文件路径。

## 5. 数据面攻击面

`proxy` 是纯 `io.Copy`，不解析协议。风险：

- 端口池耗尽 → 拒绝服务（返回明确错误）；
- 连接数打满 fd（`LimitNOFILE=65535`，`ulimit` 可调）；
- 慢连接占端口（每端口单 listener，多连接并发，不阻塞）。

没有 TLS 终止、没有认证代理，因此不存在“代理层凭证泄露”。

## 6. 预览面

- 默认 `remote_ip <创建者 IP>` 限制，防止局域网其他人直接访问未公开的服务。
- `share` 后公开，此时任何能访问入口的人都能打开 —— 提醒用户不要在预览里放密钥。
- Caddy 用内部 CA，证书不被公网信任；这是特性，不是缺陷。
- 不要让 VM 监听 `0.0.0.0:2019`（Caddy admin）或 `:2375`（docker）之类敏感端口并暴露到 8080。

## 7. 密钥管理

```text
/var/lib/railans/ssh_host_ed25519_key   0600 root
/var/lib/railans/state.json             0600 root
/etc/railans/config.yaml                0640 root:railans（M4：属组 railans 可读）
/var/lib/railans/audit.jsonl            0600（审计缺省落点；audit_file "off" 可关）
/var/lib/railans/assets/                0700（orca-cli.tar.gz + .sha256，文件 0640）
```

- `/var/lib/railans/assets` 是资产化落点：构建脚本把 orca CLI 包（随附 `.sha256` 供核对）落盘于此，控制面经 `box_assets.orca_tar` 按箱注入。路径取环境变量 `RAILANS_ASSET_DIR`，缺省 `/var/lib/railans/assets`；目录不可建/不可写时构建 loud fail。
- 控制面 host key 首次启动自动生成；建议备份后离线保存，避免重装后客户端 `known_hosts` 冲突（或者干脆接受冲突，重新 `ssh-keygen -R`）。
- 入口节点的系统 OpenSSH 被挪到 `2200`，因为控制面占用了 `:22`。这个端口只对管理网开放：
  在入口节点上确认 `nft list chain inet railans input` 之外，最好再加一条只允许管理网访问
  `2200` 的规则。若不想动系统 sshd，把 `config.yaml` 的 `listen` 改成 `":2222"`。
- **不要**把宿主机的 `/etc/ssh/ssh_host_*` 复制给 box。
- **不要**在镜像里烘焙个人 token / SSH key / `.npmrc`。

## 8. 已知限制

| 限制 | 影响 | 缓解 |
|---|---|---|
| 入口单点 | 入口挂了全挂 | keepalived + 状态共享（未实现） |
| 无用户隔离配额 | 一个用户能占满集群 | `max_boxes_per_key` / `max_creates_per_ip_per_day`；healthcheck 权限断言：enroll code/config 超宽即 FAIL，防本机任意账号读码 self-enroll |
| 审计：audit.jsonl 已落地（rm/stop/start/share/snapshot/enroll 类命令级，JSONL 0600） | 出事后可按「谁何时对谁」追溯；轮转无内建 | 自行配 logrotate；写失败仅 WARN 不阻断；`audit_file: "off"` 可关 |
| 网关→VM 段不验 host key | br-vm 上 ARP 欺骗可把会话桥到伪 VM | br-vm 为宿主私有网桥（内网基础设施信任模型）；TOFU 已评估未排期 |
| 状态文件非事务 | 极端并发可能丢更新 | 控制面单进程 + 互斥锁；迁移数据库 |
| 无带宽限制 | 一台 box 能打满上行 | tc / Incus `limits.network` |
| 无镜像签名校验 | 上游镜像被投毒 | 安装器/release digest pin + refresh 对 simplestreams 索引 sha256 闸 + apply 人工闸（2026-11-24 落地）；内网镜像仓未建 |

