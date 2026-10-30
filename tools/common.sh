# Sourced by the build scripts: paths and the air/OS SDK.
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ARCH=${ARCH:?set ARCH to x86_64 or arm64}
case $ARCH in
	x86_64) LINUX_ARCH=x86_64 GOARCH=amd64 ALPINE_ARCH=x86_64 QEMU_TARGET=x86_64 ;;
	arm64) LINUX_ARCH=arm64 GOARCH=arm64 ALPINE_ARCH=aarch64 QEMU_TARGET=aarch64 ;;
	*) echo "unknown architecture $ARCH" >&2; exit 1 ;;
esac
BUILD=${LINUXVM_BUILD:-$ROOT/build/$ARCH}
CACHE=${LINUXVM_CACHE:-${AIROS_CACHE:-$HOME/.cache}/linuxvm}
AIROS_SDK=${AIROS_SDK:-/data1/airos/sdk}
JOBS=${JOBS:-$(nproc)}
mkdir -p "$BUILD" "$CACHE"

QEMU_VERSION=10.2.0
LINUX_VERSION=6.18.52
ALPINE_VERSION=3.22
GO_LINUX_VERSION=1.27.3

fetch() { # fetch URL FILE: download into the cache once, print its path
	local url=$1 out=$CACHE/$2
	if [[ ! -s $out ]]; then
		curl -fsSL --retry 3 -o "$out.part" "$url" || { echo "download failed: $url" >&2; exit 1; }
		mv -f "$out.part" "$out"
	fi
	echo "$out"
}
