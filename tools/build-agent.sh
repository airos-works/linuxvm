#!/usr/bin/env bash
# Build containerd-linuxvm-agent (the VM's init) from an airos-works/containerd
# checkout, static, with a stock Go toolchain (the air/OS one gives Linux
# binaries an interpreter).
#   ARCH=x86_64|arm64 tools/build-agent.sh CONTAINERD_DIR  -> build/ARCH/agent
set -euo pipefail
. "$(dirname "$0")/common.sh"
containerd=$(realpath "${1:?usage: build-agent.sh CONTAINERD_DIR}")
go=${LINUX_GO:-}
if [[ -z $go ]]; then
	goroot=$CACHE/go-$GO_LINUX_VERSION
	if [[ ! -x $goroot/bin/go ]]; then
		mkdir -p "$goroot.tmp"
		tar -C "$goroot.tmp" -xzf "$(fetch "https://go.dev/dl/go$GO_LINUX_VERSION.linux-amd64.tar.gz" "go$GO_LINUX_VERSION.linux-amd64.tar.gz")"
		mv "$goroot.tmp/go" "$goroot" && rmdir "$goroot.tmp"
	fi
	go=$goroot/bin/go
fi
(cd "$containerd" && GOOS=linux GOARCH=$GOARCH CGO_ENABLED=0 GOFLAGS=-mod=vendor GOTOOLCHAIN=local GOROOT= \
	GOCACHE=${GOCACHE:-$CACHE/gocache} "$go" build -trimpath -ldflags="-s -w" -o "$BUILD/agent" ./cmd/containerd-linuxvm-agent)
ls -la "$BUILD/agent"
