#!/usr/bin/env bash
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
    NEW_LOG_NAME="${OP_MODEL}_${OP_OS_VERSION}_${KERNEL_FULL_VER}_ccache.log"
    mv "$CCACHE_LOGFILE" "${LOG_DIR}/${NEW_LOG_NAME}"
    export_env "CCACHE_LOGFILE" "${LOG_DIR}/${NEW_LOG_NAME}"
  else
    echo "[WARN] ccache log not found, skipping rename."
  fi
fi

STATS="$(ccache -s)"

CACHEABLE=$(echo "$STATS" | awk '/Cacheable calls:/ {
  match($0, /[0-9]+/);
  print substr($0, RSTART, RLENGTH)
}' | head -n1)

HITS=$(echo "$STATS" | awk '/^[[:space:]]*Hits:/ {
  match($0, /[0-9]+/);
  print substr($0, RSTART, RLENGTH)
}' | head -n1)

DIRECT=$(echo "$STATS" | awk '/Direct:/ {
  match($0, /[0-9]+/);
  print substr($0, RSTART, RLENGTH)
}' | head -n1)

if [ "${CACHEABLE:-0}" -gt 0 ]; then
  HIT_RATE=$(awk -v h="${HITS:-0}" -v c="$CACHEABLE" 'BEGIN{printf "%.1f", (h/c)*100}')
  DIRECT_RATE=$(awk -v d="${DIRECT:-0}" -v c="$CACHEABLE" 'BEGIN{printf "%.1f", (d/c)*100}')
else
  HIT_RATE="0.0"
  DIRECT_RATE="0.0"
fi

export_env "CCACHE_HIT_RATE" "${HIT_RATE}%"
export_env "CCACHE_DIRECT_RATE" "${DIRECT_RATE}%"

set_output "hit_rate" "${HIT_RATE}%"
set_output "direct_rate" "${DIRECT_RATE}%"

log_endgroup

{
  echo "## ccache Statistics"
  echo ""
  echo '```'
  ccache -s --verbose
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
