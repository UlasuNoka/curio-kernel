#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

log_group "Check and Prepare ccache"

add_path "/usr/lib/ccache"

echo "Current ccache configuration:"
ccache -p

if [ -n "${CCACHE_DIR:-}" ] && [ -d "$CCACHE_DIR" ] && find "$CCACHE_DIR" -maxdepth 2 -type f -print -quit 2>/dev/null | grep -q .; then
  log_success "Restored cache found"
  echo ""
  echo "Pre-build cache statistics:"
  ccache -s | head -n 20

  echo "Updating atime to achieve cache eviction"
  find "$CCACHE_DIR" -type f -exec touch -t "$(date -d "1 day ago" +%Y%m%d%H%M)" {} +
else
  echo "[WARN] No existing cache - building from scratch"
  echo "Cache will be populated for future builds"
fi

ccache -z
if [ -n "${CCACHE_DIR:-}" ]; then
  rm -f "${CCACHE_DIR}/ccache.log"
fi

# Blacklist risky files from ccache (supported by cctv18 kernel ccache)
CONFIGS_C="${COMMON_KERNEL_FOLDER}/kernel/configs.c"
if [ -f "$CONFIGS_C" ]; then
  sed -i "1i // CI_RUN_ID: ${GITHUB_RUN_ID:-0}" "$CONFIGS_C"
  sed -i '1i // ccache:disable' "$CONFIGS_C"

  if head -n 1 "$CONFIGS_C" | grep -q "// ccache:disable"; then
    log_success "ccache is disabled for kernel/configs.c"
  else
    log_error "Failed to inject // ccache:disable into kernel/configs.c"
    exit 1
  fi
fi

log_endgroup
