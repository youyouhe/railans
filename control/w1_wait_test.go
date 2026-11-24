package main

// TC-wait 组用例(W1 §1.10 wait 命令增补)。
// 依据:内部方案文档（未随公开版发布） §1.10 + 配套测试用例文档 §2。
// 复用 fixes_test.go helper(fakeSession/stubIncus/newTestControl/putBox)与
// vm_node_failure_test.go 的 testPubKey——只复用不修改。
// 被测对象:waiters.go(waitRegistry/waitForBox/waitOwnerCheck)与
// sshd.go(cmdWait/printHelp)。单测不 mock SSH 会话,直接打纯函数 + registry;
// 会话文本断言用本组自建带 bytes.Buffer 的 session 变体(fixes_test.go 不改)。

import (
	"bytes"
	"context"
	"net"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	gssh "github.com/gliderlabs/ssh"
)

// bufSession:输出捕获型 session 变体(TC-WT-06 not-found 文本 / TC-WT-08 printHelp)。
type bufSession struct {
	gssh.Session
	buf      bytes.Buffer
	exited   bool
	exitCode int
}

func (f *bufSession) RemoteAddr() net.Addr {
	return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 22222}
}

func (f *bufSession) Write(p []byte) (int, error) { return f.buf.Write(p) }

func (f *bufSession) Exit(code int) error {
	f.exited = true
	f.exitCode = code
	return nil
}

type waitResult struct {
	b   *Box
	err error
}

// runWaiter 在后台 goroutine 跑 waitForBox,带超时收口防用例自身挂死。
func runWaiter(t *testing.T, ctx context.Context, c *Control, reg *waitRegistry, name string, wait time.Duration) waitResult {
	t.Helper()
	done := make(chan waitResult, 1)
	go func() {
		b, err := waitForBox(ctx, c.store, reg, name)
		done <- waitResult{b, err}
	}()
	select {
	case r := <-done:
		return r
	case <-time.After(wait):
		t.Fatalf("waitForBox(%s) 超时未返回(挂死)", name)
		return waitResult{}
	}
}

// TC-WT-01:registry 纯单测(含泄漏防护与同名重注册)。
func TestWaitRegistryLifecycle(t *testing.T) {
	var reg waitRegistry // 零值可用(挂 Control 字段的形态)

	ch, cancel := reg.register("box-wt1")
	reg.notify("box-wt1")
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal("notify 未送达已注册 waiter")
	}
	cancel() // notify 已清条目,cancel 幂等无害

	// 无人等待的 notify:幂等无操作、不 panic
	reg.notify("box-wt1")
	reg.notify("box-absent")

	// defer 注销路径:cancel 后内部 map 为空(泄漏防护断言)
	_, cancel2 := reg.register("box-wt1y")
	cancel2()
	reg.mu.Lock()
	empty := len(reg.waiters) == 0
	reg.mu.Unlock()
	if !empty {
		t.Fatal("cancel 后 registry 仍有残留条目(waiter 泄漏)")
	}

	// cancel 后同名可重新 register(条目复用无脏状态)
	ch3, cancel3 := reg.register("box-wt1y")
	select {
	case <-ch3:
		t.Fatal("重新注册的 waiter 不应收到残留信号")
	default:
	}
	reg.notify("box-wt1y")
	select {
	case <-ch3:
	case <-time.After(2 * time.Second):
		t.Fatal("重新注册后 notify 未送达")
	}
	cancel3()
}

// TC-WT-02 交错 a:先落账、后 notify → A 返回 running。
func TestWaitInterleavePutThenNotify(t *testing.T) {
	c := newTestControl(t, stubIncus(t, false))
	reg := newWaitRegistry()
	putBox(t, c.store, "box-wt2a", "FPWA", "creating", 22130, time.Now().UTC().Add(time.Hour))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan waitResult, 1)
	go func() {
		b, err := waitForBox(ctx, c.store, reg, "box-wt2a")
		done <- waitResult{b, err}
	}()
	time.Sleep(100 * time.Millisecond) // A 已注册并挂起

	// 落账用「拷贝 + PutBox」:store 内是指针,锁外改共享字段会与 waiter 的
	// 读取构成数据竞争;经 PutBox 原子替换指针与真实落账语义一致。
	b := *c.store.BoxByName("box-wt2a")
	b.State = "running"
	_ = c.store.PutBox(&b) // 先落账
	reg.notify("box-wt2a") // 后 notify

	select {
	case r := <-done:
		if r.err != nil || r.b.State != "running" {
			t.Fatalf("交错 a: err=%v state=%s, want nil/running", r.err, r.b.State)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("交错 a: 落账+notify 后 waiter 挂死")
	}
}

// TC-WT-02 交错 b:先 notify(假信号)、后落账 → 醒来复查仍 creating 必须继续挂起,
// 落账后二次 notify 唤醒(notify 即注销条目实现的要求)→ 最终 running。
func TestWaitInterleaveNotifyThenPut(t *testing.T) {
	c := newTestControl(t, stubIncus(t, false))
	reg := newWaitRegistry()
	putBox(t, c.store, "box-wt2b", "FPWB", "creating", 22131, time.Now().UTC().Add(time.Hour))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan waitResult, 1)
	go func() {
		b, err := waitForBox(ctx, c.store, reg, "box-wt2b")
		done <- waitResult{b, err}
	}()
	time.Sleep(100 * time.Millisecond) // A 已挂起

	reg.notify("box-wt2b") // 假信号:先 notify
	time.Sleep(100 * time.Millisecond)
	// 醒来复查仍非终态 → 不得退出错报(不得出现「醒来即退出并错报 creating 终态」)
	select {
	case r := <-done:
		t.Fatalf("复查仍非终态却提前返回: b=%+v err=%v", r.b, r.err)
	default:
	}

	b := *c.store.BoxByName("box-wt2b")
	b.State = "running"
	_ = c.store.PutBox(&b) // 后落账(拷贝+PutBox,同交错 a 的竞争规避)
	reg.notify("box-wt2b") // 落账后二次 notify

	select {
	case r := <-done:
		if r.err != nil || r.b.State != "running" {
			t.Fatalf("交错 b: err=%v state=%s, want nil/running", r.err, r.b.State)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("交错 b: 二次 notify 后仍挂死")
	}
}

// TC-WT-03:已终态立即回话(注册后先查短路,ctx 从未触发),stopped 同证。
func TestWaitTerminalStateImmediate(t *testing.T) {
	c := newTestControl(t, stubIncus(t, false))
	reg := newWaitRegistry()
	far := time.Now().UTC().Add(time.Hour)
	putBox(t, c.store, "box-wt3r", "FPW3", "running", 22132, far)
	putBox(t, c.store, "box-wt3s", "FPW4", "stopped", 22133, far)

	ctx, cancel := context.WithCancel(context.Background()) // 从不触发,返回即证明无挂起
	defer cancel()
	if r := runWaiter(t, ctx, c, reg, "box-wt3r", 2*time.Second); r.err != nil || r.b.State != "running" {
		t.Fatalf("running: err=%v state=%s, want nil/running", r.err, r.b.State)
	}
	if r := runWaiter(t, ctx, c, reg, "box-wt3s", 2*time.Second); r.err != nil || r.b.State != "stopped" {
		t.Fatalf("stopped: err=%v state=%s, want nil/stopped", r.err, r.b.State)
	}
	// 短路路径同样注销条目
	reg.mu.Lock()
	defer reg.mu.Unlock()
	if len(reg.waiters) != 0 {
		t.Fatalf("终态短路后 waiter 未注销: %v", reg.waiters)
	}
}

// TC-WT-04:挂起期间记录消失 → wait_target_gone(retryable=true)。
func TestWaitTargetGone(t *testing.T) {
	c := newTestControl(t, stubIncus(t, false))
	reg := newWaitRegistry()
	putBox(t, c.store, "box-gone44", "FPW5", "creating", 22134, time.Now().UTC().Add(time.Hour))
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	done := make(chan waitResult, 1)
	go func() {
		b, err := waitForBox(ctx, c.store, reg, "box-gone44")
		done <- waitResult{b, err}
	}()
	time.Sleep(100 * time.Millisecond)
	_ = c.store.DeleteBox("box-gone44") // 模拟 rm/destroy 经落账点删除
	reg.notify("box-gone44")

	select {
	case r := <-done:
		if r.err == nil {
			t.Fatal("记录消失应返回错误")
		}
		body := envelopeError(t, mustRender(t, r.err))
		if body["code"] != "wait_target_gone" || body["retryable"] != true {
			t.Fatalf("code/retryable = %v/%v, want wait_target_gone/true", body["code"], body["retryable"])
		}
	case <-time.After(2 * time.Second):
		t.Fatal("记录删除+notify 后 waiter 挂死")
	}
}

// TC-WT-05:超时 → wait_timeout(retryable=true)。
func TestWaitTimeout(t *testing.T) {
	c := newTestControl(t, stubIncus(t, false))
	reg := newWaitRegistry()
	putBox(t, c.store, "box-wt5", "FPW6", "creating", 22135, time.Now().UTC().Add(time.Hour))

	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_, err := waitForBox(ctx, c.store, reg, "box-wt5")
	if err == nil {
		t.Fatal("短超时应返回错误")
	}
	if elapsed := time.Since(start); elapsed < 40*time.Millisecond {
		t.Fatalf("%v 即返回,未等到超时", elapsed)
	}
	body := envelopeError(t, mustRender(t, err))
	if body["code"] != "wait_timeout" || body["retryable"] != true {
		t.Fatalf("code/retryable = %v/%v, want wait_timeout/true", body["code"], body["retryable"])
	}
}

// TC-WT-06:fp 校验 → wait_not_owner(retryable=false);记录不存在回旧文本
// not found(不占 wait 码,wait 与 ownedBox 的掩蔽行为刻意区分)。
func TestWaitOwnerCheck(t *testing.T) {
	c := newTestControl(t, stubIncus(t, false))
	putBox(t, c.store, "box-own66", "OTHER", "running", 22136, time.Now().UTC().Add(time.Hour))

	err := waitOwnerCheck(c.store.BoxByName("box-own66"), "FPW7")
	if err == nil {
		t.Fatal("他人箱的 wait 应被拒")
	}
	body := envelopeError(t, mustRender(t, err))
	if body["code"] != "wait_not_owner" || body["retryable"] != false {
		t.Fatalf("code/retryable = %v/%v, want wait_not_owner/false", body["code"], body["retryable"])
	}
	if err := waitOwnerCheck(c.store.BoxByName("box-own66"), "OTHER"); err != nil {
		t.Fatalf("自己的箱应通过校验: %v", err)
	}

	// 记录不存在:cmdWait 层旧文本 + exit 1(经 bufSession 验证,不 mock 信封)
	var bs bufSession
	c.cmdWait(context.Background(), &bs, "FPW7", []string{"box-absent99"}, map[string]bool{})
	if !strings.Contains(bs.buf.String(), `box "box-absent99" not found`) {
		t.Fatalf("不存在记录应回旧文本 not found,实际输出: %q", bs.buf.String())
	}
	if !bs.exited || bs.exitCode != 1 {
		t.Fatalf("not found 退出态 exited=%v code=%d, want true/1", bs.exited, bs.exitCode)
	}
}

// TC-WT-07:幂等重入对 wait 无影响——同 key 先 ensureBox(复用路径)再 waitForBox,
// 立即回 running(harbor「new 成功后仍想 wait」的误用形态)。
func TestWaitAfterEnsureReuse(t *testing.T) {
	c := newTestControl(t, stubIncus(t, false))
	reg := newWaitRegistry()
	pk := testPubKey(t)
	fp := ssh.FingerprintSHA256(pk)
	putBox(t, c.store, "box-wt7", fp, "running", 22137, time.Now().UTC().Add(time.Hour))

	b, err := c.ensureBox(context.Background(), &fakeSession{}, fp, pk, false)
	if err != nil || b.State != "running" {
		t.Fatalf("ensureBox 复用路径: b=%+v err=%v", b, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if r := runWaiter(t, ctx, c, reg, "box-wt7", 2*time.Second); r.err != nil || r.b.State != "running" {
		t.Fatalf("wait: err=%v state=%s, want nil/running", r.err, r.b.State)
	}
}

// TC-WT-08(自动部分):printHelp 含 wait 行(经 bufSession 捕获输出)。
func TestPrintHelpListsWait(t *testing.T) {
	c := newTestControl(t, stubIncus(t, false))
	var bs bufSession
	c.printHelp(&bs)
	if !strings.Contains(bs.buf.String(), "wait <box>") {
		t.Fatalf("printHelp 缺 wait 行:\n%s", bs.buf.String())
	}
}
