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

sed -i 's/do\.check_boot_version=.*/do.check_boot_version=1/' anykernel.sh

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

TARGET_BASE="${GITHUB_WORKSPACE}/${CFG_TARGET_DIR:-targets/${CFG_MODEL}}"

if [ "${BUILD_BOOT_IMAGE:-true}" = "true" ] && [ "${CFG_BOOT_STUB:-}" = "none" ]; then
  log_info "Skipping standalone boot.img packaging (boot_stub=none)"
elif [ "${BUILD_BOOT_IMAGE:-true}" = "true" ]; then
  log_group "Create GKI boot.img (OEM Stub + magiskboot)"

  BOOT_IMG_NAME="boot_${TAG}_${CFG_OS_VERSION}_${KERNEL_FULL_VER}.img"
  BOOT_IMG_PATH="${ARTIFACTS_FOLDER}/${BOOT_IMG_NAME}"
  MAGISKBOOT_BIN="${KERNEL_PATCHES_FOLDER}/bin/magiskboot"

  if [ ! -x "$MAGISKBOOT_BIN" ]; then
    chmod +x "$MAGISKBOOT_BIN" 2>/dev/null || true
  fi

  if [ ! -f "$MAGISKBOOT_BIN" ]; then
    log_error "magiskboot binary not found at: $MAGISKBOOT_BIN"
    exit 1
  fi

  STUB_DIR="${TARGET_BASE}/stubs"
  if [ -n "${CFG_BOOT_STUB:-}" ] && [ -f "${STUB_DIR}/${CFG_BOOT_STUB}" ]; then
    BOOT_STUB_PATH="${STUB_DIR}/${CFG_BOOT_STUB}"
  else
    log_error "Configured boot_stub not found: ${STUB_DIR#"${GITHUB_WORKSPACE}/"}/${CFG_BOOT_STUB:-<unset>}"
    exit 1
  fi

  echo "Using OEM boot stub: ${BOOT_STUB_PATH#"${GITHUB_WORKSPACE}/"}"

  REPACK_WORK_DIR="$(mktemp -d)"
  tar -I 'zstd -d' -xf "$BOOT_STUB_PATH" -O > "${REPACK_WORK_DIR}/donor.img"
  cp "$IMG" "${REPACK_WORK_DIR}/kernel"

  (
    cd "$REPACK_WORK_DIR"
    "$MAGISKBOOT_BIN" repack donor.img "$BOOT_IMG_PATH"
  )

  rm -rf "$REPACK_WORK_DIR"

  if [ ! -f "$BOOT_IMG_PATH" ]; then
    log_error "Failed to repack boot.img via magiskboot"
    exit 1
  fi

  BOOT_IMG_SIZE=$(stat -c%s "$BOOT_IMG_PATH")
  BOOT_IMG_SHA256=$(sha256sum "$BOOT_IMG_PATH" | awk '{print $1}')

  export_env "BOOT_IMG_NAME" "$BOOT_IMG_NAME"
  export_env "BOOT_IMG_SHA256" "$BOOT_IMG_SHA256"

  set_output "boot_img_name" "$BOOT_IMG_NAME"

  log_success "Standalone boot.img created successfully:"
  echo "   - Name: $BOOT_IMG_NAME"
  echo "   - Size: $(numfmt --to=iec-i --suffix=B "$BOOT_IMG_SIZE")"
  echo "   - SHA256: $BOOT_IMG_SHA256"

  log_endgroup
fi

if [ -d "${GKI_VERIFIER_FOLDER:-}/gki_verifier" ]; then
  log_group "Verify KMI / vABI Compatibility"

  BASELINE_DIR="${TARGET_BASE}/baselines"
  KMI_BASELINE_PATH=""
  if [ "${CFG_KMI_BASELINE:-}" = "none" ]; then
    log_warn "KMI audit skipped (kmi_baseline=none)"
  elif [ -n "${CFG_KMI_BASELINE:-}" ] && [ -f "${BASELINE_DIR}/${CFG_KMI_BASELINE}" ]; then
    KMI_BASELINE_PATH="${BASELINE_DIR}/${CFG_KMI_BASELINE}"
  else
    log_error "Configured kmi_baseline not found: ${BASELINE_DIR#"${GITHUB_WORKSPACE}/"}/${CFG_KMI_BASELINE:-<unset>}"
    exit 1
  fi
  if [ -n "$KMI_BASELINE_PATH" ] && [ -f "$KMI_BASELINE_PATH" ]; then
    AUDIT_TARGET="${BOOT_IMG_PATH:-$IMG}"
    KMI_JSON="${ARTIFACTS_FOLDER}/kmi_audit.json"
    KMI_MD="${ARTIFACTS_FOLDER}/kmi_audit.md"
    echo "Running KMI / vABI audit against baseline: ${KMI_BASELINE_PATH#"${GITHUB_WORKSPACE}/"}"

    set +e
    PYTHONPATH="${GKI_VERIFIER_FOLDER}" python3 -m gki_verifier diff \
      "$KMI_BASELINE_PATH" "$AUDIT_TARGET" \
      --json "$KMI_JSON" --markdown "$KMI_MD"
    KMI_RC=$?
    set -e

    if [ -f "$KMI_JSON" ]; then
      KMI_VERDICT=$(jq -r '.verdict' "$KMI_JSON")
      KMI_MISMATCHES=$(jq -r '.summary.crc_mismatches' "$KMI_JSON")
      KMI_MISSING=$(jq -r '.summary.missing_symbols' "$KMI_JSON")
      KMI_ADDED=$(jq -r '.summary.added_symbols' "$KMI_JSON")

      export_env "KMI_VERDICT" "$KMI_VERDICT"
      export_env "KMI_CRC_MISMATCHES" "$KMI_MISMATCHES"
      export_env "KMI_MISSING_SYMBOLS" "$KMI_MISSING"
      export_env "KMI_ADDED_SYMBOLS" "$KMI_ADDED"
      export_env "KMI_AUDIT_MD" "$KMI_MD"

    fi

    if [ "$KMI_RC" -ne 0 ]; then
      if [ -f "$KMI_MD" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        cat "$KMI_MD" >> "$GITHUB_STEP_SUMMARY"
      fi
      log_error "KMI / vABI mismatch detected against ${KMI_BASELINE_PATH#"${GITHUB_WORKSPACE}/"} (exit code $KMI_RC)"
      log_endgroup
      exit "$KMI_RC"
    fi

    log_success "KMI / vABI audit passed (0 mismatches, 0 missing)"
  fi

  log_endgroup
fi
