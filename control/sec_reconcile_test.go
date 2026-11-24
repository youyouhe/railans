package main

import (
	"bytes"
	"context"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// newSecControl 与 fixes_test.go 的 newTestControl 同构，唯 logger 落 buf——
// TC-L1（告警文本）/TC-H2-05（WARN 关键词）/TC-L5-03（WARN）需要断言日志。
// 既有 helper 只复用不修改，故另立；由 sec_*_test.go 三件共用。
func newSecControl(t *testing.T, incus *Incus, buf *bytes.Buffer) *Control {
	t.Helper()
	cfg := &Config{
		Listen:      "127.0.0.1:0",
		StateFile:   filepath.Join(t.TempDir(), "state.json"),
		PortRange:   []int{22100, 22199},
		PreviewPort: 8080,
		// 零值 Limits 会在配额闸提前拦截（对齐 TC-W1-05 放行形态），创建路径用例需过闸。
		Limits: Limits{BoxTTL: "1h", MaxBoxes: 10, MaxPerKey: 3, MaxPerIPDay: 100},
		Nodes: []NodeConfig{{
			Name: "node1", Address: "10.0.0.11", Subnet: "10.10.1.0/24", Gateway: "10.10.1.1",
		}},
	}
	store, err := OpenStore(cfg.StateFile)
	if err != nil {
		t.Fatal(err)
	}
	logger := log.New(buf, "test ", 0)
	proxy := NewProxy(store, logger)
	caddy := &Caddy{Path: filepath.Join(t.TempDir(), "boxes.caddy"), Domain: "box.test", Port: 8080, Logger: logger}
	t.Cleanup(func() { proxy.Close() })
	return &Control{cfg: cfg, store: store, incus: incus, proxy: proxy, caddy: caddy, logger: logger, ctx: context.Background()}
}

// TC-L1-01：瞬态（STARTING/STOPPING）不告警、不掉账。
// 修复锚：reconcile.go case 字面量改小写后，ToLower 后的瞬态不再误落 default。
func TestSecReconcileTransientNoAlarm(t *testing.T) {
	buf := &bytes.Buffer{}
	c := newSecControl(t, stubIncus(t, false), buf)
	far := time.Now().UTC().Add(time.Hour)
	putBox(t, c.store, "box-l1a01", "FP-L1", "running", 22180, far)

	for _, status := range []string{"STARTING", "STOPPING"} {
		buf.Reset()
		c.reconcileWith([]incusInstance{{Name: "box-l1a01", Status: status, Location: "node1"}})
		if strings.Contains(buf.String(), "状态异常") {
			t.Fatalf("status %s: 瞬态误入「状态异常」告警: %s", status, buf.String())
		}
		if strings.Contains(buf.String(), "同步为") {
			t.Fatalf("status %s: 瞬态被当作状态迁移: %s", status, buf.String())
		}
		if got := c.store.BoxByName("box-l1a01"); got == nil || got.State != "running" {
			t.Fatalf("status %s: 账本 state 被改: %+v", status, got)
		}
	}
}

// TC-L1-02：修复锚定——reconcile.go 的 case 字面量已小写，无大写残留。
// （Go 测试内读源码静态断言，cwd 即包目录；测试用例文档 TC-L1-02 二选一取 Go 侧。）
func TestSecReconcileCaseLiteralsLowercase(t *testing.T) {
	raw, err := os.ReadFile("reconcile.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(raw)
	if !strings.Contains(src, `case "starting", "stopping":`) {
		t.Fatal(`reconcile.go 缺少 case "starting", "stopping"（L1 修复锚丢失）`)
	}
	if strings.Contains(src, `"STARTING"`) || strings.Contains(src, `"STOPPING"`) {
		t.Fatal("reconcile.go 仍残留大写瞬态字面量——ToLower 之后永不命中")
	}
}

// TC-L1-03：既有 reconcile 语义零回归——running/stopped 同步、ERROR 告警、
// 外部删除释放，改造前后结果一致（对齐 fixes_test.go TestReconcileSyncsExternalChanges 口径）。
func TestSecReconcileExistingSemantics(t *testing.T) {
	buf := &bytes.Buffer{}
	c := newSecControl(t, stubIncus(t, false), buf)
	far := time.Now().UTC().Add(time.Hour)
	putBox(t, c.store, "box-l1r01", "FP-R", "running", 22181, far)  // 外部强停 → stopped
	putBox(t, c.store, "box-l1r02", "FP-S", "stopped", 22182, far) // 外部拉起 → running
	putBox(t, c.store, "box-l1r03", "FP-T", "running", 22183, far) // ERROR → default 仅告警
	putBox(t, c.store, "box-l1r04", "FP-U", "running", 22184, far) // 缺席 → 外部删除释放

	c.reconcileWith([]incusInstance{
		{Name: "box-l1r01", Status: "STOPPED", Location: "node1"},
		{Name: "box-l1r02", Status: "RUNNING", Location: "node1"},
		{Name: "box-l1r03", Status: "ERROR", Location: "node1"},
		// box-l1r04 缺席
	})

	if got := c.store.BoxByName("box-l1r01"); got == nil || got.State != "stopped" {
		t.Fatalf("外部强停未同步为 stopped: %+v", got)
	}
	if got := c.store.BoxByName("box-l1r02"); got == nil || got.State != "running" {
		t.Fatalf("外部拉起未同步为 running: %+v", got)
	}
	if got := c.store.BoxByName("box-l1r03"); got == nil || got.State != "running" {
		t.Fatalf("ERROR 态不应改账: %+v", got)
	}
	if !strings.Contains(buf.String(), "状态异常") {
		t.Fatalf("ERROR 态未告警: %s", buf.String())
	}
	if c.store.BoxByName("box-l1r04") != nil {
		t.Fatal("外部删除未释放记录")
	}
}
