#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

log_group "Configure Kernel Defconfig & Module Debloat"

DEFCONFIG_FILE="${COMMON_KERNEL_FOLDER}/arch/arm64/configs/gki_defconfig"
PLATFORM="${CFG_PLATFORM}"
KERNEL_VERSION="${KERNEL_VER}"

echo "Adding Tmpfs, Net Schedulers (qdisc), and Base Build configs..."
append_defconfig_fragment "tmpfs.conf" "$DEFCONFIG_FILE"
append_defconfig_fragment "storage_fs.conf" "$DEFCONFIG_FILE"
append_defconfig_fragment "net_qdisc.conf" "$DEFCONFIG_FILE"
append_defconfig_fragment "base_build.conf" "$DEFCONFIG_FILE"

if [ "${CFG_NTSYNC:-false}" = "true" ]; then
  append_defconfig_fragment "ntsync.conf" "$DEFCONFIG_FILE"
fi

if [ "${CFG_BBR:-false}" = "true" ]; then
  append_defconfig_fragment "bbr.conf" "$DEFCONFIG_FILE"
fi

if [ "${CFG_BBR3:-false}" = "true" ]; then
  append_defconfig_fragment "bbr3.conf" "$DEFCONFIG_FILE"
fi

if [ "${CFG_TTL:-false}" = "true" ]; then
  append_defconfig_fragment "ttl.conf" "$DEFCONFIG_FILE"
fi

if [ "${CFG_IP_SET:-false}" = "true" ]; then
  if [[ "$KERNEL_VERSION" == "6.12" ]] || [[ "$PLATFORM" == mt* ]]; then
    echo "::debug::Skipping CONFIG_BPF_STREAM_PARSER for $KERNEL_VERSION / $PLATFORM"
  else
    echo "CONFIG_BPF_STREAM_PARSER=y" >> "$DEFCONFIG_FILE"
  fi
  append_defconfig_fragment "ip_set.conf" "$DEFCONFIG_FILE"
fi

if [ "${CFG_CONTAINERS:-false}" = "true" ]; then
  append_defconfig_fragment "containers.conf" "$DEFCONFIG_FILE"
fi

if [ "${CFG_USB_GADGET:-false}" = "true" ]; then
  append_defconfig_fragment "usb_gadget.conf" "$DEFCONFIG_FILE"
fi

if [ "${CFG_RUST_BUILD:-false}" = "true" ]; then
  append_defconfig_fragment "rust.conf" "$DEFCONFIG_FILE"
fi

cd "$COMMON_KERNEL_FOLDER"

mapfile -t RISKY_MODULES < <(grep -vE '^[[:space:]]*(#|$)' "${CONFIG_ROOT}/protected_modules.txt" | tr -d '\r')

declare -a modules=()
IFS=',' read -ra ADDR <<< "${CFG_BLACKLIST_MODULES:-}"
for mod in "${ADDR[@]}"; do
  [[ -n "$mod" ]] && modules+=("$mod")
done

if [ "${CFG_VENDOR:-oplus}" = "oplus" ] && { [ "${CFG_BBR:-false}" = "true" ] || [ "${CFG_BBR3:-false}" = "true" ]; }; then
  if [[ " ${modules[*]} " != *" oplus_network_tuning "* ]]; then
    modules+=("oplus_network_tuning")
  fi
  if [[ " ${modules[*]} " != *" oplus_networks_tuning "* ]]; then
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
  patch -p1 < "${KERNEL_PATCHES_FOLDER}/patches/base/module_filter/5.15-and-below.patch"
else
  patch -p1 < "${KERNEL_PATCHES_FOLDER}/patches/base/module_filter/6.1-and-above.patch"
fi

log_success "Kernel configuration & module debloat completed"
log_endgroup
