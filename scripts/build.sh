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

setup_toolchain() {
	# LineageOS buildroot GCC 9.3 uses the "aarch64-linux-" prefix.
	local tc="${TOOLCHAIN_DIR:-$ROOT/tc}"
	if [ -d "$tc/bin" ]; then
		case ":$PATH:" in
			*":$tc/bin:"*) ;;
			*) export PATH="$tc/bin:$PATH" ;;
		esac
	fi
	export ARCH=arm64
	export SUBARCH=arm64
	export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-}"
	command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 || \
		echo "WARNING: ${CROSS_COMPILE}gcc not in PATH"
}

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
	patch_base_tree
	echo "   overlay applied"
}

# The 4.19 base tree (branch 'back') has a small number of call sites that do
# not match their prototypes at the pinned commit.  Patch them here so the
# tree builds; each patch is idempotent and verified.
patch_base_tree() {
	python3 - "$K" <<'PY'
import os
import sys

k = sys.argv[1]
edits = [
    # kernel/sched/fair.c: prefer_spread_on_idle() is declared
    #   static inline bool prefer_spread_on_idle(int cpu, bool new_ilb)
    # in kernel/sched/walt.h, but this call site passes one argument.
    ('kernel/sched/fair.c',
     'prefer_spread_on_idle(this_cpu)',
     'prefer_spread_on_idle(this_cpu, false)'),
]
for rel, old, new in edits:
    path = os.path.join(k, rel)
    if not os.path.exists(path):
        print(f'   WARNING: {rel} missing, skipping')
        continue
    src = open(path, errors='surrogateescape').read()
    if new in src and old not in src:
        print(f'   {rel}: already patched')
        continue
    if old not in src:
        print(f'   WARNING: pattern not found in {rel}')
        continue
    src = src.replace(old, new)
    open(path, 'w', errors='surrogateescape').write(src)
    print(f'   {rel}: patched ({old} -> {new})')
PY
}

do_config() {
	echo "== [2/4] generating .config (sdm660-perf + H7000 fragments)"
	setup_toolchain
	cd "$K"
	mkdir -p "$OUT"
	# Deterministic: always start from the vendor defconfig file itself.
	cp "arch/$ARCH/configs/vendor/sdm660-perf_defconfig" "$OUT/.config"
	./scripts/kconfig/merge_config.sh -m -O "$OUT" \
		"$OUT/.config" \
		"$ROOT/config/H7000.config" \
		"$ROOT/config/sdm660-common.config" || true

	# The CLO vendor defconfig leaves some int/hex symbols with an empty value.
	# Modern kconfig rejects those and then prompts interactively, which hangs
	# non-interactive builds, so give them explicit valid values.
	python3 - "$OUT/.config" <<'PY'
import re
import sys

path = sys.argv[1]
fixes = {'LITTLE_CPU_MASK': '0', 'BIG_CPU_MASK': '0'}
lines = open(path).read().splitlines()
out = []
for line in lines:
    m = re.match(r'^CONFIG_([A-Za-z0-9_]+)=(.*)$', line)
    if m and m.group(2).strip() == '':
        name = m.group(1)
        val = fixes.get(name, '0')
        print(f'   empty value for CONFIG_{name}, forcing {val}')
        out.append(f'CONFIG_{name}={val}')
    else:
        out.append(line)
have = {re.match(r'^CONFIG_([A-Za-z0-9_]+)=', l).group(1)
        for l in out if re.match(r'^CONFIG_([A-Za-z0-9_]+)=', l)}
for name, val in fixes.items():
    if name not in have:
        print(f'   missing CONFIG_{name}, adding {val}')
        out.append(f'CONFIG_{name}={val}')
open(path, 'w').write('\n'.join(out) + '\n')
PY

	# stdin from /dev/null: if kconfig ever tries to prompt, fail fast instead
	# of hanging the job.
	make -s O="$OUT" ARCH=$ARCH olddefconfig </dev/null

	if grep -nE '^CONFIG_[A-Za-z0-9_]+=$' "$OUT/.config"; then
		echo "   WARNING: empty-valued symbols remain in .config"
	else
		echo "   .config has no empty-valued symbols"
	fi
	echo "   --- effective device config ---"
	grep -E 'CONFIG_(TOUCHSCREEN_FTS|BACKLIGHT_KTZ8864|ARCH_SDM660|QCA_CLD_WLAN|PSTORE|LITTLE_CPU_MASK|BIG_CPU_MASK|LOCALVERSION)=' \
		"$OUT/.config" || true
}

do_build() {
	echo "== [3/4] building kernel (jobs=$JOBS)"
	setup_toolchain
	cd "$K"
	export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-dsh-ci}"
	export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-h7000}"
	# ccache has to be passed as a make command-line variable, otherwise the
	# kernel Makefile's own "CC = $(CROSS_COMPILE)gcc" wins over the environment.
	CCVAR=()
	if [ "${USE_CCACHE:-0}" = "1" ] && command -v ccache >/dev/null 2>&1; then
		CCVAR=("CC=ccache ${CROSS_COMPILE}gcc")
		echo "   ccache enabled: ${CCVAR[*]}"
	fi
	set -o pipefail
	# dtbs first: device-tree errors surface in ~1 minute instead of after a
	# full kernel compile.
	make -j"$JOBS" O="$OUT" "${CCVAR[@]}" KCFLAGS="-Wno-error" dtbs </dev/null 2>&1 | tee "$ROOT/build-dtbs.log"
	test -f "$OUT/arch/arm64/boot/dts/vendor/qcom/eebbk/sda660-mtp-H7000.dtb"
	make -j"$JOBS" O="$OUT" "${CCVAR[@]}" KCFLAGS="-Wno-error" Image.gz </dev/null 2>&1 | tee "$ROOT/build.log"
	test -f "$OUT/arch/arm64/boot/Image.gz"
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
