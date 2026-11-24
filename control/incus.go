package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

type Incus struct {
	Bin       string
	BaseImage string
	Profile   string
}

func (i *Incus) run(ctx context.Context, timeout time.Duration, args ...string) (string, error) {
	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(cctx, i.Bin, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("incus %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

func networkConfig(ip string, prefix int, gateway string) string {
	// Do NOT use set-name: the interface is already named (e.g. enp5s0) when
	// cloud-init applies this config on first boot, and a rename that fails
	// leaves the whole eth0 stanza unmatched — no address, no route. Match the
	// real name pattern instead and let the kernel name stand.
	return fmt.Sprintf(`version: 2
ethernets:
  nic0:
    match:
      name: "en*"
    dhcp4: false
    addresses:
      - %s/%d
    routes:
      - to: default
        via: %s
    nameservers:
      addresses: [223.5.5.5, 119.29.29.29]
`, ip, prefix, gateway)
}

func (i *Incus) Launch(ctx context.Context, name, node, ip string, prefix int, gateway string) error {
	args := []string{
		"launch", i.BaseImage, name,
		"--vm",
		"--profile", i.Profile,
		"--target", node,
		"--config", "cloud-init.network-config=" + networkConfig(ip, prefix, gateway),
	}
	_, err := i.run(ctx, 10*time.Minute, args...)
	return err
}

func (i *Incus) WaitReady(ctx context.Context, name string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		if _, err := i.run(ctx, 30*time.Second, "exec", name, "--", "true"); err == nil {
			break
		} else {
			lastErr = err
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("vm %s not ready after %s: %w", name, timeout, lastErr)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
	// The agent starts before sshd; returning at agent-ready lets an
	// immediate data-plane connection RST against a not-yet-listening sshd.
	// Wait until port 22 accepts inside the VM before declaring ready.
	for {
		if _, err := i.run(ctx, 10*time.Second, "exec", name, "--",
			"bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/22"); err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("vm %s agent ready but sshd not accepting after %s", name, timeout)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

type instanceJSON struct {
	State struct {
		Status  string `json:"status"`
		Network map[string][]struct {
			Address string `json:"address"`
			Scope   string `json:"scope"`
			Family  string `json:"family"`
		} `json:"network"`
	} `json:"state"`
}

type incusInstance struct {
	Name     string
	Status   string
	Location string
	IP       string
}

// List 返回集群全部实例的对账所需字段（name/status/location/首个全局 IPv4）。
func (i *Incus) List(ctx context.Context) ([]incusInstance, error) {
	out, err := i.run(ctx, 30*time.Second, "list", "--format", "json")
	if err != nil {
		return nil, err
	}
	var raw []struct {
		Name     string `json:"name"`
		Status   string `json:"status"`
		Location string `json:"location"`
		State    struct {
			Network map[string]struct {
				Addresses []struct {
					Address string `json:"address"`
					Family  string `json:"family"`
					Scope   string `json:"scope"`
				} `json:"addresses"`
			} `json:"network"`
		} `json:"state"`
	}
	if err := json.Unmarshal([]byte(out), &raw); err != nil {
		return nil, fmt.Errorf("parse incus list: %w", err)
	}
	outp := make([]incusInstance, 0, len(raw))
	for _, r := range raw {
		it := incusInstance{Name: r.Name, Status: r.Status, Location: r.Location}
		for _, netif := range r.State.Network {
			for _, a := range netif.Addresses {
				if a.Family == "inet" && a.Scope == "global" && it.IP == "" {
					it.IP = a.Address
				}
			}
		}
		outp = append(outp, it)
	}
	return outp, nil
}

func (i *Incus) inspect(ctx context.Context, name string) (*instanceJSON, error) {
	out, err := i.run(ctx, 30*time.Second, "list", name, "--format", "json")
	if err != nil {
		return nil, err
	}
	var arr []instanceJSON
	if err := json.Unmarshal([]byte(out), &arr); err != nil {
		return nil, fmt.Errorf("parse incus list: %w", err)
	}
	if len(arr) == 0 {
		return nil, fmt.Errorf("instance %s not found", name)
	}
	return &arr[0], nil
}

func (i *Incus) IP(ctx context.Context, name string) (string, error) {
	inst, err := i.inspect(ctx, name)
	if err != nil {
		return "", err
	}
	for _, addrs := range inst.State.Network {
		for _, a := range addrs {
			if a.Family == "inet" && a.Scope == "global" {
				return a.Address, nil
			}
		}
	}
	return "", fmt.Errorf("instance %s has no global IPv4 address yet", name)
}

func (i *Incus) State(ctx context.Context, name string) (string, error) {
	inst, err := i.inspect(ctx, name)
	if err != nil {
		return "", err
	}
	return inst.State.Status, nil
}

func (i *Incus) PushKey(ctx context.Context, name, pubkey string) error {
	if _, err := i.run(ctx, 30*time.Second, "exec", name, "--", "install", "-d", "-o", "dev", "-g", "dev", "-m", "700", "/home/dev/.ssh"); err != nil {
		return err
	}
	f, err := os.CreateTemp("", "railans-key-*.pub")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(strings.TrimSpace(pubkey) + "\n"); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if _, err := i.run(ctx, 30*time.Second, "file", "push", f.Name(), name+"/home/dev/.ssh/authorized_keys", "--uid", "1000", "--gid", "1000", "--mode", "0600"); err != nil {
		return err
	}
	_, err = i.run(ctx, 30*time.Second, "exec", name, "--", "chown", "dev:dev", "/home/dev/.ssh/authorized_keys")
	return err
}

// orcaUnpackScript guest 侧解压 + wrapper 写入，与 scripts/build-base-image-local.sh
// 注入段现行命令逐字同款（H2 后移时领地内复用，不造新机制）。
const orcaUnpackScript = `mkdir -p /home/dev/mincli && tar -xzf /home/dev/orca-cli.tar.gz -C /home/dev/mincli && chmod +x /home/dev/mincli/cli/index.js && printf '#!/usr/bin/env bash\nexec node /home/dev/mincli/cli/index.js "$@"\n' > /usr/local/bin/orca && chmod 755 /usr/local/bin/orca`

// ProvisionAssets 把宿主侧资产按箱注入 guest（H2，railans-kit#7：凭据出镜像，
// 注入时机后移到 ensureBox，镜像保持零凭据）。命令形态与构建脚本现行 guest 侧一致：
// db 走 file push（--uid 1000 --gid 1000 --mode 600），orca 走 file push tar +
// guest 内解压写 /usr/local/bin/orca wrapper。
// assets 两键均空 = 注入关闭（no-op，零配置/testbed 行为不变，不硬依赖宿主文件）；
// 配置了但源缺失返回 error（ensureBox 包装为 asset_push_failed，loud）。
func (i *Incus) ProvisionAssets(ctx context.Context, name string, assets BoxAssets) error {
	if assets.CCSwitchDB == "" && assets.OrcaTar == "" {
		return nil
	}
	if assets.CCSwitchDB != "" {
		if _, err := os.Stat(assets.CCSwitchDB); err != nil {
			return fmt.Errorf("box asset source not found: %s", assets.CCSwitchDB)
		}
		if _, err := i.run(ctx, 2*time.Minute, "file", "push", "--uid", "1000", "--gid", "1000", "--mode", "600",
			assets.CCSwitchDB, name+"/home/dev/.cc-switch/cc-switch.db"); err != nil {
			return fmt.Errorf("push cc-switch.db: %w", err)
		}
	}
	if assets.OrcaTar != "" {
		if _, err := os.Stat(assets.OrcaTar); err != nil {
			return fmt.Errorf("box asset source not found: %s", assets.OrcaTar)
		}
		if _, err := i.run(ctx, 5*time.Minute, "file", "push", assets.OrcaTar, name+"/home/dev/orca-cli.tar.gz"); err != nil {
			return fmt.Errorf("push orca tar: %w", err)
		}
		if _, err := i.run(ctx, 5*time.Minute, "exec", name, "--", "bash", "-c", orcaUnpackScript); err != nil {
			return fmt.Errorf("unpack orca tar: %w", err)
		}
	}
	return nil
}

// AssetsPresent 探测 guest 内配置的资产是否齐备（H2 复用路径幂等自愈的依据，
// 对齐 sshd.go PushKey 幂等自愈惯例）。一次 exec（~百毫秒级）；两键均空视为齐备；
// 探测 exec 失败按「缺」处理——上层据此补推，补推失败仅 WARN 不阻断复用。
func (i *Incus) AssetsPresent(ctx context.Context, name string, assets BoxAssets) bool {
	var conds []string
	if assets.CCSwitchDB != "" {
		conds = append(conds, "test -f /home/dev/.cc-switch/cc-switch.db")
	}
	if assets.OrcaTar != "" {
		conds = append(conds, "test -f /usr/local/bin/orca")
	}
	if len(conds) == 0 {
		return true
	}
	_, err := i.run(ctx, 30*time.Second, "exec", name, "--", "bash", "-c", strings.Join(conds, " && "))
	return err == nil
}

func (i *Incus) Start(ctx context.Context, name string) error {
	_, err := i.run(ctx, 2*time.Minute, "start", name)
	return err
}

func (i *Incus) Stop(ctx context.Context, name string) error {
	_, err := i.run(ctx, 2*time.Minute, "stop", name)
	return err
}

func (i *Incus) Delete(ctx context.Context, name string) error {
	_, err := i.run(ctx, 2*time.Minute, "delete", name, "--force")
	return err
}

func (i *Incus) Snapshot(ctx context.Context, name, snap string) error {
	_, err := i.run(ctx, 2*time.Minute, "snapshot", "create", name, snap)
	return err
}
