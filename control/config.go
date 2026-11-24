package main

import (
	"fmt"
	"net"
	"os"
	"time"

	"gopkg.in/yaml.v3"
)

type NodeConfig struct {
	Name    string `yaml:"name"`
	Address string `yaml:"address"`
	Subnet  string `yaml:"subnet"`
	Gateway string `yaml:"gateway"`
	// per-node 静态上限（内部任务单 Phase 1）：该节点可同时存在的箱数
	// （全状态计数，含 creating/stopped/deleting，与 CountByNode 同口径）。
	// 0/缺省 = 不设节点上限，仅全局 limits.max_boxes 生效（向后兼容：
	// 无 max_boxes 的旧 config 照常启动）；配了动态余量地板后此字段是保底闸。
	MaxBoxes int `yaml:"max_boxes"`
}

type VMConfig struct {
	CPUs   int    `yaml:"cpus"`
	Memory string `yaml:"memory"`
	Disk   string `yaml:"disk"`
}

type Limits struct {
	BoxTTL      string `yaml:"box_ttl"`
	IdleStop    string `yaml:"idle_stop"`
	MaxBoxes    int    `yaml:"max_boxes"`
	MaxPerKey   int    `yaml:"max_boxes_per_key"`
	MaxPerIPDay int    `yaml:"max_creates_per_ip_per_day"`
}

type Security struct {
	EnrollCode    string `yaml:"enroll_code"`
	RequireEnroll bool   `yaml:"require_enroll"`
	AllowedCIDR   string `yaml:"allowed_source_cidr"`
}

type CaddyConfig struct {
	ConfPath  string   `yaml:"conf_path"`
	ReloadCmd []string `yaml:"reload_cmd"`
}

// BoxAssets 宿主侧按箱注入的资产源（H2，railans-kit#7）：凭据与 orca 包不进
// 镜像，由 ensureBox 在交付前 incus file push。两键均缺省空 = 注入关闭
// （零配置/testbed 行为不变）；配置了但源文件缺失 → asset_push_failed（loud，
// 不悄悄发出没 keys 的箱）。
type BoxAssets struct {
	CCSwitchDB string `yaml:"cc_switch_db"`
	OrcaTar    string `yaml:"orca_tar"`
}

type Config struct {
	Listen        string `yaml:"listen"`
	ControlHost   string `yaml:"control_host"`
	PublicHost    string `yaml:"public_host"`
	PreviewDomain string `yaml:"preview_domain"`
	// 公网预览子域（如 boxes.example.org，经 Cloudflare Tunnel 暴露）。
	// 设置后 Caddy 站点同时声明 box-x.<preview_domain> 与 box-x.<preview_public_domain>。
	PreviewPublicDomain string       `yaml:"preview_public_domain"`
	PreviewPort         int          `yaml:"preview_port"`
	StateFile           string       `yaml:"state_file"`
	HostKeyFile         string       `yaml:"host_key_file"`
	IncusBin            string       `yaml:"incus_bin"`
	BaseImage           string       `yaml:"base_image"`
	Profile             string       `yaml:"profile"`
	Bridge              string       `yaml:"bridge"`
	StorageDriver       string       `yaml:"storage_driver"`
	PortRange           []int        `yaml:"port_range"`
	Nodes               []NodeConfig `yaml:"nodes"`
	VM                  VMConfig     `yaml:"vm"`
	Limits              Limits       `yaml:"limits"`
	Security            Security     `yaml:"security"`
	Caddy               CaddyConfig  `yaml:"caddy"`
	// H2：镜像零凭据，交付前按箱注入（缺省空 = 注入关闭）。
	BoxAssets BoxAssets `yaml:"box_assets"`
	// L5：命令级审计 JSONL 落点；缺省 = state 同目录 audit.jsonl，"off" 关闭。
	AuditFile string `yaml:"audit_file"`
}

func LoadConfig(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func (c *Config) validate() error {
	if c.Listen == "" {
		c.Listen = ":22"
	}
	if c.ControlHost == "" {
		c.ControlHost = "new.box.lan"
	}
	if c.PreviewDomain == "" {
		c.PreviewDomain = "box.lan"
	}
	if c.PreviewPort == 0 {
		c.PreviewPort = 8080
	}
	if c.StateFile == "" {
		c.StateFile = "/var/lib/railans/state.json"
	}
	if c.HostKeyFile == "" {
		c.HostKeyFile = "/var/lib/railans/ssh_host_ed25519_key"
	}
	if c.IncusBin == "" {
		c.IncusBin = "incus"
	}
	if c.BaseImage == "" {
		c.BaseImage = "dev-base"
	}
	if c.Profile == "" {
		c.Profile = "dev"
	}
	if c.Bridge == "" {
		c.Bridge = "br-vm"
	}
	if len(c.PortRange) == 0 {
		c.PortRange = []int{22000, 22999}
	}
	if len(c.PortRange) != 2 || c.PortRange[0] < 1024 || c.PortRange[1] <= c.PortRange[0] {
		return fmt.Errorf("port_range must be [min,max] with min>=1024 and max>min")
	}
	if len(c.Nodes) == 0 || len(c.Nodes) > 32 {
		return fmt.Errorf("nodes must contain 1..32 entries")
	}
	seen := map[string]bool{}
	for i := range c.Nodes {
		n := &c.Nodes[i]
		if n.Name == "" || n.Address == "" || n.Subnet == "" || n.Gateway == "" {
			return fmt.Errorf("node %d: name/address/subnet/gateway are required", i)
		}
		if seen[n.Name] {
			return fmt.Errorf("duplicate node name %q", n.Name)
		}
		seen[n.Name] = true
		if net.ParseIP(n.Address) == nil || net.ParseIP(n.Gateway) == nil {
			return fmt.Errorf("node %s: invalid address or gateway", n.Name)
		}
		if n.MaxBoxes < 0 {
			return fmt.Errorf("node %s: max_boxes must be >= 0 (0 = no per-node limit)", n.Name)
		}
		_, ipnet, err := net.ParseCIDR(n.Subnet)
		if err != nil {
			return fmt.Errorf("node %s: invalid subnet: %w", n.Name, err)
		}
		ones, bits := ipnet.Mask.Size()
		if bits != 32 || ones != 24 {
			return fmt.Errorf("node %s: subnet must be IPv4 /24", n.Name)
		}
		if !ipnet.Contains(net.ParseIP(n.Gateway)) {
			return fmt.Errorf("node %s: gateway %s is outside %s", n.Name, n.Gateway, n.Subnet)
		}
	}
	if c.PublicHost == "" {
		c.PublicHost = c.Nodes[0].Address
	}
	if c.Limits.BoxTTL == "" {
		c.Limits.BoxTTL = "168h"
	}
	if c.Limits.IdleStop == "" {
		c.Limits.IdleStop = "30m"
	}
	if _, err := time.ParseDuration(c.Limits.BoxTTL); err != nil {
		return fmt.Errorf("limits.box_ttl: %w", err)
	}
	if _, err := time.ParseDuration(c.Limits.IdleStop); err != nil {
		return fmt.Errorf("limits.idle_stop: %w", err)
	}
	if c.Limits.MaxBoxes == 0 {
		c.Limits.MaxBoxes = 12
	}
	if c.Limits.MaxPerKey == 0 {
		c.Limits.MaxPerKey = 1
	}
	if c.Limits.MaxPerIPDay == 0 {
		c.Limits.MaxPerIPDay = 3
	}
	if c.Security.AllowedCIDR != "" {
		if _, _, err := net.ParseCIDR(c.Security.AllowedCIDR); err != nil {
			return fmt.Errorf("security.allowed_source_cidr: %w", err)
		}
	}
	if c.Security.RequireEnroll && (c.Security.EnrollCode == "" || c.Security.EnrollCode == "change-me") {
		return fmt.Errorf("security.enroll_code must be set to a long random value when require_enroll is true")
	}
	if c.Caddy.ConfPath == "" {
		c.Caddy.ConfPath = "/etc/caddy/conf.d/boxes.caddy"
	}
	return nil
}

func (c *Config) BoxTTL() time.Duration {
	d, _ := time.ParseDuration(c.Limits.BoxTTL)
	return d
}

func (c *Config) IdleStop() time.Duration {
	d, _ := time.ParseDuration(c.Limits.IdleStop)
	return d
}

func (c *Config) NodeByName(name string) *NodeConfig {
	for i := range c.Nodes {
		if c.Nodes[i].Name == name {
			return &c.Nodes[i]
		}
	}
	return nil
}

func (c *Config) NodeByAddress(addr string) *NodeConfig {
	for i := range c.Nodes {
		if c.Nodes[i].Address == addr {
			return &c.Nodes[i]
		}
	}
	return nil
}
