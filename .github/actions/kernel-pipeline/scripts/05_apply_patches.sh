#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PLATFORM="${CFG_PLATFORM}"
KERNEL_VERSION="${KERNEL_VER}"
MIN_VERSION="5.16"

if [ "${CFG_BBG:-false}" = "true" ]; then
  log_group "Add BBG LSM"
  cd "$KERNEL_PLATFORM_FOLDER"
  echo "Adding BBG from local source..."

  BBG_TARGET_DIR="common/security/baseband-guard"
  rm -rf "$BBG_TARGET_DIR"
  mkdir -p "${BBG_TARGET_DIR}/tracing"
  cp -f "${BBG_FOLDER}/Kconfig" "${BBG_FOLDER}/Makefile" "${BBG_FOLDER}/LICENSE" \
        "${BBG_FOLDER}"/*.c "${BBG_FOLDER}"/*.h "${BBG_TARGET_DIR}/"
  if [ -d "${BBG_FOLDER}/tracing" ]; then
    cp -f "${BBG_FOLDER}/tracing/Makefile" "${BBG_FOLDER}/tracing/"*.c \
          "${BBG_FOLDER}/tracing/"*.h "${BBG_TARGET_DIR}/tracing/"
  fi

  if ! grep -q 'baseband-guard' common/security/Makefile; then
    printf '\nobj-$(CONFIG_BBG) += baseband-guard/\n' >> common/security/Makefile
  fi

  if ! grep -q 'security/baseband-guard/Kconfig' common/security/Kconfig; then
    sed -i '/endmenu/i source "security/baseband-guard/Kconfig"' common/security/Kconfig
  fi

  echo "CONFIG_BBG=y" >> common/arch/arm64/configs/gki_defconfig
  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' common/security/Kconfig

  case "$PLATFORM" in
    sm8850|sm8845)
      echo "Applying BBG efisp abl whitelist patch"
      patch -p1 < "${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/bbg_efisp/0001-allow-abl-efisp-flashing.patch"
      ;;
  esac

  log_success "BBG LSM added"
  log_endgroup
fi

log_group "Apply Core & Vendor Patches"
cd "$COMMON_KERNEL_FOLDER"

if version_le "$KERNEL_VERSION" "$MIN_VERSION"; then
  log_info "Applying ptrace patch..."
  patch -p1 -F 3 < "${KERNEL_PATCHES_FOLDER}/patches/base/gki_ptrace.patch"
else
  echo "Kernel > $MIN_VERSION, skipping ptrace patch"
fi

if [ "${CFG_HMBIRD:-false}" = "true" ]; then
  log_info "Applying HMBIRD scheduler patches..."
  OS_LOWER=$(echo "${CFG_OS_VERSION:-A16}" | tr '[:upper:]' '[:lower:]')
  HMBIRD_DIR="${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/hmbird/${OS_LOWER}"
  case "$PLATFORM" in
    mt*|dimensity*) HMBIRD_SOC="mt6991" ;;
    *)              HMBIRD_SOC="$PLATFORM" ;;
  esac

  if version_le "${TKERNEL_VER:-6.6.118}" "6.6.89"; then
    HMBIRD_CANDIDATES=(
      "${HMBIRD_DIR}/hmbird_${HMBIRD_SOC}_legacy.patch"
      "${HMBIRD_DIR}/hmbird_${HMBIRD_SOC}_cph_legacy.patch"
      "${HMBIRD_DIR}/hmbird_${HMBIRD_SOC}.patch"
    )
  else
    HMBIRD_CANDIDATES=(
      "${HMBIRD_DIR}/hmbird_${HMBIRD_SOC}.patch"
      "${HMBIRD_DIR}/hmbird_${HMBIRD_SOC}_cph.patch"
      "${HMBIRD_DIR}/hmbird_${HMBIRD_SOC}_compact.patch"
      "${HMBIRD_DIR}/hmbird_${HMBIRD_SOC}_tablet.patch"
      "${HMBIRD_DIR}/hmbird_${HMBIRD_SOC}_legacy.patch"
    )
  fi

  HMBIRD_PATCH=""
  for cand in "${HMBIRD_CANDIDATES[@]}"; do
    if [ -f "$cand" ] && patch -p1 -F 3 --dry-run --forward -s -f < "$cand" >/dev/null 2>&1; then
      HMBIRD_PATCH="$cand"
      break
    fi
  done

  if [ -z "$HMBIRD_PATCH" ]; then
    log_error "No compatible HMBIRD patch found for ${PLATFORM} (${CFG_OS_VERSION}, ${TKERNEL_VER:-unknown})"
    exit 1
  fi

  log_info "Using HMBIRD patch: ${HMBIRD_PATCH#"${KERNEL_PATCHES_FOLDER}/"}"
  dos2unix "${HMBIRD_PATCH}"
  patch -p1 -F 3 < "${HMBIRD_PATCH}"
  dos2unix "${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/hmbird/overwriter.patch"
  patch -p1 -F 3 < "${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/hmbird/overwriter.patch"
  chmod +x ./drivers/of/overwriter/overwrite_configs/convert_configs.sh
  dos2unix "${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/hmbird/hmbird_config.patch"
  patch -p1 -F 3 < "${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/hmbird/hmbird_config.patch"
else
  echo "Hmbird not enabled, skipping fengchi patch"
fi

echo "Patching module intercept and overlay mechanism"
patch -p1 < "${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/module_overlay/overlay-${ANDROID_VER}-${KERNEL_VER}.patch"
if [ -d "${COMMON_KERNEL_FOLDER}/kernel/module/module_overlay/" ]; then
  chmod +x ./kernel/module/module_overlay/convert_overlay.sh
elif [ -d "${COMMON_KERNEL_FOLDER}/kernel/module_overlay/" ]; then
  chmod +x ./kernel/module_overlay/convert_overlay.sh
fi

copied_modules=""
SOC="$PLATFORM"

declare -A selected_file=()
declare -A selected_priority=()
selected_count=0

suffixes=(
  "_${CFG_MODEL}_${CFG_OS_VERSION}_${KERNEL_FULL_VER}.ko"
  "_${SOC}_${CFG_OS_VERSION}_${KERNEL_FULL_VER}.ko"
  "_${CFG_MODEL}_${CFG_OS_VERSION}.ko"
  "_${SOC}_${CFG_OS_VERSION}.ko"
  "_${CFG_MODEL}.ko"
  "_${SOC}.ko"
  "_${KERNEL_FULL_VER}.ko"
)

if [ -d "${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/module_overlay/modules/" ]; then
  while IFS= read -r -d '' file; do
    filename="${file##*/}"
    module_name=""
    priority=0

    exact_module_name=$(modinfo -F name "$file" 2>/dev/null || true)

    for i in "${!suffixes[@]}"; do
      suffix="${suffixes[$i]}"
      if [[ "$filename" == *"$suffix" ]]; then
        extracted_name="${filename%"$suffix"}"
        extracted_normalized="${extracted_name//-/_}"

        if [[ "$extracted_normalized" == "$exact_module_name" ]]; then
          module_name="$extracted_name"
          priority=$((i + 1))
        fi
        break
      fi
    done

    [[ -n "$module_name" ]] || continue

    if [[ -z "${selected_priority[$module_name]+exists}" ]]; then
      echo "New module: $file"
      selected_file["$module_name"]="$file"
      selected_priority["$module_name"]="$priority"
      selected_count=$((selected_count + 1))
    elif (( priority < selected_priority["$module_name"] )); then
      echo "Existing module: $file ; replace with a higher-priority variant."
      selected_file["$module_name"]="$file"
      selected_priority["$module_name"]="$priority"
    fi
  done < <(find "${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/module_overlay/modules/" -type f -name '*.ko' -print0)
fi

if (( selected_count == 0 )); then
  echo "No matching kernel modules found."
fi

for module_name in "${!selected_file[@]}"; do
  file="${selected_file[$module_name]}"
  priority="${selected_priority[$module_name]}"
  echo "Copying module '$module_name' priority=$priority: $file"

  dest_path=""
  if [ -d "${COMMON_KERNEL_FOLDER}/kernel/module/module_overlay/modules/" ]; then
    dest_path="${COMMON_KERNEL_FOLDER}/kernel/module/module_overlay/modules/${module_name}.ko"
  elif [ -d "${COMMON_KERNEL_FOLDER}/kernel/module_overlay/modules/" ]; then
    dest_path="${COMMON_KERNEL_FOLDER}/kernel/module_overlay/modules/${module_name}.ko"
  fi

  if [ -n "$dest_path" ]; then
    mkdir -p "$(dirname "$dest_path")"
    cp -f "$file" "$dest_path"

    if [ -z "$copied_modules" ]; then
      copied_modules="$dest_path"
    else
      copied_modules="${copied_modules}:${dest_path}"
    fi
  fi
done

ccache --set-config=extra_files_to_hash="$copied_modules"

log_success "Core & vendor patches applied"
log_endgroup

if [ "${CFG_OPT:-false}" = "true" ]; then
  log_group "Apply Optimisation Patches"
  cd "$COMMON_KERNEL_FOLDER"
  OPT_DIR="${KERNEL_PATCHES_FOLDER}/patches/opt"

  while IFS= read -r opt_patch || [ -n "$opt_patch" ]; do
    opt_patch="${opt_patch%%#*}"
    opt_patch="${opt_patch#"${opt_patch%%[![:space:]]*}"}"
    opt_patch="${opt_patch%"${opt_patch##*[![:space:]]}"}"
    [ -z "$opt_patch" ] && continue
    echo "Applying opt/${opt_patch}"
    patch -p1 --forward < "${OPT_DIR}/${opt_patch}"
  done < "${OPT_DIR}/series"

  if version_ge "$KERNEL_VERSION" "$MIN_VERSION"; then
    patch -p1 --forward < "${OPT_DIR}/optimise_memcmp.patch"
  elif version_ge "$KERNEL_VERSION" "5.11"; then
    sed -e 's/SYM_FUNC_START(__pi_memcmp)/SYM_FUNC_START_WEAK_PI(memcmp)/' \
        -e 's/SYM_FUNC_END(__pi_memcmp)/SYM_FUNC_END_PI(memcmp)/' \
        -e 's/SYM_FUNC_ALIAS_WEAK(memcmp, __pi_memcmp)/EXPORT_SYMBOL_NOKASAN(memcmp)/' \
        "${OPT_DIR}/optimise_memcmp.patch" | patch -p1 --forward
  fi

  if version_le "$KERNEL_VERSION" "$MIN_VERSION"; then
    patch -p1 --forward < "${OPT_DIR}/clear_page_16bytes_align.patch"
  else
    sed -e 's/SYM_FUNC_START_PI(clear_page)/SYM_FUNC_START_PI(__pi_clear_page)/' \
        "${OPT_DIR}/clear_page_16bytes_align.patch" | patch -p1 -F3 --forward
  fi

  if [ "${CFG_BBR:-false}" = "false" ] && [ "${CFG_BBR3:-false}" = "false" ]; then
    patch -p1 --forward < "${OPT_DIR}/force_tcp_nodelay.patch"
  fi

  apply_patch_cascade "${KERNEL_PATCHES_FOLDER}/patches/features/zstd" "$COMMON_KERNEL_FOLDER" "warn"

  log_success "Optimisation patches applied"
  log_endgroup
fi

if [ "${CFG_WAKELOCK_BLOCKER:-false}" = "true" ] && [ -f "${KERNEL_PATCHES_FOLDER}/patches/features/boeffla_wl/boeffla_wakelock_blocker.patch" ]; then
  log_group "Apply Boeffla Wakelock Blocker"
  cd "$COMMON_KERNEL_FOLDER"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/patches/features/boeffla_wl/boeffla_wakelock_blocker.patch"
  log_success "Boeffla Wakelock Blocker applied"
  log_endgroup
fi

if [ "${CFG_USB_SDP_900MA:-false}" = "true" ] && [ "${CFG_VENDOR:-oplus}" = "oplus" ] && [ -f "${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/usb_sdp_limit.patch" ]; then
  log_group "Apply USB SDP 900mA Current Limit Driver"
  cd "$COMMON_KERNEL_FOLDER"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/usb_sdp_limit.patch"
  log_success "USB SDP 900mA driver applied"
  log_endgroup
fi

if [ "${CFG_REKERNEL:-false}" = "true" ]; then
  log_group "Apply Re-Kernel Frozen Task Notifier"
  cd "$COMMON_KERNEL_FOLDER"
  apply_patch_cascade "${KERNEL_PATCHES_FOLDER}/patches/features/rekernel" "$COMMON_KERNEL_FOLDER" "warn"
  log_success "Re-Kernel applied"
  log_endgroup
fi

if [ "${CFG_NTSYNC:-false}" = "true" ]; then
  log_group "Apply NTSync Patch"
  cd "$COMMON_KERNEL_FOLDER"
  NTSYNC_FOLDER="${KERNEL_PATCHES_FOLDER}/patches/features/ntsync"
  GKI_KEY="${ANDROID_VER}-${KERNEL_VER}"

  NTSYNC_PATCH=""
  for cand in \
    "${NTSYNC_FOLDER}/ntsync_compat_${GKI_KEY}_${CFG_OS_VERSION}.patch" \
    "${NTSYNC_FOLDER}/ntsync_compat_${GKI_KEY}.patch" \
    "${NTSYNC_FOLDER}/ntsync_compat_${GKI_KEY}_A14.patch"; do
    if [ -f "$cand" ] && patch -p1 --dry-run --forward -s -f < "$cand" >/dev/null 2>&1; then
      NTSYNC_PATCH="$cand"
      break
    fi
  done

  if [ -z "$NTSYNC_PATCH" ]; then
    log_error "NTSync patch not found or incompatible for ${GKI_KEY} (${CFG_OS_VERSION})"
    exit 1
  fi

  echo "Using patch: $(basename "$NTSYNC_PATCH")"
  if [ "$ANDROID_VER" = "android16" ] && [ "$KERNEL_VER" = "6.12" ]; then
    echo "Removing pre-existing ntsync files for android16-6.12"
    rm -f include/uapi/linux/ntsync.h
    rm -f drivers/misc/ntsync.c
  fi

  log_info "Applying $(basename "$NTSYNC_PATCH")..."
  patch -p1 --forward < "$NTSYNC_PATCH"
  log_info "Applying ntsync_base.patch..."
  patch -p1 --forward < "${NTSYNC_FOLDER}/ntsync_base.patch"

  log_success "NTSync patch applied"
  log_endgroup
fi

if [ "${CFG_UNICODE:-false}" = "true" ]; then
  log_group "Apply Unicode Fix Patch"
  cd "$COMMON_KERNEL_FOLDER"
  log_info "Applying VFS unicode fix..."
  if version_le "$KERNEL_VERSION" "$MIN_VERSION"; then
    patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/patches/features/unicode/unicode_fix_6.1-.patch"
  else
    patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/patches/features/unicode/unicode_fix_6.1+.patch"
  fi
  log_success "Unicode Fix patch applied"
  log_endgroup
fi

if [ "${CFG_BBR3:-false}" = "true" ]; then
  log_group "Apply BBRv3 Patches"
  cd "$COMMON_KERNEL_FOLDER"
  patch -p1 < "${KERNEL_PATCHES_FOLDER}/patches/features/bbr3/bbr3-${ANDROID_VER}-${KERNEL_VER}.patch"

  if [ "$ANDROID_VER" = "android12" ] && [ "$KERNEL_VER" = "5.10" ]; then
    if ! grep -qF 'int proc_dou8vec_minmax(' ./include/linux/sysctl.h; then
      patch -p1 < "${KERNEL_PATCHES_FOLDER}/patches/features/bbr3/sysctl_add_proc_dou8vec_minmax.patch"
      patch -p1 < "${KERNEL_PATCHES_FOLDER}/patches/features/bbr3/sysctl_fix_data-races_in_proc_dou8vec_minmax.patch"
    fi
  fi

  log_success "BBRv3 patches applied"
  log_endgroup
fi

if [ "${CFG_CONTAINERS:-false}" = "true" ]; then
  log_group "Apply Container Patches"
  cd "$COMMON_KERNEL_FOLDER"

  echo "Applying patch to enable SYSVIPC without breaking ABI"
  case "$PLATFORM" in
    sm8850|sm8845)
      patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/patches/features/containers/sysvipc/kabi_a16-6.12.patch"
      ;;
    sm8550|sm7550)
      patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/patches/features/containers/sysvipc/kabi_1_2_3.patch"
      ;;
    sm8450|sm8475|mt6895|mt6983|mt6789)
      if [ "$ANDROID_VER" = "android12" ] && [ "$KERNEL_VER" = "5.10" ]; then
        patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/patches/features/containers/sysvipc/kabi_bypass_below_6.12.patch"
        patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/patches/features/containers/sysvipc/mqueue_abi_padding.patch"
      else
        patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/patches/features/containers/sysvipc/kabi_6_7_8.patch"
      fi
      ;;
    *)
      patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/patches/features/containers/sysvipc/kabi_6_7_8.patch"
      ;;
  esac

  log_info "Applying oplus_bsp_midas null-task guard..."
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/midas_null_task_guard.patch"
  if [ -f "${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/sched_assist_ddl_oob.patch" ]; then
    echo "Applying oplus_bsp_sched_assist update_ddl_hit_history OOB fix..."
    patch -p1 -F 3 --forward < "${KERNEL_PATCHES_FOLDER}/patches/vendor/oplus/sched_assist_ddl_oob.patch"
  fi

  if [ -f "${COMMON_KERNEL_FOLDER}/fs/overlayfs/params.c" ] && [ -f "${KERNEL_PATCHES_FOLDER}/patches/features/containers/ovl_override_creds_default.patch" ]; then
    echo "Applying overlayfs override_creds default initialization fix..."
    patch -p1 -F 3 --forward < "${KERNEL_PATCHES_FOLDER}/patches/features/containers/ovl_override_creds_default.patch"
  fi

  CVE_USERNS_PATCH="${KERNEL_PATCHES_FOLDER}/patches/features/containers/userns_rtmutex/cve-2026-43499-rtmutex-${KERNEL_VER}.patch"
  if [ -f "$CVE_USERNS_PATCH" ]; then
    echo "Applying CVE-2026-43499 rtmutex security fix for USER_NS..."
    patch -p1 -F 3 --forward < "$CVE_USERNS_PATCH"
  fi

  CGROUP_LIMITS_PATCH=$(find "${KERNEL_PATCHES_FOLDER}/patches/features/containers/cgroup_limits" -maxdepth 1 -type f -name "fix_cgroup_limits_kabi_${KERNEL_VER}.*.patch" 2>/dev/null | head -n 1 || true)
  if [ -n "$CGROUP_LIMITS_PATCH" ] && [ -f "$CGROUP_LIMITS_PATCH" ]; then
    echo "Applying KABI-preserving cgroup limits patch: $(basename "$CGROUP_LIMITS_PATCH")"
    patch -p1 -F 3 --forward < "$CGROUP_LIMITS_PATCH"
  fi

  if [ -f "${KERNEL_PATCHES_FOLDER}/patches/features/containers/ipvlan_l3mdev_kabi.patch" ]; then
    echo "Applying KABI-preserving L3 master device patch for IPVLAN and VRF..."
    patch -p1 -F 3 --forward < "${KERNEL_PATCHES_FOLDER}/patches/features/containers/ipvlan_l3mdev_kabi.patch"
  fi

  if [ -f "${KERNEL_PATCHES_FOLDER}/patches/features/containers/xt_cgroup_kabi.patch" ]; then
    echo "Applying KABI-preserving XT_MATCH_CGROUP patch..."
    patch -p1 -F 3 --forward < "${KERNEL_PATCHES_FOLDER}/patches/features/containers/xt_cgroup_kabi.patch"
  fi

  if [ "${CFG_RUST_BUILD:-false}" = "true" ]; then
    echo "Add IPC NS missing symbols for rust binder"
    if ! grep -q 'EXPORT_SYMBOL.*put_ipc_ns' "${COMMON_KERNEL_FOLDER}/ipc/namespace.c"; then
      echo -e '\nEXPORT_SYMBOL_GPL(put_ipc_ns);' >> "${COMMON_KERNEL_FOLDER}/ipc/namespace.c"
    fi
    if ! grep -q 'EXPORT_SYMBOL.*init_ipc_ns' "${COMMON_KERNEL_FOLDER}/ipc/msgutil.c"; then
      echo -e '\nEXPORT_SYMBOL_GPL(init_ipc_ns);' >> "${COMMON_KERNEL_FOLDER}/ipc/msgutil.c"
    fi
  fi

  log_success "Container patches applied"
  log_endgroup
fi

if [ "${CFG_USB_GADGET:-false}" = "true" ]; then
  log_group "Apply USB Gadget Patches"
  cd "$COMMON_KERNEL_FOLDER"
  UA_DIR="${KERNEL_PATCHES_FOLDER}/patches/features/usb_gadget/${KERNEL_VER}"

  if [ -d "$UA_DIR" ]; then
    for p in "$UA_DIR"/*.patch; do
      [ -f "$p" ] || continue
      echo "Applying USB gadget patch: $(basename "$p")"
      patch -p1 --forward < "$p"
    done
    log_success "USB gadget patches applied for kernel ${KERNEL_VER}"
  else
    log_warn "No USB gadget patches found for kernel ${KERNEL_VER}, skipping"
  fi
  log_endgroup
fi

if [[ "$KERNEL_VER" == "5.10" && ("$CFG_SOC" == dimensity* || "$CFG_SOC" == helio*) ]]; then
  log_group "Disable GPUEB for MTK kernel 5.10"
  sed -i '/obj-y.*gpueb/d' "${COMMON_KERNEL_FOLDER}/drivers/gpu/mediatek/Makefile"
  log_endgroup
fi

log_group "Apply Fake config.gz Patch"
cd "$COMMON_KERNEL_FOLDER"
patch -p1 < "${KERNEL_PATCHES_FOLDER}/patches/base/fake_config.patch"

OPTIONS=()

if [ "${CFG_BBR:-false}" = "true" ] || [ "${CFG_BBR3:-false}" = "true" ]; then
  OPTIONS+=("CONFIG_TCP_CONG_ADVANCED")
fi

if [ "${CFG_IP_SET:-false}" = "true" ]; then
  OPTIONS+=("CONFIG_IP6_NF_NAT")
fi

CONFIG_STRING="${OPTIONS[*]}"
export_env "CONFIG_FAKE_DISABLE" "$CONFIG_STRING"
log_success "Fake config.gz patch applied (CONFIG_FAKE_DISABLE='${CONFIG_STRING}')"
log_endgroup
