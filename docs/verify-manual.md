# railans 亲手验收手册（单节点测试环境）

> 面向：想在入口节点上亲手把整套流程走一遍的人。
> 全程普通用户权限，约 15 分钟。每步都给了**预期输出**——对不上就是问题。
> 生产部署顺序见 docs/runbook.md §0。

## 0. 前置与约定

| 项 | 值 |
|---|---|
| 入口（控制面） | `192.168.1.11:2229`（示例，按实际改；测试环境用 2229，生产环境是 22） |
| 数据面端口池 | 22100-22199 |
| 你的身份 | 一把 SSH 公钥（`~/.ssh/id_ed25519.pub` 或已有 key） |
| enroll code | 控制面 config 的 `security.enroll_code`（在入口节点上 `cat <kit 目录>/.local-test/enroll_code.txt` 亦可） |

约定：下面命令里的 `$CODE` = enroll code 内容；`$H` = 入口 IP（示例 `192.168.1.11`）；
`<user>` = 入口节点上你的登录账号（服务端只认公钥，用户名任意，示例用 `ops`）。
**本手册所有命令可在任意局域网机器上执行**（code 也是从入口节点远程取的）；直接在入口节点上跑亦可。
SSH 基础参数（首次连接会问 host key，答 yes）：

```bash
H=192.168.1.11
CODE=$(ssh <user>@$H cat '<kit 目录>/.local-test/enroll_code.txt')
CT="-i ~/.ssh/id_ed25519 -p 2229 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"
ssh $CT ops@$H "enroll $CODE my-name"     # my-name 换成你的标识
```

**✅ 预期**：`enrolled SHA256:xxxx… (my-name)`。报 `invalid enroll code` 说明 code 不对。

## 1. 创建 box（约 90 秒）

```bash
ssh $CT ops@$H new
```

**✅ 预期**（5 行，记下 box 名和端口）：

```text
box:     box-xxxxxx (running on node1)
ssh:     ssh -p 221xx dev@ctl.test
preview: https://box-xxxxxx.box.lan
expires: （7 天后的时间）
```

超过 3 分钟未返回 = 问题（找维护者看 `journalctl` 或 railans.log）。

## 2. 数据面 SSH 进 box

```bash
PORT=221xx   # 上一步的端口
ssh -i ~/.ssh/id_ed25519 -p $PORT dev@$H 'hostname; sudo -n whoami; getent hosts archive.ubuntu.com | head -1'
```

**✅ 预期**三行依次为：`box-xxxxxx`、`root`（免密 sudo）、一个 IP 地址（VM 能出网）。

> host key 提示：box 的 host key 是 VM 自己的，首次连接答 yes 属正常。

## 3. 起服务 + 预览（属主 200）

```bash
ssh -i ~/.ssh/id_ed25519 -p $PORT dev@$H 'nohup python3 -m http.server 8080 --directory /home/dev >/dev/null 2>&1 & sleep 1; echo started'
BOX=box-xxxxxx
curl -sk --resolve $BOX.box.lan:443:$H https://$BOX.box.lan/ | head -3
```

**✅ 预期**：`started` + 返回一个 HTML 目录页（`<!DOCTYPE HTML>…`），`curl -o /dev/null -w '%{http_code}'` 为 **200**。
浏览器验证：往客户端 hosts 加一行 `<H> $BOX.box.lan`，访问 `https://$BOX.box.lan`（自签证书需信任或继续访问）。

## 4. 非属主 403（需要第二台机器）

在**另一台**局域网机器上：

```bash
curl -sk --resolve $BOX.box.lan:443:$H https://$BOX.box.lan/ -o /dev/null -w '%{http_code}\n'
```

**✅ 预期**：`403`。想放开：`ssh $CT ops@$H "share $BOX"` 后同命令变 **200**（share 也可再收，见 rm 前随意）。

## 5. scp / sftp（端到端验证）

```bash
echo hello > /tmp/t.txt && scp -i ~/.ssh/id_ed25519 -P $PORT /tmp/t.txt dev@$H:/home/dev/
ssh -i ~/.ssh/id_ed25519 -p $PORT dev@$H 'cat /home/dev/t.txt'
```

**✅ 预期**：输出 `hello`。

## 6. stop → start（保盘语义）

```bash
ssh $CT ops@$H stop $BOX          # ✅ 预期: "$BOX stopped (disk kept)"
ssh -i ~/.ssh/id_ed25519 -p $PORT dev@$H hostname   # ✅ 预期: 连接失败(refused)
ssh $CT ops@$H start $BOX         # ✅ 预期: "$BOX started"（约 20-60s）
ssh -i ~/.ssh/id_ed25519 -p $PORT dev@$H hostname   # ✅ 预期: box-xxxxxx
```

## 7. snapshot（dir 池预期拒绝）

```bash
ssh $CT ops@$H snapshot $BOX
```

**✅ 预期**：明确提示 dir 池不支持快照、建议 lvm/zfs。这是**设计行为**（测试池是 dir）。

## 8. 查账与删除

```bash
ssh $CT ops@$H ls       # ✅ 预期: 表格列出你的 box（NAME/NODE/IP/PORT/STATE/EXPIRES）
ssh $CT ops@$H info $BOX
ssh $CT ops@$H rm $BOX  # ✅ 预期: "removed $BOX"
ssh $CT ops@$H ls       # ✅ 预期: "no boxes. run: ssh ctl.test new"
```

## 9. 管理员侧复核（在入口节点上，运维账号）

```bash
KIT=<kit 目录>                        # 按实际改，如 ~/railans-kit
$KIT/.local-test/ctl.sh status       # running + :2229 listening
sg incus-admin -c 'incus list'       # box 对应的 RUNNING/STOPPED 虚机
$KIT/node/railans-node.sh healthcheck   # 逐项 PASS/FAIL；FAIL 即非 0
python3 -I -c "import json;d=json.load(open('$KIT/.local-test/state.json'));print({k:v['state'] for k,v in d['boxes'].items()})"
grep -E "idle stop|reaping|created|removed" "$KIT/.local-test/railans.log" | tail -5
```

## 10. 观察自动回收（可选，慢）

- **空闲停机**：box 建好后放着 30 分钟不连，`incus list` 会变 STOPPED（磁盘保留），下次 `new`/`start` 自动拉起。
- **TTL**：7 天后 reap 自动销毁。不想等可让维护者演示（改 state 的 expires_at）。

## 11. 静态断言测试（仓库根直接跑，零副作用）

五套静态断言脚本，仓库根直接跑、零副作用：

```bash
bash scripts/tests/test-build-gate.sh    # 镜像构建闸：注入段已删 / 零凭据自检闸 / digest pin / refresh 双段化
bash scripts/tests/test-nft-render.sh    # 防火墙：三占位符渲染 / 规则序 / 无占位符残留
bash scripts/tests/test-subid.sh         # rootless podman subuid/subgid 兼容（回归）
bash scripts/tests/test-node-sec.sh      # 节点安全：权限断言 fixture 化 / unit 静态 / control 干跑 / 零凭据闸
bash scripts/tests/test-add-node.sh      # add-node 八步编排断言（全垫片，不碰真机真集群）
```

控制面 Go 单测与回归：`cd control && go vet ./... && go test ./...`。

**手册级真机项本手册不代跑**：真构建零凭据验证与首启无重复 sudoers、四节点 nft 应用与
探针矩阵（用 `verify-nft`，见 runbook §1.1）、入口节点权限收紧 + code 轮换、systemd 迁移
真机、refresh 报告模式真机首跑、mcp enroll-key 端到端——属部署/变更时人工执行，仓库内
静态测试不覆盖。

## 已知差异（测试环境 vs 生产）

| 项 | 测试环境 | 生产 |
|---|---|---|
| 控制面端口 | 2229（系统 sshd 占 22） | 22 |
| DNS | 无局域网 DNS，用 `--resolve` 或 hosts | dnsmasq 通配 `*.box.lan` |
| 证书 | 自签（curl 需 `-k`） | 同为内网 CA（装根证书后无需 -k） |
| snapshot | dir 池不支持 | lvm/zfs 池支持 |

## 出问题找谁

把**步骤编号 + 实际输出**发给维护者；维护者按 docs/runbook.md 的故障表和 railans.log 定位。
