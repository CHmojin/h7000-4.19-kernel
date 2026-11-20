#!/usr/bin/env bash
# H7000 (BBK S5) msm-4.19 build driver.
#
# Usage:  bash scripts/build.sh [apply|config|build|package|all]
#
# Expects the kernel tree at $KERNEL_DIR (default: ./kernel) and the device
# overlay at ./overlay.  Everything it modifies lives inside the kernel tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="${KERNEL_DIR:-$ROOT/kernel}"
OUT="${OUT_DIR:-$K/out}"
ARCH=arm64
JOBS="${JOBS:-$(nproc)}"

# Stock BBK S5 (H7000) cmdline, verbatim from the vendor boot image.
CMDLINE="androidboot.console=0 androidboot.hardware=qcom ehci-hcd.park=3 loop.max_part=7 lpm_levels.sleep_disabled=1 msm_rtb.filter=0x37 printk.devkmsg=on sched_enable_hmp=1 sched_enable_power_aware=1 service_locator.enable=1 swiotlb=1 user_debug=31 androidboot.init_fatal_reboot_target=recovery androidboot.selinux=permissive buildvariant=eng"

die() { echo "ERROR: $*" >&2; exit 1; }

apply_overlay() {
	echo "== [1/4] applying device overlay into $K"
	[ -d "$K" ] || die "kernel tree not found: $K"
	cp -a "$ROOT/overlay/." "$K/"

	# Register the H7000 dtb.  The vendor dts Makefile accumulates dtb-y and
	# then snapshots it in 'always := $(dtb-y)', so the entry must be
	# inserted *before* that line.
	local mk="$K/arch/arm64/boot/dts/vendor/qcom/Makefile"
	python3 - "$mk" <<-'PY'
	import re, sys
	p = sys.argv[1]
	s = open(p).read()
	line = 'dtb-$(CONFIG_ARCH_SDM660) += eebbk/sda660-mtp-H7000.dtb'
	if line in s:
	    print('   dtb entry already present')
	else:
	    s2, n = re.subn(r'(?m)^always\s*:=\s*\$\(dtb-y\)',
	                    line + r'\n\1', s, count=1)
	    if n != 1:
	        sys.exit('cannot find "always := $(dtb-y)" in ' + p)
	    open(p, 'w').write(s2)
	    print('   inserted dtb entry')
	PY

	# Backlight driver (KTZ8864 init driver) registration
	local blk="$K/drivers/video/backlight/Kconfig"
	local blm="$K/drivers/video/backlight/Makefile"
	if ! grep -q 'BACKLIGHT_KTZ8864' "$blk"; then
		cat >>"$blk" <<-'EOF'

		config BACKLIGHT_KTZ8864
			tristate "KTZ8864 backlight controller init driver"
			depends on I2C
			help
			  Minimal I2C driver for the KTZ8864 LCD backlight controller
			  (PWM dimming) used on the BBK S5 (H7000).
		EOF
	fi
	if ! grep -q 'ktz8864' "$blm"; then
		echo 'obj-$(CONFIG_BACKLIGHT_KTZ8864) += ktz8864.o' >>"$blm"
	fi
	echo "   overlay applied"
}

do_config() {
	echo "== [2/4] generating .config (sdm660-perf + H7000 fragments)"
	cd "$K"
	mkdir -p "$OUT"
	if ! make -s O="$OUT" ARCH=$ARCH sdm660-perf_defconfig; then
		echo "   vendor defconfig target unavailable, copying file"
		cp "arch/$ARCH/configs/vendor/sdm660-perf_defconfig" "$OUT/.config"
	fi
	./scripts/kconfig/merge_config.sh -m -O "$OUT" \
		"$OUT/.config" \
		"$ROOT/config/H7000.config" \
		"$ROOT/config/sdm660-common.config" || true
	make -s O="$OUT" ARCH=$ARCH olddefconfig
	grep -E 'CONFIG_(TOUCHSCREEN_FTS|BACKLIGHT_KTZ8864|ARCH_SDM660|LOCALVERSION)=' "$OUT/.config" || true
}

do_build() {
	echo "== [3/4] building kernel (jobs=$JOBS)"
	cd "$K"
	export ARCH SUBARCH=$ARCH
	export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
	export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-dsh-ci}"
	export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-h7000}"
	if [ "${USE_CCACHE:-0}" = "1" ] && command -v ccache >/dev/null 2>&1; then
		export CC="ccache ${CROSS_COMPILE}gcc"
		echo "   ccache enabled: $CC"
	fi
	make -j"$JOBS" O="$OUT" KCFLAGS="-Wno-error" Image.gz dtbs 2>&1 | tee "$ROOT/build.log"
	test -f "$OUT/arch/arm64/boot/Image.gz"
	test -f "$OUT/arch/arm64/boot/dts/vendor/qcom/eebbk/sda660-mtp-H7000.dtb"
}

do_package() {
	echo "== [4/4] packaging boot.img"
	mkdir -p "$ROOT/artifacts"
	python3 "$ROOT/scripts/mkbootimg.py" \
		--kernel "$OUT/arch/arm64/boot/Image.gz" \
		--dtb "$OUT/arch/arm64/boot/dts/vendor/qcom/eebbk/sda660-mtp-H7000.dtb" \
		--ramdisk "$ROOT/ramdisk/ramdisk.cpio.gz" \
		--cmdline "$CMDLINE" \
		--out "$ROOT/artifacts/boot-H7000-4.19.img"
	cp "$OUT/arch/arm64/boot/Image.gz" "$ROOT/artifacts/"
	cp "$OUT/arch/arm64/boot/dts/vendor/qcom/eebbk/sda660-mtp-H7000.dtb" "$ROOT/artifacts/"
	cp "$OUT/.config" "$ROOT/artifacts/config-4.19-h7000" 2>/dev/null || true
	cp "$OUT/System.map" "$ROOT/artifacts/" 2>/dev/null || true
	ls -l "$ROOT/artifacts"
}

stage="${1:-all}"
case "$stage" in
	apply)   apply_overlay ;;
	config)  do_config ;;
	build)   do_build ;;
	package) do_package ;;
	all)     apply_overlay; do_config; do_build; do_package ;;
	*)       die "unknown stage: $stage" ;;
esac
