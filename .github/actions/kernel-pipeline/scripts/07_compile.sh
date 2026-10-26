#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

log_group "Build Kernel with ccache Optimization"

cd "$COMMON_KERNEL_FOLDER"
: > "${COMMON_KERNEL_FOLDER}/.scmversion"

export PYTHONWARNINGS="ignore:invalid escape sequence"

echo "Getting last commit timestamp from kernel source..."
COMMIT_TIMESTAMP=$(git log -1 --format=%ct 2>/dev/null || date +%s)

WORKSPACE="${GITHUB_WORKSPACE}"
MAP="-fdebug-prefix-map=${WORKSPACE}=."
MPMAP="-fmacro-prefix-map=${WORKSPACE}=."
FPMAP="-ffile-prefix-map=${WORKSPACE}=."

export KCFLAGS="${KCFLAGS:-} $MAP $MPMAP $FPMAP -no-canonical-prefixes -fdiagnostics-color=never -Qunused-arguments -Wno-unused-command-line-argument -D__ANDROID_COMMON_KERNEL__"
export KCPPFLAGS="${KCPPFLAGS:-} $MAP $MPMAP $FPMAP"

export LLVM=1 LLVM_IAS=1
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export PAHOLE="${KERNEL_PLATFORM_FOLDER}/prebuilts/kernel-build-tools/linux-x86/bin/pahole"
export LD=ld.lld HOSTLD=ld.lld AR=llvm-ar NM=llvm-nm
export OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip

cat << 'EOF' > "${COMMON_KERNEL_FOLDER}/ld-wrapper"
#!/bin/bash
ld.lld "$@" --thinlto-jobs=$(nproc --all)
EOF
chmod +x "${COMMON_KERNEL_FOLDER}/ld-wrapper"

KERNEL_BUILD_DATE=$(date -u)
export SOURCE_DATE_EPOCH=$COMMIT_TIMESTAMP

if [ -n "${CFG_BUILD_TIMESTAMP:-}" ]; then
  export KBUILD_BUILD_TIMESTAMP="$CFG_BUILD_TIMESTAMP"
  echo "Using custom build timestamp: $KBUILD_BUILD_TIMESTAMP"
else
  export KBUILD_BUILD_TIMESTAMP="$KERNEL_BUILD_DATE"
  echo "Using current UTC build timestamp: $KBUILD_BUILD_TIMESTAMP"
fi

export KBUILD_BUILD_USER="${BUILD_USER:-kleaf}"
export KBUILD_BUILD_HOST="${BUILD_HOST:-build-host}"
export KBUILD_BUILD_VERSION=1

echo "SOURCE_DATE_EPOCH: $SOURCE_DATE_EPOCH"
echo "Build user: $KBUILD_BUILD_USER"
echo "Build host: $KBUILD_BUILD_HOST"

export CC="ccache clang"
export CXX="ccache clang++"
export HOSTCC="ccache clang"
export HOSTCXX="ccache clang++"

if [ "${INPUT_CLEAN:-false}" = "false" ]; then
  echo "ccache-accelerated build"
else
  echo "Clean build mode"
fi

OUT=out
mkdir -p "$OUT"

log_info "Toolchain: $(clang --version 2>&1 | head -n1 || true)"

make LD="${COMMON_KERNEL_FOLDER}/ld-wrapper" HOSTLD="${COMMON_KERNEL_FOLDER}/ld-wrapper" O="$OUT" gki_defconfig

if [ "${CFG_OPTIMIZE_LEVEL:-O2}" = "O3" ]; then
  scripts/config --file "$OUT/.config" -d CC_OPTIMIZE_FOR_PERFORMANCE -e CC_OPTIMIZE_FOR_PERFORMANCE_O3
  KCFLAGS_EXTRA="-O3"
else
  scripts/config --file "$OUT/.config" -e CC_OPTIMIZE_FOR_PERFORMANCE -d CC_OPTIMIZE_FOR_PERFORMANCE_O3
  KCFLAGS_EXTRA="-O2"
fi

scripts/config --file "$OUT/.config" -e LTO_CLANG -d LTO_CLANG_NONE -d LTO_CLANG_THIN -d LTO_CLANG_FULL

case "${CFG_LTO}" in
  "none") scripts/config --file "$OUT/.config" -e LTO_CLANG_NONE ;;
  "thin") scripts/config --file "$OUT/.config" -e LTO_CLANG_THIN ;;
  "full") scripts/config --file "$OUT/.config" -e LTO_CLANG_FULL ;;
  *)
    log_error "Unsupported LTO option: ${CFG_LTO}"
    exit 1
    ;;
esac

make LD="${COMMON_KERNEL_FOLDER}/ld-wrapper" HOSTLD="${COMMON_KERNEL_FOLDER}/ld-wrapper" O="$OUT" olddefconfig

KCFLAGS="$KCFLAGS -Wno-error -pipe ${KCFLAGS_EXTRA}"
KCPPFLAGS="$KCPPFLAGS -DCONFIG_OPTIMIZE_INLINING"

log_info "Target: device=${CFG_MODEL} kernel=${KERNEL_FULL_VER} lto=${CFG_LTO} opt=${CFG_OPTIMIZE_LEVEL:-O2} jobs=$(nproc --all)"

BUILD_START=$(date +%s)

if [ "${INPUT_DEBUG:-false}" = "true" ]; then
  make V=1 LD="${COMMON_KERNEL_FOLDER}/ld-wrapper" HOSTLD="${COMMON_KERNEL_FOLDER}/ld-wrapper" -j"$(nproc --all)" O="$OUT" KCFLAGS="$KCFLAGS" KCPPFLAGS="$KCPPFLAGS" CONFIG_FAKE_DISABLE="${CONFIG_FAKE_DISABLE:-}" Image modules 2>&1 | tee build.log
  make V=1 LD="${COMMON_KERNEL_FOLDER}/ld-wrapper" HOSTLD="${COMMON_KERNEL_FOLDER}/ld-wrapper" -j"$(nproc --all)" O="${COMMON_KERNEL_FOLDER}/out" KCFLAGS="$KCFLAGS" KCPPFLAGS="$KCPPFLAGS" CONFIG_FAKE_DISABLE="${CONFIG_FAKE_DISABLE:-}" INSTALL_MOD_PATH="${COMMON_KERNEL_FOLDER}/out/install" modules_install 2>&1 | tee install.log

  cp build.log "${DEBUG_ARTIFACTS_FOLDER}/build.log"
  cp install.log "${DEBUG_ARTIFACTS_FOLDER}/install.log"
  rsync -av --no-links --exclude='build' "${COMMON_KERNEL_FOLDER}/out/install/lib/modules"/*/ "${DEBUG_ARTIFACTS_FOLDER}"
  cp "${COMMON_KERNEL_FOLDER}/out/vmlinux" "${DEBUG_ARTIFACTS_FOLDER}/vmlinux"
  cp "${COMMON_KERNEL_FOLDER}/out/Module.symvers" "${DEBUG_ARTIFACTS_FOLDER}/Module.symvers"
  cp "${COMMON_KERNEL_FOLDER}/out/System.map" "${DEBUG_ARTIFACTS_FOLDER}/System.map"

  ls -la "$DEBUG_ARTIFACTS_FOLDER"
else
  make LD="${COMMON_KERNEL_FOLDER}/ld-wrapper" HOSTLD="${COMMON_KERNEL_FOLDER}/ld-wrapper" -j"$(nproc --all)" O="$OUT" KCFLAGS="$KCFLAGS" KCPPFLAGS="$KCPPFLAGS" CONFIG_FAKE_DISABLE="${CONFIG_FAKE_DISABLE:-}" Image 2>&1 | tee build.log
fi

BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))

export_env "BUILD_TIME" "$BUILD_TIME"

IMG="${OUT}/arch/arm64/boot/Image"
if [ ! -f "$IMG" ]; then
  log_error "Kernel Image missing"
  log_group "Last 100 lines of build log"
  tail -n 100 build.log || echo "Build log not available"
  log_endgroup
  exit 1
fi

IMG_SIZE=$(stat -c%s "$IMG")

log_success "Built arch/arm64/boot/Image ($(numfmt --to=iec-i --suffix=B "$IMG_SIZE")) in $((BUILD_TIME / 60))m $((BUILD_TIME % 60))s"
ccache -s
log_endgroup
