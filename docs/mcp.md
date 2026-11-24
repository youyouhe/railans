# MCP 接入（railans-mcp）

`mcp/server.mjs` 是 railans 控制面 CLI 的 MCP 包装器：stdio 传输，每个工具经
`ssh -p <port> <user>@<host> <cmd>` 调用控制面（下文示例用 `ops`，用户名按实际改——
服务端只认公钥，用户名任意）。**不引入新的认证面**——身份仍然是
SSH 公钥指纹（enroll 准入），MCP server 以运行它的本机用户身份持钥匙。

这与 MCP 规范对本地服务器的立场一致：stdio 传输不用 OAuth，凭据从环境取
（spec 2025-06-18 Authorization："STDIO … SHOULD NOT follow this specification,
and instead retrieve credentials from the environment"）。

## 1. 前置条件

- 网关（控制面）已上线，本机能访问其控制端口（生产默认 `2229`，让位系统 sshd）
- 本机已有 SSH 密钥对，且**该钥匙已 enroll**（见 §2）——未 enroll 时所有工具都会被拒
- Node ≥ 18（实测 v24）；`mcp/` 下 `npm ci` 装依赖（`@modelcontextprotocol/sdk` + `zod`）

## 2. Enroll（一次性身份准入）

### 2.1 自助 enroll（人肉持码，推荐）

```bash
ssh -p 2229 ops@<gateway> enroll <code> <label>
```

- enroll 的是**当前连接的钥匙**（`~ssh/id_*.pub` 的指纹）
- `label` 是身份标签，建议按机器+用途命名（如 `tb350-ops`、`macbook-agent`）
- 验证：`ssh -p 2229 ops@<gateway> capacity` 出 JSON 即成功

### 2.2 enroll-key 代办（已 enroll 身份 + code 双重验证）

```bash
ssh -p 2229 ops@<gateway> enroll-key <publickey-line> <label> <code>
```

给新设备/新 agent 注册**任意公钥**，无需在新设备上人肉操作。
MCP 的 `enroll` 工具（§4）就是这个命令的包装。

### 2.3 code 在哪

`enroll_code` 在控制面 config 的 `security.enroll_code` 字段。

> **坑：配置文件不一定在 `/etc/railans/config.yaml`。**
> 那只是 systemd 单元与二进制的**默认值**；实际部署可能用了仓库工作目录里的
> config（如自己工作目录里的 `~/railans-testbed/config.yaml`）。
> 定位真身：
>
> ```bash
> systemctl cat railans 2>/dev/null | grep ExecStart   # 看 unit 实际写法
> ps -ef | grep [r]ailans                              # 看运行中进程的 -config 参数
> ```

## 3. 注册到 MCP 客户端

以 Claude Code 为例（user 级，所有会话生效）：

```bash
claude mcp add --scope user railans \
  --env RAILANS_HOST=<gateway-ip> \
  -- node <绝对路径>/mcp/server.mjs
```

环境变量（server.mjs 读取）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `RAILANS_HOST` | `127.0.0.1` | 控制面网关地址（**远程接入必配**） |
| `RAILANS_PORT` | `2229` | 控制面 SSH 端口 |
| `RAILANS_USER` | `ops` | 控制面 SSH 用户（服务端只认公钥，用户名任意） |
| `RAILANS_ENROLL_CODE` | 空 | 可选。配置后 `enroll` 工具可用（agent 可代办新钥匙准入）；不配则该工具报"服务端未配置"。按需开启 |

其他 MCP 客户端：任何支持 stdio transport 的都行，等价配置为
`command=node`、`args=[<绝对路径>/server.mjs]`、`env={RAILANS_HOST: ...}`。

## 4. 工具清单（10 个）

| 工具 | 阻塞 | annotations | 说明 |
|---|---|---|---|
| `create` | 最长 360s（首启可能更久） | — | 创建（或复用同 key 已有的）box；**同 key 幂等**；客户端 MCP 超时建议 ≥360s |
| `list` | — | readOnlyHint | 当前身份全部 box（name/node/ip/port/state/expires） |
| `capacity` | — | readOnlyHint | 集群余量与分布、端口池 |
| `info` | — | readOnlyHint | 单台 box 完整记录 |
| `start` | 20–60s | — | 启动已停止的 box |
| `stop` | — | destructiveHint | 停止（磁盘保留） |
| `snapshot` | — | — | 创建存储快照 |
| `share` | — | destructiveHint | 预览解除来源 IP 门禁，URL 可外发 |
| `enroll` | — | destructiveHint | 代办新公钥准入；code 走 `RAILANS_ENROLL_CODE`，不进调用参数 |
| `remove` | — | destructiveHint | **销毁 box，磁盘数据不可恢复**；agent 应先与用户确认 |

## 5. 验证

```bash
# 1) 裸 SSH 链路（MCP 之下那层）
ssh -p 2229 ops@<gateway> capacity

# 2) MCP 进程级
claude mcp list          # railans 应显示 ✔ Connected

# 3) 工具级端到端（模拟 client 的 JSON-RPC 调用）
cd mcp
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0.0.1"}}}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"capacity","arguments":{}}}\n' \
  | RAILANS_HOST=<gateway> node server.mjs
```

注意：**"✔ Connected" 只代表本地进程握手成功**，不代表后端认证通过——
钥匙未 enroll 时一样显示 Connected，一调工具才报错。

## 6. 排障

| 症状 | 原因 | 处置 |
|---|---|---|
| `this key is not enrolled yet.` | 本机钥匙未准入 | §2 enroll |
| `Host key verification failed` | known_hosts 无网关记录 | MCP server 自带 `StrictHostKeyChecking=accept-new`；手动 `ssh -p 2229 ops@<gateway> capacity` 走一遍即可 |
| 工具报 `ssh new 失败` / 超时 | create 阻塞最长 360s，首启可能更久，客户端默认超时太短 | 客户端 MCP timeout 调到 ≥360s |
| `错误：服务端未配置 RAILANS_ENROLL_CODE` | 想用 enroll 工具但 env 没配 | 配置或改走 §2.1 人肉 enroll |
| 找不到 enroll code | 配置文件不在默认路径 | §2.3 的 `ps -ef` 定位法 |
| Connected 但所有工具失败 | 握手 ≠ 后端认证 | §2 enroll 后重试 |

## 7. 安全注意

- 身份 = 公钥指纹；MCP server 持谁的钥匙，agent 行为就记在谁的 label 上。
  给 agent 用专用钥匙 + 专用 label（如 `xxx-agent`），审计可区分人肉与 agent 操作
- `enroll_code` 目前是**长期共享口令，无 TTL**（对照 k8s bootstrap token / Tailscale
  pre-auth key 的差距）。轮换流程见 `docs/runbook.md`「泄露处置」；上公网前建议先加过期机制
- 网关可选 `security.allowed_source_cidr` 收紧来源网段
- MCP 层依赖本机用户隔离：能读你 env / SSH key 的本地进程即能以你身份操作集群，
  这是 stdio MCP 的通用信任模型，不是本实现的缺陷
