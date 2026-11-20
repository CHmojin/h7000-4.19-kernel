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

register_dtb() {
	local mk="$K/arch/arm64/boot/dts/vendor/qcom/Makefile"
	python3 - "$mk" <<'PY'
import re
import sys

path = sys.argv[1]
src = open(path).read()
entry = 'dtb-$(CONFIG_ARCH_SDM660) += eebbk/sda660-mtp-H7000.dtb'
if entry in src:
    print('   dtb entry already present')
    sys.exit(0)
pat = re.compile(r'(?m)^(always[ \t]*:=[ \t]*\$\(dtb-y\))')
new, count = pat.subn(lambda m: entry + '\n' + m.group(1), src, count=1)
if count != 1:
    sys.exit('cannot find "always := $(dtb-y)" in ' + path)
open(path, 'w').write(new)
print('   dtb entry inserted')
PY
}

register_backlight() {
	local kconfig="$K/drivers/video/backlight/Kconfig"
	local makefile="$K/drivers/video/backlight/Makefile"

	if ! grep -q 'BACKLIGHT_KTZ8864' "$kconfig"; then
		{
			printf '\n'
			printf 'config BACKLIGHT_KTZ8864\n'
			printf '\ttristate "KTZ8864 backlight controller init driver"\n'
			printf '\tdepends on I2C\n'
			printf '\thelp\n'
			printf '\t  Minimal I2C driver for the KTZ8864 LCD backlight controller\n'
			printf '\t  (PWM dimming) used on the BBK S5 (H7000).\n'
		} >>"$kconfig"
		echo '   Kconfig: BACKLIGHT_KTZ8864 added'
	fi
	if ! grep -q 'ktz8864' "$makefile"; then
		echo 'obj-$(CONFIG_BACKLIGHT_KTZ8864) += ktz8864.o' >>"$makefile"
		echo '   Makefile: ktz8864.o added'
	fi
}

apply_overlay() {
	echo "== [1/4] applying device overlay into $K"
	[ -d "$K" ] || die "kernel tree not found: $K"
	cp -a "$ROOT/overlay/." "$K/"
	register_dtb
	register_backlight
	echo "   overlay applied"
}

do_config() {
	echo "== [2/4] generating .config (sdm660-perf + H7000 fragments)"
	cd "$K"
	mkdir -p "$OUT"
	if ! make -s O="$OUT" ARCH=$ARCH sdm660-perf_defconfig; then
		echo "   vendor defconfig target unavailable, copying file instead"
		cp "arch/$ARCH/configs/vendor/sdm660-perf_defconfig" "$OUT/.config"
	fi
	./scripts/kconfig/merge_config.sh -m -O "$OUT" \
		"$OUT/.config" \
		"$ROOT/config/H7000.config" \
		"$ROOT/config/sdm660-common.config" || true
	make -s O="$OUT" ARCH=$ARCH olddefconfig
	echo "   --- effective device config ---"
	grep -E 'CONFIG_(TOUCHSCREEN_FTS|BACKLIGHT_KTZ8864|ARCH_SDM660|QCA_CLD_WLAN|PSTORE|LOCALVERSION)=' \
		"$OUT/.config" || true
}

do_build() {
	echo "== [3/4] building kernel (jobs=$JOBS)"
	cd "$K"
	export ARCH=arm64
	export SUBARCH=arm64
	export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
	export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-dsh-ci}"
	export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-h7000}"
	if [ "${USE_CCACHE:-0}" = "1" ] && command -v ccache >/dev/null 2>&1; then
		export CC="ccache ${CROSS_COMPILE}gcc"
		echo "   ccache enabled: $CC"
	fi
	set -o pipefail
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
