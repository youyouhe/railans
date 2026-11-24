package main

import (
	"fmt"

	gssh "github.com/gliderlabs/ssh"
)

// cmdWizard 向导：把运维知识编码成分步指导，按目标返回带实时状态的行动清单。
// agent 遇到问题先问向导再动手——所有历史踩坑都固化在这里。
func (c *Control) cmdWizard(s gssh.Session, rest []string) {
	goal := "menu"
	if len(rest) > 0 {
		goal = rest[0]
	}
	switch goal {
	case "create":
		boxes := c.store.AllBoxes()
		bvals := make([]Box, 0, len(boxes))
		for _, b := range boxes {
			bvals = append(bvals, *b)
		}
		p := capacityJSON(bvals, c.cfg.Limits.MaxBoxes, c.store.CountByNode(), c.cfg.Nodes, c.cfg.PortRange[0], c.cfg.PortRange[1])
		fmt.Fprintln(s, "向导：创建 box")
		fmt.Fprintf(s, "当前余量: %s\n", string(p))
		fmt.Fprintln(s, "1. ssh -p 2229 ops@"+c.cfg.ControlHost+" new   （阻塞约 90-120 秒，超时设 300s）")
		fmt.Fprintln(s, "2. 完成后返回 JSON：name/port/ip/expires")
		fmt.Fprintln(s, "3. 数据面连接: ssh -p <port> dev@"+c.cfg.ControlHost)
		fmt.Fprintln(s, "4. box 内工具: claude / opencode / cc-switch / orca / tmux（已预装）")
		fmt.Fprintln(s, "注意: 同 key 重复 new 幂等返回已有 box；余量不足会报 cluster box limit")

	case "recover":
		fmt.Fprintln(s, "向导：失联恢复阶梯（按序执行，每步验证后再下一步）")
		fmt.Fprintln(s, "1. ssh -p 2229 ops@"+c.cfg.ControlHost+" ls --json   —— 账本里的 box 状态")
		fmt.Fprintln(s, "2. 对比实际：incus list（须经 incus-admin 组）——账本说 running 而 incus 停止 → 直接重连即可自动拉起")
		fmt.Fprintln(s, "3. ssh 进不了 box（publickey 拒绝）→ 检查家目录: stat /home/dev（须 dev:dev 且无组写）——tar 解包类操作可能污染属主")
		fmt.Fprintln(s, "4. box 内网络失联 → 检查节点上: ip route get 10.10.x.x 与 hysteria 分流（ip rule）")
		fmt.Fprintln(s, "5. 预览不通 → 隧道 ingress: cloudflared 配置里 *.<预览域名> → Caddy 443；box 内 8080 须有服务监听")
		fmt.Fprintln(s, "6. 全部失败 → journalctl -u ssh（box 内）+ railans 日志（入口节点）")

	case "daily":
		fmt.Fprintln(s, "向导：日常使用语义")
		fmt.Fprintln(s, "- 连接: ssh -p 2229 ops@"+c.cfg.ControlHost+"（自动建/拉起/直落 shell）")
		fmt.Fprintln(s, "- 长任务放 tmux（box 内已装）: tmux new -s work；断线重连自动 attach")
		fmt.Fprintln(s, "- 空闲保活 24h：会话断开 24h 内 box 不停机；超时停机保盘，重连自动拉起")
		fmt.Fprintln(s, "- 预览: box 内 8080 端口 → https://box-<hash>.<预览域名>（示例 boxes.example.org；按部署套访问保护）")
		fmt.Fprintln(s, "- TTL 7 天到期销毁（含磁盘）；重要数据自行备份/推送")
		fmt.Fprintln(s, "- 工作跑在 tmux 里 = 断线零损失；VM 被停机 = 进程没了但磁盘数据都在")

	case "cleanup":
		fmt.Fprintln(s, "向导：清理顺序")
		fmt.Fprintln(s, "1. ssh -p 2229 ops@"+c.cfg.ControlHost+" ls   —— 先看清单")
		fmt.Fprintln(s, "2. ssh -p 2229 ops@"+c.cfg.ControlHost+" rm box-xxxx   —— 逐台确认删除")
		fmt.Fprintln(s, "3. 测试箱私钥在 /tmp（易失）——重启后无法连接的箱只能等 TTL 或管理员清理")

	case "tunnel":
		fmt.Fprintln(s, "向导：隧道暴露边界")
		fmt.Fprintln(s, "- *.boxes.example.org → Caddy 443 → 各 box 8080（预览通道）")
		fmt.Fprintln(s, "- railans.example.org（Incus UI）不上隧道：客户端证书无法穿过隧道，登录不可用")
		fmt.Fprintln(s, "- 管理面: 局域网 https://<入口节点管理IP>:8443/ui/（示例 192.168.1.11）或 WireGuard 远程")
		fmt.Fprintln(s, "- SSH: 保持局域网 key+enroll")
		fmt.Fprintln(s, "- hysteria 配置变更后必须复验: ip route get 10.10.2.10（须走物理网卡）")

	default:
		fmt.Fprintln(s, "向导目标（wizard <目标>）:")
		fmt.Fprintln(s, "  create   创建前置检查（余量/分布）")
		fmt.Fprintln(s, "  recover  失联恢复阶梯（连接/认证/网络/隧道）")
		fmt.Fprintln(s, "  daily    日常使用语义（连接/tmux/保活/预览/TTL）")
		fmt.Fprintln(s, "  cleanup  清理顺序")
		fmt.Fprintln(s, "  tunnel   隧道暴露边界（什么上公网什么不上）")
	}
}
