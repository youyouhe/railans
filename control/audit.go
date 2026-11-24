package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// 命令级审计日志（L5，安全整改波方案 §5.5）：破坏性/敏感操作「谁何时对谁」的
// JSONL 追加记录。挂点在 handler 层（fp/box 语境齐备处，见 sshd.go 六处）+
// destroy 后端失败补记 ok=false；不挂 store 层（store 不知 fp，归因丢失）。

// auditRecord 一条审计事件。box 对 enroll 类命令无语境（omitempty 省略）；
// fp 是操作者指纹；ip 为空表示无会话语境（destroy 后端失败路径，取账本属主）；
// detail 不含凭据（enroll 失败只记原因，不记被尝试的 code 本身）。
type auditRecord struct {
	TS     string `json:"ts"`
	Op     string `json:"op"` // rm | stop | start | share | snapshot | enroll | enroll_key
	Box    string `json:"box,omitempty"`
	FP     string `json:"fp,omitempty"`
	IP     string `json:"ip,omitempty"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail,omitempty"`
}

// auditFilePath 解析审计落点：显式 "off" = 关闭（返回空串，零写入）；
// 缺省 = state 同目录 audit.jsonl（state 目录进程必可写，kit/打包两布局自动成立，
// 与 systemd ReadWritePaths 对齐）。
func (c *Control) auditFilePath() string {
	switch c.cfg.AuditFile {
	case "off":
		return ""
	case "":
		return filepath.Join(filepath.Dir(c.cfg.StateFile), "audit.jsonl")
	default:
		return c.cfg.AuditFile
	}
}

// audit 落一条命令级审计。写失败仅进程日志 WARN，不阻断命令（dev 集群定位，
// 可用性优先）。调用方负责传齐语境；detail 请勿携带任何密钥/口令。
func (c *Control) audit(op, box, fp, ip string, ok bool, detail string) {
	path := c.auditFilePath()
	if path == "" {
		return
	}
	rec := auditRecord{
		TS:     time.Now().UTC().Format(time.RFC3339Nano),
		Op:     op,
		Box:    box,
		FP:     fp,
		IP:     ip,
		OK:     ok,
		Detail: detail,
	}
	c.auditMu.Lock()
	defer c.auditMu.Unlock()
	if err := appendAuditJSONL(path, rec); err != nil {
		c.logger.Printf("WARN: audit write failed (%s): op=%s box=%s: %v", path, op, box, err)
	}
}

// appendAuditJSONL 追加一条 JSONL。每次写单独 open/close（O_APPEND + 单次 write
// 行内原子）：外部轮转/删文件后自动重建，无需内建轮转（logrotate 属变更单）；
// 权限 0600。
func appendAuditJSONL(path string, rec auditRecord) error {
	line, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(line, '\n')); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}
