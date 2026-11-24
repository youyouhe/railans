package main

// W1 creating 期结构化错误码用例(TC-W1 组)。
// 依据:内部方案文档 §1 + 配套测试用例文档 §1（内部正本，未随公开版发布）。
// 复用 fixes_test.go 既有 helper(fakeSession/stubIncus/newTestControl/putBox)与
// vm_node_failure_test.go 的 testPubKey——只复用不修改(两文件均在禁碰清单)。
// 断言 JSON 的用例经渲染纯函数 renderNewErrorJSON,输出层不 mock SSH 会话,
// 与仓内 capacityJSON / enrollKeyRegister 纯函数可测风格一致。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

// mustRender 渲染错误信封并解析为顶层 map,渲染未命中即失败。
func mustRender(t *testing.T, err error) map[string]interface{} {
	t.Helper()
	rendered, ok := renderNewErrorJSON(err)
	if !ok {
		t.Fatalf("renderNewErrorJSON(%v) 未命中 BoxError 信封", err)
	}
	var top map[string]interface{}
	if err := json.Unmarshal([]byte(rendered), &top); err != nil {
		t.Fatalf("信封不是合法 JSON: %v\n%s", err, rendered)
	}
	return top
}

// envelopeError 断言信封顶层有且仅有 error 键(与成功路径 boxView 可区分)并返回其内容。
func envelopeError(t *testing.T, top map[string]interface{}) map[string]interface{} {
	t.Helper()
	if len(top) != 1 {
		t.Fatalf("信封顶层应有且仅有 error 键,实际: %v", top)
	}
	raw, ok := top["error"]
	if !ok {
		t.Fatalf("信封顶层缺 error 键: %v", top)
	}
	body, ok := raw.(map[string]interface{})
	if !ok {
		t.Fatalf("error 键不是对象: %v", raw)
	}
	return body
}

// w1CreatingFixture:creating 期同名 key 的 `new` 重发场景(TC-W1-01/02 共用)。
func w1CreatingFixture(t *testing.T) (*Control, ssh.PublicKey) {
	t.Helper()
	c := newTestControl(t, stubIncus(t, false))
	putBox(t, c.store, "box-aaa111", "FP1", "creating", 22100, time.Now().UTC().Add(time.Hour))
	return c, testPubKey(t)
}

// TC-W1-01:creating 期 `new --json` 返回结构化信封。
func TestW1CreatingJSONEnvelope(t *testing.T) {
	c, pk := w1CreatingFixture(t)
	_, err := c.ensureBox(context.Background(), &fakeSession{}, "FP1", pk, false)
	if err == nil {
		t.Fatal("creating 期同 key 重发 new 应被拒,实际成功")
	}
	body := envelopeError(t, mustRender(t, err))
	if body["code"] != "creating_in_progress" {
		t.Fatalf("code = %v, want creating_in_progress", body["code"])
	}
	if body["box"] != "box-aaa111" {
		t.Fatalf("box = %v, want box-aaa111", body["box"])
	}
	if body["retryable"] != true {
		t.Fatalf("retryable = %v, want true", body["retryable"])
	}
	if body["retry_after_seconds"] != float64(5) {
		t.Fatalf("retry_after_seconds = %v, want 5", body["retry_after_seconds"])
	}
	if msg, _ := body["message"].(string); !strings.Contains(msg, "is still being created") {
		t.Fatalf("message = %q, want 含 is still being created", msg)
	}
}

// TC-W1-02:非 json 错误文本逐字不变(harbor 客户端轮询兜底的兼容硬锚)。
func TestW1CreatingLegacyTextVerbatim(t *testing.T) {
	c, pk := w1CreatingFixture(t)
	_, err := c.ensureBox(context.Background(), &fakeSession{}, "FP1", pk, false)
	const want = "box box-aaa111 is still being created, retry in a few seconds"
	if err == nil || err.Error() != want {
		t.Fatalf("非 json 错误文本漂移:\n got: %q\nwant: %q", err, want)
	}
}

// TC-W1-03:stuck deleting → stuck_deleting(旧文本回归 + 码/retryable)。
func TestW1StuckDeletingCode(t *testing.T) {
	c := newTestControl(t, stubIncus(t, true))
	putBox(t, c.store, "box-del777", "FP3", "deleting", 22104, time.Now().UTC().Add(time.Hour))
	_, err := c.ensureBox(context.Background(), &fakeSession{}, "FP3", testPubKey(t), false)
	if err == nil || !strings.Contains(err.Error(), "stuck deleting") {
		t.Fatalf("err = %v, want 旧文本 stuck deleting", err)
	}
	body := envelopeError(t, mustRender(t, err))
	if body["code"] != "stuck_deleting" || body["retryable"] != true {
		t.Fatalf("code/retryable = %v/%v, want stuck_deleting/true", body["code"], body["retryable"])
	}
}

// TC-W1-04:名字碰撞 → name_collision(P5 边界:只分类不修复,boxName() 未动)。
func TestW1NameCollisionCode(t *testing.T) {
	c := newTestControl(t, stubIncus(t, false))
	// newTestControl 零值 Limits 会在配额闸提前拦截,按 TC-W1-05 同款注入放行。
	c.cfg.Limits = Limits{BoxTTL: "1h", MaxBoxes: 10, MaxPerKey: 3, MaxPerIPDay: 100}
	pk := testPubKey(t)
	fp := ssh.FingerprintSHA256(pk)
	putBox(t, c.store, boxName(fp), "OTHER", "running", 22105, time.Now().UTC().Add(time.Hour))
	_, err := c.ensureBox(context.Background(), &fakeSession{}, fp, pk, false)
	if err == nil || !strings.Contains(err.Error(), "collides with an existing box") {
		t.Fatalf("err = %v, want 旧文本 collides with an existing box", err)
	}
	body := envelopeError(t, mustRender(t, err))
	if body["code"] != "name_collision" || body["retryable"] != false {
		t.Fatalf("code/retryable = %v/%v, want name_collision/false", body["code"], body["retryable"])
	}
}

// TC-W1-05:三类配额码抽样,均 retryable=false。
func TestW1LimitCodes(t *testing.T) {
	far := time.Now().UTC().Add(time.Hour)

	// 集群箱数上限
	c := newTestControl(t, stubIncus(t, false))
	c.cfg.Limits = Limits{BoxTTL: "1h", MaxBoxes: 1, MaxPerKey: 5, MaxPerIPDay: 100}
	putBox(t, c.store, "box-full11", "FPX", "running", 22121, far)
	_, err := c.ensureBox(context.Background(), &fakeSession{}, "FPNEW1", testPubKey(t), false)
	if err == nil {
		t.Fatal("超 MaxBoxes 应被拒")
	}
	body := envelopeError(t, mustRender(t, err))
	if body["code"] != "limit_max_boxes" || body["retryable"] != false {
		t.Fatalf("code/retryable = %v/%v, want limit_max_boxes/false", body["code"], body["retryable"])
	}

	// 单 key 配额:能走到该闸的 key 必无在册箱(BoxByKey 命中者走复用/拒绝路径),
	// 故 MaxPerKey=0(配置缺省值直通形态)才可触发该分支。
	c2 := newTestControl(t, stubIncus(t, false))
	c2.cfg.Limits = Limits{BoxTTL: "1h", MaxBoxes: 10, MaxPerKey: 0, MaxPerIPDay: 100}
	_, err2 := c2.ensureBox(context.Background(), &fakeSession{}, "FPNEW2", testPubKey(t), false)
	if err2 == nil {
		t.Fatal("MaxPerKey=0 应被拒")
	}
	body2 := envelopeError(t, mustRender(t, err2))
	if body2["code"] != "limit_per_key" || body2["retryable"] != false {
		t.Fatalf("code/retryable = %v/%v, want limit_per_key/false", body2["code"], body2["retryable"])
	}

	// 单 IP 日配额:预消费当日额度,ensureBox 再次计入即拒。
	c3 := newTestControl(t, stubIncus(t, false))
	c3.cfg.Limits = Limits{BoxTTL: "1h", MaxBoxes: 10, MaxPerKey: 5, MaxPerIPDay: 1}
	if !c3.store.AllowCreate("127.0.0.1", 1) {
		t.Fatal("setup: 首次额度应放行")
	}
	_, err3 := c3.ensureBox(context.Background(), &fakeSession{}, "FPNEW3", testPubKey(t), false)
	if err3 == nil {
		t.Fatal("超 MaxPerIPDay 应被拒")
	}
	body3 := envelopeError(t, mustRender(t, err3))
	if body3["code"] != "limit_per_ip_day" || body3["retryable"] != false {
		t.Fatalf("code/retryable = %v/%v, want limit_per_ip_day/false", body3["code"], body3["retryable"])
	}
}

// TC-W1-06:无可用节点两形态(故障冷却摘要 / 节点清单为空),均 retryable=true。
func TestW1NoNodeCodes(t *testing.T) {
	vmErr := errors.New(`Instance type "virtual-machine" is not supported on this server`)
	limits := Limits{BoxTTL: "1h", MaxBoxes: 10, MaxPerKey: 5, MaxPerIPDay: 100}

	// 全部节点处于故障冷却 → 摘要形态
	c := newTestControl(t, stubIncus(t, false))
	c.cfg.Limits = limits
	c.markNodeVMFailure("node1", vmErr)
	_, err := c.ensureBox(context.Background(), &fakeSession{}, "FPNN1", testPubKey(t), false)
	if err == nil {
		t.Fatal("全部节点冷却时应被拒")
	}
	body := envelopeError(t, mustRender(t, err))
	if body["code"] != "no_vm_node_available" || body["retryable"] != true {
		t.Fatalf("code/retryable = %v/%v, want no_vm_node_available/true", body["code"], body["retryable"])
	}
	if msg, _ := body["message"].(string); !strings.Contains(msg, "no VM-capable node") {
		t.Fatalf("message = %q, want 含 no VM-capable node(旧文本关键词)", msg)
	}

	// 节点清单为空 → 裸形态
	c2 := newTestControl(t, stubIncus(t, false))
	c2.cfg.Limits = limits
	c2.cfg.Nodes = nil
	_, err2 := c2.ensureBox(context.Background(), &fakeSession{}, "FPNN2", testPubKey(t), false)
	if err2 == nil {
		t.Fatal("无节点时应被拒")
	}
	body2 := envelopeError(t, mustRender(t, err2))
	if body2["code"] != "no_node_available" || body2["retryable"] != true {
		t.Fatalf("code/retryable = %v/%v, want no_node_available/true", body2["code"], body2["retryable"])
	}
	if msg2, _ := body2["message"].(string); !strings.Contains(msg2, "no node available") {
		t.Fatalf("message = %q, want 含 no node available(旧文本)", msg2)
	}
}

// stubIncusSlowLaunch:stubIncus 全成功语义,但 launch 子命令先睡 delay
// (TC-W1-07 需要创建者在途窗口,保证先返回者走 re-check 幂等路径)。
func stubIncusSlowLaunch(t *testing.T, delay string) *Incus {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "incus-stub")
	script := fmt.Sprintf("#!/bin/sh\nif [ \"$1\" = \"launch\" ]; then sleep %s; fi\nexit 0\n", delay)
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return &Incus{Bin: bin, BaseImage: "dev-base", Profile: "dev"}
}

// TC-W1-07:并发 creating 窄窗口语义保持(方案 §1.6 第二行的回归锚)。
// 确定性构造 sshd.go createMu 锁内 re-check 窗口:先占住 createMu,让两个并发
// ensureBox 都停在锁上且首查(BoxByKey)扑空;放锁后先到者建箱,后到者
// re-check 命中 → 幂等返回 State=creating 的记录,err == nil,不产生错误信封。
func TestW1ConcurrentNewNarrowWindowIdempotent(t *testing.T) {
	c := newTestControl(t, stubIncusSlowLaunch(t, "3"))
	c.cfg.Limits = Limits{BoxTTL: "1h", MaxBoxes: 10, MaxPerKey: 3, MaxPerIPDay: 100}
	c.cfg.PortRange = []int{26100, 26199}
	pk := testPubKey(t)
	fp := ssh.FingerprintSHA256(pk)

	c.createMu.Lock()
	type ensureResult struct {
		box *Box
		err error
	}
	results := make(chan ensureResult, 2)
	for i := 0; i < 2; i++ {
		go func() {
			b, err := c.ensureBox(context.Background(), &fakeSession{}, fp, pk, false)
			results <- ensureResult{b, err}
		}()
		time.Sleep(150 * time.Millisecond) // 各自停在 createMu 上
	}
	c.createMu.Unlock()

	first := <-results // 后到者:re-check 命中,立即幂等返回
	if first.err != nil {
		t.Fatalf("幂等路径返回错误: %v", first.err)
	}
	if first.box.State != "creating" {
		t.Fatalf("幂等返回 state = %q, want creating(方案 §1.6 第二行)", first.box.State)
	}
	second := <-results // 先到者:走完整创建链(stub launch 3s 在途保证先后序)
	if second.err != nil {
		t.Fatalf("创建路径返回错误: %v", second.err)
	}
	if second.box.State != "running" {
		t.Fatalf("创建完成 state = %q, want running", second.box.State)
	}
	if b := c.store.BoxByKey(fp); b == nil || b.State != "running" {
		t.Fatalf("落库终态 = %+v, want running", b)
	}
}

// TC-W1-08:幂等重入——running 后再 `new` 走复用路径,err == nil 且无错误信封。
func TestW1ReuseRunningNoEnvelope(t *testing.T) {
	c := newTestControl(t, stubIncus(t, false))
	putBox(t, c.store, "box-run888", "FP8", "running", 22110, time.Now().UTC().Add(time.Hour))
	b, err := c.ensureBox(context.Background(), &fakeSession{}, "FP8", testPubKey(t), false)
	if err != nil {
		t.Fatalf("复用路径应成功: %v", err)
	}
	if b.State != "running" || b.SSHPort != 22110 {
		t.Fatalf("复用返回 state/port = %s/%d, want running/22110", b.State, b.SSHPort)
	}
	if rendered, ok := renderNewErrorJSON(nil); ok {
		t.Fatalf("nil err 渲染不应命中,却输出: %s", rendered)
	}
}

// TC-W1-09:渲染函数兜底——非 BoxError 返回 false(调用方走旧文本路径,
// 方案 §1.4-3 选定形态,与 handle 调用侧一致);internal 兜底码信封总有 code,
// 且无 box 语境时不携带 box / retry_after_seconds 键。
func TestW1RenderFallbackPassthrough(t *testing.T) {
	if rendered, ok := renderNewErrorJSON(fmt.Errorf("boom")); ok {
		t.Fatalf("非 BoxError 应走旧文本路径(方案 §1.4-3 选定形态),却渲染: %s", rendered)
	}
	be := newBoxError("internal", "boom", "", false, 0)
	if be.Error() != "boom" {
		t.Fatalf("Error() 必须逐字返回旧文本, got %q", be.Error())
	}
	body := envelopeError(t, mustRender(t, be))
	if body["code"] != "internal" || body["retryable"] != false {
		t.Fatalf("code/retryable = %v/%v, want internal/false", body["code"], body["retryable"])
	}
	for _, absent := range []string{"box", "retry_after_seconds"} {
		if _, present := body[absent]; present {
			t.Fatalf("无 box 语境/无重试间隔的信封不应携带 %q 键: %v", absent, body)
		}
	}
}
