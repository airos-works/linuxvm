#!/usr/bin/env bash
# Package the Linux VM for air/OS (after build-qemu, build-kernel,
# build-agent and build-initramfs):
#   ARCH=x86_64 tools/package-haiku-cross.sh   -> artifacts/linuxvm-*.hpkg
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$AIROS_SDK/$ARCH/env.sh"
PACKAGE_TOOL=${PACKAGE_TOOL:-$TOOLS/package/package}
VERSION=0.1.0~git.$(git -C "$ROOT" rev-list --count HEAD).$(git -C "$ROOT" rev-parse --short HEAD)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/linuxvm-pkg-XXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
mkdir -p "$STAGE/lib/linuxvm" "$STAGE/data/linuxvm/firmware" "$STAGE/documentation/packages/linuxvm" "$ROOT/artifacts"
cp "$BUILD/qemu-system-$QEMU_TARGET" "$STAGE/lib/linuxvm/"
cp "$BUILD/vmlinuz" "$BUILD/initramfs.img" "$STAGE/data/linuxvm/"
# x86_64 boots with SeaBIOS; arm64's virt machine needs no firmware but
# brings QEMU's own GLib and libslirp (lib/linuxvm/lib, its RPATH)
[[ ! -d $BUILD/firmware ]] || cp "$BUILD"/firmware/* "$STAGE/data/linuxvm/firmware/"
if [[ -d $BUILD/lib ]]; then
	mkdir -p "$STAGE/lib/linuxvm/lib"
	cp "$BUILD"/lib/* "$STAGE/lib/linuxvm/lib/"
fi
cp "$ROOT/README.md" "$STAGE/documentation/packages/linuxvm/"
cat > "$STAGE/.PackageInfo" <<PKGEOF
name linuxvm
version $VERSION-1
architecture $ARCH
summary "The Linux VM that runs Linux containers on air/OS"
description "A small Linux virtual machine for the Docker Engine: QEMU with NVMM acceleration, a Linux kernel and an Alpine userland whose init is containerd-linuxvm-agent. Containers from Linux images run in it with runc, with their own namespaces, cgroups and networks; their files stay on BFS, shared over virtio-9p. containerd-linuxvm (in the containerd package) starts it on demand."
packager "air/OS contributors"
vendor "air/OS"
copyrights { "2026 air/OS contributors" "Fabrice Bellard and the QEMU contributors" "Linus Torvalds and others" "The Alpine Linux contributors" }
licenses { "GNU GPL v2" "Apache v2" "MIT" }
provides {
    linuxvm = $VERSION
}
requires {
    haiku >= r1~beta5
    lib:libglib_2.0
    lib:libslirp
    lib:libz
}
PKGEOF
# arm64's QEMU carries its own GLib and libslirp
[[ $ARCH == x86_64 ]] || sed -i '/lib:libglib_2.0/d; /lib:libslirp/d' "$STAGE/.PackageInfo"
out="$ROOT/artifacts/linuxvm-$VERSION-1-$ARCH.hpkg"
rm -f "$out"
"$PACKAGE_TOOL" create -C "$STAGE" "$out"
ls -la "$out"
