#!/usr/bin/env bash
# The VM's initramfs: Alpine's runc and iptables, the agent as /init.
#   ARCH=x86_64|arm64 tools/build-initramfs.sh   (after build-agent.sh)
set -euo pipefail
. "$(dirname "$0")/common.sh"
python3 "$ROOT/tools/mkrootfs.py" --arch "$ALPINE_ARCH" --alpine "$ALPINE_VERSION" \
	--agent "$BUILD/agent" --cache "$CACHE/alpine" --out "$BUILD/initramfs.img"
