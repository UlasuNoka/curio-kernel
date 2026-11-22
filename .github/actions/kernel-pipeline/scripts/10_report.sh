#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

cd "$GITHUB_WORKSPACE"

active_features=()
[ "${CFG_HMBIRD:-false}" = "true" ] && active_features+=("hmbird")
[ "${CFG_OPT:-false}" = "true" ] && active_features+=("opt")
[ "${CFG_WAKELOCK_BLOCKER:-false}" = "true" ] && active_features+=("wakelock-blocker")
[ "${CFG_REKERNEL:-false}" = "true" ] && active_features+=("rekernel")
[ "${CFG_USB_SDP_900MA:-false}" = "true" ] && active_features+=("usb-sdp-900ma")
[ "${CFG_BBG:-false}" = "true" ] && active_features+=("bbg")
[ "${CFG_BBR3:-false}" = "true" ] && active_features+=("bbr3") || { [ "${CFG_BBR:-false}" = "true" ] && active_features+=("bbr"); }
[ "${CFG_TTL:-false}" = "true" ] && active_features+=("ttl")
[ "${CFG_IP_SET:-false}" = "true" ] && active_features+=("ipset")
[ "${CFG_UNICODE:-false}" = "true" ] && active_features+=("unicode")
[ "${CFG_NTSYNC:-false}" = "true" ] && active_features+=("ntsync")
[ "${CFG_CONTAINERS:-false}" = "true" ] && active_features+=("containers")
[ "${CFG_USB_GADGET:-false}" = "true" ] && active_features+=("usb-gadget")
FEATURES_STR="${active_features[*]:-none}"

{
  echo "Target       : ${CFG_MODEL} (${CFG_OS_VERSION})"
  echo "Kernel       : ${KERNEL_FULL_VER}"
  echo "Uname        : ${KERNEL_UNAME:-unknown}"
  echo "Identity     : ${BUILD_USER}@${BUILD_HOST}"
  echo "Toolchain    : ${CLANG_VERSION:-unknown}"
  echo "Profile      : opt=${CFG_OPTIMIZE_LEVEL:-O2} lto=${CFG_LTO:-none} clean=${INPUT_CLEAN:-false}"
  echo "Subsystems   : ${FEATURES_STR}"
  echo "Build Time   : ${BUILD_TIME:-0}s (warnings: ${WARNINGS_COUNT:-0})"
  if [ "${INPUT_CLEAN:-false}" = "false" ]; then
    echo "ccache       : hit=${CCACHE_HIT_RATE:-0.0%} direct=${CCACHE_DIRECT_RATE:-0.0%}"
  fi
  echo "Image SHA256 : ${IMG_SHA256:-unknown}"
  echo "AK3 Package  : ${ZIP_NAME:-none} (${ZIP_SHA256:-unknown})"
  if [ -n "${BOOT_IMG_NAME:-}" ]; then
    echo "Boot Image   : ${BOOT_IMG_NAME} (${BOOT_IMG_SHA256:-unknown})"
  fi
  if [ -n "${KMI_VERDICT:-}" ]; then
    echo "KMI Audit    : ${KMI_VERDICT} (mismatches=${KMI_CRC_MISMATCHES:-0} missing=${KMI_MISSING_SYMBOLS:-0} added=${KMI_ADDED_SYMBOLS:-0})"
  fi
} | tee summary.txt

{
  echo "### Curio Kernel Build Report"
  echo ""
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Target | \`${CFG_MODEL}\` (\`${CFG_OS_VERSION}\`) |"
  echo "| Kernel | \`${KERNEL_FULL_VER}\` |"
  echo "| Uname | \`${KERNEL_UNAME:-unknown}\` |"
  echo "| Toolchain | \`${CLANG_VERSION:-unknown}\` |"
  echo "| Profile | \`opt=${CFG_OPTIMIZE_LEVEL:-O2}\` \`lto=${CFG_LTO:-none}\` \`time=${BUILD_TIME:-0}s\` \`warnings=${WARNINGS_COUNT:-0}\` |"
  if [ "${INPUT_CLEAN:-false}" = "false" ]; then
    echo "| ccache | \`hit=${CCACHE_HIT_RATE:-0.0%}\` \`direct=${CCACHE_DIRECT_RATE:-0.0%}\` |"
  fi
  echo "| Subsystems | \`${FEATURES_STR}\` |"
  echo "| Image SHA256 | \`${IMG_SHA256:-unknown}\` |"
  echo "| AnyKernel3 ZIP | \`${ZIP_NAME:-unknown}\` (\`${ZIP_SHA256:-unknown}\`) |"
  if [ -n "${BOOT_IMG_NAME:-}" ]; then
    echo "| GKI Boot Image | \`${BOOT_IMG_NAME}\` (\`${BOOT_IMG_SHA256:-unknown}\`) |"
  fi
} >> "$GITHUB_STEP_SUMMARY"

if [ -n "${KMI_AUDIT_MD:-}" ] && [ -f "${KMI_AUDIT_MD}" ]; then
  {
    echo ""
    cat "${KMI_AUDIT_MD}"
  } >> "$GITHUB_STEP_SUMMARY"
fi
