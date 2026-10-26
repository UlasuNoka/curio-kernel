#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

log_group "Detect Clang Toolchain"

CLANG_FOUND=false
CLANG_BIN=""
CUSTOM_CLANG="${OP_C_COMPILER:-}"

if [ -n "$CUSTOM_CLANG" ] && [ "$CUSTOM_CLANG" != "null" ]; then
  # Priority 1: User specified a custom C compiler path
  if [ -x "${CONFIG_FOLDER}/${CUSTOM_CLANG}/clang" ]; then
    CLANG_BIN="${CONFIG_FOLDER}/${CUSTOM_CLANG}"
    CLANG_FOUND=true
  else
    log_warn "OP_C_COMPILER='${CUSTOM_CLANG}' specified, but clang binary not found at ${CONFIG_FOLDER}/${CUSTOM_CLANG}/clang"
  fi
fi

if [ "$CLANG_FOUND" = false ]; then
  # Priority 2: Auto-detect from prebuilts
  for base in "${KERNEL_PLATFORM_FOLDER}/prebuilts" "${KERNEL_PLATFORM_FOLDER}/prebuilts-master"; do
    [ -d "$base/clang/host/linux-x86" ] || continue
    latest=$(ls -d "$base/clang/host/linux-x86/clang-r"* 2>/dev/null | sort -V | tail -n1 || true)
    if [ -n "$latest" ] && [ -x "$latest/bin/clang" ]; then
      CLANG_BIN="$latest/bin"
      CLANG_FOUND=true
      break
    fi
  done
fi

if [ "$CLANG_FOUND" = false ] && command -v clang >/dev/null 2>&1; then
  # Priority 3: Fallback to system-installed clang
  CLANG_BIN="$(dirname "$(command -v clang)")"
  CLANG_FOUND=true
  echo "Using system clang."
fi

if [ "$CLANG_FOUND" != true ]; then
  log_error "No clang toolchain found"
  exit 1
fi

export_env "CLANG_BIN_PATH" "$CLANG_BIN"

CLANG_VERSION="$("$CLANG_BIN/clang" --version | head -n1)"
export_env "CLANG_VERSION" "$CLANG_VERSION"

echo "Derive Clang fingerprint"
short="$("${CLANG_BIN}/clang" --version | sed -n '1s/.*clang-r\([0-9.]\+\).*/\1/p')"

if [ -z "$short" ]; then
  short="$("${CLANG_BIN}/clang" --version | sha256sum | cut -c1-8)"
  echo "[WARN] Could not extract clang-r version, using hash: $short"
else
  log_success "Clang version fingerprint: $short"
fi

export_env "CLANG_VERSION_SHORT" "$short"
add_path "$CLANG_BIN"
export_env "LIBCLANG_PATH" "${CLANG_BIN}/../lib"

log_success "Detected Clang: $CLANG_VERSION"
log_endgroup

# Optional Rust & bindgen setup
if [ "${OP_RUST_BUILD:-false}" = "true" ]; then
  log_group "Detect Rust & bindgen"

  RUSTC_FOUND=false
  BINDGEN_FOUND=false
  CUSTOM_RUST="${OP_RUST_COMPILER:-}"
  CUSTOM_BINDGEN="${OP_BINDGEN:-}"

  if [ -z "$CUSTOM_RUST" ] || [ "$CUSTOM_RUST" = "null" ]; then
    for base in "${KERNEL_PLATFORM_FOLDER}/prebuilts" "${KERNEL_PLATFORM_FOLDER}/prebuilts-master"; do
      [ -d "$base/rust/linux-x86" ] || continue
      latest=$(ls -d "$base/rust/linux-x86/1."* 2>/dev/null | sort -V | head -n1 || true)
      if [ -n "$latest" ] && [ -x "$latest/bin/rustc" ]; then
        RUSTC_BIN="$latest/bin"
        RUSTC_FOUND=true
        break
      fi
    done
  else
    if [ -x "${CONFIG_FOLDER}/${CUSTOM_RUST}/rustc" ]; then
      RUSTC_BIN="${CONFIG_FOLDER}/${CUSTOM_RUST}"
      RUSTC_FOUND=true
    fi
  fi

  if [ -z "$CUSTOM_BINDGEN" ] || [ "$CUSTOM_BINDGEN" = "null" ]; then
    for base in "${KERNEL_PLATFORM_FOLDER}/prebuilts" "${KERNEL_PLATFORM_FOLDER}/prebuilts-master"; do
      [ -d "$base/clang-tools/linux-x86" ] || continue
      if [ -x "$base/clang-tools/linux-x86/bin/bindgen" ]; then
        BINDGEN_BIN="$base/clang-tools/linux-x86/bin"
        BINDGEN_FOUND=true
        chmod +x "$base/clang-tools/linux-x86/bin/bindgen"
        break
      fi
    done
  else
    if [ -x "${CONFIG_FOLDER}/${CUSTOM_BINDGEN}/bindgen" ]; then
      BINDGEN_BIN="${CONFIG_FOLDER}/${CUSTOM_BINDGEN}"
      BINDGEN_FOUND=true
      chmod +x "${CONFIG_FOLDER}/${CUSTOM_BINDGEN}/bindgen"
    fi
  fi

  if [ "$RUSTC_FOUND" != true ]; then
    log_error "No RUST toolchain found"
    exit 1
  fi

  export_env "RUSTC_BIN_PATH" "$RUSTC_BIN"
  RUSTC_VERSION="$("$RUSTC_BIN/rustc" --version | head -n1)"
  export_env "RUSTC_VERSION" "$RUSTC_VERSION"
  export_env "RUSTC" "${RUSTC_BIN}/rustc"
  add_path "$RUSTC_BIN"
  log_success "Detected RUSTC: $RUSTC_VERSION"

  if [ "$BINDGEN_FOUND" = true ]; then
    export_env "BINDGEN_BIN_PATH" "$BINDGEN_BIN"
    BINDGEN_VERSION="$("$BINDGEN_BIN/bindgen" --version | head -n1)"
    export_env "BINDGEN_VERSION" "$BINDGEN_VERSION"
    add_path "$BINDGEN_BIN"
    export_env "BINDGEN" "${BINDGEN_BIN}/bindgen"
    log_success "Detected BINDGEN: $BINDGEN_VERSION"
  else
    log_warn "No prebuilt bindgen found in prebuilts. Rust build may fail."
  fi

  log_endgroup

  log_group "Test Rust & bindgen"
  cd "$COMMON_KERNEL_FOLDER"
  export RUSTTARGET="aarch64-linux-android"
  make V=1 rustavailable
  log_endgroup
fi
