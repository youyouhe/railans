package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	gssh "github.com/gliderlabs/ssh"
)

// secSession 捕获 handler 输出的会话 stub——handler 层挂点（cmdRemove 等）会写
// 会话，fixes_test.go 的 fakeSession 只供 ensureBox 读 RemoteAddr（只复用不修改），
// 故另建。Exit 为 no-op：测试直接调 handler 函数，无需真实退出语义。
type secSession struct {
	gssh.Session
	buf bytes.Buffer
}

func (f *secSession) Write(p []byte) (int, error) { return f.buf.Write(p) }
func (f *secSession) RemoteAddr() net.Addr {
	return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 22222}
}
func (f *secSession) Exit(code int) error { return nil }

// secAuditLines 读审计文件并逐行解析为 JSON 对象（顺带断言每行合法 JSON）。
func secAuditLines(t *testing.T, path string) []map[string]interface{} {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		t.Fatal(err)
	}
	var out []map[string]interface{}
	for i, l := range strings.Split(strings.TrimRight(string(raw), "\n"), "\n") {
		var m map[string]interface{}
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("审计第 %d 行非合法 JSON: %v (%s)", i+1, err, l)
		}
		out = append(out, m)
	}
	return out
}

// secAuditOf 过滤出指定 op 的审计行。
func secAuditOf(lines []map[string]interface{}, op string) []map[string]interface{} {
	var out []map[string]interface{}
	for _, m := range lines {
		if secStr(m, "op") == op {
			out = append(out, m)
		}
	}
	return out
}

// secStr 取字符串字段——omitempty 省略的空值键按空串处理。
func secStr(m map[string]interface{}, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

// TC-L5-01：审计器直测——temp 目录写一条 → 追加第二条，逐行 JSON 合法、
// 字段齐（ts/op/box/fp/ip/ok/detail）、0600 权限在位。
func TestSecAuditWriterJSONL(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "audit.jsonl")

	r1 := auditRecord{TS: "2026-11-24T00:00:00Z", Op: "rm", Box: "box-aaa111",
		FP: "SHA256:fake1", IP: "127.0.0.1", OK: true, Detail: "removed"}
	r2 := auditRecord{TS: "2026-11-24T00:00:01Z", Op: "enroll", Box: "box-bbb222",
		FP: "SHA256:fake2", IP: "127.0.0.1", OK: false, Detail: "invalid enroll code"}
	if err := appendAuditJSONL(path, r1); err != nil {
		t.Fatalf("首条写入: %v", err)
	}
	if err := appendAuditJSONL(path, r2); err != nil {
		t.Fatalf("追加写入: %v", err)
	}

	lines := secAuditLines(t, path)
	if len(lines) != 2 {
		t.Fatalf("行数 = %d, want 2", len(lines))
	}
	for i, m := range lines {
		for _, key := range []string{"ts", "op", "box", "fp", "ip", "ok", "detail"} {
			if _, ok := m[key]; !ok {
				t.Fatalf("第 %d 行缺字段 %q: %v", i+1, key, m)
			}
		}
	}
	if lines[0]["op"] != "rm" || lines[0]["ok"] != true {
		t.Fatalf("第 1 行内容不符: %v", lines[0])
	}
	if lines[1]["op"] != "enroll" || lines[1]["ok"] != false {
		t.Fatalf("第 2 行内容不符: %v", lines[1])
	}

	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("审计文件权限 = %v, want 0600", fi.Mode().Perm())
	}
}

// TC-L5-02：挂点覆盖——rm（含 destroy 失败 ok=false，且周期重试不重复入审）、
// stop（成功+失败）、start、share、enroll（成功+无效 code）、enroll-key、snapshot
// （成功+dir 驱动拒绝）：每命令恰一条审计行，op/box/fp 与动作一致。
func TestSecAuditHookCoverage(t *testing.T) {
	dir := t.TempDir()
	incusDir := t.TempDir()
	auditPath := filepath.Join(dir, "audit.jsonl")

	buf := &bytes.Buffer{}
	c := newSecControl(t, secAssetsStubIncus(t, incusDir), buf)
	c.cfg.AuditFile = auditPath
	sess := &secSession{}
	far := futureHour(t)

	// rm 成功
	putBox(t, c.store, "box-a51", "FP-A51", "running", 22151, far)
	c.cmdRemove(sess, "FP-A51", []string{"box-a51"})
	// rm 后端失败（首个失败入审 ok=false；卡删重试不再重复入审）
	putBox(t, c.store, "box-a52", "FP-A52", "running", 22152, far)
	if err := os.WriteFile(filepath.Join(incusDir, "fail-delete"), []byte("1"), 0o644); err != nil {
		t.Fatal(err)
	}
	c.cmdRemove(sess, "FP-A52", []string{"box-a52"})
	c.cmdRemove(sess, "FP-A52", []string{"box-a52"}) // state 已是 deleting 的重试路径
	// stop 成功 / stop 失败 / start 成功
	putBox(t, c.store, "box-a53", "FP-A53", "running", 22153, far)
	c.cmdStopStart(sess, "FP-A53", []string{"box-a53"}, true)
	putBox(t, c.store, "box-a54", "FP-A54", "running", 22154, far)
	if err := os.WriteFile(filepath.Join(incusDir, "fail-stop"), []byte("1"), 0o644); err != nil {
		t.Fatal(err)
	}
	c.cmdStopStart(sess, "FP-A54", []string{"box-a54"}, true)
	c.cmdStopStart(sess, "FP-A53", []string{"box-a53"}, false)
	// share / snapshot 成功 / snapshot dir 驱动拒绝
	putBox(t, c.store, "box-a55", "FP-A55", "running", 22155, far)
	c.cmdShare(sess, "FP-A55", []string{"box-a55"})
	c.cmdSnapshot(sess, "FP-A55", []string{"box-a55"})
	c.cfg.StorageDriver = "dir"
	c.cmdSnapshot(sess, "FP-A55", []string{"box-a55"})
	c.cfg.StorageDriver = ""
	// enroll 成功 / 无效 code / enroll-key 成功
	c.cfg.Security.EnrollCode = "sec-code"
	c.cmdEnroll(sess, "FP-NEW1", []string{"sec-code", "label-a"})
	c.cmdEnroll(sess, "FP-BAD1", []string{"wrong-code"})
	pubLine := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPd98GljZ/1srMj3HLJeJd4tIYeDO74bJBUrpCEpsJPp someone@host"
	c.cmdEnrollKey(sess, "FP-OWNER", []string{pubLine, "newlabel", "sec-code"})

	lines := secAuditLines(t, auditPath)
	if len(lines) != 11 {
		t.Fatalf("审计行数 = %d, want 11:\n%s", len(lines), auditDump(lines))
	}
	type expect struct {
		op   string
		box  string
		fp   string
		ok   bool
		want int
	}
	for _, e := range []expect{
		{"rm", "box-a51", "FP-A51", true, 1},
		{"rm", "box-a52", "FP-A52", false, 1}, // 重试未重复入审
		{"stop", "box-a53", "FP-A53", true, 1},
		{"stop", "box-a54", "FP-A54", false, 1},
		{"start", "box-a53", "FP-A53", true, 1},
		{"share", "box-a55", "FP-A55", true, 1},
		{"snapshot", "box-a55", "FP-A55", true, 1},
		{"snapshot", "box-a55", "FP-A55", false, 1},
		{"enroll", "", "FP-NEW1", true, 1},
		{"enroll", "", "FP-BAD1", false, 1},
		{"enroll_key", "", "FP-OWNER", true, 1},
	} {
		got := 0
		for _, m := range secAuditOf(lines, e.op) {
			okBool, _ := m["ok"].(bool)
			if secStr(m, "box") == e.box && secStr(m, "fp") == e.fp && okBool == e.ok {
				got++
			}
		}
		if got != e.want {
			t.Fatalf("op=%s box=%s fp=%s ok=%v 期望 %d 条, 实得 %d:\n%s", e.op, e.box, e.fp, e.ok, e.want, got, auditDump(lines))
		}
	}
	// 失败的 enroll 尝试 detail 只记原因，不含被尝试的 code 本身
	for _, m := range secAuditOf(lines, "enroll") {
		if okBool, _ := m["ok"].(bool); !okBool && strings.Contains(secStr(m, "detail"), "wrong-code") {
			t.Fatal("audit detail 泄漏了被尝试的 enroll code")
		}
	}
	// destroy 失败记录无会话语境：ip 为空
	for _, m := range secAuditOf(lines, "rm") {
		if okBool, _ := m["ok"].(bool); !okBool && secStr(m, "ip") != "" {
			t.Fatalf("destroy 后端失败记录 ip 应为空: %v", m)
		}
	}
	// enroll_key detail 带新注册指纹留痕
	for _, m := range secAuditOf(lines, "enroll_key") {
		if !strings.Contains(fmt.Sprint(m["detail"]), "SHA256:") {
			t.Fatalf("enroll_key detail 缺新指纹: %v", m)
		}
	}
}

// TC-L5-03：审计写失败不阻断命令——文件指向不可写路径，命令照常成功，
// logger buffer 含 WARN，无 panic。
func TestSecAuditFailureNotBlocking(t *testing.T) {
	incusDir := t.TempDir()
	buf := &bytes.Buffer{}
	c := newSecControl(t, secAssetsStubIncus(t, incusDir), buf)
	c.cfg.AuditFile = filepath.Join(t.TempDir(), "no-such-dir", "audit.jsonl")
	sess := &secSession{}

	putBox(t, c.store, "box-n51", "FP-N51", "running", 22156, futureHour(t))
	c.cmdRemove(sess, "FP-N51", []string{"box-n51"})

	if out := sess.buf.String(); !strings.Contains(out, "removed box-n51") {
		t.Fatalf("命令输出被审计失败阻断: %q", out)
	}
	if b := c.store.BoxByKey("FP-N51"); b != nil {
		t.Fatalf("记录未删除: %+v", b)
	}
	if !strings.Contains(buf.String(), "WARN") {
		t.Fatalf("logger 无 WARN: %q", buf.String())
	}
}

// TC-L5-04：缺省路径与关闭开关——audit_file 缺省落 state 同目录 audit.jsonl；
// 显式 "off" 零写入。
func TestSecAuditDefaultAndOff(t *testing.T) {
	incusDir := t.TempDir()
	buf := &bytes.Buffer{}
	c := newSecControl(t, secAssetsStubIncus(t, incusDir), buf)
	sess := &secSession{}
	putBox(t, c.store, "box-d51", "FP-D51", "running", 22157, futureHour(t))

	// 缺省：state 同目录 audit.jsonl
	want := filepath.Join(filepath.Dir(c.cfg.StateFile), "audit.jsonl")
	if got := c.auditFilePath(); got != want {
		t.Fatalf("缺省审计路径 = %q, want %q", got, want)
	}
	c.cmdShare(sess, "FP-D51", []string{"box-d51"})
	if lines := secAuditLines(t, want); len(lines) != 1 {
		t.Fatalf("缺省落点行数 = %d, want 1", len(lines))
	}

	// "off"：零写入
	c.cfg.AuditFile = "off"
	if got := c.auditFilePath(); got != "" {
		t.Fatalf("off 应返回空路径, got %q", got)
	}
	c.cmdShare(sess, "FP-D51", []string{"box-d51"})
	if lines := secAuditLines(t, want); len(lines) != 1 {
		t.Fatalf("off 后仍发生写入: %d 行", len(lines))
	}
}

func futureHour(t *testing.T) time.Time {
	t.Helper()
	return time.Now().UTC().Add(time.Hour)
}

func auditDump(lines []map[string]interface{}) string {
	raw, _ := json.Marshal(lines)
	return string(raw)
}
