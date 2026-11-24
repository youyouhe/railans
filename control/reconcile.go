package main

import (
	"net"
	"strings"
)

// reconcile 对账：railans 的 state.json 与 incus 实际状态可能因外部操作
// （UI/面板强停、强删、启动、面板建箱）失同步。由 reap 节奏每分钟驱动一次。
//
// 原则：只改 railans 自己的状态与监听，不做任何破坏性 incus 操作——
// UI 里创建的非 railans 实例只告警不处理（管理员决定去留）。
func (c *Control) reconcileWith(insts []incusInstance) {
	inMap := make(map[string]incusInstance, len(insts))
	for _, it := range insts {
		inMap[it.Name] = it
	}

	for _, b := range c.store.AllBoxes() {
		// creating/deleting 是 railans 自己的进行中事务，跳过对账
		if b.State == "creating" || b.State == "deleting" {
			continue
		}
		it, ok := inMap[b.Name]
		if !ok {
			// incus 里没了 = 被外部删除：释放端口与记录（含 Caddy 站点）
			c.logger.Printf("reconcile: %s 已被外部删除，释放记录与端口", b.Name)
			c.proxy.Remove(b.SSHPort)
			_ = c.store.DeleteBox(b.Name)
			c.caddy.Sync(c.store.AllBoxes())
			continue
		}
		st := strings.ToLower(it.Status)
		switch st {
		case "running":
			if b.State != "running" {
				c.logger.Printf("reconcile: %s incus=%s state=%s → 同步为 running", b.Name, it.Status, b.State)
				b.State = "running"
				_ = c.store.PutBox(b)
			}
			c.proxy.Add(b.SSHPort, net.JoinHostPort(b.VMIP, "22"))
		case "stopped":
			if b.State != "stopped" {
				c.logger.Printf("reconcile: %s incus=%s state=%s → 同步为 stopped（外部强停）", b.Name, it.Status, b.State)
				b.State = "stopped"
				_ = c.store.PutBox(b)
				c.proxy.Remove(b.SSHPort)
			}
		case "starting", "stopping":
			// 瞬态，下一轮再看。incus 原始态是大写 STARTING/STOPPING，上方已
			// ToLower——小写字面量才可达（L1 修复 railans-kit#8：原大写字面量
			// 永不命中，正常瞬态误落 default 刷「状态异常」告警）
		default: // ERROR 等异常态
			c.logger.Printf("reconcile: %s incus 状态异常 (%s)，仅告警", b.Name, it.Status)
		}
		// 节点/IP 漂移同步（外部 move 或 DHCP 类变更；正常为静态 IP 不会变）
		if it.Location != "" && it.Location != b.Node {
			c.logger.Printf("reconcile: %s 节点漂移 %s → %s", b.Name, b.Node, it.Location)
			b.Node = it.Location
			_ = c.store.PutBox(b)
		}
		if it.IP != "" && it.IP != b.VMIP {
			c.logger.Printf("reconcile: %s IP 漂移 %s → %s", b.Name, b.VMIP, it.IP)
			b.VMIP = it.IP
			_ = c.store.PutBox(b)
			c.proxy.Remove(b.SSHPort)
			c.proxy.Add(b.SSHPort, net.JoinHostPort(b.VMIP, "22"))
		}
	}

	// incus 侧未纳管实例（box- 命名空间但不属于 railans 账本）——只告警
	for _, it := range insts {
		if !strings.HasPrefix(it.Name, "box-") {
			continue
		}
		if c.store.BoxByName(it.Name) == nil {
			c.logger.Printf("reconcile: 未纳管实例 %s（%s, %s）在 incus 中存在但不属于 railans 账本，仅告警", it.Name, it.Status, it.Location)
		}
	}
}
