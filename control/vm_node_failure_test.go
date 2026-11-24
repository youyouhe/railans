package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

// stubIncusVM is stubIncus with per-node launch failures: `launch --target X`
// exits 1 while <dir>/fail-launch-X exists, reproducing a node that cannot run
// virtual machines (the real incus diagnosis for #1).
func stubIncusVM(t *testing.T, failNodes ...string) *Incus {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "incus-stub")
	for _, node := range failNodes {
		if err := os.WriteFile(filepath.Join(dir, "fail-launch-"+node), []byte("1"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	script := fmt.Sprintf(`#!/bin/sh
d='%s'
if [ "$1" = "launch" ]; then
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--target" ] && [ -f "$d/fail-launch-$arg" ]; then
      echo 'Error: Instance type "virtual-machine" is not supported on this server: QEMU failed to run feature checks' >&2
      exit 1
    fi
    prev="$arg"
  done
fi
exit 0
`, dir)
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return &Incus{Bin: bin, BaseImage: "dev-base", Profile: "dev"}
}

// twoNodeControl builds a control plane whose nodes are [bad, good] (bad first
// so the tie-break picks it, like the broken cluster in #1), with limits wide
// enough for several creates in one test.
func twoNodeControl(t *testing.T, failNodes ...string) *Control {
	t.Helper()
	c := newTestControl(t, stubIncusVM(t, failNodes...))
	bad := NodeConfig{Name: "bad", Address: "10.0.0.12", Subnet: "10.10.2.0/24", Gateway: "10.10.2.1"}
	good := NodeConfig{Name: "good", Address: "10.0.0.11", Subnet: "10.10.1.0/24", Gateway: "10.10.1.1"}
	c.cfg.Nodes = []NodeConfig{bad, good}
	c.cfg.Limits = Limits{BoxTTL: "1h", MaxBoxes: 10, MaxPerKey: 3, MaxPerIPDay: 10}
	c.cfg.PortRange = []int{25100, 25199}
	return c
}

func testPubKey(t *testing.T) ssh.PublicKey {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pk, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	return pk
}

// T1 (#1 regression): the broken node keeps the lowest box count because every
// failed create deletes its record, so before the fix every `new` bounced off
// it forever. After a VM-unsupported failure the node must be skipped and the
// next `new` must land on the good node.
func TestNewSkipsNodeThatCannotRunVMs(t *testing.T) {
	c := twoNodeControl(t, "bad")
	pk := testPubKey(t)

	_, err := c.ensureBox(context.Background(), &fakeSession{}, "FPVM1", pk, false)
	if err == nil {
		t.Fatal("first new on the VM-incapable node succeeded; stub is wrong")
	}
	if b := c.store.BoxByKey("FPVM1"); b != nil {
		t.Fatalf("failed create left a record behind: %+v", b)
	}
	if _, blocked := c.vmBlocked("bad", time.Now()); !blocked {
		t.Fatal("bad node was not marked as VM-incapable after the failed launch")
	}

	b, err := c.ensureBox(context.Background(), &fakeSession{}, "FPVM1", pk, false)
	if err != nil {
		t.Fatalf("second new did not recover onto the good node: %v", err)
	}
	if b.Node != "good" {
		t.Fatalf("second new landed on %q, want good", b.Node)
	}
	if b.State != "running" {
		t.Fatalf("second new state = %q, want running", b.State)
	}
}

// T2: pickNode skips nodes inside the backoff window; when every node is
// blocked the caller reports no VM-capable node instead of a bare "no node".
func TestPickNodeSkipsBlockedNodes(t *testing.T) {
	c := twoNodeControl(t, "bad")
	vmErr := errors.New(`Instance type "virtual-machine" is not supported on this server`)

	c.markNodeVMFailure("bad", vmErr)
	if n := c.pickNode(); n == nil || n.Name != "good" {
		t.Fatalf("pickNode = %+v, want good (bad is in backoff)", n)
	}

	c.markNodeVMFailure("good", vmErr)
	if n := c.pickNode(); n != nil {
		t.Fatalf("pickNode = %+v, want nil when every node is blocked", n)
	}

	pk := testPubKey(t)
	_, err := c.ensureBox(context.Background(), &fakeSession{}, "FPVM2", pk, false)
	if err == nil {
		t.Fatal("new succeeded although no node can run VMs")
	}
	for _, want := range []string{"no VM-capable node available", "bad=", "good="} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("err = %q, want it to contain %q", err, want)
		}
	}
}

// T4: a launch failure always names the node it happened on, with the original
// incus text kept for diagnosis.
func TestLaunchErrorNamesNode(t *testing.T) {
	c := twoNodeControl(t, "bad")
	pk := testPubKey(t)

	_, err := c.ensureBox(context.Background(), &fakeSession{}, "FPVM4", pk, false)
	if err == nil {
		t.Fatal("launch on the VM-incapable node succeeded; stub is wrong")
	}
	for _, want := range []string{"launch on node bad failed", "not supported"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("err = %q, want it to contain %q", err, want)
		}
	}
}

// T3: the backoff expires on its own (no restart, no probe) and lets exactly
// one retry through; a still-broken node is re-marked, so the loop drains via
// the good node in between.
func TestVMBackoffExpiresThenRetries(t *testing.T) {
	c := twoNodeControl(t, "bad")
	c.vmFailBackoff = 300 * time.Millisecond
	pk := testPubKey(t)

	if _, err := c.ensureBox(context.Background(), &fakeSession{}, "FPVM3", pk, false); err == nil {
		t.Fatal("first new on the VM-incapable node succeeded; stub is wrong")
	}
	if _, blocked := c.vmBlocked("bad", time.Now()); !blocked {
		t.Fatal("bad node not marked after failed launch")
	}
	if n := c.pickNode(); n == nil || n.Name != "good" {
		t.Fatalf("pickNode inside backoff = %+v, want good", n)
	}

	time.Sleep(c.vmFailBackoff + 100*time.Millisecond)

	if _, blocked := c.vmBlocked("bad", time.Now()); blocked {
		t.Fatal("backoff did not expire on its own")
	}
	if n := c.pickNode(); n == nil || n.Name != "bad" {
		t.Fatalf("pickNode after expiry = %+v, want bad retried (tie-break)", n)
	}

	// The node still rejects VMs, so the retry fails and the marker returns.
	if _, err := c.ensureBox(context.Background(), &fakeSession{}, "FPVM3", pk, false); err == nil {
		t.Fatal("retry on the still-broken node succeeded; marker did not fail the launch")
	}
	if _, blocked := c.vmBlocked("bad", time.Now()); !blocked {
		t.Fatal("node was not re-marked after the failed retry")
	}
}
