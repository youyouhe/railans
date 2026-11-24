package main

import (
	"context"
	"time"
)

func (c *Control) Reap(ctx context.Context) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.reapOnce(ctx)
		}
	}
}

func (c *Control) reapOnce(ctx context.Context) {
	// 对账：state.json 与 incus 实际状态可能因外部操作（UI 强停/强删/启动）
	// 失同步，每轮先对一次账（一次 incus list，代价可忽略）
	if insts, err := c.incus.List(ctx); err == nil {
		c.reconcileWith(insts)
	} else {
		c.logger.Printf("reconcile: incus list 失败（下轮重试）: %v", err)
	}
	now := time.Now()
	for _, b := range c.store.AllBoxes() {
		if b.State == "deleting" {
			c.logger.Printf("retrying delete of %s", b.Name)
			c.destroy(ctx, b)
			continue
		}
		if now.After(b.ExpiresAt) {
			c.logger.Printf("reaping expired box %s", b.Name)
			c.destroy(ctx, b)
			continue
		}
		if b.State != "running" {
			continue
		}
		last := b.LastUsed
		if last.IsZero() {
			last = b.CreatedAt
		}
		if now.Sub(last) > c.cfg.IdleStop() {
			c.logger.Printf("idle stop %s (last used %s)", b.Name, last.Format(time.RFC3339))
			c.proxy.Remove(b.SSHPort)
			if err := c.incus.Stop(ctx, b.Name); err != nil {
				c.logger.Printf("idle stop %s: %v", b.Name, err)
				continue
			}
			b.State = "stopped"
			_ = c.store.PutBox(b)
		}
	}
	c.caddy.Sync(c.store.AllBoxes())
}
