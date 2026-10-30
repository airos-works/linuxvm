#!/usr/bin/env bash
# Cross-build QEMU for air/OS with the air/OS SDK: the system emulator for
# the VM's architecture only, headless, with NVMM (x86_64), slirp networking
# and virtio-9p, patched with qemu/patches. Its libraries (GLib, libslirp)
# come from HaikuPorts, staged with airos-ci's deps/haikuports.py.
#   ARCH=x86_64 tools/build-qemu.sh   -> build/ARCH/qemu-system-*, firmware/
set -euo pipefail
. "$(dirname "$0")/common.sh"
[[ $ARCH == x86_64 ]] || { echo "QEMU for $ARCH: its libraries (GLib, libslirp) are not built for air/OS $ARCH yet" >&2; exit 1; }
. "$AIROS_SDK/$ARCH/env.sh"
AIROS_CI=${AIROS_CI:-/mnt/HaikuWork/src/airos-ci}

deps=$BUILD/qemu-deps
if [[ ! -f $deps/.staged ]]; then
	AIROS_CACHE=${AIROS_CACHE:-/data2/airos/cache} AIROS_SDK=$AIROS_SDK \
		python3 "$AIROS_CI/deps/haikuports.py" stage "$ARCH" "$deps/boot/system" \
		glib2_devel libslirp_devel zlib_devel >/dev/null
	# HaikuPorts' .pc files name /packages/<package>/.self: the stage
	while read -r p; do
		mkdir -p "$deps$(dirname "$p")"
		ln -sfn ../../boot/system "$deps$p"
	done < <(grep -ho "/packages/[^/]*/.self" "$deps"/boot/system/develop/lib/pkgconfig/*.pc | sort -u)
	touch "$deps/.staged"
fi

# compiler wrappers: QEMU's configure takes a cross prefix, not flags
bin=$BUILD/qemu-bin
mkdir -p "$bin"
for t in gcc g++; do
	cat > "$bin/$TRIPLET-$t" <<WRAP
#!/bin/sh
exec ${CROSS}$t --sysroot=$SYSROOT -specs=$UNWIND_SPECS -I$deps/boot/system/develop/headers \\
	-I$SYSROOT/boot/system/develop/headers/private/libs/nvmm -L$deps/boot/system/develop/lib \\
	-Wl,-rpath-link,$deps/boot/system/lib "\$@"
WRAP
	chmod +x "$bin/$TRIPLET-$t"
done
for t in ar nm strip ranlib objcopy ld as readelf windres; do ln -sf "${CROSS}$t" "$bin/$TRIPLET-$t"; done
cat > "$bin/$TRIPLET-pkg-config" <<WRAP
#!/bin/sh
PKG_CONFIG_SYSROOT_DIR=$deps PKG_CONFIG_LIBDIR=$deps/boot/system/develop/lib/pkgconfig exec pkg-config "\$@"
WRAP
chmod +x "$bin/$TRIPLET-pkg-config"

src=$BUILD/qemu-$QEMU_VERSION
if [[ ! -f $src/.patched ]]; then
	rm -rf "$src"
	tar -C "$BUILD" -xf "$(fetch "https://download.qemu.org/qemu-$QEMU_VERSION.tar.xz" "qemu-$QEMU_VERSION.tar.xz")"
	for p in "$ROOT"/qemu/patches/*.patch; do patch -d "$src" -p1 -s < "$p"; done
	touch "$src/.patched"
fi
mkdir -p "$src/build-haiku"
cd "$src/build-haiku"
export PATH=$bin:$PATH
[[ -f build.ninja ]] || ../configure --cross-prefix="$TRIPLET-" --prefix=/boot/system \
	--target-list="$QEMU_TARGET-softmmu" --without-default-features \
	--enable-slirp --enable-nvmm --enable-tcg --enable-virtfs --enable-fdt=internal \
	--disable-docs --disable-werror >/dev/null
ninja -j"$JOBS" "qemu-system-$QEMU_TARGET" >/dev/null
"${CROSS}strip" -o "$BUILD/qemu-system-$QEMU_TARGET" "qemu-system-$QEMU_TARGET"
mkdir -p "$BUILD/firmware"
for f in bios-256k.bin kvmvapic.bin linuxboot_dma.bin; do cp "$src/pc-bios/$f" "$BUILD/firmware/"; done
ls -la "$BUILD/qemu-system-$QEMU_TARGET"
