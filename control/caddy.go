package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Caddy struct {
	Path         string
	Domain       string
	PublicDomain string // 公网预览子域（隧道暴露）；空 = 不启用
	Port         int
	ReloadCmd    []string
	Logger       *log.Logger

	mu   sync.Mutex
	last string
}

func (c *Caddy) Sync(boxes []*Box) {
	c.mu.Lock()
	defer c.mu.Unlock()

	var b strings.Builder
	b.WriteString("# managed by railans; do not edit\n")
	for _, box := range boxes {
		if box.State == "deleted" || box.VMIP == "" {
			continue
		}
		if c.PublicDomain != "" {
			fmt.Fprintf(&b, "\n# %s\n%s.%s, %s.%s {\n    tls internal\n", box.Name, box.Name, c.Domain, box.Name, c.PublicDomain)
		} else {
			fmt.Fprintf(&b, "\n# %s\n%s.%s {\n    tls internal\n", box.Name, box.Name, c.Domain)
		}
		upstream := fmt.Sprintf("%s:%d", box.VMIP, c.Port)
		if !box.Shared && box.CreatorIP != "" {
			fmt.Fprintf(&b, "    @owner remote_ip %s\n    handle @owner {\n        reverse_proxy %s\n    }\n    respond 403\n", box.CreatorIP, upstream)
		} else {
			fmt.Fprintf(&b, "    reverse_proxy %s\n", upstream)
		}
		b.WriteString("}\n")
	}
	content := b.String()
	if content == c.last {
		return
	}
	if err := os.MkdirAll(filepath.Dir(c.Path), 0o755); err != nil {
		c.Logger.Printf("caddy mkdir: %v", err)
		return
	}
	tmp := c.Path + ".tmp"
	if err := os.WriteFile(tmp, []byte(content), 0o644); err != nil {
		c.Logger.Printf("caddy write: %v", err)
		return
	}
	if err := os.Rename(tmp, c.Path); err != nil {
		c.Logger.Printf("caddy rename: %v", err)
		return
	}
	// Advance the watermark only after a successful reload: while caddy is
	// down, every Sync must retry the reload instead of short-circuiting on
	// unchanged content (P3).
	if len(c.ReloadCmd) > 0 {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, c.ReloadCmd[0], c.ReloadCmd[1:]...)
		if out, err := cmd.CombinedOutput(); err != nil {
			c.Logger.Printf("caddy reload: %v: %s", err, strings.TrimSpace(string(out)))
			return
		}
	}
	c.last = content
}
