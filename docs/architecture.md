# 架构

## 1. 为什么是“控制面 + 端口池”，而不是 Railway 的透明入口

Railway 的 `ssh railway.new` 在网关终止 SSH，再向沙箱重新发起一条 SSH。要做得完整，必须在网关里重新实现：

- `session` / `pty-req` / `window-change` / `signal`
- `direct-tcpip`（`-L`、`-R`）
- `subsystem sftp`（`scp` / `sftp` / VS Code Remote）
- 多路复用与流控

任何一项没实现，用户都会遇到“能用但突然不能用”的割裂体验。

本方案把**控制面**和**数据面**分开：

```text
control plane:  ssh new.box.lan  <cmd>          （小、无状态、可重放）
data plane:     ssh -p 22xxx dev@new.box.lan    （纯 TCP，端到端 SSH）
```

数据面就是 `io.Copy` 两个方向。SSH 握手、host key 校验、加密、认证全部发生在客户端和 VM 的 sshd 之间，网关看不到明文，也不需要实现任何 channel 类型。

代价是多一个端口号；用 `client/newbox.sh` 封装掉这个差异。

## 2. 进程与组件

| 组件 | 位置 | 职责 |
|---|---|---|
| `railans`（Go） | 入口节点 | SSH 控制面、端口池转发、Caddy 配置生成、TTL/空闲回收、JSON 状态 |
| Incus | 3 节点集群 | 创建/启动/停止/删除 VM、快照、镜像 |
| Caddy | 入口节点 | `*.box.lan` 反代到 `VM:8080`，内网 CA |
| dnsmasq | 入口节点 | `new.box.lan`、`*.box.lan` 解析 |
| nftables | 每节点 | VM NAT 出网、阻断 VM 访问管理网 |
| systemd-networkd/netplan | 每节点 | `br-vm` 网桥 |

控制面无数据库：`/var/lib/railans/state.json`，写入用临时文件 + rename。适合几十到几百台 box。要上规模再换 Postgres。

## 3. 网络

### 3.1 地址规划

```text
管理网            192.168.1.0/24（示例网段，按自己环境替换）
  node1           192.168.1.11  （入口：SSH 控制面 + Caddy + dnsmasq）
  node2           192.168.1.12
  node3           192.168.1.13
  node4           192.168.1.14

每节点 VM 网段（mesh，不暴露到管理网）
  node1 br-vm     10.10.1.1/24   box: 10.10.1.10-250
  node2 br-vm     10.10.2.1/24   box: 10.10.2.10-250
  node3 br-vm     10.10.3.1/24   box: 10.10.3.10-250
  node4 br-vm     10.10.4.1/24   box: 10.10.4.10-250
```

没有 VLAN 时，隔离靠三件事：

1. **NAT**：VM 只有私有地址，局域网无法主动发起连接。
2. **nftables**（模板三占位符渲染，`__MGMT__` 取本机管理网 /24）：VM 出方向放行 `10.10.0.0/16`（mesh 互通，含跨节点）与公网 masquerade；forward 对管理网（渲染值 `192.168.1.0/24`，另留 `10.0.0.0/8` 规划期兜底）直接 drop；跨节点箱源（源保持 10.10.x）进宿主 input 只放行白名单端口——数据面端口池 `22000-22999` 与门面端口 `4092`，其余 drop；同节点箱→宿主 input 一律 drop（白名单除外）。
3. **端口池**：网关只暴露 `22000-22999` 给 SSH，且每个端口只映射一台 VM 的 22。

### 3.2 数据流

创建：

```text
client --ssh--> railans(:22)
                 |-- incus launch dev-base box-xxx --vm --target nodeN
                 |-- cloud-init 静态 IP 10.10.N.x
                 |-- incus file push authorized_keys
                 |-- listen :22xxx  ->  10.10.N.x:22
                 '-- 写 Caddy: box-xxx.box.lan -> 10.10.N.x:8080
```

连接：

```text
client --tcp :22xxx--> railans(io.Copy) --tcp :22--> 10.10.N.x sshd
```

因为中间只是字节流：

- `known_hosts` 里记的是 `[new.box.lan]:22xxx` 对应 **VM 自己的 host key**；
- VM 重建后 host key 变化，`known_hosts` 会冲突 —— 这是正确行为，删掉旧条目即可；
- `scp -P`、`sftp -P`、`ssh -L`、VS Code Remote SSH、`rsync -e` 全部原生可用。

### 3.3 跨节点路由

入口节点需要访问 node2/node3 的 VM 网段：

```text
node1: 10.10.2.0/24 via 192.168.1.12
       10.10.3.0/24 via 192.168.1.13
node2: 10.10.1.0/24 via 192.168.1.11
       10.10.3.0/24 via 192.168.1.13
node3: 反向同理
```

每条都装进 `railans-routes.service`，开机自动恢复。管理网交换机不需要任何配置 —— 这就是“没有 VLAN”时的替代方案。

### 3.4 存储：不要求 ZFS

每节点一个**本地**存储池，三台互不共享：

| DRIVER | 前提 | 快照 | 说明 |
|---|---|---|---|
| `lvm`（默认） | `lvm2`，根分区 ext4 即可 | 支持 | loop 文件或空盘做 PV，thin pool，VM 磁盘是真块设备 |
| `zfs` | `zfsutils-linux` + 内核模块 | 支持 | 快照/压缩最好，但内核升级后可能要重装模块 |
| `dir` | 无 | 不支持 | 零准备，VM 磁盘是普通文件；`snapshot` 会直接提示不支持 |

ext4 主机用 `DRIVER=lvm` 即可：Incus 会在 `/var/lib/incus/disks/` 建一个 100GiB 的
稀疏文件当 PV，再在上面建 thin pool，性能和快照都够用。有独立空盘就 `DEVICE=/dev/sdX`。

代价：box 的磁盘跟着节点走，节点挂了该节点的 box 只能从快照/备份恢复（控制面记录仍在）。

## 4. 状态模型

```json
{
  "boxes": {
    "box-7f3a2b": {
      "name": "box-7f3a2b",
      "key_fp": "SHA256:...",
      "node": "node2",
      "vm_ip": "10.10.2.10",
      "ssh_port": 22013,
      "state": "running",
      "creator_ip": "192.168.1.55",
      "shared": false,
      "created_at": "...",
      "last_used": "...",
      "expires_at": "..."
    }
  },
  "keys": { "SHA256:...": { "label": "my-laptop" } },
  "creates": { "192.168.1.55": ["..."] },
  "next_port": 22014
}
```

- box 名 = `box-` + `sha256(公钥指纹)[:6]`，稳定、不可枚举（指纹不可猜）。
- 端口、IP 从 state 里已用集合分配，不依赖 Incus 内部状态。
- 重启后 `proxy.Restore()` 按 state 重新监听端口。

## 5. 生命周期

```text
create ──► running ──(30m 无连接)──► stopped ──(再次 new)──► running
              │                         │
              └────(7d TTL)─────────────┴──► deleted（VM + 记录）
```

- `last_used` 在每次 TCP 连接建立时更新（不是每条命令，避免频繁写盘）。
- `stopped` 只停 VM，磁盘保留；`new` 会 `start` + 等 agent + 重新查 IP。
- 到期先删 VM，再删记录；删 VM 失败只记日志，下轮重试（记录仍在）。

## 6. 为什么不用容器

容器共享内核：`/proc`、`sysctl`、内核模块、cgroup、网络命名空间逃逸面都还在。用户要的是“给我一台机器随便折腾”，那就必须是 VM。

Incus `--vm` 的启动成本：首次 ~10-20s（cloud-init + agent），之后从停止状态恢复 ~3-5s。这个量级对“开发沙箱”完全够用。

## 7. 扩展点

| 需求 | 做法 |
|---|---|
| 更多节点 | 改 `config.yaml` 的 `nodes`（或 `add-node` 一条命令），控制面按静态上限+实时余量双闸选节点（见 §8） |
| 高可用 | keepalived 把 `192.168.1.10` VIP 漂到 node1/2，两边都跑 railans（state 需共享或改 Postgres） |
| 模板缓存 | 预建 `dev-base-node2`/`dev-base-node3`，避免跨节点拉镜像 |
| 计量 | 在 `proxy.pipe` 里记录连接时长/字节数 |
| Web 控制台 | 复用 `Store`，加 HTTP handler |
| fork | `incus copy box-a box-a-fork --instance-only` |

## 8. 调度：per-node 静态上限 + 动态余量地板

`new` 选节点（pickNode）按三道闸，按序过滤：

1. **VM 故障冷却**：launch 报「不支持 VM」的节点退避 30 分钟（内存态，重启清零）。
2. **per-node 静态上限**：`nodes[].max_boxes`——该节点可同时存在的箱数
   （全状态计数，含 creating/stopped/deleting，与 CountByNode 同口径）。
   0/缺省 = 不设节点上限，仅全局 `limits.max_boxes` 生效（旧 config 向后兼容）。
3. **动态余量地板**：调度时实时探测。总量经 `incus query --target <node> /1.0/resources`
   （等价 REST `GET /1.0/resources?target=<node>`）；已分配经 `incus list --format json`
   的 location+limits（展开配置，含 profile 合并值）。**STOPPED 实例不占 CPU/内存，不计入分配**。
   地板两条：`mem_available ≥ vm.memory + 1GiB 预留`；`cpu_total - vcpu_allocated ≥ vm.cpus`。
   不满足即跳过并记原因。探测失败/超时（5s）= 该节点余量未知 → 回退仅静态闸并 WARN
   （探测失败不全局拒建）。

全部候选被新闸拒绝时，`no_node_available` 错误并入原因，机器和 agent 都能读：
`no node available (node3: memory floor 2GiB+1GiB reserve not met (avail 2GiB))`。

`capacity` / `wizard create` 同口径：每节点行增 `cap`（静态上限，null=未设）、
`mem_avail_gib`、`vcpu_free`（null=余量未知）、`eligible`——agent 建箱前先问 capacity，
不可落箱节点在 wizard 里点名原因（「CPU 已满，自动改排」语义）。

### 建议值（真实集群画像）

每箱默认 2C/2G（profile dev），**CPU 是稀缺维度**——least-count 摊派会让 2C 小节点过载：

| 节点 | 内存/CPU | 建议 max_boxes |
|---|---|---|
| 107 | 30G/2C | 3 |
| 221 | 7.7G/2C | 2 |
| 239 | 7.7G/2C | 2 |
| 入口 | 15G/2C | 2 |

配了动态地板后，静态上限是**保底**（探测失败时兜底），日常调度以实时余量为准。
`add-node --max-boxes N` 在接线步写入新节点条目的该字段；手工编辑 config 后重启控制面生效。

