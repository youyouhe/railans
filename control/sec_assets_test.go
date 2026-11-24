package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// secAssetsStubIncus：带调用记录与可编程失败点的 incus stub（TC-H2 组专用变体，
// 不进 fixes_test.go——既有 helper 只复用不修改，测试用例文档 §1 表 A 行约定）。
// 每次调用把参数追加写 <dir>/calls.log；失败点开关（文件存在即生效）：
//   fail-push     内容为目标路径关键词，file push 命中关键词即失败
//   probe-missing guest 探测 exec（含 test -f）退出 1（模拟资产缺一）
//   fail-delete   delete 失败
//   fail-stop     stop 失败（TC-L5 组复用）
func secAssetsStubIncus(t *testing.T, dir string) *Incus {
	t.Helper()
	bin := filepath.Join(dir, "incus-stub")
	callsLog := filepath.Join(dir, "calls.log")
	failPush := filepath.Join(dir, "fail-push")
	probeMissing := filepath.Join(dir, "probe-missing")
	failDelete := filepath.Join(dir, "fail-delete")
	failStop := filepath.Join(dir, "fail-stop")
	script := fmt.Sprintf(`#!/bin/sh
printf '%%s\n' "$*" >> %s
if [ "$1" = "delete" ] && [ -f %s ]; then echo 'stub: delete failure' >&2; exit 1; fi
if [ "$1" = "stop" ] && [ -f %s ]; then echo 'stub: stop failure' >&2; exit 1; fi
if [ "$1" = "file" ] && [ -f %s ]; then
  keyword="$(cat %s)"
  case "$*" in *"$keyword"*) echo 'stub: push failure' >&2; exit 1;; esac
fi
if [ "$1" = "exec" ] && [ -f %s ]; then
  case "$*" in *"test -f"*) exit 1;; esac
fi
exit 0
`, callsLog, failDelete, failStop, failPush, failPush, probeMissing)
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return &Incus{Bin: bin, BaseImage: "dev-base", Profile: "dev"}
}

// secReadCalls 读 stub 的调用记录（每行一次 incus 子调用的参数拼接）。
func secReadCalls(t *testing.T, dir string) []string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dir, "calls.log"))
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		t.Fatal(err)
	}
	return strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
}

// secCallIndex 返回首个含 substr 的调用行下标，无则 -1。
func secCallIndex(lines []string, substr string) int {
	for i, l := range lines {
		if strings.Contains(l, substr) {
			return i
		}
	}
	return -1
}

// secWriteAssetFixtures 在 dir 内写假 db/假 tar（全程不碰真 ~/.cc-switch
// 与真 orca 产物，测试用例文档 TC-H2 组通用前置）。
func secWriteAssetFixtures(t *testing.T, dir string) (db, tar string) {
	t.Helper()
	db = filepath.Join(dir, "cc-switch.db")
	tar = filepath.Join(dir, "orca-cli.tar.gz")
	if err := os.WriteFile(db, []byte("fake-db"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(tar, []byte("fake-tar"), 0o600); err != nil {
		t.Fatal(err)
	}
	return db, tar
}

// TC-H2-01：创建路径注入调用序——launch → waitready → PushKey →
// ProvisionAssets(push db → push tar → exec 解压/wrapper) → （此后零 incus 调用，
// 即 proxy.Add 与终态落账前完成整备）；db push 参数含 --uid 1000 --gid 1000 --mode 600。
func TestSecAssetsCreatePathInjectionOrder(t *testing.T) {
	dir := t.TempDir()
	db, tar := secWriteAssetFixtures(t, dir)

	c := newSecControl(t, secAssetsStubIncus(t, dir), &bytes.Buffer{})
	c.cfg.BoxAssets = BoxAssets{CCSwitchDB: db, OrcaTar: tar}

	box, err := c.ensureBox(context.Background(), &fakeSession{}, "FP-H2-01", testPubKey(t), false)
	if err != nil {
		t.Fatalf("ensureBox: %v", err)
	}
	if box.State != "running" {
		t.Fatalf("state = %q, want running", box.State)
	}

	lines := secReadCalls(t, dir)
	idxLaunch := secCallIndex(lines, "launch ")
	idxAuthKeys := secCallIndex(lines, "authorized_keys")
	idxDB := secCallIndex(lines, "cc-switch.db")
	idxTar := secCallIndex(lines, "orca-cli.tar.gz")
	idxUnpack := secCallIndex(lines, "tar -xzf")
	dump := strings.Join(lines, "\n")
	for name, i := range map[string]int{"launch": idxLaunch, "authorized_keys": idxAuthKeys, "db": idxDB, "tar": idxTar, "unpack": idxUnpack} {
		if i < 0 {
			t.Fatalf("调用序缺 %s:\n%s", name, dump)
		}
	}
	if !(idxLaunch < idxAuthKeys && idxAuthKeys < idxDB && idxDB < idxTar && idxTar < idxUnpack) {
		t.Fatalf("调用序错乱: launch=%d authkeys=%d db=%d tar=%d unpack=%d\n%s",
			idxLaunch, idxAuthKeys, idxDB, idxTar, idxUnpack, dump)
	}
	if idxUnpack != len(lines)-1 {
		t.Fatalf("解压 exec 之后不应再有 incus 调用（proxy.Add/终态落账前完成整备）:\n%s", dump)
	}
	dbLine := lines[idxDB]
	for _, want := range []string{"--uid 1000", "--gid 1000", "--mode 600"} {
		if !strings.Contains(dbLine, want) {
			t.Fatalf("db push 参数缺 %s: %s", want, dbLine)
		}
	}
}

// TC-H2-02：注入失败 → cleanup + asset_push_failed（retryable=true）、
// store 无该 box 记录、stub 收到 VM delete。
func TestSecAssetsPushFailureCleanup(t *testing.T) {
	dir := t.TempDir()
	db, tar := secWriteAssetFixtures(t, dir)
	if err := os.WriteFile(filepath.Join(dir, "fail-push"), []byte("cc-switch.db"), 0o644); err != nil {
		t.Fatal(err)
	}

	c := newSecControl(t, secAssetsStubIncus(t, dir), &bytes.Buffer{})
	c.cfg.BoxAssets = BoxAssets{CCSwitchDB: db, OrcaTar: tar}

	_, err := c.ensureBox(context.Background(), &fakeSession{}, "FP-H2-02", testPubKey(t), false)
	if err == nil {
		t.Fatal("db push 失败未被上报")
	}
	rendered, ok := renderNewErrorJSON(err)
	if !ok {
		t.Fatalf("未命中 BoxError 信封: %v", err)
	}
	if !strings.Contains(rendered, `"asset_push_failed"`) {
		t.Fatalf("code 不是 asset_push_failed: %s", rendered)
	}
	if !strings.Contains(rendered, `"retryable": true`) {
		t.Fatalf("retryable 不是 true: %s", rendered)
	}
	if b := c.store.BoxByKey("FP-H2-02"); b != nil {
		t.Fatalf("cleanup 未删记录（半交付箱）: %+v", b)
	}
	if secCallIndex(secReadCalls(t, dir), "delete ") < 0 {
		t.Fatalf("stub 未收到 VM delete（清理未执行）:\n%s", strings.Join(secReadCalls(t, dir), "\n"))
	}
}

// TC-H2-03：box_assets 两键缺省空 = 注入关闭——零配置兼容锚，行为与改造前一致。
func TestSecAssetsDefaultEmptyNoOp(t *testing.T) {
	dir := t.TempDir()
	c := newSecControl(t, secAssetsStubIncus(t, dir), &bytes.Buffer{})
	// cfg.BoxAssets 保持零值

	box, err := c.ensureBox(context.Background(), &fakeSession{}, "FP-H2-03", testPubKey(t), false)
	if err != nil {
		t.Fatalf("ensureBox: %v", err)
	}
	if box.State != "running" {
		t.Fatalf("state = %q, want running", box.State)
	}
	for _, l := range secReadCalls(t, dir) {
		if strings.Contains(l, "cc-switch.db") || strings.Contains(l, "orca") || strings.Contains(l, "test -f") {
			t.Fatalf("空配置不应出现注入/探测调用: %s", l)
		}
	}
}

// TC-H2-04：配置了但源文件缺失 → asset_push_failed，message 含缺失路径，不发半交付箱。
func TestSecAssetsMissingSourceLoudFail(t *testing.T) {
	dir := t.TempDir()
	for _, tc := range []struct {
		name   string
		fp     string
		assets BoxAssets
	}{
		{"cc_switch_db 缺失", "FP-H2-04A", BoxAssets{CCSwitchDB: filepath.Join(dir, "nope-cc.db")}},
		{"orca_tar 缺失", "FP-H2-04B", BoxAssets{OrcaTar: filepath.Join(dir, "nope-orca.tar.gz")}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := newSecControl(t, secAssetsStubIncus(t, dir), &bytes.Buffer{})
			c.cfg.BoxAssets = tc.assets

			_, err := c.ensureBox(context.Background(), &fakeSession{}, tc.fp, testPubKey(t), false)
			if err == nil {
				t.Fatal("源缺失未 loud fail")
			}
			rendered, ok := renderNewErrorJSON(err)
			if !ok || !strings.Contains(rendered, `"asset_push_failed"`) {
				t.Fatalf("未命中 asset_push_failed 信封: %v (%s)", err, rendered)
			}
			if !strings.Contains(err.Error(), "not found") || !strings.Contains(err.Error(), filepath.Base(tc.assets.orcaOrDB())) {
				t.Fatalf("message 不含缺失路径关键词: %v", err)
			}
			if b := c.store.BoxByKey(tc.fp); b != nil {
				t.Fatalf("半交付箱残留: %+v", b)
			}
			if secCallIndex(secReadCalls(t, dir), "delete ") < 0 {
				t.Fatal("源缺失路径未触发 VM cleanup")
			}
		})
	}
}

// orcaOrDB 取配置里任一源路径（测试断言辅助：两例各只配一键）。
func (a BoxAssets) orcaOrDB() string {
	if a.CCSwitchDB != "" {
		return a.CCSwitchDB
	}
	return a.OrcaTar
}

// TC-H2-05：复用路径幂等自愈——两文件齐探测短路零补推（探测 ≤1 次无风暴）；
// 缺一补推失败仅 WARN 不阻断复用，box 照常返回。
func TestSecAssetsReuseSelfHeal(t *testing.T) {
	dir := t.TempDir()
	db, tar := secWriteAssetFixtures(t, dir)

	buf := &bytes.Buffer{}
	c := newSecControl(t, secAssetsStubIncus(t, dir), buf)
	c.cfg.BoxAssets = BoxAssets{CCSwitchDB: db, OrcaTar: tar}
	putBox(t, c.store, "box-h2r05", "FP-H2-05", "running", 22190, time.Now().UTC().Add(time.Hour))
	pk := testPubKey(t)

	// 两文件齐 → 探测短路，零补推
	if _, err := c.ensureBox(context.Background(), &fakeSession{}, "FP-H2-05", pk, false); err != nil {
		t.Fatalf("复用 ensureBox: %v", err)
	}
	probes, dbPushes := 0, 0
	for _, l := range secReadCalls(t, dir) {
		if strings.Contains(l, "test -f") {
			probes++
		}
		if strings.HasPrefix(l, "file") && strings.Contains(l, "cc-switch.db") {
			dbPushes++
		}
	}
	if probes != 1 {
		t.Fatalf("探测 exec 次数 = %d, want 1（无风暴）:\n%s", probes, strings.Join(secReadCalls(t, dir), "\n"))
	}
	if dbPushes != 0 {
		t.Fatalf("资产齐备仍发生了补推: %d 次", dbPushes)
	}

	// 缺 orca（探测不命中）+ push 失败 → 补推失败仅 WARN，复用不阻断
	if err := os.WriteFile(filepath.Join(dir, "probe-missing"), []byte("1"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "fail-push"), []byte("orca-cli.tar.gz"), 0o644); err != nil {
		t.Fatal(err)
	}
	buf.Reset()
	box, err := c.ensureBox(context.Background(), &fakeSession{}, "FP-H2-05", pk, false)
	if err != nil || box == nil {
		t.Fatalf("自愈失败不应阻断复用: box=%+v err=%v", box, err)
	}
	if !strings.Contains(buf.String(), "WARN") {
		t.Fatalf("logger 无 WARN: %q", buf.String())
	}
	probes = 0
	for _, l := range secReadCalls(t, dir) {
		if strings.Contains(l, "test -f") {
			probes++
		}
	}
	if probes != 2 { // 第一段复用 1 次 + 第二段复用 1 次
		t.Fatalf("探测 exec 总次数 = %d, want 2（每轮复用 ≤1）", probes)
	}
}
