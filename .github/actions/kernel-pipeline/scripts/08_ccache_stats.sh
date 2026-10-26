#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

log_group "ccache Final Statistics & Eviction"

export CCACHE_DIR="${CCACHE_DIR}"

echo "Clear temporary cache files..."
ccache -c

echo "Perform ccache eviction (unused > 12h)..."
find "$CCACHE_DIR" -type f -mmin +720 -delete
find "$CCACHE_DIR" -type d -empty -delete

if [ -n "${CCACHE_LOGFILE:-}" ] && [ -f "$CCACHE_LOGFILE" ]; then
  cp "$CCACHE_LOGFILE" "$CCACHE_DIR"
fi

if [ "${INPUT_DEBUG:-false}" = "true" ]; then
  if [ -n "${CCACHE_LOGFILE:-}" ] && [ -f "$CCACHE_LOGFILE" ]; then
    echo "Rename ccache log"
    LOG_DIR=$(dirname "$CCACHE_LOGFILE")
    NEW_LOG_NAME="${CFG_MODEL}_${CFG_OS_VERSION}_${KERNEL_FULL_VER}_ccache.log"
    mv "$CCACHE_LOGFILE" "${LOG_DIR}/${NEW_LOG_NAME}"
    export_env "CCACHE_LOGFILE" "${LOG_DIR}/${NEW_LOG_NAME}"
  else
    echo "[WARN] ccache log not found, skipping rename."
  fi
fi

read -r HIT_RATE DIRECT_RATE < <(python3 - << 'PYSTATS'
import re, subprocess
out = subprocess.check_output(["ccache", "-s"], text=True, errors="replace")
def grab(pat):
    m = re.search(pat, out, re.M)
    return int(m.group(1)) if m else 0
calls = grab(r"Cacheable calls:\s+(\d+)")
hits = grab(r"^\s*Hits:\s+(\d+)")
direct = grab(r"Direct:\s+(\d+)")
if calls > 0:
    print(f"{hits * 100.0 / calls:.1f} {direct * 100.0 / calls:.1f}")
else:
    print("0.0 0.0")
PYSTATS
)

export_env "CCACHE_HIT_RATE" "${HIT_RATE}%"
export_env "CCACHE_DIRECT_RATE" "${DIRECT_RATE}%"

log_endgroup

