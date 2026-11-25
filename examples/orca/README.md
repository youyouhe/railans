# railans box —— orca per-workspace 环境 recipe（示范）

把 [railans](https://github.com/youyouhe/railans) 的一次性箱接进
[orca](https://github.com/stablyai/orca) 的 `environmentRecipes`：每个
workspace 一只专属箱，随 workspace 生灭。orca 与 railans 两侧代码零改动，
接入物只有本目录的 orca.yaml 条目 + 四个生命周期脚本。

| orca 事件 | 本目录脚本 | railans 命令 | 语义 |
|---|---|---|---|
| provision（新建 workspace） | `scripts/create.sh` | `new --json` | 阻塞到箱 ready；已有箱幂等复用，过期箱自动滚新 |
| workspace sleep | `scripts/suspend.sh` | `stop <box>` | 停机保盘，数据面 host:port 不变 |
| workspace 激活 | `scripts/resume.sh` | `start <box>`（失败回退 `new`） | 拉起并重发新鲜结果 JSON |
| workspace 删除 / Settings 清理 | `scripts/destroy.sh` | `rm <box>` + `ls` 复核 | rm 最终一致，脚本复核到箱消失（≤60s） |

orca 侧没有自动 suspend/destroy：箱的停与删由 railans 兜底
（7 天 TTL 到期即删、桌面断开 30 分钟 idle 自动停机保盘）。

## 前置

1. **orca 桌面**：版本支持 `environmentRecipes`，且已打开实验开关
   `experimentalEphemeralVms`（Settings 里默认关闭）。
2. **railans 网关**：控制面地址（主机名 + SSH 端口）网络可达。
   生命周期脚本统一以 `ssh -p $RAILANS_CTL_PORT git@$RAILANS_CTL_HOST`
   的形态调控制面（`new/stop/start/rm/ls`）。
3. **provider 钥匙（需先 enroll）**：生成一对专用 SSH 密钥，公钥在网关上
   enroll 成 provider 身份（一次性人肉步骤，enroll code 不落任何文件）：

   ```
   ssh -p <ops端口> ops@<网关> enroll <一次性code> railans-orca-provider
   ```

   一把 enroll 钥匙同时是**控制面会话钥匙**和**箱内 `dev` 用户钥匙**；
   箱名 = `box-` + 钥匙指纹散列前缀，由钥匙唯一决定。
4. **one key = one box（单工作区约束）**：一把钥匙在集群上只对应一只箱。
   v1 口径 = 一把 provider 钥匙服务一个并发 workspace。若对同一 recipe 开
   第二个 workspace，`create.sh` 会用 repo 本地锁拒绝（避免两个 workspace
   拿到同一只箱导致隔离破防）；跨 repo 同钥匙由控制面幂等复用兜住，同样
   只会拿到同一只箱——不要这么用。
5. **本地工具**：bash、ssh、python3（无 jq 等额外依赖）。

## 环境变量

`RAILANS_*` 由使用者配置（export 到 shell、direnv 或桌面环境，勿写进仓库）：

| 变量 | 必填 | 说明 |
|---|---|---|
| `RAILANS_CTL_HOST` | 是 | railans 控制面主机名，如 `ctl.example.org` |
| `RAILANS_CTL_PORT` | 是 | 控制面 SSH 端口 |
| `RAILANS_PROVIDER_KEY` | 是 | 已 enroll 的 provider **私钥路径**（支持 `~/`；只传路径，密钥材料不进脚本/参数/输出） |
| `RAILANS_PROJECT_ROOT_BASE` | 否 | 箱上项目锚点目录基路径，默认 `/home/dev/orca`；实际 `projectRoot` 会在其下按 workspace 名分段 |
| `RAILANS_STATE_FILE` | 否 | repo 本地锁/状态文件路径，默认 `<repo根>/.railans-orca-state.json`（非密值，建议加进 .gitignore） |
| `RAILANS_CTL_SSH` | 否 | 覆写 ssh 可执行（连接参数不变），仅供测试/代理场景 |

orca runner 自动注入 `ORCA_*` 变量（`ORCA_VM_MODE`、`ORCA_WORKSPACE_ID`、
`ORCA_WORKSPACE_NAME`、`ORCA_REPO_PATH`、`ORCA_RECIPE_RESULT_SCHEMA_VERSION`
等），脚本只读使用，无需手工配置。本 recipe 只支持默认 orca-worktree 检出
（schemaVersion 1）；`ORCA_RECIPE_RESULT_SCHEMA_VERSION=2` 时 create 显式失败。

示例：

```sh
export RAILANS_CTL_HOST=ctl.example.org
export RAILANS_CTL_PORT=2222
export RAILANS_PROVIDER_KEY="$HOME/.ssh/railans-orca-provider"
```

## 安装

1. 把 `orca.yaml` 里的 `environmentRecipes` 条目并入你仓库根的 orca.yaml，
   并把本目录 `scripts/` 拷到仓库根 `scripts/` 下（保持四个脚本）。
2. `chmod +x scripts/{create,suspend,resume,destroy}.sh`（orca doctor 会查执行位）。
3. 配置上表 `RAILANS_*` 环境变量；把 `.railans-orca-state.json` 加进 `.gitignore`。
4. 静态体检（免费门，不动真集群）：

   ```
   orca vm recipe doctor railans-box --repo-path <仓库根> --json
   ```

## 验收

1. **一键试车**：`orca vm recipe doctor railans-box --provision --repo-path <仓库根>`
   ——真跑 create→校验→destroy 全链，结束后 railans 侧 `ls` 应无残留箱。
2. **建 workspace**：orca composer 里「Run on」选 `railans box (ephemeral)`
   提交；railans 侧确认新箱：

   ```
   ssh -p "$RAILANS_CTL_PORT" -i "$RAILANS_PROVIDER_KEY" git@"$RAILANS_CTL_HOST" ls
   ```

3. **终端链路**：在该 workspace 开终端执行命令（orca 自动部署 relay 过数据面）。
4. **挂起/恢复**：sleep 该 workspace → `ls` 里箱转 stopped；激活 → 箱回 running、
   终端重建。
5. **销毁**：删除该 workspace（或 Settings→Ephemeral VMs 清理）→ `ls` 里箱消失
   （≤2 分钟，含 deleting 尾巴）。
6. **TTL/idle 演示**：桌面断开 30+ 分钟后箱自动转 stopped（保盘），激活自动拉起、
   worktree 完好；7 天到期箱被彻底删除，此时激活得到全新空箱。

注意：不要把 recipe 箱手工 `orca host add` 登记成常驻宿主——recipe 路径的宿主
由 orca 随 runtime 生命周期自动注册/注销，两套并存会出现「删了一个还有一个」。

## 生命周期语义与数据安全

- **TTL 7 天是硬删除**，挂起（stopped）也不豁免。到期（或销毁）后激活将得到
  **全新空箱**，箱内数据不保。口径：可重建的工作区适合放箱上；不可重建的
  长跑数据不要放。
- **idle 30 分钟自动停机保盘**：数据面无连接 30 分钟后箱转 stopped；激活时
  resume 自动拉起，数据完好。
- **并发**：一把钥匙一只箱。同 repo 第二个 workspace 会被本地锁拒绝（提示
  先删除已持有的 workspace）；orca 崩溃留下的残留锁，按提示手工删除
  state 文件的 `activeBox` 字段即可。
- **手工清理**：orca Settings→Ephemeral VMs 的「复制手工清理命令」会把
  lifecycle payload 管进 destroy 命令，可直接复用；手工调试时也可
  `echo '<payload JSON>' | scripts/destroy.sh`。

## 安全边界

- 私钥**只以路径**参与：脚本经 `RAILANS_PROVIDER_KEY` 拿路径、结果 JSON 的
  `identityFile` 也是路径引用；任何密钥材料不进脚本、不进参数、不进输出、
  不进 state 文件。enroll code 只在人肉步骤出现，不入任何文件。
- userData / state 文件只含非密编排值（箱名、expires、workspace id 等）。
- 该钥匙能看见、能操作的只有它自己的那一只箱（one key = one box）；
  railans 控制面对每次操作留审计记录。
- 网段/域名示例（`192.168.1.0/24`、`example.org`）仅为文档示意。
