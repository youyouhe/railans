package main

import (
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"time"
)

type Proxy struct {
	mu     sync.Mutex
	ln     map[int]net.Listener
	active map[int]int // port -> live connection count
	store  *Store
	logger *log.Logger
}

func NewProxy(store *Store, logger *log.Logger) *Proxy {
	p := &Proxy{ln: map[int]net.Listener{}, active: map[int]int{}, store: store, logger: logger}
	go p.touchLoop()
	return p
}

// touchLoop refreshes last_used for ports with live connections: idle is
// judged by "nobody connected", never by traffic (SSH keepalives would make
// every attached session look active, but a quiet attached session must not
// be idle-stopped either).
func (p *Proxy) touchLoop() {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for range t.C {
		for _, port := range p.livePorts() {
			p.store.TouchByPort(port)
		}
	}
}

func (p *Proxy) livePorts() []int {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]int, 0, len(p.active))
	for port, n := range p.active {
		if n > 0 {
			out = append(out, port)
		}
	}
	return out
}

func (p *Proxy) markActive(port int) {
	p.mu.Lock()
	p.active[port]++
	p.mu.Unlock()
}

func (p *Proxy) markClosed(port int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.active[port] <= 1 {
		delete(p.active, port)
	} else {
		p.active[port]--
	}
}

func (p *Proxy) Add(port int, target string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, ok := p.ln[port]; ok {
		return nil
	}
	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		return fmt.Errorf("listen :%d: %w", port, err)
	}
	p.ln[port] = ln
	go p.accept(ln, port, target)
	p.logger.Printf("data plane :%d -> %s", port, target)
	return nil
}

func (p *Proxy) accept(ln net.Listener, port int, target string) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go p.pipe(conn, port, target)
	}
}

func (p *Proxy) pipe(down net.Conn, port int, target string) {
	defer down.Close()
	p.markActive(port)
	defer p.markClosed(port)
	p.store.TouchByPort(port)
	up, err := net.DialTimeout("tcp", target, 5*time.Second)
	if err != nil {
		p.logger.Printf("data plane :%d dial %s: %v", port, target, err)
		return
	}
	defer up.Close()
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(up, down)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(down, up)
		done <- struct{}{}
	}()
	<-done
}

func (p *Proxy) Remove(port int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if ln, ok := p.ln[port]; ok {
		_ = ln.Close()
		delete(p.ln, port)
	}
}

func (p *Proxy) Restore(boxes []*Box) {
	for _, b := range boxes {
		if b.State != "running" || b.VMIP == "" || b.SSHPort == 0 {
			continue
		}
		if err := p.Add(b.SSHPort, net.JoinHostPort(b.VMIP, "22")); err != nil {
			p.logger.Printf("restore %s: %v", b.Name, err)
		}
	}
}

func (p *Proxy) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for port, ln := range p.ln {
		_ = ln.Close()
		delete(p.ln, port)
	}
}
