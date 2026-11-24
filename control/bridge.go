package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"strings"
	"time"

	gssh "github.com/gliderlabs/ssh"
	"golang.org/x/crypto/ssh"
)

// L3 transparent entry: the gateway terminates the client's SSH and bridges
// sessions into the box over a second SSH hop authenticated with the gateway
// keypair. The client pins the gateway host key; the gateway-VM leg is
// infrastructure-internal (see docs/security.md).

func (c *Control) dialVM(b *Box) (*ssh.Client, error) {
	if c.gwSigner == nil {
		return nil, fmt.Errorf("gateway key not initialised")
	}
	if b.VMIP == "" {
		return nil, fmt.Errorf("box %s has no IP assigned yet", b.Name)
	}
	cfg := &ssh.ClientConfig{
		User: "dev",
		Auth: []ssh.AuthMethod{ssh.PublicKeys(c.gwSigner)},
		// The VM is a box we created on our own private bridge; the gateway
		// trusts it the same way it trusts the storage it sits on. Exposing
		// this hop to clients would defeat the point of the gateway key.
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         10 * time.Second,
	}
	return ssh.Dial("tcp", net.JoinHostPort(b.VMIP, "22"), cfg)
}

type bridgeRequest struct {
	subsys string // non-empty: subsystem bridge (sftp)
	cmd    string // non-empty: exec bridge
	pty    bool   // interactive shell bridge
}

// bridgeSession ensures the box exists (creating it on first use, streaming
// progress to the client), then bridges the client session into the VM.
func (c *Control) bridgeSession(s gssh.Session, fp string, pk ssh.PublicKey, req bridgeRequest) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	defer cancel()

	box, err := c.ensureBox(ctx, s, fp, pk, true)
	if err != nil {
		fmt.Fprintf(s, "error: %v\r\n", err)
		_ = s.Exit(1)
		return
	}

	// 长会话续期：L3 桥接不经过数据面端口，定时 Touch 防止活跃会话被误判空闲
	go func() {
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for {
			select {
			case <-s.Context().Done():
				return
			case <-t.C:
				c.store.Touch(box.Name)
			}
		}
	}()

	client, err := c.dialVM(box)
	if err != nil {
		// 状态可能失同步（如 UI/外部强制 stop 绕过了 railans 状态机）：
		// 拉起后重试一次，而不是直接失败。
		fmt.Fprintf(s, "box %s not reachable (%v) — starting it, 30-60s…\r\n", box.Name, err)
		c.logger.Printf("dial %s failed (%v), attempting recovery start", box.Name, err)
		if e := c.incus.Start(ctx, box.Name); e != nil && !isAlreadyRunningErr(e) {
			fmt.Fprintf(s, "error: start: %v\r\n", e)
			_ = s.Exit(1)
			return
		}
		if e := c.incus.WaitReady(ctx, box.Name, 3*time.Minute); e != nil {
			fmt.Fprintf(s, "error: agent: %v\r\n", e)
			_ = s.Exit(1)
			return
		}
		if ip, e := c.incus.IP(ctx, box.Name); e == nil && ip != "" && ip != box.VMIP {
			box.VMIP = ip
			_ = c.store.PutBox(box)
		}
		box.State = "running"
		_ = c.store.PutBox(box)
		client, err = c.dialVM(box)
		if err != nil {
			fmt.Fprintf(s, "error: still unreachable after start: %v\r\n", err)
			_ = s.Exit(1)
			return
		}
	}
	defer client.Close()

	sess, err := client.NewSession()
	if err != nil {
		fmt.Fprintf(s, "error: session: %v\r\n", err)
		_ = s.Exit(1)
		return
	}
	defer sess.Close()

	stdin, err := sess.StdinPipe()
	if err != nil {
		fmt.Fprintf(s, "error: stdin: %v\r\n", err)
		_ = s.Exit(1)
		return
	}
	stdout, err := sess.StdoutPipe()
	if err != nil {
		fmt.Fprintf(s, "error: stdout: %v\r\n", err)
		_ = s.Exit(1)
		return
	}
	stderr, err := sess.StderrPipe()
	if err != nil {
		fmt.Fprintf(s, "error: stderr: %v\r\n", err)
		_ = s.Exit(1)
		return
	}

	switch {
	case req.subsys != "":
		if err := sess.RequestSubsystem(req.subsys); err != nil {
			fmt.Fprintf(s, "error: subsystem %s: %v\r\n", req.subsys, err)
			_ = s.Exit(1)
			return
		}
	case req.cmd != "":
		if err := sess.Start(req.cmd); err != nil {
			fmt.Fprintf(s, "error: exec: %v\r\n", err)
			_ = s.Exit(1)
			return
		}
	default:
		pty, _, _ := s.Pty()
		if err := sess.RequestPty(pty.Term, pty.Window.Height, pty.Window.Width, ssh.TerminalModes{}); err != nil {
			fmt.Fprintf(s, "error: pty: %v\r\n", err)
			_ = s.Exit(1)
			return
		}
		if err := sess.Shell(); err != nil {
			fmt.Fprintf(s, "error: shell: %v\r\n", err)
			_ = s.Exit(1)
			return
		}
	}

	// Client → VM. On EOF close the write side so the VM sees stdin close.
	go func() {
		io.Copy(stdin, s)
		stdin.Close()
	}()
	// VM → client. With a pty stderr is merged by the remote tty; without,
	// keep the streams separate for tools that care.
	go io.Copy(s, stdout)
	go io.Copy(s.Stderr(), stderr)

	// Interactive niceties: forward terminal resizes and signals.
	if pty, winch, ok := s.Pty(); ok && pty.Term != "" {
		go func() {
			for w := range winch {
				_ = sess.WindowChange(w.Height, w.Width)
			}
		}()
		sigc := make(chan gssh.Signal, 8)
		s.Signals(sigc)
		go func() {
			for sig := range sigc {
				_ = sess.Signal(ssh.Signal(sig))
			}
		}()
	}

	// If the client goes away, tear the VM side down with it.
	go func() {
		<-s.Context().Done()
		sess.Close()
		client.Close()
	}()

	err = sess.Wait()
	code := 0
	if err != nil {
		if ee, ok := err.(*ssh.ExitError); ok {
			code = ee.ExitStatus()
		} else {
			code = 255
		}
	}
	_ = s.Exit(code)
}

// rawCommand returns the un-parsed command line the client asked for.
func rawCommand(s gssh.Session) string {
	if rc, ok := any(s).(interface{ RawCommand() string }); ok {
		return strings.TrimSpace(rc.RawCommand())
	}
	return strings.Join(s.Command(), " ")
}

// isAlreadyRunningErr：incus 对"已在运行"实例的 Start 报错——恢复流程应容忍。
func isAlreadyRunningErr(err error) bool {
	return err != nil && strings.Contains(strings.ToLower(err.Error()), "already")
}
