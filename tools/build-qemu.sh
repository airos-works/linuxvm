#!/usr/bin/env bash
# Cross-build QEMU for air/OS with the air/OS SDK: the system emulator for
# the VM's architecture only, headless, with slirp networking, virtio-9p and,
# on x86_64, NVMM, patched with qemu/patches.
#
# x86_64: its libraries (GLib, libslirp) come from HaikuPorts, staged with
# airos-ci's deps/haikuports.py. arm64 has no HaikuPorts repository: GLib and
# libslirp are built here (with HaikuPorts' Haiku patches, qemu/deps-patches)
# against air/OS's arm64 libraries (libffi, PCRE2, libiconv) and shipped with
# QEMU in lib/linuxvm/lib.
#   ARCH=x86_64|arm64 tools/build-qemu.sh
#     -> build/ARCH/qemu-system-*, lib/ (arm64), firmware/ (x86_64)
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$AIROS_SDK/$ARCH/env.sh"
AIROS_CI=${AIROS_CI:-/mnt/HaikuWork/src/airos-ci}
GLIB_VERSION=2.90.1
GVDB_COMMIT=c6f2359cc1d00f16e0a0e2527fa0bc1882b8b5ab
SLIRP_VERSION=4.7.0
PRIVATE_LIBDIR=/boot/system/lib/linuxvm/lib

deps=$BUILD/qemu-deps
sys=$deps/boot/system

# compiler wrappers: QEMU's configure takes a cross prefix, not flags
bin=$BUILD/qemu-bin
mkdir -p "$bin" "$sys/lib/pkgconfig" "$sys/develop/lib/pkgconfig" "$sys/develop/headers"
for t in gcc g++; do
	cat > "$bin/$TRIPLET-$t" <<WRAP
#!/bin/sh
exec ${CROSS}$t --sysroot=$SYSROOT -specs=$UNWIND_SPECS -I$sys/develop/headers \\
	-I$SYSROOT/boot/system/develop/headers/private/libs/nvmm -L$sys/develop/lib -L$sys/lib \\
	-Wl,-rpath-link,$sys/lib "\$@"
WRAP
	chmod +x "$bin/$TRIPLET-$t"
done
for t in ar nm strip ranlib objcopy ld as readelf windres; do ln -sf "${CROSS}$t" "$bin/$TRIPLET-$t"; done
cat > "$bin/$TRIPLET-pkg-config" <<WRAP
#!/bin/sh
PKG_CONFIG_SYSROOT_DIR=$deps PKG_CONFIG_LIBDIR=$sys/lib/pkgconfig:$sys/develop/lib/pkgconfig exec pkg-config "\$@"
WRAP
chmod +x "$bin/$TRIPLET-pkg-config"
export PATH=$bin:$PATH

if [[ ! -f $deps/.staged ]]; then
	if [[ $ARCH == x86_64 ]]; then
		AIROS_CACHE=${AIROS_CACHE:-/data2/airos/cache} AIROS_SDK=$AIROS_SDK \
			python3 "$AIROS_CI/deps/haikuports.py" stage "$ARCH" "$sys" \
			glib2_devel libslirp_devel zlib_devel >/dev/null
		# HaikuPorts' .pc files name /packages/<package>/.self: the stage
		while read -r p; do
			mkdir -p "$deps$(dirname "$p")"
			ln -sfn ../../boot/system "$deps$p"
		done < <(grep -ho "/packages/[^/]*/.self" "$sys"/develop/lib/pkgconfig/*.pc | sort -u)
	else
		# air/OS's own arm64 libraries (deps/build-deps.sh)
		adeps=${AIROS_DEPS:-/data1/airos/deps/$ARCH/boot/system}
		for lib in libffi libpcre2-8 libiconv; do
			cp -a "$adeps"/lib/$lib.so* "$sys/lib/"
			ln -sfn "$(basename "$(readlink -f "$adeps/develop/lib/$lib.so")")" "$sys/lib/$lib.so"
		done
		cp -a "$adeps"/develop/headers/{ffi.h,ffitarget.h,iconv.h,pcre2.h} "$sys/develop/headers/"
		for pc in libffi.pc libpcre2-8.pc; do cp "$adeps/develop/lib/pkgconfig/$pc" "$sys/lib/pkgconfig/"; done
		cat > "$BUILD/haiku-$ARCH.cross" <<CROSSFILE
[binaries]
c = '$bin/$TRIPLET-gcc'
cpp = '$bin/$TRIPLET-g++'
ar = '$bin/$TRIPLET-ar'
strip = '$bin/$TRIPLET-strip'
pkg-config = '$bin/$TRIPLET-pkg-config'

[host_machine]
system = 'haiku'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['-D_BSD_SOURCE']
c_link_args = ['-lbsd', '-lgnu', '-lnetwork']
CROSSFILE
		meson_args=(--cross-file "$BUILD/haiku-$ARCH.cross" --prefix=/boot/system --libdir=lib
			--includedir=develop/headers --buildtype=release)
		# GLib, without gettext (proxy-libintl stands in) or anything QEMU does not use
		g=$BUILD/glib-$GLIB_VERSION
		rm -rf "$g"
		tar -C "$BUILD" -xzf "$(fetch "https://gitlab.gnome.org/GNOME/glib/-/archive/$GLIB_VERSION/glib-$GLIB_VERSION.tar.gz" "glib-$GLIB_VERSION.tar.gz")"
		(cd "$g" && git init -q && git add -A && git -c user.name=build -c user.email=build@airos.works commit -qm base \
			&& git -c user.name=build -c user.email=build@airos.works am -q "$ROOT/qemu/deps-patches/glib2-$GLIB_VERSION.patchset")
		rm -rf "$g/subprojects/gvdb"
		tar -C "$g/subprojects" -xzf "$(fetch "https://gitlab.gnome.org/GNOME/gvdb/-/archive/$GVDB_COMMIT.tar.gz" "gvdb-$GVDB_COMMIT.tar.gz")"
		mv "$g/subprojects/gvdb-$GVDB_COMMIT" "$g/subprojects/gvdb"
		meson setup "$g/build" "$g" "${meson_args[@]}" -Dtests=false -Dglib_debug=disabled \
			-Dintrospection=disabled -Dwerror=false -Dnls=disabled -Dman-pages=disabled \
			-Ddocumentation=false -Dlibmount=disabled -Dselinux=disabled -Dxattr=false \
			-Dsysprof=disabled -Dlibelf=disabled >/dev/null
		ninja -C "$g/build" -j"$JOBS" >/dev/null
		DESTDIR=$deps meson install -C "$g/build" --no-rebuild >/dev/null
		# libslirp
		s=$BUILD/libslirp-v$SLIRP_VERSION
		rm -rf "$s"
		tar -C "$BUILD" -xzf "$(fetch "https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v$SLIRP_VERSION/libslirp-v$SLIRP_VERSION.tar.gz" "libslirp-v$SLIRP_VERSION.tar.gz")"
		patch -d "$s" -p1 -s < "$ROOT/qemu/deps-patches/libslirp-$SLIRP_VERSION.patchset"
		meson setup "$s/build" "$s" "${meson_args[@]}" >/dev/null
		ninja -C "$s/build" -j"$JOBS" >/dev/null
		DESTDIR=$deps meson install -C "$s/build" --no-rebuild >/dev/null
	fi
	touch "$deps/.staged"
fi

src=$BUILD/qemu-$QEMU_VERSION
if [[ ! -f $src/.patched ]]; then
	rm -rf "$src"
	tar -C "$BUILD" -xf "$(fetch "https://download.qemu.org/qemu-$QEMU_VERSION.tar.xz" "qemu-$QEMU_VERSION.tar.xz")"
	for p in "$ROOT"/qemu/patches/*.patch; do patch -d "$src" -p1 -s < "$p"; done
	touch "$src/.patched"
fi
accel=(--enable-tcg)
[[ $ARCH != x86_64 ]] || accel+=(--enable-nvmm)
ldflags=()
[[ $ARCH == x86_64 ]] || ldflags=(--extra-ldflags="-Wl,-rpath,$PRIVATE_LIBDIR")
mkdir -p "$src/build-haiku"
cd "$src/build-haiku"
[[ -f build.ninja ]] || ../configure --cross-prefix="$TRIPLET-" --prefix=/boot/system \
	--target-list="$QEMU_TARGET-softmmu" --without-default-features \
	--enable-slirp "${accel[@]}" --enable-virtfs --enable-fdt=internal \
	--disable-docs --disable-werror "${ldflags[@]}" >/dev/null
ninja -j"$JOBS" "qemu-system-$QEMU_TARGET" >/dev/null
"${CROSS}strip" -o "$BUILD/qemu-system-$QEMU_TARGET" "qemu-system-$QEMU_TARGET"
if [[ $ARCH == x86_64 ]]; then
	mkdir -p "$BUILD/firmware"
	for f in bios-256k.bin kvmvapic.bin linuxboot_dma.bin; do cp "$src/pc-bios/$f" "$BUILD/firmware/"; done
else
	# only the private library directory, not the build tree's
	patchelf --force-rpath --set-rpath "$PRIVATE_LIBDIR" "$BUILD/qemu-system-$QEMU_TARGET"
	rm -rf "$BUILD/lib"
	mkdir -p "$BUILD/lib"
	for lib in libglib-2.0.so.0 libslirp.so.0 libintl.so.8 libiconv.so.2 libpcre2-8.so.0; do
		"${CROSS}strip" -o "$BUILD/lib/$lib" "$(readlink -f "$sys/lib/$lib")"
	done
fi
ls -la "$BUILD/qemu-system-$QEMU_TARGET"
