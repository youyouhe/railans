package main

import (
	"context"
	"fmt"
	"sync"
)

// waitRegistry 是 `wait` 命令的进程内事件注册表(方案 §1.10-6)。
// 零值可用(register 惰性建 map,挂 Control 字段无需显式初始化),随进程生死,
// 无持久化——挂起连接本就是进程内态,重启即断连(§1.10-5 跨进程边界)。
// 并发不变量:register/notify/cancel 各自整段持锁。
type waitRegistry struct {
	mu      sync.Mutex
	waiters map[string][]chan struct{}
}

func newWaitRegistry() *waitRegistry {
	return &waitRegistry{waiters: map[string][]chan struct{}{}}
}

// register 把一个 waiter 挂到 box 名下,返回带缓冲信号 chan 与注销闭包。
// cancel 必须 defer(TC-WT-01 泄漏防护)。
func (r *waitRegistry) register(name string) (<-chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	r.mu.Lock()
	if r.waiters == nil {
		r.waiters = map[string][]chan struct{}{}
	}
	r.waiters[name] = append(r.waiters[name], ch)
	r.mu.Unlock()
	cancel := func() {
		r.mu.Lock()
		if list, ok := r.waiters[name]; ok {
			for i, c := range list {
				if c == ch {
					list = append(list[:i], list[i+1:]...)
					break
				}
			}
			if len(list) == 0 {
				delete(r.waiters, name)
			} else {
				r.waiters[name] = list
			}
		}
		r.mu.Unlock()
	}
	return ch, cancel
}

// notify 唤醒该名下全部 waiter 并清空该名条目(方案 §1.10-6);无人等待时幂等无操作。
// 信号 chan 带缓冲,发送永不阻塞;信号不带 payload——醒来方必复查(waitForBox)。
// notify 即注销:醒来复查仍非终态的 waiter 由循环顶部重新 register(先注册→后查询)。
func (r *waitRegistry) notify(name string) {
	r.mu.Lock()
	list := r.waiters[name]
	delete(r.waiters, name)
	r.mu.Unlock()
	for _, ch := range list {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

// waitOwnerCheck 是 wait 入口的属主校验纯函数(方案 §1.10-3):只许等自己 key 的箱。
// 记录不存在(b == nil)不在此占码——调用方(cmdWait)按现状回旧文本
// `box %q not found`(wait 与 ownedBox 的掩蔽行为刻意区分,拍板语义)。
func waitOwnerCheck(b *Box, fp string) error {
	if b == nil {
		return nil
	}
	if b.KeyFP != fp {
		return newBoxError("wait_not_owner",
			fmt.Sprintf("box %s exists but belongs to another key", b.Name), "", false, 0)
	}
	return nil
}

// waitForBox 挂起等待 box 落终态(running/stopped)。
// 固定顺序不变量(方案 §1.10-4,实施不得调换):每轮「先注册 → 后查询 →
// 挂起 → 醒来必复查」——notify 只是「可能变了」的信号,醒来重新查询;
// 仍非终态则重新注册继续挂起。「先落账后 notify」与「先 notify 后落账」
// 两种交错都收敛正确(TC-WT-02)。
func waitForBox(ctx context.Context, store *Store, reg *waitRegistry, name string) (*Box, error) {
	for {
		ch, cancel := reg.register(name)
		b := store.BoxByName(name)
		if b == nil {
			// 注册与查询之间记录被删(rm/destroy 经落账点),或创建失败回滚。
			cancel()
			return nil, newBoxError("wait_target_gone",
				fmt.Sprintf("box %s was removed while waiting; re-run new to recreate", name), "", true, 0)
		}
		if b.State == "running" || b.State == "stopped" {
			cancel()
			return b, nil
		}
		select {
		case <-ctx.Done():
			cancel()
			return nil, newBoxError("wait_timeout",
				fmt.Sprintf("timed out waiting for box %s (still %s); check ls --json and retry", name, b.State), "", true, 0)
		case <-ch:
			cancel()
			// 醒来必复查:回到循环顶部先重注册再查询(notify 已注销本条目)。
		}
	}
}

// putBoxNotify / deleteBoxNotify:store 落账点之后接 notify(方案 §1.10-5)。
// 替换 sshd.go 内全部落账调用点;reap.go/reconcile.go 的落账点本波不接(禁碰边界),
// 其路径上的 waiter 靠 wait_timeout 兜底自查——推送迟到,不是错终态。
func (c *Control) putBoxNotify(b *Box) error {
	err := c.store.PutBox(b)
	if err == nil {
		c.waitReg.notify(b.Name)
	}
	return err
}

func (c *Control) deleteBoxNotify(name string) error {
	err := c.store.DeleteBox(name)
	if err == nil {
		c.waitReg.notify(name)
	}
	return err
}
