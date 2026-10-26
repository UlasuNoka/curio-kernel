#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

log_group "Validate Kernel Image & Collect Build Stats"

IMG="${COMMON_KERNEL_FOLDER}/out/arch/arm64/boot/Image"


if [ -f "${COMMON_KERNEL_FOLDER}/build.log" ]; then
  WARNINGS_COUNT="$(grep -ciE '\bwarning:' "${COMMON_KERNEL_FOLDER}/build.log" || true)"
  [ -n "$WARNINGS_COUNT" ] || WARNINGS_COUNT="0"
else
  WARNINGS_COUNT="0"
fi

if [ ! -f "$IMG" ]; then
  log_error "Kernel Image not found at: $IMG"
  exit 1
fi

if ! file "$IMG" | grep -qi 'ARM64'; then
  log_error "Image is not ARM64 format"
  file "$IMG"
  exit 1
fi

IMG_SIZE=$(stat -c %s "$IMG")
MIN_SIZE="${MIN_KERNEL_IMAGE_SIZE:-6102400}"
if [ "$IMG_SIZE" -lt "$MIN_SIZE" ]; then
  log_error "Image size too small: $(numfmt --to=iec-i --suffix=B "$IMG_SIZE")"
  exit 1
fi

IMG_SHA256=$(sha256sum "$IMG" | awk '{print $1}')
BUILD_TIME="${BUILD_TIME:-0}"

KERNEL_UNAME=$(strings "$IMG" | grep -E 'Linux version.*#' | tail -n1 || echo "unknown")
echo "Kernel Uname: $KERNEL_UNAME"

export_env "KERNEL_UNAME" "$KERNEL_UNAME"
export_env "WARNINGS_COUNT" "$WARNINGS_COUNT"
export_env "IMG_SHA256" "$IMG_SHA256"

set_output "kernel_version" "${KERNEL_FULL_VER}"
set_output "image_sha256" "$IMG_SHA256"

log_success "Validation passed:"
echo "   - Warnings: $WARNINGS_COUNT"
echo "   - Image size: $(numfmt --to=iec-i --suffix=B "$IMG_SIZE")"
echo "   - SHA256: $IMG_SHA256"
echo "   - Build time: ${BUILD_TIME}s"
log_endgroup

log_group "Create AnyKernel3 Flashable ZIP"

cp "$IMG" "${AK3_FOLDER}/Image"

if [ -f "${ARTIFACTS_FOLDER}/${CFG_MODEL}_${CFG_OS_VERSION}.txt" ]; then
  mv "${ARTIFACTS_FOLDER}/${CFG_MODEL}_${CFG_OS_VERSION}.txt" "${AK3_FOLDER}/"
fi

cd "$AK3_FOLDER"

sed -i 's/do.check_boot_version=.*/do.check_boot_version=1/' anykernel.sh

PLATFORM="${CFG_PLATFORM}"
case "$PLATFORM" in
  sm8850|sm8845)
    echo "Applying BBG efisp abl whitelist control patch"
    patch -p1 < "${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/bbg_efisp/0002-ak3-volume-efisp-toggle.patch"
    ;;
esac

TAG="${ARTIFACT_TAG:-$CFG_MODEL}"
ZIP_NAME="AK3_${TAG}_${CFG_OS_VERSION}_${KERNEL_FULL_VER}.zip"
mkdir -p "$ARTIFACTS_FOLDER"

echo "Creating flashable ZIP: $ZIP_NAME"

if ! zip -r9 "$ZIP_NAME" ./* \
     -x "*.git*" \
     -x "$ZIP_NAME" \
     -x "README.md" 2>&1 | tee "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/zip.log"; then
  log_error "Failed to create ZIP package"
  exit 1
fi

mv "$ZIP_NAME" "${ARTIFACTS_FOLDER}/"

find "$ARTIFACTS_FOLDER" -maxdepth 1 -type f ! -name "$ZIP_NAME" -delete

ZIP_SIZE=$(stat -c%s "${ARTIFACTS_FOLDER}/${ZIP_NAME}")
ZIP_SHA256=$(sha256sum "${ARTIFACTS_FOLDER}/${ZIP_NAME}" | awk '{print $1}')

export_env "ZIP_NAME" "$ZIP_NAME"
export_env "ZIP_SHA256" "$ZIP_SHA256"

set_output "zip_name" "$ZIP_NAME"

log_success "Kernel ZIP created successfully:"
echo "   - Name: $ZIP_NAME"
echo "   - Size: $(numfmt --to=iec-i --suffix=B "$ZIP_SIZE")"
echo "   - SHA256: $ZIP_SHA256"
log_endgroup

if [ "${BUILD_BOOT_IMAGE:-true}" = "true" ]; then
  log_group "Create GKI boot.img (Header v4 + VBMETA)"

  BOOT_PARTITION_SIZE="${CFG_BOOT_PARTITION_SIZE:-${DEFAULT_BOOT_PARTITION_SIZE:-100663296}}"
  BOOT_IMG_NAME="boot_${TAG}_${CFG_OS_VERSION}_${KERNEL_FULL_VER}.img"
  BOOT_IMG_PATH="${ARTIFACTS_FOLDER}/${BOOT_IMG_NAME}"

  MKBOOTIMG_BIN="$(command -v mkbootimg.py || command -v mkbootimg || true)"
  AVBTOOL_BIN="$(command -v avbtool.py || command -v avbtool || true)"

  if [ -n "$MKBOOTIMG_BIN" ] && [ -n "$AVBTOOL_BIN" ]; then
    python3 "$MKBOOTIMG_BIN" \
      --header_version 4 \
      --kernel "$IMG" \
      --cmdline "" \
      --pagesize 4096 \
      --output "$BOOT_IMG_PATH"

    python3 "$AVBTOOL_BIN" add_hash_footer \
      --image "$BOOT_IMG_PATH" \
      --partition_name boot \
      --partition_size "$BOOT_PARTITION_SIZE"

    BOOT_IMG_SIZE=$(stat -c%s "$BOOT_IMG_PATH")
    BOOT_IMG_SHA256=$(sha256sum "$BOOT_IMG_PATH" | awk '{print $1}')

    export_env "BOOT_IMG_NAME" "$BOOT_IMG_NAME"
    export_env "BOOT_IMG_SHA256" "$BOOT_IMG_SHA256"

    set_output "boot_img_name" "$BOOT_IMG_NAME"

    log_success "Standalone boot.img created successfully:"
    echo "   - Name: $BOOT_IMG_NAME"
    echo "   - Size: $(numfmt --to=iec-i --suffix=B "$BOOT_IMG_SIZE") (Partition target: $((BOOT_PARTITION_SIZE / 1024 / 1024)) MiB)"
    echo "   - SHA256: $BOOT_IMG_SHA256"
  else
    log_warn "mkbootimg or avbtool not found in PATH; skipping boot.img creation."
  fi

  log_endgroup
fi
