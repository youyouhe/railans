# 运维手册

## 0. 部署顺序（照抄）

```bash
# 三台都做
sudo ./node/railans-node.sh preflight
sudo ./node/railans-node.sh install-incus

# node1
sudo NODE_NAME=node1 NODE_ADDR=192.168.1.11 DRIVER=lvm SIZE=100GiB \
  ./node/railans-node.sh bootstrap node2 node3
# 把两条 token 分别拿到 node2/node3 执行
sudo ./node/railans-node.sh join     # 交互式：Join existing cluster

# 三台都做（IP/网段按自己环境改）
sudo NODE_ADDR=192.168.1.11 SUBNET=10.10.1.0/24 WAN=eno1 \
  ROUTES="10.10.2.0/24 via 192.168.1.12;10.10.3.0/24 via 192.168.1.13" \
  ./node/railans-node.sh network

# node1（镜像构建：唯一入口是 scripts/build-base-image-local.sh；image 子命令已弃用。
#        缺省 NODE=node1、BASE_IP=10.10.1.250，普通用户跑——需 incus-admin 组）
./scripts/build-base-image-local.sh
sudo ./node/railans-node.sh control
sudo ENTRY_IP=192.168.1.11 ./node/railans-node.sh caddy
```

`railans-node.sh network` 会在 node2/node3 上生成各自的路由；`ROUTES` 一定要写全另外两个网段。

## 1. 日常检查

```bash
sudo ./node/railans-node.sh healthcheck        # 逐项 PASS/FAIL；任何 FAIL 退出码非 0
sudo ./node/railans-node.sh healthcheck --all  # 从本机 ssh 各成员汇总（只读）
incus cluster list                 # 3 个节点都 Online
incus list --columns n,s,t,4       # box 列表
systemctl status railans caddy dnsmasq
journalctl -u railans -n 100 --no-pager
ss -lntp | grep -E ':(22|2200[0-9]|443|53)\b'
cat /var/lib/railans/state.json | jq '.boxes | length'
```

`healthcheck` 不只看 `/dev/kvm`：它读 `incus query /1.0` 的 driver 是否含 `qemu`，
因为 KVM 在、QEMU 特性探测失败的节点会让 `new` 报 `virtual-machine not supported`。

### 1.1 防火墙变更复验（verify-nft）

改 nft 模板 / 重渲染 / 换网段的前后，每节点各跑一轮。节点本机自足、零 ssh 依赖，只读命令不改任何状态；输出对齐 healthcheck 的 PASS/WARN/FAIL 风格，FAIL 退出码非 0：

```bash
sudo env NODE_ADDR=<本机管理IP> SUBNET=10.10.N.0/24 WAN=<网卡> \
  ./node/railans-node.sh verify-nft                     # 断言+探针（平时自查）
sudo ... verify-nft --baseline /tmp/nft-baseline-nodeN.json             # 变更前采集
sudo ... verify-nft --verify --baseline /tmp/nft-baseline-nodeN.json   # 变更后比对
sudo ... verify-nft --print-box-probes                     # 箱内探针清单（免 root，箱内粘贴执行）
```

三形态：

- **`--baseline`**：变更前把运行态 `nft list ruleset` 全量 dump 落 JSON（base64 内嵌，零 jq/python 依赖）；
- **`--verify`**：变更后比对——运行态与持久化渲染文件逐链一致性（有模板外手工规则即 FAIL）、静态断言（established accept、门面 4092 在 `br-vm drop` 之前、箱源允许面两条+限面一条、forward 管理网 drop、渲染产物无 `__` 占位符残留）、箱内探针 JSON 比对（放行面「改前通→改后断」的非预期项 = FAIL、阻断面改后仍通 = FAIL）；
- **`--print-box-probes`**：生成箱内阻断面/放行面探针清单；箱内执行后按清单文末说明把结果回填 `<baseline>.probes.json`（变更前）/`<baseline>.probes.after.json`（变更后），再跑 `--verify` 完成比对。

FAIL 附回滚指引：恢复变更前保留的旧渲染文件 + `systemctl restart railans-nftables`（节点级秒级回滚）。另有一项专项核查：postrouting 若运行态存在「LAN 方向不 masquerade」豁免而模板没有，verify-nft 会提示固化进模板——防止下次重渲染把运行态豁免静默抹掉。

## 2. 常见故障

### 2.1 `ssh new.box.lan` 卡住 / 超时

```bash
getent hosts new.box.lan          # 是否解析到入口 IP
nc -vz new.box.lan 22             # 22 是否通
systemctl status railans          # 服务是否在
journalctl -u railans -n 50       # 看是否 panic / 配置错
```

如果连管理 SSH 也进不去：入口节点的 OpenSSH 被挪到了 `2200`（见 `control` 子命令），
用 `ssh -p 2200 root@192.168.1.11`，或从 node2/node3 跳。

### 2.2 `new` 报 `incus launch ...` 失败

```bash
incus list
incus info box-xxxxxx --show-log | tail -50
incus storage list                # 池是否满
df -h /var/lib/incus
```

池满时先删无用 box：`ssh new.box.lan ls`，再 `rm`。

### 2.3 VM 起来了但 SSH 连不上

```bash
# 在 VM 所在节点
incus exec box-xxxxxx -- systemctl status ssh
incus exec box-xxxxxx -- ss -lntp
incus list box-xxxxxx --columns n,4       # 确认 IP 与 state 一致
```

如果 VM IP 变了（cloud-init 没生效），`ssh new.box.lan stop <box>` 再 `start <box>`，控制面会重新查 IP。

### 2.4 端口转发建立了但立刻断开

```bash
# 从入口节点直接测
nc -vz 10.10.2.10 22
# 不通则查跨节点路由
ip route get 10.10.2.10
# 查 nftables 是否误 drop
nft list table inet railans
```

### 2.5 `https://box-xxxxxx.box.lan` 403

默认只有创建者 IP 能访问（防顺手牵羊）。要公开：

```bash
ssh new.box.lan share box-xxxxxx
```

### 2.6 证书不受信任

Caddy 用内部 CA。把入口节点上的

```text
/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
```

装进客户端信任库（见 `caddy` 子命令输出）。这是**预期行为**，不要改成 `tls internal` 之外的公网证书。

### 2.7 `known_hosts` 冲突

VM 重建后 host key 变化：

```bash
ssh-keygen -R '[new.box.lan]:22013'
```

### 2.8 存储池满了

```bash
incus storage list                 # 看 USED / TOTAL
incus storage info default
```

- `lvm` / `zfs` 且用 loop 文件：直接扩容，Incus 会自己长文件

  ```bash
  incus storage set default size=150GiB
  ```

- 用独立空盘（`DEVICE=/dev/sdb`）：要先扩分区/PV，再 `incus storage set default size=...`
- `dir`：只能扩底层文件系统（`lvextend` / 云盘扩容），Incus 不管
- 实在不够：`ssh new.box.lan ls` 找出无用 box，`rm` 掉；或加节点（见 §5）

## 3. 备份

需要备份的只有两样：

```bash
# 1) 控制面状态
cp /var/lib/railans/state.json /backup/state-$(date +%F).json

# 2) 镜像（dev-base）
incus image export dev-base /backup/dev-base-$(date +%F)
```

box 本身的磁盘在 Incus 存储池里；要保留就给单台做快照：

```bash
ssh new.box.lan snapshot box-xxxxxx
incus snapshot list box-xxxxxx
```

## 4. 升级

```bash
# 控制面
cd railans-kit && make build-linux
sudo install -m755 bin/railans-linux-amd64 /usr/local/bin/railans
sudo systemctl restart railans

# 镜像升级（新建 box 才用新镜像）：重跑构建脚本产出新 dev-base
./scripts/build-base-image-local.sh
# 验证没问题后做别名切换（旧 box 用自己的磁盘，不受影响）
incus image alias rename dev-base dev-base-old
incus image alias create dev-base <new-fingerprint>
```

旧 box 不受影响，它们用的是自己的磁盘。

### 4.1 控制面迁移到 systemd（ctl.sh nohup → railans.service，2026-11-24）

- **unit 形态**（`node/deploy/railans.service`，打包布局 `railans-node.sh control` 直接装）：专用系统用户 `railans`（ SupplementaryGroups=incus-admin）+ `CAP_NET_BIND_SERVICE`（非特权绑 ：22）+ `ProtectSystem=strict`（写面仅 `/var/lib/railans` 与 `/etc/caddy/conf.d`）+ `ProtectHome=read-only` + `NoNewPrivileges` 等沙箱；`Restart=always` 崩溃自起，日志进 journald。caddy reload 不走 sudo（NoNewPrivileges 禁 setuid），由 polkit drop-in（仅授权 railans 用户管 caddy.service）放行。
- **前置步**（`control` 子命令第 4 步，幂等）：建 railans 用户并入 incus-admin 组、`/var/lib/railans` 0700 属 railans、config 属组 railans 保 0640、`/etc/caddy/conf.d` 属组 g+w、写 polkit drop-in、装 unit enable。
- **ctl.sh 降级共存**：unit 不可用时回退 ctl.sh（nohup+pidfile）仍可行；双跑防护由构造保证——state 文件 flock 进程级排他，第二实例 loud fail，不会分脑。回退顺序：`systemctl disable --now railans` + ctl.sh start。
- **迁移窗口约束**：先 `ls --json` 确认无 creating 箱；公告挂起——切换瞬间 wait 连接会断（客户端重试即可）；切完起一只箱做全链路验证（incus 调用 / caddy reload / :22 绑定 / 审计落盘）。

## 5. 扩容

增加 node4：

1. 目标机跑 `preflight`、`install-incus`、`join`、`network`（`NODE_ADDR=192.168.1.14 SUBNET=10.10.4.0/24`）；
   或者从控制机一条命令 `deploy-remote`（见本节末）
2. 在 node1/2/3 的 `ROUTES` 里加上 `10.10.4.0/24 via 192.168.1.14`，重跑 `network`
3. 在 `config.yaml` 里加 node4，`systemctl restart railans`
4. （可选）`incus image copy dev-base local: --target node4 --alias dev-base`

从控制机上架新节点（缺省干跑：只打印目标、变量和将执行的命令；加 `--yes` 才真的
rsync + ssh 执行）：

```bash
./node/railans-node.sh deploy-remote ops@192.168.1.14 \
  NODE_NAME=node4 NODE_ADDR=192.168.1.14 SUBNET=10.10.4.0/24 \
  ROUTES="10.10.1.0/24 via 192.168.1.11;10.10.2.0/24 via 192.168.1.12;10.10.3.0/24 via 192.168.1.13"
```

它只做「送 kit + 远端 `deploy`」，第 2–3 步（其他节点的 `ROUTES`、控制面 `config.yaml`）
仍要自己做。目标机该用户需要免密 sudo。

### 5.1 add-node 一条命令（2026-11-24）

把上面第 1–4 步（送 kit 上架 → 集群 join → 镜像分发 → config 接线 → 路由补全 → 验收）
合成一条命令，在控制机上执行（缺省干跑只打印计划，`--yes` 才执行）：

```bash
./node/railans-node.sh add-node ops@192.168.1.15 node5 10.10.5.0/24           # 干跑看计划
./node/railans-node.sh add-node ops@192.168.1.15 node5 10.10.5.0/24 --yes     # 真执行
```

八步编排（每步幂等、失败停住并打印断点与 `--from-step <N> --yes` 续跑命令）：
预检（ssh/免密 sudo/KVM/磁盘）→ deploy-remote 上架（ROUTES 自动推导，别手写）→
集群入伙（token + join preseed，字段名 `cluster_token`/`server_address`/`cluster_address`）→
镜像分发（`incus image copy dev-base local: --target <name>`）→ 控制面 config 安全追加
（备份+校验+原子替换+重启）→ 老节点路由补全（各老节点 ROUTES 追加新成员后重跑 network）→
验收（healthcheck --all + 验收箱落新节点 + 数据面 keyscan 抽测 + rm 验收箱）→ 汇总。

选项：

- `--addr <管理IP>`：缺省取 host 的 IPv4 字面量；hostname 场景执行期按「集群对端路由 src」
  推导（踩坑教训：hysteria 分流下默认路由可能走隧道，禁用默认路由推导）
- `--pool-dir <路径>`：新节点 dir 池路径（缺省 `/var/lib/incus/storage-pools/default`）
- `--max-boxes N`：仅记为建议值——控制面 per-node 配额暂无字段，不落 config（汇总里注明）
- `--skip-verify`：跳过验收箱段（healthcheck --all 仍跑）
- `--from-step N`：断点续跑（1–8；各步幂等，前序步骤自动跳过）

物理前提（脚本只探测报缺，不自动化补齐）：目标机有能从控制机免密 ssh 登录的账号
（公钥已入 authorized_keys）+ 免密 sudo + BIOS 开 VT-x/AMD-V。老 Intel（物理地址 ≤36 位）
在 bootstrap 前需 profile 配 `limits.memory.hotplug=4GiB`（add-node 预检只提示不自动判定；
AMD 不受影响）。镜像须已在本机（`scripts/build-base-image-local.sh` 构建后
`incus image copy` 由第 4 步代劳）。hysteria 分流节点在配置变更后复验 `ip route get 10.10.x.x`。

## 6. 安全事件响应

| 事件 | 动作 |
|---|---|
| 公钥泄露 | `incus delete box-xxxxxx --force`；从 `state.json` 删除该 key；轮换 enroll_code |
| box 在扫内网 | `incus stop box-xxxxxx --force`；检查 `nft list table inet railans` 是否被改 |
| enroll_code 泄露 | **先 chmod 后轮换**：先把 `.local-test/`（或 `/etc/railans`）与 `config.yaml` 权限收紧到 `healthcheck` 权限断言全绿，再改 `config.yaml` 的 `enroll_code`、`systemctl restart railans`、清理 `state.json` 里的 `keys`——顺序反了新 code 会立即又被本机账号读到 |
| 宿主机被拿下 | 所有 box 不可信；重建集群，轮换所有 host key 与公钥 |

### 6.1 命令级审计（audit.jsonl，2026-11-24）

破坏性/敏感命令（rm / stop / start / share / snapshot / enroll / enroll_key）逐条落 JSONL 审计，一行一事件：`{"ts","op","box","fp","ip","ok","detail"}`（fp=操作者公钥指纹，ip=来源）。缺省落 state 同目录 `audit.jsonl`（0600；打包布局即 `/var/lib/railans/audit.jsonl`），`audit_file: "off"` 可关；写失败仅进程日志 WARN 不阻断命令。排查事件：

```bash
tail -20 /var/lib/railans/audit.jsonl | jq .   # kit 布局在 .local-test/audit.jsonl
```

脚本无内建轮转（文件被删/改名后下一次写自动重建）；生产可自行配 logrotate。detail 不含任何凭据（enroll 失败只记原因，不记被尝试的 code 本身）。

## 7. Roadmap（按优先级）

1. **状态迁移到 SQLite/Postgres**：多入口 HA 的前置条件。
2. **快照恢复 / fork**：`incus copy` + `incus restore`，对“复现 bug”很有用。
3. **按节点预置镜像**：避免 `--target node2` 时跨节点拉 20G 镜像。
4. **审计日志**：谁在什么时候创建/删除/连了哪台。
5. **配额细化**：CPU/内存总量而不是台数。
6. **Web 控制台**：`Store` 已经解耦，加 HTTP 很快。

