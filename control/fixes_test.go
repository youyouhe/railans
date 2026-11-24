package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	gssh "github.com/gliderlabs/ssh"
)

// fakeSession satisfies only what ensureBox reads: the client address.
type fakeSession struct {
	gssh.Session
}

func (f *fakeSession) RemoteAddr() net.Addr {
	return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 22222}
}

// stubIncus returns an Incus wrapper around a stub binary: every call
// succeeds except `delete`, which fails while the marker file exists.
func stubIncus(t *testing.T, failDelete bool) *Incus {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "incus-stub")
	marker := filepath.Join(dir, "fail-delete")
	if failDelete {
		if err := os.WriteFile(marker, []byte("1"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	script := fmt.Sprintf("#!/bin/sh\nif [ \"$1\" = \"delete\" ] && [ -f %s ]; then echo 'stub: delete failure' >&2; exit 1; fi\nexit 0\n", marker)
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return &Incus{Bin: bin, BaseImage: "dev-base", Profile: "dev"}
}

func newTestControl(t *testing.T, incus *Incus) *Control {
	t.Helper()
	cfg := &Config{
		Listen:      "127.0.0.1:0",
		StateFile:   filepath.Join(t.TempDir(), "state.json"),
		PortRange:   []int{22100, 22199},
		PreviewPort: 8080,
		Nodes: []NodeConfig{{
			Name: "node1", Address: "10.0.0.11", Subnet: "10.10.1.0/24", Gateway: "10.10.1.1",
		}},
	}
	store, err := OpenStore(cfg.StateFile)
	if err != nil {
		t.Fatal(err)
	}
	logger := log.New(os.Stderr, "test ", 0)
	proxy := NewProxy(store, logger)
	caddy := &Caddy{Path: filepath.Join(t.TempDir(), "boxes.caddy"), Domain: "box.test", Port: 8080, Logger: logger}
	t.Cleanup(func() { proxy.Close() })
	return &Control{cfg: cfg, store: store, incus: incus, proxy: proxy, caddy: caddy, logger: logger, ctx: context.Background()}
}

func putBox(t *testing.T, st *Store, name, fp, state string, port int, expires time.Time) {
	t.Helper()
	now := time.Now().UTC()
	if err := st.PutBox(&Box{
		ID: name, Name: name, KeyFP: fp, Node: "node1",
		VMIP: "10.10.1.10", SSHPort: port, State: state,
		CreatorIP: "127.0.0.1", CreatedAt: now, LastUsed: now, ExpiresAt: expires,
	}); err != nil {
		t.Fatal(err)
	}
}

// P1: a "creating" record left behind by a dead process must be swept —
// VM deleted best-effort, record dropped, other boxes untouched.
func TestSweepOrphanCreating(t *testing.T) {
	c := newTestControl(t, stubIncus(t, false))
	far := time.Now().UTC().Add(time.Hour)
	putBox(t, c.store, "box-aaa111", "FP1", "creating", 22100, far)
	putBox(t, c.store, "box-bbb222", "FP2", "running", 22101, far)

	sweepOrphanCreating(c.store, c.incus, c.logger)

	if b := c.store.BoxByKey("FP1"); b != nil {
		t.Fatalf("orphaned creating record survived sweep: %+v", b)
	}
	if b := c.store.BoxByKey("FP2"); b == nil {
		t.Fatal("sweep removed a non-creating box")
	}
}

// P2: destroy() must keep the record (state=deleting) when incus delete
// fails, so the IP/port stay reserved and the reap loop retries.
func TestDestroyKeepsRecordOnDeleteFailure(t *testing.T) {
	c := newTestControl(t, stubIncus(t, true))
	putBox(t, c.store, "box-ccc333", "FP3", "running", 22102, time.Now().UTC().Add(-time.Minute))

	b := c.store.BoxByKey("FP3")
	if b == nil {
		t.Fatal("setup: box missing")
	}
	c.destroy(context.Background(), b)

	got := c.store.BoxByKey("FP3")
	if got == nil {
		t.Fatal("record dropped although incus delete failed: the IP/port would be re-allocated while the orphan VM still holds them")
	}
	if got.State != "deleting" {
		t.Fatalf("state = %q, want deleting", got.State)
	}

	// Retry with a working backend completes the removal.
	c.incus = stubIncus(t, false)
	c.destroy(context.Background(), got)
	if b := c.store.BoxByKey("FP3"); b != nil {
		t.Fatalf("record survived successful delete retry: %+v", b)
	}
}

// P2 (reap path): a stuck "deleting" box is retried by reapOnce until it
// goes away.
func TestReapRetriesDeletingBoxes(t *testing.T) {
	c := newTestControl(t, stubIncus(t, true))
	putBox(t, c.store, "box-ddd444", "FP4", "running", 22103, time.Now().UTC().Add(-time.Minute))

	c.reapOnce(context.Background())
	if got := c.store.BoxByKey("FP4"); got == nil || got.State != "deleting" {
		t.Fatalf("after reap with failing backend: %+v, want state deleting", got)
	}

	c.incus = stubIncus(t, false)
	c.reapOnce(context.Background())
	if got := c.store.BoxByKey("FP4"); got != nil {
		t.Fatalf("record survived successful reap retry: %+v", got)
	}
}

// P2 (new path): `new` for a key whose box is stuck deleting finishes the
// delete or reports it, instead of reusing the dying box.
func TestEnsureBoxReportsStuckDeleting(t *testing.T) {
	c := newTestControl(t, stubIncus(t, true))
	putBox(t, c.store, "box-eee555", "FP5", "deleting", 22104, time.Now().UTC().Add(time.Hour))

	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pk, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	_ = priv

	_, err = c.ensureBox(context.Background(), &fakeSession{}, "FP5", pk, false)
	if err == nil || !strings.Contains(err.Error(), "stuck deleting") {
		t.Fatalf("err = %v, want stuck-deleting notice", err)
	}
}

// P1/P2: sweep must keep the record (as deleting) when the VM cannot be
// deleted yet — e.g. incus is still running the create operation.
func TestSweepKeepsRecordWhenDeleteBusy(t *testing.T) {
	c := newTestControl(t, stubIncus(t, true))
	far := time.Now().UTC().Add(time.Hour)
	putBox(t, c.store, "box-fff666", "FP6", "creating", 22105, far)

	sweepOrphanCreating(c.store, c.incus, c.logger)

	got := c.store.BoxByKey("FP6")
	if got == nil {
		t.Fatal("record dropped although VM delete failed: IP/port would be re-allocated to a live orphan")
	}
	if got.State != "deleting" {
		t.Fatalf("state = %q, want deleting", got.State)
	}

	// The reap loop then finishes the job once the backend recovers.
	c.incus = stubIncus(t, false)
	c.reapOnce(context.Background())
	if b := c.store.BoxByKey("FP6"); b != nil {
		t.Fatalf("record survived reap retry: %+v", b)
	}
}

// F4: a second Store on the same state file must be refused (split-brain
// guard via flock).
func TestStoreRefusesSecondInstance(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	s1, err := OpenStore(path)
	if err != nil {
		t.Fatalf("first open: %v", err)
	}
	defer s1.Close()
	if _, err := OpenStore(path); err == nil {
		t.Fatal("second OpenStore on the same state file succeeded: split-brain possible")
	}
	s1.Close()
	if s2, err := OpenStore(path); err != nil {
		t.Fatalf("reopen after release: %v", err)
	} else {
		s2.Close()
	}
}

// P3: a failed caddy reload must not advance the watermark, so the next
// Sync retries the reload.
func TestCaddySyncRetriesReloadAfterFailure(t *testing.T) {
	dir := t.TempDir()
	reload := filepath.Join(dir, "reload.sh")
	marker := filepath.Join(dir, "fail")
	if err := os.WriteFile(marker, []byte("1"), 0o644); err != nil {
		t.Fatal(err)
	}
	script := fmt.Sprintf("#!/bin/sh\nif [ -f %s ]; then echo 'stub: reload failure' >&2; exit 1; fi\nexit 0\n", marker)
	if err := os.WriteFile(reload, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	c := &Caddy{
		Path:      filepath.Join(dir, "boxes.caddy"),
		Domain:    "box.test",
		Port:      8080,
		ReloadCmd: []string{reload},
		Logger:    log.New(&bytes.Buffer{}, "", 0),
	}
	c.Sync(nil)
	if c.last != "" {
		t.Fatal("watermark advanced although reload failed; the next Sync would skip the retry")
	}

	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	c.Sync(nil)
	if c.last == "" {
		t.Fatal("reload was not retried after the backend recovered")
	}
}

// reconcile: 外部强停→state 同步为 stopped；外部删除→释放记录；未纳管→不入库
func TestReconcileSyncsExternalChanges(t *testing.T) {
	c := newTestControl(t, stubIncus(t, false))
	far := time.Now().UTC().Add(time.Hour)
	putBox(t, c.store, "box-run77", "FPR", "running", 22110, far)
	putBox(t, c.store, "box-gone8", "FPG", "running", 22111, far)

	insts := []incusInstance{
		{Name: "box-run77", Status: "STOPPED", Location: "node1"},  // 外部强停
		{Name: "box-extra9", Status: "RUNNING", Location: "node1"}, // 未纳管（UI 建箱）
		// box-gone8 缺席 = 被外部删除
	}
	c.reconcileWith(insts)

	if got := c.store.BoxByName("box-run77"); got == nil || got.State != "stopped" {
		t.Fatalf("外部强停未同步: %+v", got)
	}
	if c.store.BoxByName("box-gone8") != nil {
		t.Fatal("外部删除未释放记录")
	}
	if c.store.BoxByName("box-extra9") != nil {
		t.Fatal("未纳管实例不应入库")
	}
}

// enroll-key：code 错误拒绝 / 正确注册 / 证书形态拒绝（三用例）
func TestEnrollKeyRegister(t *testing.T) {
	realCode := "test-code-123"
	valid := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPd98GljZ/1srMj3HLJeJd4tIYeDO74bJBUrpCEpsJPp someone@host"

	fp, err := enrollKeyRegister("test-code-123", realCode, valid, "newkey")
	if err != nil {
		t.Fatalf("valid enroll-key rejected: %v", err)
	}
	if fp == "" || !strings.HasPrefix(fp, "SHA256:") {
		t.Fatalf("fingerprint malformed: %q", fp)
	}

	if _, err := enrollKeyRegister("wrong-code", realCode, valid, "x"); err == nil {
		t.Fatal("wrong code accepted")
	}

	if _, err := enrollKeyRegister("test-code-123", realCode,
		"ssh-ed25519-cert-v01@openssh.com AAAA... someone@host", "x"); err == nil {
		t.Fatal("certificate key accepted")
	}
}
