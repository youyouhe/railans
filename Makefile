SHELL := /bin/bash
ROOT  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
CTL   := $(ROOT)control
BIN   := $(ROOT)bin
PKG   := railans-kit.tar.gz

.PHONY: all build build-linux build-all fmt vet test clean package check

all: build-linux

build:
	cd $(CTL) && go build -o $(BIN)/railans .

build-linux:
	cd $(CTL) && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o $(BIN)/railans-linux-amd64 .
	cd $(CTL) && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o $(BIN)/railans-linux-arm64 .

fmt:
	cd $(CTL) && go fmt ./...

vet:
	cd $(CTL) && go vet ./...

test:
	cd $(CTL) && go test ./...

check:
	@for f in scripts/*.sh node/*.sh client/*.sh; do echo "bash -n $$f"; bash -n "$$f"; done

package: build-linux check
	tar -czf $(ROOT)$(PKG) -C $(ROOT).. \
	    --exclude='railans-kit/bin/railans' \
	    --exclude='railans-kit/bin/railans.exe' \
	    railans-kit
	@echo "wrote $(ROOT)$(PKG)"

clean:
	rm -f $(BIN)/railans $(BIN)/railans-linux-amd64 $(BIN)/railans-linux-arm64 $(ROOT)$(PKG)

