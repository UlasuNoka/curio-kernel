#!/usr/bin/env bash
set -euo pipefail

# Determine base paths for the composite action
ACTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_ROOT="${ACTION_ROOT}/config"
DEFCONFIG_FRAGMENTS_DIR="${CONFIG_ROOT}/defconfig"

# Load global defaults
if [ -f "${CONFIG_ROOT}/defaults.conf" ]; then
  # shellcheck disable=SC1091
  source "${CONFIG_ROOT}/defaults.conf"
fi

# Logging helpers
log_group() {
  echo "::group::$*"
}

log_endgroup() {
  echo "::endgroup::"
}

log_info() {
  echo "[INFO]  $*"
}

log_success() {
  echo "[OK] $*"
}

log_warn() {
  echo "::warning::$*"
}

log_error() {
  echo "::error::$*" >&2
}

# GitHub Environment / Path / Output helpers
export_env() {
  local key="$1"
  local val="$2"
  export "${key}=${val}"
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "${key}=${val}" >> "$GITHUB_ENV"
  fi
}

add_path() {
  local dir="$1"
  export PATH="${dir}:${PATH}"
  if [ -n "${GITHUB_PATH:-}" ]; then
    echo "${dir}" >> "$GITHUB_PATH"
  fi
}

set_output() {
  local key="$1"
  local val="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$val" >> "$GITHUB_OUTPUT"
  fi
}

# Version comparison helpers (using sort -V)
# Returns 0 (true) if $1 <= $2
version_le() {
  local v1="$1"
  local v2="$2"
  [ "$(printf '%s\n' "$v1" "$v2" | sort -V | head -n1)" = "$v1" ]
}

# Returns 0 (true) if $1 >= $2
version_ge() {
  local v1="$1"
  local v2="$2"
  [ "$(printf '%s\n' "$v1" "$v2" | sort -V | tail -n1)" = "$v1" ]
}

# Append a Kconfig fragment file to target defconfig
append_defconfig_fragment() {
  local fragment_name="$1"
  local target_defconfig="$2"
  local fragment_path="${DEFCONFIG_FRAGMENTS_DIR}/${fragment_name}"

  if [ ! -f "$fragment_path" ]; then
    log_error "Defconfig fragment not found: $fragment_path"
    return 1
  fi

  cat "$fragment_path" >> "$target_defconfig"
  echo "" >> "$target_defconfig"
}

# Resilient Git clone supporting branches, tags, and exact 40-char commit SHAs
retry_clone() {
  local url="$1"
  local ref="${2:-main}"
  local target_dir="${3:-$(basename "$url" .git)}"
  local depth="${4:-1}"
  local max_attempts=3
  local attempt=1

  while [ $attempt -le $max_attempts ]; do
    echo "[RETRY] Attempt $attempt/$max_attempts: cloning $url (ref: $ref) -> $target_dir"
    rm -rf "$target_dir" 2>/dev/null || true

    if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
      mkdir -p "$target_dir"
      if (
        cd "$target_dir"
        git init -q
        git remote add origin "$url"
        if [ "$depth" != "0" ] && [ -n "$depth" ]; then
          git fetch --depth "$depth" origin "$ref"
        else
          git fetch origin "$ref"
        fi
        git checkout -q FETCH_HEAD
      ); then
        log_success "Cloned $url at commit $ref"
        return 0
      fi
    else
      local clone_args=(--branch "$ref")
      if [ "$depth" != "0" ] && [ -n "$depth" ]; then
        clone_args+=(--depth "$depth")
      fi
      if git clone "${clone_args[@]}" "$url" "$target_dir"; then
        log_success "Cloned $url ($ref)"
        return 0
      fi
    fi

    echo "[ERROR] Clone attempt $attempt failed, cleaning up..."
    rm -rf "$target_dir" 2>/dev/null || true
    sleep $((attempt * 5))
    attempt=$((attempt + 1))
  done

  log_error "All clone attempts failed for $url"
  return 1
}
