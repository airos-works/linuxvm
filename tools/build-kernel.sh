#!/usr/bin/env bash
# Build the VM's Linux kernel: upstream Linux with kernel/linuxvm.config
# merged into the architecture's defconfig and the KVM guest fragment,
# everything built in (no modules).
#   ARCH=x86_64|arm64 tools/build-kernel.sh      -> build/ARCH/vmlinuz
set -euo pipefail
. "$(dirname "$0")/common.sh"
src=$BUILD/linux-$LINUX_VERSION
if [[ ! -d $src ]]; then
	tar -C "$BUILD" -xf "$(fetch "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$LINUX_VERSION.tar.xz" "linux-$LINUX_VERSION.tar.xz")"
fi
# objtool needs libelf's headers; take them from the distribution's
# packages without installing anything.
hostelf=$CACHE/hostlibelf
if [[ ! -f /usr/include/gelf.h && ! -f $hostelf/usr/include/gelf.h ]]; then
	mkdir -p "$hostelf/debs"
	(cd "$hostelf/debs" && apt-get download libelf-dev libelf1t64 zlib1g-dev libzstd-dev >/dev/null)
	for d in "$hostelf"/debs/*.deb; do dpkg-deb -x "$d" "$hostelf"; done
fi
make_args=(-C "$src" O="$BUILD/kernel" -j"$JOBS"
	HOSTCFLAGS="-I$hostelf/usr/include" HOSTLDFLAGS="-L$hostelf/usr/lib/x86_64-linux-gnu -Wl,-rpath,$hostelf/usr/lib/x86_64-linux-gnu")
image=arch/x86/boot/bzImage defconfig=x86_64_defconfig
if [[ $ARCH == arm64 ]]; then
	make_args+=(ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-})
	image=arch/arm64/boot/Image defconfig=defconfig
fi
mkdir -p "$BUILD/kernel"
make "${make_args[@]}" "$defconfig" >/dev/null
(cd "$BUILD/kernel" && "$src/scripts/kconfig/merge_config.sh" -m .config \
	"$src/kernel/configs/kvm_guest.config" "$ROOT/kernel/linuxvm.config" >/dev/null)
make "${make_args[@]}" olddefconfig >/dev/null
make "${make_args[@]}" "$(basename "$image")" >/dev/null
cp "$BUILD/kernel/$image" "$BUILD/vmlinuz"
ls -la "$BUILD/vmlinuz"
