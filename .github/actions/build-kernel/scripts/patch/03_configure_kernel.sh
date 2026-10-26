#!/usr/bin/env bash
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

log_group "Configure Kernel Defconfig & Module Debloat"

DEFCONFIG_FILE="${COMMON_KERNEL_FOLDER}/arch/arm64/configs/gki_defconfig"
PLATFORM="${OP_PLATFORM:-${OP_BRANCH#*/}}"
KERNEL_VERSION="${KERNEL_VER}"

# 1. Always-enabled fragments
echo "Adding Tmpfs, Net Schedulers (qdisc), and Base Build configs..."
append_defconfig_fragment "tmpfs.conf" "$DEFCONFIG_FILE"
append_defconfig_fragment "net_qdisc.conf" "$DEFCONFIG_FILE"
append_defconfig_fragment "base_build.conf" "$DEFCONFIG_FILE"

# 2. Conditional feature fragments
if [ "${OP_NTSYNC:-false}" = "true" ]; then
  append_defconfig_fragment "ntsync.conf" "$DEFCONFIG_FILE"
fi

if [ "${OP_BBR:-false}" = "true" ]; then
  append_defconfig_fragment "bbr.conf" "$DEFCONFIG_FILE"
fi

if [ "${OP_BBR3:-false}" = "true" ]; then
  append_defconfig_fragment "bbr3.conf" "$DEFCONFIG_FILE"
fi

if [ "${OP_TTL:-false}" = "true" ]; then
  append_defconfig_fragment "ttl.conf" "$DEFCONFIG_FILE"
fi

if [ "${OP_IP_SET:-false}" = "true" ]; then
  if [[ "$KERNEL_VERSION" == "6.12" ]] || [[ "$PLATFORM" == mt* ]]; then
    echo "::debug::Skipping CONFIG_BPF_STREAM_PARSER for $KERNEL_VERSION / $PLATFORM"
  else
    echo "CONFIG_BPF_STREAM_PARSER=y" >> "$DEFCONFIG_FILE"
  fi
  append_defconfig_fragment "ip_set.conf" "$DEFCONFIG_FILE"
fi

if [ "${OP_DS:-false}" = "true" ]; then
  append_defconfig_fragment "droidspaces.conf" "$DEFCONFIG_FILE"
fi

if [ "${OP_RUST_BUILD:-false}" = "true" ]; then
  append_defconfig_fragment "rust.conf" "$DEFCONFIG_FILE"
fi

# 3. ZRAM default compression algorithm
ALGO="${OP_ZRAM_COMPRESSION:-}"
if [ -z "$ALGO" ] || [ "$ALGO" = "default" ] || [ "$ALGO" = "null" ]; then
  log_info "ZRAM compression not specified in JSON; keeping defconfig default"
else
  sed -i '/^CONFIG_ZRAM_DEF_COMP_/d' "$DEFCONFIG_FILE"
  sed -i '/^CONFIG_ZRAM_DEF_COMP=/d' "$DEFCONFIG_FILE"

  case "$ALGO" in
    lz4)     echo 'CONFIG_ZRAM_DEF_COMP_LZ4=y' ;;
    zstd)    echo 'CONFIG_ZRAM_DEF_COMP_ZSTD=y' ;;
    lzo)     echo 'CONFIG_ZRAM_DEF_COMP_LZO=y' ;;
    lzo-rle) echo 'CONFIG_ZRAM_DEF_COMP_LZORLE=y' ;;
  esac >> "$DEFCONFIG_FILE"

  echo "CONFIG_ZRAM_DEF_COMP=\"${ALGO}\"" >> "$DEFCONFIG_FILE"
  log_success "ZRAM default: $ALGO (all algorithms still supported)"
fi

# 4. Disable Vendor / Kernel Modules (Blacklist with Protected Filter)
cd "$COMMON_KERNEL_FOLDER"

mapfile -t RISKY_MODULES < <(grep -vE '^[[:space:]]*(#|$)' "${CONFIG_ROOT}/protected_modules.txt" | tr -d '\r')

declare -a modules=()
IFS=',' read -ra ADDR <<< "${OP_BLACKLIST_MODULES:-}"
for mod in "${ADDR[@]}"; do
  [[ -n "$mod" ]] && modules+=("$mod")
done

if [ "${OP_BBR:-false}" = "true" ] || [ "${OP_BBR3:-false}" = "true" ]; then
  if [[ ! " ${modules[*]} " =~ " oplus_network_tuning " ]]; then
    modules+=("oplus_network_tuning")
  fi
  if [[ ! " ${modules[*]} " =~ " oplus_networks_tuning " ]]; then
    modules+=("oplus_networks_tuning")
  fi
fi

declare -a validated_modules=()
for mod in "${modules[@]}"; do
  is_risky=false
  for risky in "${RISKY_MODULES[@]}"; do
    if [ "$mod" = "$risky" ]; then
      is_risky=true
      echo "[WARN] WARNING: Blocked attempt to blacklist protected module: $mod"
      break
    fi
  done

  if [ "$is_risky" = false ]; then
    validated_modules+=("$mod")
  fi
done

if [ ${#validated_modules[@]} -gt 0 ]; then
  RAW_JOINED=$(IFS=,; echo "${validated_modules[*]}")
  RESULT_LIST="\"${RAW_JOINED}\""
else
  RESULT_LIST='""'
fi

echo "Disabling following kernel modules: ${RESULT_LIST}"
echo "CONFIG_DEBLOAT_VENDOR_MODULES=${RESULT_LIST}" >> "$DEFCONFIG_FILE"

MIN_VERSION="5.16"
if version_le "$KERNEL_VERSION" "$MIN_VERSION"; then
  patch -p1 < "${KERNEL_PATCHES_FOLDER}/common/vendor_modules/0001-Support-conditional-vendor-modules-blacklisting-5.15-and-below.patch"
else
  patch -p1 < "${KERNEL_PATCHES_FOLDER}/common/vendor_modules/0001-Support-conditional-vendor-modules-blacklisting-6.1-and-above.patch"
fi

log_success "Kernel configuration & module debloat completed"
log_endgroup
