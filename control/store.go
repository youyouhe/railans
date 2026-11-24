package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"syscall"
	"time"
)

type Key struct {
	Fingerprint string    `json:"fingerprint"`
	Label       string    `json:"label"`
	CreatedAt   time.Time `json:"created_at"`
}

type Box struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	KeyFP     string    `json:"key_fp"`
	Node      string    `json:"node"`
	VMIP      string    `json:"vm_ip"`
	SSHPort   int       `json:"ssh_port"`
	State     string    `json:"state"` // creating | running | stopped | deleting
	CreatorIP string    `json:"creator_ip"`
	Shared    bool      `json:"shared"`
	CreatedAt time.Time `json:"created_at"`
	LastUsed  time.Time `json:"last_used"`
	ExpiresAt time.Time `json:"expires_at"`
}

type State struct {
	Boxes    map[string]*Box        `json:"boxes"`
	Keys     map[string]*Key        `json:"keys"`
	Creates  map[string][]time.Time `json:"creates"`
	NextPort int                    `json:"next_port"`
}

type Store struct {
	mu     sync.Mutex
	path   string
	lockFD int // singleton guard: flock held for the process lifetime
	state  State
}

// OpenStore loads the state file and takes an exclusive non-blocking flock on
// <path>.lock for the lifetime of the process. A second instance sharing the
// same state file would split-brain (two writers, port/IP double-allocation),
// so it is refused here instead (F4).
func OpenStore(path string) (*Store, error) {
	lockFD, err := syscall.Open(path+".lock", syscall.O_CREAT|syscall.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open lock %s: %w", path+".lock", err)
	}
	if err := syscall.Flock(lockFD, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		syscall.Close(lockFD)
		return nil, fmt.Errorf("another railans instance is already using %s (flock held)", path)
	}
	s := &Store{path: path, lockFD: lockFD}
	raw, err := os.ReadFile(path)
	switch {
	case err == nil:
		if err := json.Unmarshal(raw, &s.state); err != nil {
			return nil, fmt.Errorf("parse state %s: %w", path, err)
		}
	case errors.Is(err, os.ErrNotExist):
		// fresh state
	default:
		return nil, err
	}
	if s.state.Boxes == nil {
		s.state.Boxes = map[string]*Box{}
	}
	if s.state.Keys == nil {
		s.state.Keys = map[string]*Key{}
	}
	if s.state.Creates == nil {
		s.state.Creates = map[string][]time.Time{}
	}
	return s, nil
}

// Close releases the singleton lock. The process normally exits holding it.
func (s *Store) Close() error {
	if s.lockFD > 0 {
		err := syscall.Close(s.lockFD)
		s.lockFD = 0
		return err
	}
	return nil
}

func (s *Store) saveLocked() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

func (s *Store) Enroll(fp, label string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.Keys[fp] = &Key{Fingerprint: fp, Label: label, CreatedAt: time.Now().UTC()}
	return s.saveLocked()
}

func (s *Store) IsEnrolled(fp string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.state.Keys[fp]
	return ok
}

func (s *Store) BoxByKey(fp string) *Box {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, b := range s.state.Boxes {
		if b.KeyFP == fp && b.State != "deleted" {
			return b
		}
	}
	return nil
}

func (s *Store) BoxByName(name string) *Box {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.state.Boxes[name]
}

func (s *Store) ListByKey(fp string) []*Box {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []*Box
	for _, b := range s.state.Boxes {
		if b.KeyFP == fp && b.State != "deleted" {
			out = append(out, b)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	return out
}

func (s *Store) AllBoxes() []*Box {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]*Box, 0, len(s.state.Boxes))
	for _, b := range s.state.Boxes {
		if b.State != "deleted" {
			out = append(out, b)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	return out
}

func (s *Store) PutBox(b *Box) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.Boxes[b.Name] = b
	return s.saveLocked()
}

func (s *Store) DeleteBox(name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.state.Boxes, name)
	return s.saveLocked()
}

func (s *Store) Touch(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if b, ok := s.state.Boxes[name]; ok {
		b.LastUsed = time.Now().UTC()
		_ = s.saveLocked()
	}
}

func (s *Store) TouchByPort(port int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, b := range s.state.Boxes {
		if b.SSHPort == port {
			b.LastUsed = time.Now().UTC()
			_ = s.saveLocked()
			return
		}
	}
}

func (s *Store) AllocPort(min, max int) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	used := map[int]bool{}
	for _, b := range s.state.Boxes {
		if b.State != "deleted" {
			used[b.SSHPort] = true
		}
	}
	start := s.state.NextPort
	if start < min || start > max {
		start = min
	}
	width := max - min + 1
	for i := 0; i < width; i++ {
		p := min + ((start - min + i) % width)
		if !used[p] {
			s.state.NextPort = p + 1
			if s.state.NextPort > max {
				s.state.NextPort = min
			}
			return p, nil
		}
	}
	return 0, errors.New("ssh port pool exhausted")
}

func (s *Store) AllocIP(node *NodeConfig) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ipnet, err := net.ParseCIDR(node.Subnet)
	if err != nil {
		return "", err
	}
	base := ipnet.IP.To4()
	if base == nil {
		return "", fmt.Errorf("node %s: not an IPv4 subnet", node.Name)
	}
	used := map[string]bool{}
	for _, b := range s.state.Boxes {
		if b.State != "deleted" {
			used[b.VMIP] = true
		}
	}
	for i := 10; i <= 250; i++ {
		ip := net.IPv4(base[0], base[1], base[2], byte(i)).String()
		if !used[ip] {
			return ip, nil
		}
	}
	return "", fmt.Errorf("node %s: ip pool exhausted", node.Name)
}

// AllowCreate records a creation attempt and reports whether the per-IP daily
// quota allows it. Records older than 24h are pruned first.
func (s *Store) AllowCreate(ip string, limit int) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	cutoff := time.Now().Add(-24 * time.Hour)
	arr := s.state.Creates[ip]
	kept := arr[:0]
	for _, t := range arr {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= limit {
		s.state.Creates[ip] = kept
		_ = s.saveLocked()
		return false
	}
	s.state.Creates[ip] = append(kept, time.Now().UTC())
	_ = s.saveLocked()
	return true
}

func (s *Store) CountByNode() map[string]int {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]int{}
	for _, b := range s.state.Boxes {
		if b.State != "deleted" {
			out[b.Node]++
		}
	}
	return out
}
