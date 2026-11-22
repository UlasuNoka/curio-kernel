#!/usr/bin/env bash
set -euo pipefail

ACTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_ROOT="${ACTION_ROOT}/config"
DEFCONFIG_FRAGMENTS_DIR="${CONFIG_ROOT}/fragments"

if [ -f "${CONFIG_ROOT}/defaults.conf" ]; then
  # shellcheck disable=SC1091
  source "${CONFIG_ROOT}/defaults.conf"
fi

log_group() {
  echo "::group::$*"
}

log_endgroup() {
  echo "::endgroup::"
}

log_info() {
  echo "[INFO] $*"
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

version_le() {
  local v1="$1"
  local v2="$2"
  [ "$(printf '%s\n' "$v1" "$v2" | sort -V | head -n1)" = "$v1" ]
}

version_ge() {
  local v1="$1"
  local v2="$2"
  [ "$(printf '%s\n' "$v1" "$v2" | sort -V | tail -n1)" = "$v1" ]
}

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

apply_patch_cascade() {
  local base_dir="${1%/}"
  local target_work_dir="${2:-${COMMON_KERNEL_FOLDER}}"
  local os_lower
  os_lower="$(echo "${CFG_OS_VERSION:-}" | tr '[:upper:]' '[:lower:]')"

  if [ -z "$base_dir" ] || [ ! -d "$base_dir" ]; then
    log_info "Patch cascade directory not found: $base_dir (skipping)"
    return 0
  fi

  local -a levels=("${base_dir}/common")
  if [ -n "${KERNEL_VER:-}" ]; then
    levels+=("${base_dir}/${KERNEL_VER}")
  fi
  if [ -n "${TKERNEL_VER:-}" ] && [ "${TKERNEL_VER}" != "${KERNEL_VER:-}" ]; then
    levels+=("${base_dir}/${TKERNEL_VER}")
  fi
  if [ -n "$os_lower" ] && [ -n "${CFG_MODEL:-}" ]; then
    levels+=("${base_dir}/${os_lower}/${CFG_MODEL}")
  fi

  declare -A resolved_path=()
  declare -A resolved_level=()
  local lvl p fname lvl_label

  for lvl in "${levels[@]}"; do
    [ -d "$lvl" ] || continue
    lvl_label="${lvl#"${base_dir}/"}"
    while IFS= read -r -d '' p; do
      fname="${p##*/}"
      resolved_path["$fname"]="$p"
      resolved_level["$fname"]="$lvl_label"
    done < <(find "$lvl" -maxdepth 1 -type f -name '*.patch' -print0)
  done

  if [ "${#resolved_path[@]}" -eq 0 ]; then
    log_info "No matching patches in cascade: ${base_dir#"${KERNEL_PATCHES_FOLDER}/"} (kernel=${TKERNEL_VER:-unknown})"
    return 0
  fi

  local -a sorted_names=()
  mapfile -t sorted_names < <(printf '%s\n' "${!resolved_path[@]}" | LC_ALL=C sort)

  pushd "$target_work_dir" >/dev/null
  for fname in "${sorted_names[@]}"; do
    p="${resolved_path[$fname]}"
    lvl_label="${resolved_level[$fname]}"

    if [ ! -s "$p" ]; then
      log_info "Masking ${fname} (disabled by ${lvl_label}/${fname})"
      continue
    fi

    if patch -p1 -F 0 --dry-run --forward -s -f < "$p" >/dev/null 2>&1; then
      log_info "Applying ${lvl_label}/${fname}..."
      patch -p1 -F 0 --forward < "$p"
    elif patch -p1 -F 0 --dry-run -R -s -f < "$p" >/dev/null 2>&1; then
      log_info "Skipping ${lvl_label}/${fname} (already applied in ${TKERNEL_VER:-kernel})"
    else
      log_error "Patch check failed (-F 0): ${lvl_label}/${fname}"
      patch -p1 -F 0 --dry-run --forward < "$p" || true
      popd >/dev/null
      return 1
    fi
  done
  popd >/dev/null
}

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
