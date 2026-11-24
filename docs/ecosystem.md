# LXC 家族生态科普

> 2026-11-10 · 面向后来接手的人：理解"为什么是 Incus、为什么是 Zabbly、8443 上跑的是什么"。

## 族谱

```
2008 ── LXC ──────── 容器技术祖父（内核 namespace/cgroup 原语 + C 工具集）
   │        │
   │        └── 2014：Docker 出生时构建在 LXC 之上，后转 libcontainer/runc 自立门户
   │
2014 ── LXD ──────── Canonical 给 LXC 套的现代管理层（REST API/镜像/集群）
   │        │
2023 ── Incus ────── LXD 的社区分叉（我们运行的就是它，当前 7.6）
   │     ├── lxcfs ── 让容器"看到正确世界"的 FUSE 文件系统
   │     └── incus-os ─ 2025：把整台裸机变成 Incus 专用设备的操作系统
```

## 1. LXC（lxc/lxc）—— 祖父

2008 年诞生（IBM/Canonical 系工程师），用 Linux 内核的 namespace + cgroup 手工造容器的第一代工具：`lxc-create/lxc-start` C 命令行。定义了"**系统容器**"形态——容器里跑完整 init/服务，像轻量小机器（区别于 Docker 的单应用容器）。今天仍是低层 C 库（liblxc）+ 工具集；**Incus 的容器后端经 Go 绑定（go-lxc）调 liblxc**；虚机后端则是 QEMU/KVM。

历史地位：Docker 0.x 时代的执行引擎就是 LXC，2014 年 Docker 换 libcontainer（后来的 runc/OCI）自立门户。

## 2. LXCFS（lxc/lxcfs）—— 让容器"看到正确的世界"

C 写的 FUSE 文件系统，解决一个小而疼的问题：容器里的 `free`/`top`/`uptime` 默认读**宿主的** `/proc`——给容器限了 2G 内存，`free` 显示宿主的 15G。LXCFS 把 `/proc/meminfo`、`cpuinfo`、`uptime`、`loadavg` 按容器逐个虚拟化。

**连接点**：入口节点上 `/opt/incus/bin/lxcfs /var/lib/incus-lxcfs` 常驻（Zabbly 集成）。box 是 VM（独立内核，天然看到正确的自己）所以感知不明显；若用容器形态实例，它是体验质量的关键。

## 3. Incus（lxc/incus）—— LXD 的社区分叉

- 2014 Canonical 发布 **LXD**：LXC 的现代外壳（REST API、镜像管理、集群、存储池抽象），主理人 Stéphane Graber
- 2023 Canonical 把 LXD 收归公司（仓库迁 canonical 组织、引入 CLA、商标归公司）
- **Linux Containers 社区当即分叉出 Incus**，Graber 领队，仓库放回社区自己的 lxc org——所以 lxc 和 incus 同仓库
- API 与 LXD 兼容（大量 LXD 生态工具可直接用）、无 CLA、社区治理、迭代更快
- 包渠道即我们用的 **Zabbly**（Graber 运营，stable 每周构建）；UI 是独立包 `incus-ui-canonical`，挂在 incusd 的 8443 `/ui/`

分工：**容器走 liblxc、虚机走 QEMU/KVM、lxcfs 管容器内 /proc**——"lxc 家族"里只有容器那半边真正姓 lxc。

## 4. Incus OS（lxc/incus-os）—— 专用设备操作系统（2025）

一句话：**装在裸机上的 Incus 家电操作系统**（类比 ESXi 之于 VMware）。

- 整机从 Incus OS 启动：极简不可变系统、ZFS 根、原子 A/B 升级、TPM 安全启动
- 无通用用户空间：不装别的软件、不 ssh 折腾，管理全部通过网络上的 incus 客户端/API/UI
- 解决的痛点：生产 Incus 翻车最常见的是宿主系统自身坏掉/配置漂移——把宿主变成不可变设备即根除

**对本项目**：若某台机器整体奉献给集群（不再干别的），可评估 Incus OS；多用途机器维持 Ubuntu + Zabbly。

## 5. 相邻生态（非 lxc org 但常一起出现）

| 项目 | 作用 | 我们用到吗 |
|---|---|---|
| Zabbly（pkgs.zabbly.com） | Incus 官方推荐的 deb 包渠道（Incus 作者参与运营） | ✅ 唯一安装源（部分环境 snap 商店无 incus） |
| go-lxc | liblxc 的 Go 绑定 | 间接（Incus 容器后端） |
| distrobuilder | 构建 LXC/Incus 镜像的工具 | 否（我们用 cloud 镜像+自 provision） |
| images.linuxcontainers.org | LXC/Incus 社区镜像站 | ✅ noble-cloud-vm 源 |

## 6. 一句话演进史

LXC 证明容器可行 → Docker 在它上面出生后转向单应用容器 → Canonical 把系统容器现代化为 LXD → 公司收编引发社区分叉出 Incus → 家族向两个方向深化：向下的 lxcfs（体验保真）与向外的 incus-os（整机设备化）。
