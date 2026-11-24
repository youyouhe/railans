package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/gliderlabs/ssh"
)

func main() {
	configPath := flag.String("config", "/etc/railans/config.yaml", "path to config file")
	flag.Parse()

	logger := log.New(os.Stderr, "railans ", log.LstdFlags|log.LUTC)
	cfg, err := LoadConfig(*configPath)
	if err != nil {
		logger.Fatalf("config: %v", err)
	}
	store, err := OpenStore(cfg.StateFile)
	if err != nil {
		logger.Fatalf("state: %v", err)
	}

	incus := &Incus{Bin: cfg.IncusBin, BaseImage: cfg.BaseImage, Profile: cfg.Profile}

	// A "creating" record that survived a restart is an orphan: creation is
	// single-process and driven by an SSH session that died with the old
	// process. Without this sweep the owning key is locked out of `new`
	// until TTL (P1).
	sweepOrphanCreating(store, incus, logger)

	proxy := NewProxy(store, logger)
	caddy := &Caddy{
		Path:         cfg.Caddy.ConfPath,
		Domain:       cfg.PreviewDomain,
		PublicDomain: cfg.PreviewPublicDomain,
		Port:         cfg.PreviewPort,
		ReloadCmd:    cfg.Caddy.ReloadCmd,
		Logger:       logger,
	}
	ctl := &Control{
		cfg:    cfg,
		store:  store,
		incus:  incus,
		proxy:  proxy,
		caddy:  caddy,
		logger: logger,
	}

	proxy.Restore(store.AllBoxes())
	caddy.Sync(store.AllBoxes())

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	ctl.ctx = ctx
	go ctl.Reap(ctx)
	go func() {
		<-ctx.Done()
		proxy.Close()
	}()

	if err := ctl.Serve(); err != nil && err != ssh.ErrServerClosed {
		logger.Fatalf("serve: %v", err)
	}
}

// sweepOrphanCreating destroys leftovers from a previous process. For every
// "creating" record: delete the VM, then drop the record. If the VM cannot be
// deleted yet (incus may still be running the create operation), the record
// is kept as "deleting" so the IP/port stay reserved and the reap loop
// retries — dropping the record anyway would strand an orphan VM (P2 rule).
func sweepOrphanCreating(store *Store, incus *Incus, logger *log.Logger) {
	for _, b := range store.AllBoxes() {
		if b.State != "creating" {
			continue
		}
		logger.Printf("startup sweep: orphaned creating box %s, deleting VM and record", b.Name)
		if err := incus.Delete(context.Background(), b.Name); err != nil {
			logger.Printf("startup sweep: delete VM %s: %v (record kept as deleting for retry)", b.Name, err)
			b.State = "deleting"
			_ = store.PutBox(b)
			continue
		}
		if err := store.DeleteBox(b.Name); err != nil {
			logger.Printf("startup sweep: drop record %s: %v", b.Name, err)
		}
	}
}
