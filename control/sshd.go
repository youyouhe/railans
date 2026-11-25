package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"text/tabwriter"
	"time"

	gssh "github.com/gliderlabs/ssh"
	"golang.org/x/crypto/ssh"
)

type Control struct {
	cfg    *Config
	store  *Store
	incus  *Incus
	proxy  *Proxy
	caddy  *Caddy
	logger *log.Logger
	ctx    context.Context

	// Gateway identity for the L3 transparent path: the control plane
	// terminates the client's SSH and bridges into the box with this key.
	gwSigner ssh.Signer
	gwPub    string

	// createMu serialises allocations so two concurrent `new` cannot pick the
	// same IP or port before either box is recorded in the store.
	createMu sync.Mutex

	// vmFailUntil remembers nodes that rejected a VM launch (not VM-capable),
	// so `new` stops bouncing off them and their box count no longer traps
	// every request on the same broken node. Memory-only: a restart forgets it.
	vmFailMu    sync.Mutex
	vmFailUntil map[string]time.Time
	// vmFailBackoff overrides the default 30m window (tests inject a short one).
	vmFailBackoff time.Duration

	// waitReg 是 `wait` 命令的进程内事件注册表(W1 §1.10-6)。零值可用,
	// 随进程生死、无持久化——挂起连接本就是进程内态。
	waitReg waitRegistry

	// auditMu 序列化命令级审计追加写(L5,audit.go)。零值可用。
	auditMu sync.Mutex
}

func (c *Control) Serve() error {
	signer, err := ensureHostKey(c.cfg.HostKeyFile)
	if err != nil {
		return fmt.Errorf("host key: %w", err)
	}
	gwSigner, err := ensureHostKey(gwKeyPath(c.cfg))
	if err != nil {
		return fmt.Errorf("gateway key: %w", err)
	}
	c.gwSigner = gwSigner
	c.gwPub = strings.TrimRight(string(ssh.MarshalAuthorizedKey(gwSigner.PublicKey())), "\n")
	srv := &gssh.Server{
		Addr:    c.cfg.Listen,
		Handler: c.handle,
		PublicKeyHandler: func(ctx gssh.Context, key gssh.PublicKey) bool {
			return true
		},
		HostSigners: []gssh.Signer{gssh.Signer(signer)},
	}
	c.logger.Printf("ssh control listening on %s", c.cfg.Listen)
	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe() }()

	select {
	case err := <-errCh:
		return err
	case <-c.ctx.Done():
		shutCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return srv.Shutdown(shutCtx)
	}
}

func (c *Control) handle(s gssh.Session) {
	pk := s.PublicKey()
	if pk == nil {
		fmt.Fprintln(s, "public key authentication required")
		_ = s.Exit(1)
		return
	}
	fp := ssh.FingerprintSHA256(pk)

	// L3 transparent paths first: sftp subsystem and interactive logins with
	// no command land directly in the caller's box (created on first use).
	if s.Subsystem() == "sftp" {
		if !c.requireEnrolled(s, fp) {
			return
		}
		c.bridgeSession(s, fp, pk, bridgeRequest{subsys: "sftp"})
		return
	}

	cmd, rest, flags := parseArgs(s.Command())
	if cmd == "help" || flags["--help"] || flags["-h"] {
		c.printHelp(s)
		return
	}
	if cmd == "" {
		// `ssh host` with no command: straight into the box, Railway-style.
		if !c.requireEnrolled(s, fp) {
			return
		}
		c.bridgeSession(s, fp, pk, bridgeRequest{pty: true})
		return
	}

	switch cmd {
	case "enroll":
		c.cmdEnroll(s, fp, rest)
	case "enroll-key":
		// 已 enroll 身份为担保 + enroll code 双重验证，注册任意公钥
		//（供 railans-mcp 代办：新设备/新 agent 身份无需人肉持码）
		if !c.requireEnrolled(s, fp) {
			return
		}
		c.cmdEnrollKey(s, fp, rest)
	case "new":
		if !c.requireEnrolled(s, fp) {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
		defer cancel()
		box, err := c.ensureBox(ctx, s, fp, pk, !flags["--json"])
		if err != nil {
			// W1:--json 形态命中 BoxError → 机器可判信封(exit 仍为 1);
			// 否则旧两行不动,非 json 文本逐字零漂移(TC-W1-02)。
			if flags["--json"] {
				if rendered, ok := renderNewErrorJSON(err); ok {
					fmt.Fprintln(s, rendered)
					_ = s.Exit(1)
					return
				}
			}
			fmt.Fprintf(s, "error: %v\n", err)
			_ = s.Exit(1)
			return
		}
		c.printBox(s, box, flags)
	case "ls", "list":
		if !c.requireEnrolled(s, fp) {
			return
		}
		c.cmdList(s, fp, flags)
	case "capacity":
		if !c.requireEnrolled(s, fp) {
			return
		}
		c.cmdCapacity(s)
	case "wizard", "guide":
		if !c.requireEnrolled(s, fp) {
			return
		}
		c.cmdWizard(s, rest)
	case "rm", "delete":
		if !c.requireEnrolled(s, fp) {
			return
		}
		c.cmdRemove(s, fp, rest)
	case "stop":
		if !c.requireEnrolled(s, fp) {
			return
		}
		c.cmdStopStart(s, fp, rest, true)
	case "start":
		if !c.requireEnrolled(s, fp) {
			return
		}
		c.cmdStopStart(s, fp, rest, false)
	case "snapshot":
		if !c.requireEnrolled(s, fp) {
			return
		}
		c.cmdSnapshot(s, fp, rest)
	case "share":
		if !c.requireEnrolled(s, fp) {
			return
		}
		c.cmdShare(s, fp, rest)
	case "info":
		if !c.requireEnrolled(s, fp) {
			return
		}
		c.cmdInfo(s, fp, rest)
	case "wait":
		if !c.requireEnrolled(s, fp) {
			return
		}
		// 对齐 new 分支的 15min ctx:覆盖创建窗口数倍冗余,超时回 wait_timeout。
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
		defer cancel()
		c.cmdWait(ctx, s, fp, rest, flags)
	default:
		// Any other command executes inside the caller's box (created on
		// first use) — the transparent path for `ssh host uptime` and scp.
		if !c.requireEnrolled(s, fp) {
			return
		}
		c.bridgeSession(s, fp, pk, bridgeRequest{cmd: rawCommand(s)})
	}
}

func gwKeyPath(cfg *Config) string {
	return filepath.Join(filepath.Dir(cfg.HostKeyFile), "gw_ed25519")
}

// authorizedKeys combines the user's key with the gateway key: the user keeps
// direct key access (data-plane ports), the control plane can bridge in.
func (c *Control) authorizedKeys(pk ssh.PublicKey) string {
	line := strings.TrimRight(string(ssh.MarshalAuthorizedKey(pk)), "\n")
	if c.gwPub != "" {
		return line + "\n" + c.gwPub + "\n"
	}
	return line + "\n"
}

func parseArgs(args []string) (string, []string, map[string]bool) {
	flags := map[string]bool{}
	var cmd string
	var rest []string
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--"):
			flags[a] = true
		case cmd == "":
			cmd = a
		default:
			rest = append(rest, a)
		}
	}
	return cmd, rest, flags
}

func (c *Control) requireEnrolled(s gssh.Session, fp string) bool {
	if !c.cfg.Security.RequireEnroll || c.store.IsEnrolled(fp) {
		return true
	}
	fmt.Fprintf(s, "this key is not enrolled yet.\n\n  ssh %s enroll <code>\n\n", c.cfg.ControlHost)
	return false
}

func (c *Control) cmdEnroll(s gssh.Session, fp string, rest []string) {
	if len(rest) < 1 {
		fmt.Fprintf(s, "usage: ssh %s enroll <code> [label]\n", c.cfg.ControlHost)
		_ = s.Exit(2)
		return
	}
	// 常量时间比较：避免逐字节提前返回的时序侧信道
	if subtle.ConstantTimeCompare([]byte(rest[0]), []byte(c.cfg.Security.EnrollCode)) != 1 {
		// L5：失败尝试入审（暴力尝试可见性）；detail 不含被尝试的 code 本身
		c.audit("enroll", "", fp, hostOnly(s.RemoteAddr()), false, "invalid enroll code")
		fmt.Fprintln(s, "invalid enroll code")
		_ = s.Exit(1)
		return
	}
	label := "enrolled"
	if len(rest) > 1 {
		label = rest[1]
	}
	if err := c.store.Enroll(fp, label); err != nil {
		c.audit("enroll", "", fp, hostOnly(s.RemoteAddr()), false, err.Error())
		fmt.Fprintf(s, "error: %v\n", err)
		_ = s.Exit(1)
		return
	}
	c.audit("enroll", "", fp, hostOnly(s.RemoteAddr()), true, label)
	fmt.Fprintf(s, "enrolled %s (%s)\n", shortFP(fp), label)
}

// enrollKeyRegister 校验 code 与公钥合法性，返回注册指纹（纯函数，可测）。
func enrollKeyRegister(code, realCode, pubLine, label string) (fingerprint string, err error) {
	if subtle.ConstantTimeCompare([]byte(code), []byte(realCode)) != 1 {
		return "", fmt.Errorf("invalid enroll code")
	}
	parsed, _, _, _, err := ssh.ParseAuthorizedKey([]byte(pubLine))
	if err != nil {
		return "", fmt.Errorf("invalid public key: %w", err)
	}
	// 只接受基础密钥类型，拒绝证书形态（cert-v01 无法对应私钥持有者）
	if strings.Contains(parsed.Type(), "-cert-") {
		return "", fmt.Errorf("certificate keys are not accepted, use the plain public key")
	}
	return ssh.FingerprintSHA256(parsed), nil
}

// cmdEnrollKey 的 fp 参数是调用者（已 enroll 身份为担保方）指纹，用于审计归因。
func (c *Control) cmdEnrollKey(s gssh.Session, fp string, rest []string) {
	usage := "usage: ssh " + c.cfg.ControlHost + " enroll-key <publickey-line> <label> <code>\n"
	if len(rest) < 3 {
		fmt.Fprint(s, usage)
		_ = s.Exit(2)
		return
	}
	pubLine, label, code := rest[0], rest[1], rest[2]
	fingerprint, err := enrollKeyRegister(code, c.cfg.Security.EnrollCode, pubLine, label)
	if err != nil {
		c.audit("enroll_key", "", fp, hostOnly(s.RemoteAddr()), false, err.Error())
		fmt.Fprintf(s, "error: %v\n", err)
		_ = s.Exit(1)
		return
	}
	if err := c.store.Enroll(fingerprint, label); err != nil {
		c.audit("enroll_key", "", fp, hostOnly(s.RemoteAddr()), false, err.Error())
		fmt.Fprintf(s, "error: %v\n", err)
		_ = s.Exit(1)
		return
	}
	// 审计 fp=担保方（操作者），新注册指纹随 detail 留痕
	c.audit("enroll_key", "", fp, hostOnly(s.RemoteAddr()), true, "enrolled "+fingerprint)
	fmt.Fprintf(s, "enrolled %s (%s)\n", shortFP(fingerprint), label)
}

func (c *Control) cmdList(s gssh.Session, fp string, flags map[string]bool) {
	boxes := c.store.ListByKey(fp)
	if flags["--json"] {
		type row struct {
			Name    string `json:"name"`
			Node    string `json:"node"`
			IP      string `json:"ip"`
			Port    int    `json:"port"`
			State   string `json:"state"`
			Expires string `json:"expires"`
		}
		rows := make([]row, 0, len(boxes))
		for _, b := range boxes {
			rows = append(rows, row{b.Name, b.Node, b.VMIP, b.SSHPort, b.State, b.ExpiresAt.Format(time.RFC3339)})
		}
		if rows == nil {
			rows = []row{}
		}
		out, _ := json.MarshalIndent(rows, "", "  ")
		fmt.Fprintln(s, string(out))
		return
	}
	if len(boxes) == 0 {
		fmt.Fprintln(s, "no boxes. run: ssh "+c.cfg.ControlHost+" new")
		return
	}
	w := tabwriter.NewWriter(s, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "NAME\tNODE\tIP\tPORT\tSTATE\tEXPIRES")
	for _, b := range boxes {
		fmt.Fprintf(w, "%s\t%s\t%s\t%d\t%s\t%s\n", b.Name, b.Node, b.VMIP, b.SSHPort, b.State, b.ExpiresAt.Format("2006-01-02 15:04"))
	}
	_ = w.Flush()
}

// cmdCapacity：agent 建箱决策的前置查询（余量/分布，双闸动态口径）
func (c *Control) cmdCapacity(s gssh.Session) {
	// 探测预算：清单一次 + 每候选节点一次 query（各 5s 上限）；整段再兜底
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(len(c.cfg.Nodes)+1)*schedProbeTimeout)
	defer cancel()
	boxes := c.store.AllBoxes()
	bvals := make([]Box, 0, len(boxes))
	for _, b := range boxes {
		bvals = append(bvals, *b)
	}
	counts := c.store.CountByNode()
	dyn := c.capacityDyn(ctx, counts)
	out := capacityJSON(bvals, c.cfg.Limits.MaxBoxes, counts, c.cfg.Nodes, c.cfg.PortRange[0], c.cfg.PortRange[1], dyn)
	fmt.Fprintln(s, string(out))
}

// capacityDyn 探针结论 → capacityJSON 渲染源（cmdCapacity/wizard 同源）。
func (c *Control) capacityDyn(ctx context.Context, counts map[string]int) map[string]capNodeDyn {
	probes := c.schedProbe(ctx, counts)
	dyn := make(map[string]capNodeDyn, len(probes))
	for name, r := range probes {
		dyn[name] = r.Dyn
	}
	return dyn
}

// capacityJSON 纯函数：从箱记录/上限/节点清单/动态探针计算余量分布（可测）。
// 每节点行：cap=per-node 静态上限（null=未设，仅全局上限生效）；
// mem_avail_gib/vcpu_free=实时余量（null=探测失败余量未知）；
// eligible=双闸通过（余量未知时仅静态闸口径）。
func capacityJSON(boxes []Box, maxBoxes int, perNode map[string]int, nodes []NodeConfig, portLo, portHi int, dyn map[string]capNodeDyn) []byte {
	type nodeRow struct {
		Node  string `json:"node"`
		Boxes int    `json:"boxes"`
		Cap   *int   `json:"cap"`
		capNodeDyn
	}
	nodeRows := make([]nodeRow, 0, len(nodes))
	for _, n := range nodes {
		row := nodeRow{Node: n.Name, Boxes: perNode[n.Name]}
		if n.MaxBoxes > 0 {
			capv := n.MaxBoxes
			row.Cap = &capv
		}
		if d, ok := dyn[n.Name]; ok {
			row.capNodeDyn = d
		}
		nodeRows = append(nodeRows, row)
	}
	out, _ := json.MarshalIndent(struct {
		BoxesTotal int       `json:"boxes_total"`
		BoxesMax   int       `json:"boxes_max"`
		Available  int       `json:"available"`
		Nodes      []nodeRow `json:"nodes"`
		Ports      [2]int    `json:"port_range"`
	}{len(boxes), maxBoxes, maxBoxes - len(boxes), nodeRows, [2]int{portLo, portHi}}, "", "  ")
	return out
}

func (c *Control) cmdRemove(s gssh.Session, fp string, rest []string) {
	b := c.ownedBox(s, fp, rest, "rm")
	if b == nil {
		return
	}
	// L5：destroy 后端失败已在其内部补记 ok=false（首个失败事件），此处仅在
	// 删净时补 ok=true——避免同一 rm 事件出现 ok 相互矛盾的两次记录。
	if c.destroy(context.Background(), b) == nil {
		c.audit("rm", b.Name, fp, hostOnly(s.RemoteAddr()), true, "")
	}
	fmt.Fprintf(s, "removed %s\n", b.Name)
}

func (c *Control) cmdStopStart(s gssh.Session, fp string, rest []string, stop bool) {
	b := c.ownedBox(s, fp, rest, "stop/start")
	if b == nil {
		return
	}
	op := "start"
	if stop {
		op = "stop"
	}
	ip := hostOnly(s.RemoteAddr())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	if stop {
		c.proxy.Remove(b.SSHPort)
		if err := c.incus.Stop(ctx, b.Name); err != nil {
			c.audit(op, b.Name, fp, ip, false, err.Error())
			fmt.Fprintf(s, "error: %v\n", err)
			_ = s.Exit(1)
			return
		}
		b.State = "stopped"
		_ = c.putBoxNotify(b)
		c.audit(op, b.Name, fp, ip, true, "")
		fmt.Fprintf(s, "%s stopped (disk kept)\n", b.Name)
		return
	}
	if err := c.incus.Start(ctx, b.Name); err != nil {
		c.audit(op, b.Name, fp, ip, false, err.Error())
		fmt.Fprintf(s, "error: %v\n", err)
		_ = s.Exit(1)
		return
	}
	if err := c.incus.WaitReady(ctx, b.Name, 5*time.Minute); err != nil {
		c.audit(op, b.Name, fp, ip, false, err.Error())
		fmt.Fprintf(s, "error: %v\n", err)
		_ = s.Exit(1)
		return
	}
	if ip, err := c.incus.IP(ctx, b.Name); err == nil {
		b.VMIP = ip
	}
	if err := c.proxy.Add(b.SSHPort, net.JoinHostPort(b.VMIP, "22")); err != nil {
		c.audit(op, b.Name, fp, ip, false, err.Error())
		fmt.Fprintf(s, "error: %v\n", err)
		_ = s.Exit(1)
		return
	}
	b.State = "running"
	_ = c.putBoxNotify(b)
	c.audit(op, b.Name, fp, ip, true, "")
	fmt.Fprintf(s, "%s started\n", b.Name)
}

func (c *Control) cmdSnapshot(s gssh.Session, fp string, rest []string) {
	b := c.ownedBox(s, fp, rest, "snapshot")
	if b == nil {
		return
	}
	ip := hostOnly(s.RemoteAddr())
	if c.cfg.StorageDriver == "dir" {
		c.audit("snapshot", b.Name, fp, ip, false, "dir storage driver does not support snapshots")
		fmt.Fprintf(s, "存储驱动是 dir，不支持快照。\n")
		fmt.Fprintf(s, "要快照能力请用 DRIVER=lvm 或 DRIVER=zfs 重建存储池。\n")
		_ = s.Exit(1)
		return
	}
	name := "snap-" + time.Now().Format("20060102-150405")
	if err := c.incus.Snapshot(context.Background(), b.Name, name); err != nil {
		c.audit("snapshot", b.Name, fp, ip, false, err.Error())
		fmt.Fprintf(s, "error: %v\n", err)
		_ = s.Exit(1)
		return
	}
	c.audit("snapshot", b.Name, fp, ip, true, name)
	fmt.Fprintf(s, "snapshot %s created on %s\n", name, b.Name)
}

func (c *Control) cmdShare(s gssh.Session, fp string, rest []string) {
	b := c.ownedBox(s, fp, rest, "share")
	if b == nil {
		return
	}
	b.Shared = true
	_ = c.putBoxNotify(b)
	c.caddy.Sync(c.store.AllBoxes())
	c.audit("share", b.Name, fp, hostOnly(s.RemoteAddr()), true, "")
	fmt.Fprintf(s, "preview is now shareable: https://%s.%s\n", b.Name, c.cfg.PreviewDomain)
}

func (c *Control) cmdInfo(s gssh.Session, fp string, rest []string) {
	b := c.ownedBox(s, fp, rest, "info")
	if b == nil {
		return
	}
	raw, _ := json.MarshalIndent(b, "", "  ")
	fmt.Fprintln(s, string(raw))
}

// writeNewError 按命令形态回错误:--json 且命中 BoxError → 结构化信封;
// 否则旧文本行。两种形态均 exit 1(与 new 分支旧路径同形)。
func (c *Control) writeNewError(s gssh.Session, err error, flags map[string]bool) {
	if flags["--json"] {
		if rendered, ok := renderNewErrorJSON(err); ok {
			fmt.Fprintln(s, rendered)
			_ = s.Exit(1)
			return
		}
	}
	fmt.Fprintf(s, "error: %v\n", err)
	_ = s.Exit(1)
}

// cmdWait 处理 `wait <box> [--json]`(W1 §1.10-2):挂起至箱落账终态回话。
// 属主校验(waitOwnerCheck)与等待循环(waitForBox)在 waiters.go,可测纯函数,
// 本函数只做会话回话层。记录不存在沿用旧文本 not found,不占 wait 码(§1.10-3);
// 参数缺失对齐 ownedBox 的 usage + exit 2 风格。
func (c *Control) cmdWait(ctx context.Context, s gssh.Session, fp string, rest []string, flags map[string]bool) {
	if len(rest) < 1 {
		fmt.Fprintf(s, "usage: ssh %s wait <box> [--json]\n", c.cfg.ControlHost)
		_ = s.Exit(2)
		return
	}
	b := c.store.BoxByName(rest[0])
	if b == nil {
		fmt.Fprintf(s, "box %q not found\n", rest[0])
		_ = s.Exit(1)
		return
	}
	if err := waitOwnerCheck(b, fp); err != nil {
		c.writeNewError(s, err, flags)
		return
	}
	box, err := waitForBox(ctx, c.store, &c.waitReg, rest[0])
	if err != nil {
		c.writeNewError(s, err, flags)
		return
	}
	c.printBox(s, box, flags)
}

func (c *Control) ownedBox(s gssh.Session, fp string, rest []string, op string) *Box {
	if len(rest) < 1 {
		fmt.Fprintf(s, "usage: ssh %s %s <box>\n", c.cfg.ControlHost, op)
		_ = s.Exit(2)
		return nil
	}
	b := c.store.BoxByName(rest[0])
	if b == nil || b.KeyFP != fp {
		fmt.Fprintf(s, "box %q not found\n", rest[0])
		_ = s.Exit(1)
		return nil
	}
	return b
}

func (c *Control) ensureBox(ctx context.Context, s gssh.Session, fp string, pk ssh.PublicKey, progress bool) (*Box, error) {
	clientIP := hostOnly(s.RemoteAddr())
	if !c.sourceAllowed(clientIP) {
		return nil, newBoxError("source_not_allowed", fmt.Sprintf("source %s is not allowed", clientIP), "", false, 0)
	}

	if b := c.store.BoxByKey(fp); b != nil {
		if b.State == "creating" {
			return nil, newBoxError("creating_in_progress", fmt.Sprintf("box %s is still being created, retry in a few seconds", b.Name), b.Name, true, 5)
		}
		if b.State == "deleting" {
			// A previous delete is pending. Finish it now; if the backend
			// still refuses, tell the client to retry rather than reusing a
			// box that is being torn down.
			c.destroy(ctx, b)
			if again := c.store.BoxByKey(fp); again != nil {
				return nil, newBoxError("stuck_deleting", fmt.Sprintf("previous box %s is stuck deleting, try again shortly", b.Name), b.Name, true, 0)
			}
		} else if time.Now().After(b.ExpiresAt) {
			c.destroy(ctx, b)
		} else {
			if b.State == "stopped" {
				if err := c.incus.Start(ctx, b.Name); err != nil {
					return nil, wrapBoxError("start_failed", err, true)
				}
				if err := c.incus.WaitReady(ctx, b.Name, 5*time.Minute); err != nil {
					return nil, wrapBoxError("wait_ready_failed", err, true)
				}
				if ip, err := c.incus.IP(ctx, b.Name); err == nil {
					b.VMIP = ip
				}
				b.State = "running"
				_ = c.putBoxNotify(b)
			}
			if err := c.proxy.Add(b.SSHPort, net.JoinHostPort(b.VMIP, "22")); err != nil {
				return nil, err
			}
			// Refresh authorized_keys (user + gateway key): self-heals boxes
			// created before the gateway key existed.
			_ = c.incus.PushKey(ctx, b.Name, c.authorizedKeys(pk))
			// H2 assets 幂等自愈（对齐上方 PushKey 自愈惯例）：guest 内探测
			// 配置的资产缺一才补推（一次 exec，~百毫秒级）；失败仅 WARN 不阻断
			// 复用——可用性优先，自愈留待下次 new 重试。
			if c.cfg.BoxAssets.CCSwitchDB != "" || c.cfg.BoxAssets.OrcaTar != "" {
				if !c.incus.AssetsPresent(ctx, b.Name, c.cfg.BoxAssets) {
					if err := c.incus.ProvisionAssets(ctx, b.Name, c.cfg.BoxAssets); err != nil {
						c.logger.Printf("WARN: assets self-heal for %s failed (reuse continues): %v", b.Name, err)
					}
				}
			}
			c.store.Touch(b.Name)
			return b, nil
		}
	}

	if len(c.store.AllBoxes()) >= c.cfg.Limits.MaxBoxes {
		return nil, newBoxError("limit_max_boxes", fmt.Sprintf("cluster box limit reached (%d)", c.cfg.Limits.MaxBoxes), "", false, 0)
	}
	if len(c.store.ListByKey(fp)) >= c.cfg.Limits.MaxPerKey {
		return nil, newBoxError("limit_per_key", fmt.Sprintf("per-key box limit reached (%d)", c.cfg.Limits.MaxPerKey), "", false, 0)
	}
	if !c.store.AllowCreate(clientIP, c.cfg.Limits.MaxPerIPDay) {
		return nil, newBoxError("limit_per_ip_day", fmt.Sprintf("daily creation limit reached for %s", clientIP), "", false, 0)
	}

	node, reasons := c.pickNodeReasons(ctx)
	if node == nil {
		if blocked := c.vmBlockedSummary(time.Now()); blocked != "" {
			return nil, newBoxError("no_vm_node_available", fmt.Sprintf("no VM-capable node available (blocked: %s)", blocked), "", true, 0)
		}
		// 双闸全空且清单为空 = 旧裸文案逐字不变；新闸拒绝原因并入括号形态
		// （如 `no node available (node3: static cap 3 reached (boxes 3))`）。
		msg := "no node available"
		if len(reasons) > 0 {
			msg = fmt.Sprintf("no node available (%s)", strings.Join(reasons, "; "))
		}
		return nil, newBoxError("no_node_available", msg, "", true, 0)
	}
	// Hold the allocation lock until the box is recorded, so a concurrent
	// `new` cannot hand out the same IP/port.
	c.createMu.Lock()
	// Re-check under the lock: another request may have created this key's box
	// while we were waiting.
	if b := c.store.BoxByKey(fp); b != nil {
		c.createMu.Unlock()
		return b, nil
	}
	ip, err := c.store.AllocIP(node)
	if err != nil {
		c.createMu.Unlock()
		return nil, wrapBoxError("allocation_failed", err, true)
	}
	port, err := c.store.AllocPort(c.cfg.PortRange[0], c.cfg.PortRange[1])
	if err != nil {
		c.createMu.Unlock()
		return nil, wrapBoxError("allocation_failed", err, true)
	}
	prefix := subnetPrefix(node.Subnet)
	name := boxName(fp)
	// P5: 6 位十六进制名有 ~1/1600 万碰撞概率，一旦碰撞会静默覆盖他人
	// box 记录（换主+孤儿 VM）。检测到碰撞就大声失败。
	if other := c.store.BoxByName(name); other != nil && other.KeyFP != fp {
		c.createMu.Unlock()
		return nil, newBoxError("name_collision", fmt.Sprintf("box name %s collides with an existing box of another key; contact the administrator", name), name, false, 0)
	}

	// Reserve IP and port immediately so concurrent creates see them as used,
	// then release the lock: provisioning a VM takes tens of seconds.
	now := time.Now().UTC()
	b := &Box{
		ID:        name,
		Name:      name,
		KeyFP:     fp,
		Node:      node.Name,
		VMIP:      ip,
		SSHPort:   port,
		State:     "creating",
		CreatorIP: clientIP,
		CreatedAt: now,
		LastUsed:  now,
		ExpiresAt: now.Add(c.cfg.BoxTTL()),
	}
	if err := c.putBoxNotify(b); err != nil {
		c.createMu.Unlock()
		return nil, wrapBoxError("state_write_failed", err, false)
	}
	c.createMu.Unlock()

	c.logger.Printf("creating %s on %s (%s/%d, port %d)", name, node.Name, ip, prefix, port)
	if progress {
		fmt.Fprintf(s, "creating %s on %s — first boot takes about a minute\r\n", name, node.Name)
	}
	if err := c.incus.Launch(ctx, name, node.Name, ip, prefix, node.Gateway); err != nil {
		_ = c.deleteBoxNotify(name)
		c.markNodeVMFailure(node.Name, err)
		return nil, newBoxError("launch_failed", fmt.Sprintf("launch on node %s failed: %v", node.Name, err), "", true, 0)
	}
	c.clearNodeVMFailure(node.Name)
	cleanup := func() {
		_ = c.incus.Delete(context.Background(), name)
		_ = c.deleteBoxNotify(name)
	}
	if err := c.incus.WaitReady(ctx, name, 8*time.Minute); err != nil {
		cleanup()
		return nil, wrapBoxError("wait_ready_failed", err, true)
	}
	if progress {
		fmt.Fprintf(s, "agent ready — writing your key and wiring the ports\r\n")
	}
	if realIP, err := c.incus.IP(ctx, name); err == nil && realIP != "" {
		ip = realIP
	}
	if err := c.incus.PushKey(ctx, name, c.authorizedKeys(pk)); err != nil {
		cleanup()
		return nil, wrapBoxError("key_push_failed", err, true)
	}
	// H2（railans-kit#7）：镜像零凭据——凭据库与 orca 包在交付前按箱注入；
	// 失败走 cleanup + asset_push_failed，无半交付箱。两键缺省空时为 no-op。
	if err := c.incus.ProvisionAssets(ctx, name, c.cfg.BoxAssets); err != nil {
		cleanup()
		return nil, wrapBoxError("asset_push_failed", err, true)
	}
	if err := c.proxy.Add(port, net.JoinHostPort(ip, "22")); err != nil {
		cleanup()
		return nil, wrapBoxError("proxy_failed", err, true)
	}

	b.VMIP = ip
	b.State = "running"
	b.LastUsed = time.Now().UTC()
	if err := c.putBoxNotify(b); err != nil {
		c.proxy.Remove(port)
		cleanup()
		return nil, wrapBoxError("state_write_failed", err, false)
	}
	c.caddy.Sync(c.store.AllBoxes())
	c.logger.Printf("created %s (%s, port %d)", name, ip, port)
	return b, nil
}

// destroy tears a box down. If the VM deletion fails, the record is kept in
// state "deleting" so the IP/port stay reserved and the reap loop retries;
// dropping the record anyway would strand an orphan VM whose IP can be
// handed out again (P2). 返回后端删除结果（nil = 已删净），供调用方审计归因。
func (c *Control) destroy(ctx context.Context, b *Box) error {
	c.proxy.Remove(b.SSHPort)
	if err := c.incus.Delete(ctx, b.Name); err != nil {
		c.logger.Printf("delete %s: %v (keeping record for retry)", b.Name, err)
		// L5：后端失败补记审计。仅首败入审——state 已是 deleting 的是 reap
		// 周期重试（过程日志已覆盖，入审只产噪音）；此路径无会话语境，
		// ip 留空，fp 取账本属主。
		firstFailure := b.State != "deleting"
		b.State = "deleting"
		_ = c.putBoxNotify(b)
		if firstFailure {
			c.audit("rm", b.Name, b.KeyFP, "", false, fmt.Sprintf("delete failed: %v", err))
		}
		return err
	}
	_ = c.deleteBoxNotify(b.Name)
	c.caddy.Sync(c.store.AllBoxes())
	c.logger.Printf("destroyed %s", b.Name)
	return nil
}

// capNodeDyn 每节点动态口径（capacityJSON 渲染源）：指针字段 nil = 余量未知
// （探测失败/超时回退），eligible 届时仅按静态闸口径。
type capNodeDyn struct {
	MemAvailGiB *float64 `json:"mem_avail_gib"`
	VCPUFree    *int     `json:"vcpu_free"`
	Eligible    bool     `json:"eligible"`
}

// schedProbeResult 单节点双闸结论：Dyn 供 capacity/wizard 渲染，Reason 供
// pickNode 拒绝说明（新闸才有；vmFail 冷却另有摘要形态）。
type schedProbeResult struct {
	Dyn    capNodeDyn
	Reason string
}

// schedProbe 全节点双闸探针（pickNode/capacity/wizard 同源口径，内部任务单）：
// 静态上限（per-node max_boxes）+ 动态余量地板（nodeEligible）逐节点判定。
// 实例清单全集群拉一次按 location 分桶；探测失败/超时 = 该节点余量未知 →
// mem/vcpu 置 nil、eligible 按静态闸、记 WARN（探测失败不全局拒建）。
func (c *Control) schedProbe(ctx context.Context, counts map[string]int) map[string]schedProbeResult {
	out := make(map[string]schedProbeResult, len(c.cfg.Nodes))
	// 静态闸先行：候选全空就不拉实例清单（上限打满时 probe 快路径）
	var cands []*NodeConfig
	for i := range c.cfg.Nodes {
		n := &c.cfg.Nodes[i]
		r := schedProbeResult{Dyn: capNodeDyn{Eligible: true}}
		if n.MaxBoxes > 0 && counts[n.Name] >= n.MaxBoxes {
			r.Dyn.Eligible = false
			r.Reason = fmt.Sprintf("static cap %d reached (boxes %d)", n.MaxBoxes, counts[n.Name])
		}
		out[n.Name] = r
		if r.Dyn.Eligible {
			cands = append(cands, n)
		}
	}
	if len(cands) == 0 {
		return out
	}
	insts, err := schedListInstances(ctx, c.incus)
	if err != nil {
		c.logger.Printf("WARN: incus list failed, all nodes headroom unknown (falling back to static cap only): %v", err)
		return out
	}
	byNode := map[string][]schedInstance{}
	for _, it := range insts {
		byNode[it.Location] = append(byNode[it.Location], it)
	}
	for _, n := range cands {
		r := out[n.Name]
		stats, err := fetchNodeStats(ctx, c.incus, n.Name, byNode[n.Name], c.cfg.VM)
		if err != nil {
			c.logger.Printf("WARN: node %s headroom unknown (falling back to static cap only): %v", n.Name, err)
			out[n.Name] = r
			continue
		}
		mem := stats.MemAvailableGiB
		vfree := stats.CPUTotal - stats.VCPUAllocated
		r.Dyn.MemAvailGiB = &mem
		r.Dyn.VCPUFree = &vfree
		ok, why := nodeEligible(stats, byNode[n.Name], c.cfg.VM, schedDefaultFloors)
		if !ok {
			r.Dyn.Eligible = false
			r.Reason = why
		}
		out[n.Name] = r
	}
	return out
}

// pickNode 老签名薄包装：仅取选中节点（vm_node_failure 等既有测试锚零漂移）。
func (c *Control) pickNode() *NodeConfig {
	n, _ := c.pickNodeReasons(context.Background())
	return n
}

// pickNodeReasons 选节点，并给出新闸拒绝原因（内部任务单）。
// 候选按序过闸：vmFail 冷却（既有，内存态）→ per-node 静态上限（Phase 1）
// → 动态余量地板（Phase 2）。选中口径不变：余量箱数最少优先，平票取 config 顺序。
// 拒绝原因只收新闸（vmFail 冷却有 vmBlockedSummary 自己的摘要形态），
// 由 ensureBox 并入 no_node_available 文案；vmFail 锁内只做快照，
// 动态探测不加锁进行（慢 IO 不持锁）。
func (c *Control) pickNodeReasons(ctx context.Context) (*NodeConfig, []string) {
	counts := c.store.CountByNode()
	c.vmFailMu.Lock()
	blocked := make(map[string]time.Time, len(c.vmFailUntil))
	now := time.Now()
	for name, until := range c.vmFailUntil {
		if now.Before(until) {
			blocked[name] = until
		} else {
			delete(c.vmFailUntil, name)
		}
	}
	c.vmFailMu.Unlock()
	probes := c.schedProbe(ctx, counts)
	var best *NodeConfig
	var reasons []string
	for i := range c.cfg.Nodes {
		n := &c.cfg.Nodes[i]
		if _, ok := blocked[n.Name]; ok {
			continue
		}
		p := probes[n.Name]
		if !p.Dyn.Eligible {
			reasons = append(reasons, n.Name+": "+p.Reason)
			continue
		}
		if best == nil || counts[n.Name] < counts[best.Name] {
			best = n
		}
	}
	return best, reasons
}

// vmFailWindow is how long a node stays out of the rotation after rejecting a
// VM launch. Expiry alone lets one retry through, so a fixed node recovers
// without a restart and a still-broken node is re-marked.
func (c *Control) vmFailWindow() time.Duration {
	if c.vmFailBackoff > 0 {
		return c.vmFailBackoff
	}
	return 30 * time.Minute
}

// vmUnsupported reports whether err is the incus "this node cannot run VMs"
// signature. Transient errors (timeouts, image pulls) must not blacklist a node.
func vmUnsupported(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "not supported") || strings.Contains(msg, "virtual-machine")
}

func (c *Control) markNodeVMFailure(node string, err error) {
	if !vmUnsupported(err) {
		return
	}
	until := time.Now().Add(c.vmFailWindow())
	c.vmFailMu.Lock()
	if c.vmFailUntil == nil {
		c.vmFailUntil = map[string]time.Time{}
	}
	c.vmFailUntil[node] = until
	c.vmFailMu.Unlock()
	c.logger.Printf("NODE %s CANNOT LAUNCH VMs — skipping it for %s (until %s): %v",
		node, c.vmFailWindow(), until.UTC().Format(time.RFC3339), err)
}

func (c *Control) clearNodeVMFailure(node string) {
	c.vmFailMu.Lock()
	defer c.vmFailMu.Unlock()
	if _, ok := c.vmFailUntil[node]; ok {
		delete(c.vmFailUntil, node)
		c.logger.Printf("node %s launched a VM again; VM backoff cleared", node)
	}
}

// vmBlocked reports the remaining backoff for a node, if it is still blocked.
func (c *Control) vmBlocked(node string, now time.Time) (time.Duration, bool) {
	c.vmFailMu.Lock()
	defer c.vmFailMu.Unlock()
	until, ok := c.vmFailUntil[node]
	if !ok || !now.Before(until) {
		return 0, false
	}
	return until.Sub(now), true
}

// vmBlockedSummary renders "node=12m,node2=30m" for the caller's error text.
func (c *Control) vmBlockedSummary(now time.Time) string {
	c.vmFailMu.Lock()
	defer c.vmFailMu.Unlock()
	var parts []string
	for _, n := range c.cfg.Nodes {
		until, ok := c.vmFailUntil[n.Name]
		if !ok || !now.Before(until) {
			continue
		}
		mins := int((until.Sub(now) + time.Minute - 1) / time.Minute)
		if mins < 1 {
			mins = 1
		}
		parts = append(parts, fmt.Sprintf("%s=%dm", n.Name, mins))
	}
	return strings.Join(parts, ",")
}

func (c *Control) sourceAllowed(ip string) bool {
	if c.cfg.Security.AllowedCIDR == "" {
		return true
	}
	_, ipnet, err := net.ParseCIDR(c.cfg.Security.AllowedCIDR)
	if err != nil {
		return false
	}
	parsed := net.ParseIP(ip)
	return parsed != nil && ipnet.Contains(parsed)
}

type boxView struct {
	Box     string `json:"box"`
	State   string `json:"state"`
	Node    string `json:"node"`
	VMIP    string `json:"vm_ip"`
	SSH     string `json:"ssh"`
	SSHPort int    `json:"ssh_port"`
	SSHHost string `json:"ssh_host"`
	Preview string `json:"preview"`
	Expires string `json:"expires"`
	Shared  bool   `json:"shared"`
}

func (c *Control) printBox(s gssh.Session, b *Box, flags map[string]bool) {
	if flags["--connect"] {
		fmt.Fprintf(s, "%d dev@%s\n", b.SSHPort, c.cfg.ControlHost)
		return
	}
	v := boxView{
		Box:     b.Name,
		State:   b.State,
		Node:    b.Node,
		VMIP:    b.VMIP,
		SSH:     fmt.Sprintf("ssh -p %d dev@%s", b.SSHPort, c.cfg.ControlHost),
		SSHPort: b.SSHPort,
		SSHHost: c.cfg.ControlHost,
		Preview: fmt.Sprintf("https://%s.%s", b.Name, c.cfg.PreviewDomain),
		Expires: b.ExpiresAt.Format(time.RFC3339),
		Shared:  b.Shared,
	}
	if flags["--json"] {
		raw, _ := json.MarshalIndent(v, "", "  ")
		fmt.Fprintln(s, string(raw))
		return
	}
	fmt.Fprintf(s, "box:     %s (%s on %s)\n", v.Box, v.State, v.Node)
	fmt.Fprintf(s, "ssh:     %s\n", v.SSH)
	fmt.Fprintf(s, "preview: %s\n", v.Preview)
	fmt.Fprintf(s, "expires: %s\n", v.Expires)
}

func (c *Control) printHelp(s gssh.Session) {
	h := c.cfg.ControlHost
	fmt.Fprint(s, `railans — tiny Railway for your LAN

  ssh `+h+` new [--json] [--connect]
  ssh `+h+` ls
  ssh `+h+` info <box>
  ssh `+h+` stop <box>
  ssh `+h+` start <box>
  ssh `+h+` snapshot <box>
  ssh `+h+` share <box>
  ssh `+h+` rm <box>
  ssh `+h+` ls --json               JSON 格式列出你的 box
  ssh `+h+` capacity                集群余量与分布
  ssh `+h+` wait <box> [--json]     挂起等 box 落终态(创建期推送语义)
  ssh `+h+` wizard <目标>            分步向导(create/recover/daily/cleanup/tunnel)
  ssh `+h+` enroll <code> [label]

identity is your SSH public key. one key = one box.
`)
}

func ensureHostKey(path string) (ssh.Signer, error) {
	if raw, err := os.ReadFile(path); err == nil {
		return ssh.ParsePrivateKey(raw)
	}
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	_ = publicKey
	der, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return nil, err
	}
	block := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, block, 0o600); err != nil {
		return nil, err
	}
	return ssh.NewSignerFromKey(privateKey)
}

func boxName(fp string) string {
	sum := sha256.Sum256([]byte(fp))
	return "box-" + hex.EncodeToString(sum[:])[:6]
}

func shortFP(fp string) string {
	if len(fp) > 24 {
		return fp[:24] + "…"
	}
	return fp
}

func hostOnly(addr net.Addr) string {
	if addr == nil {
		return ""
	}
	host, _, err := net.SplitHostPort(addr.String())
	if err != nil {
		return addr.String()
	}
	return host
}

func subnetPrefix(cidr string) int {
	_, ipnet, err := net.ParseCIDR(cidr)
	if err != nil {
		return 24
	}
	ones, _ := ipnet.Mask.Size()
	return ones
}

func sortedNodes(cfg *Config) []string {
	out := make([]string, 0, len(cfg.Nodes))
	for _, n := range cfg.Nodes {
		out = append(out, n.Name)
	}
	sort.Strings(out)
	return out
}
