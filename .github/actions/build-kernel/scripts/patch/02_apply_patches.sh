#!/usr/bin/env bash
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PLATFORM="${OP_PLATFORM:-${OP_BRANCH#*/}}"
KERNEL_VERSION="${KERNEL_VER}"
MIN_VERSION="5.16"

# ==============================================================================
# 1. Baseband Guard (BBG) LSM
# ==============================================================================
if [ "${OP_BBG:-false}" = "true" ]; then
  log_group "Add BBG LSM"
  cd "$KERNEL_PLATFORM_FOLDER"
  echo "Adding BBG from local source..."

  BBG_TARGET_DIR="common/security/baseband-guard"
  rm -rf "$BBG_TARGET_DIR"
  cp -r "${KERNEL_PATCHES_FOLDER}/common/bbg/source" "$BBG_TARGET_DIR"

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
      patch -p1 < "${KERNEL_PATCHES_FOLDER}/common/bbg/0001-Enable-abl-and-efisp-flashing-for-efisp-exploit-devices.patch"
      ;;
  esac

  log_success "BBG LSM added"
  log_endgroup
fi

# ==============================================================================
# 2. Core Patches: ptrace, HMBIRD SCX, and Module Overlay
# ==============================================================================
log_group "Apply Core & Vendor Patches"
cd "$COMMON_KERNEL_FOLDER"

if version_le "$KERNEL_VERSION" "$MIN_VERSION"; then
  echo "Patching ptrace!"
  patch -p1 -F 3 < "${KERNEL_PATCHES_FOLDER}/gki_ptrace.patch"
else
  echo "Kernel > $MIN_VERSION, skipping ptrace patch"
fi

if [ "${OP_HMBIRD:-false}" = "true" ]; then
  echo "Patching hmbird!"
  HMBIRD_MODEL=$(echo "$OP_MODEL" | sed 's/-[0-9]\+\.[0-9]\+\.[0-9]\+$//')
  case "$OP_MODEL" in
    OP-ACE-5-ULTRA-6.6.50|OP-ACE-5-PRO-6.6.30|OP13-6.6.30|OP13-CPH-6.6.56|OP13T-6.6.89|OP13-6.6.89|OP-ACE-5-PRO-6.6.89)
      FENGCHI_DIR="${KERNEL_PATCHES_FOLDER}/oneplus/hmbird/deprecated"
      ;;
    *)
      FENGCHI_DIR="${KERNEL_PATCHES_FOLDER}/oneplus/hmbird"
      ;;
  esac
  dos2unix "${FENGCHI_DIR}/fengchi_${HMBIRD_MODEL}_${OP_OS_VERSION}.patch"
  patch -p1 -F 3 < "${FENGCHI_DIR}/fengchi_${HMBIRD_MODEL}_${OP_OS_VERSION}.patch"
  dos2unix "${KERNEL_PATCHES_FOLDER}/oneplus/hmbird/overwriter.patch"
  patch -p1 -F 3 < "${KERNEL_PATCHES_FOLDER}/oneplus/hmbird/overwriter.patch"
  chmod +x ./drivers/of/overwriter/overwrite_configs/convert_configs.sh
  dos2unix "${KERNEL_PATCHES_FOLDER}/oneplus/hmbird/hmbird_config.patch"
  patch -p1 -F 3 < "${KERNEL_PATCHES_FOLDER}/oneplus/hmbird/hmbird_config.patch"
else
  echo "Hmbird not enabled, skipping fengchi patch"
fi

echo "Patching module intercept and overlay mechanism"
patch -p1 < "${KERNEL_PATCHES_FOLDER}/oneplus/module_overlay/0001-module-Add-module-intercept-and-overlay-mechanism-${ANDROID_VER}-${KERNEL_VER}.patch"
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

# Define suffixes in order of priority (1 to 7)
suffixes=(
  "_${OP_MODEL}_${OP_OS_VERSION}_${KERNEL_FULL_VER}.ko"
  "_${SOC}_${OP_OS_VERSION}_${KERNEL_FULL_VER}.ko"
  "_${OP_MODEL}_${OP_OS_VERSION}.ko"
  "_${SOC}_${OP_OS_VERSION}.ko"
  "_${OP_MODEL}.ko"
  "_${SOC}.ko"
  "_${KERNEL_FULL_VER}.ko"
)

if [ -d "${KERNEL_PATCHES_FOLDER}/oneplus/module_overlay/modules/" ]; then
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
  done < <(find "${KERNEL_PATCHES_FOLDER}/oneplus/module_overlay/modules/" -type f -name '*.ko' -print0)
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

# ==============================================================================
# 3. Optimisation Patches
# ==============================================================================
if [ "${OP_OPT:-false}" = "true" ]; then
  log_group "Apply Optimisation Patches"
  cd "$COMMON_KERNEL_FOLDER"

  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/optimized_mem_operations.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/file_struct_8bytes_align.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/reduce_cache_pressure.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/mem_opt_prefetch.patch"

  if version_ge "$KERNEL_VERSION" "$MIN_VERSION"; then
    patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/optimise_memcmp.patch"
  elif version_ge "$KERNEL_VERSION" "5.11"; then
    sed -e 's/SYM_FUNC_START(__pi_memcmp)/SYM_FUNC_START_WEAK_PI(memcmp)/' \
        -e 's/SYM_FUNC_END(__pi_memcmp)/SYM_FUNC_END_PI(memcmp)/' \
        -e 's/SYM_FUNC_ALIAS_WEAK(memcmp, __pi_memcmp)/EXPORT_SYMBOL_NOKASAN(memcmp)/' \
        "${KERNEL_PATCHES_FOLDER}/common/optimise_memcmp.patch" | patch -p1 --forward
  else
    echo "Optimised memcmp patch not found!"
  fi

  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/minimise_wakeup_time.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/int_sqrt.patch"

  if [ "${OP_BBR:-false}" = "false" ] && [ "${OP_BBR3:-false}" = "false" ]; then
    patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/force_tcp_nodelay.patch"
  fi

  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/reduce_gc_thread_sleep_time.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/add_timeout_wakelocks_globally.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/f2fs_reduce_congestion.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/reduce_freeze_timeout.patch"

  if version_le "$KERNEL_VERSION" "$MIN_VERSION"; then
    patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/clear_page_16bytes_align.patch"
  else
    sed -e 's/SYM_FUNC_START_PI(clear_page)/SYM_FUNC_START_PI(__pi_clear_page)/' \
        "${KERNEL_PATCHES_FOLDER}/common/clear_page_16bytes_align.patch" | patch -p1 -F3 --forward
  fi

  echo "Patching add_limitation_scaling_min_freq.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/add_limitation_scaling_min_freq.patch"
  echo "Patching re_write_limitation_scaling_min_freq.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/re_write_limitation_scaling_min_freq.patch"
  echo "Patching adjust_cpu_scan_order.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/adjust_cpu_scan_order.patch"
  echo "Patching avoid_extra_s2idle_wake_attempts.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/avoid_extra_s2idle_wake_attempts.patch"
  echo "Patching disable_cache_hot_buddy.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/disable_cache_hot_buddy.patch"
  echo "Patching f2fs_enlarge_min_fsync_blocks.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/f2fs_enlarge_min_fsync_blocks.patch"
  echo "Patching increase_ext4_default_commit_age.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/increase_ext4_default_commit_age.patch"
  echo "Patching increase_sk_mem_packets.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/increase_sk_mem_packets.patch"
  echo "Patching reduce_pci_pme_wakeups.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/reduce_pci_pme_wakeups.patch"
  echo "Patching silence_irq_cpu_logspam.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/silence_irq_cpu_logspam.patch"
  echo "Patching silence_system_logspam.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/silence_system_logspam.patch"
  echo "Patching use_unlikely_wrap_cpufreq.patch"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/use_unlikely_wrap_cpufreq.patch"

  log_success "Optimisation patches applied"
  log_endgroup
fi

# ==============================================================================
# 4. NTSync Patch
# ==============================================================================
if [ "${OP_NTSYNC:-false}" = "true" ]; then
  log_group "Apply NTSync Patch"
  cd "$COMMON_KERNEL_FOLDER"
  NTSYNC_FOLDER="${KERNEL_PATCHES_FOLDER}/common/ntsync"
  GKI_KEY="${ANDROID_VER}-${KERNEL_VER}"

  NTSYNC_PATCH=""
  case "$OP_MODEL" in
    OP10r|OP-ACE-2-5.10.209|OP-ACE-2V-5.10.209|OP-PAD-MT6983-5.10.209|\
    OP10pro-5.10.209|OP10t-5.10.209|OP-ACE-5.10.209|OP11r-5.10.209|\
    OP-NORD-3-5.10.209|OP-ACE-RACE-5.10.209)
      if [[ "$OP_OS_VERSION" == "A15" ]]; then
        NTSYNC_PATCH="${NTSYNC_FOLDER}/ntsync_compat_android12-5.10_A14.patch"
      fi
      ;;
  esac

  if [ -n "$NTSYNC_PATCH" ]; then
    if [ ! -f "$NTSYNC_PATCH" ]; then
      log_error "NTSync compat patch not found for ${OP_MODEL}: $(basename "$NTSYNC_PATCH")"
      exit 1
    fi
  elif [ -f "${NTSYNC_FOLDER}/ntsync_compat_${GKI_KEY}_${OP_OS_VERSION}.patch" ]; then
    NTSYNC_PATCH="${NTSYNC_FOLDER}/ntsync_compat_${GKI_KEY}_${OP_OS_VERSION}.patch"
  elif [ -f "${NTSYNC_FOLDER}/ntsync_compat_${GKI_KEY}.patch" ]; then
    NTSYNC_PATCH="${NTSYNC_FOLDER}/ntsync_compat_${GKI_KEY}.patch"
  else
    log_error "NTSync patch not found for ${GKI_KEY} (Model: ${OP_MODEL}, Android Version: ${OP_OS_VERSION})"
    exit 1
  fi

  echo "Using patch: $(basename "$NTSYNC_PATCH")"
  if [ "$ANDROID_VER" = "android16" ] && [ "$KERNEL_VER" = "6.12" ]; then
    echo "Removing pre-existing ntsync files for android16-6.12"
    rm -f include/uapi/linux/ntsync.h
    rm -f drivers/misc/ntsync.c
  fi

  echo "Patching $(basename "$NTSYNC_PATCH")!"
  patch -p1 --forward < "$NTSYNC_PATCH"
  echo "Patching ntsync_base!"
  patch -p1 --forward < "${NTSYNC_FOLDER}/ntsync_base.patch"

  log_success "NTSync patch applied"
  log_endgroup
fi

# ==============================================================================
# 5. Unicode Fix Patch
# ==============================================================================
if [ "${OP_UNICODE:-false}" = "true" ]; then
  log_group "Apply Unicode Fix Patch"
  cd "$COMMON_KERNEL_FOLDER"
  echo "Patching unicode!"
  if version_le "$KERNEL_VERSION" "$MIN_VERSION"; then
    patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/unicode_bypass_fix_6.1-.patch"
  else
    patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/unicode_bypass_fix_6.1+.patch"
  fi
  log_success "Unicode Fix patch applied"
  log_endgroup
fi

# ==============================================================================
# 6. BBRv3 Patch
# ==============================================================================
if [ "${OP_BBR3:-false}" = "true" ]; then
  log_group "Apply BBRv3 Patches"
  cd "$COMMON_KERNEL_FOLDER"
  patch -p1 < "${KERNEL_PATCHES_FOLDER}/common/bbrv3/0001-net-tcp-backport-BBRv3-to-${ANDROID_VER}-${KERNEL_VER}.patch"

  if [ "$ANDROID_VER" = "android12" ] && [ "$KERNEL_VER" = "5.10" ]; then
    if ! grep -qF 'int proc_dou8vec_minmax(' ./include/linux/sysctl.h; then
      patch -p1 < "${KERNEL_PATCHES_FOLDER}/common/bbrv3/sysctl_add_proc_dou8vec_minmax.patch"
      patch -p1 < "${KERNEL_PATCHES_FOLDER}/common/bbrv3/sysctl_fix_data-races_in_proc_dou8vec_minmax.patch"
    fi
  fi

  log_success "BBRv3 patches applied"
  log_endgroup
fi

# ==============================================================================
# 7. Droidspaces Support
# ==============================================================================
if [ "${OP_DS:-false}" = "true" ]; then
  log_group "Add Droidspaces Support"
  cd "$COMMON_KERNEL_FOLDER"

  echo "Applying patch to enable SYSVIPC without breaking ABI"
  case "$PLATFORM" in
    sm8850|sm8845)
      patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/droidspaces/fix_sysvipc_kabi_a16-6.12.patch"
      ;;
    sm8550|sm7550)
      patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/droidspaces/fix_sysvipc_kabi_1_2_3.patch"
      ;;
    sm8450|sm8475|mt6895|mt6983|mt6789)
      if [ "$ANDROID_VER" = "android12" ] && [ "$KERNEL_VER" = "5.10" ]; then
        patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/droidspaces/fix_sysvipc_kabi_bypass_a16-6.12_below.patch"
        patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/droidspaces/fix_abi_padding_for_posix_mqueue.patch"
      else
        patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/droidspaces/fix_sysvipc_kabi_6_7_8.patch"
      fi
      ;;
    *)
      patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/droidspaces/fix_sysvipc_kabi_6_7_8.patch"
      ;;
  esac

  echo "Patch to fix kernel panic caused by oplus_bsp_midas"
  patch -p1 --forward < "${KERNEL_PATCHES_FOLDER}/common/droidspaces/0001-Return-ghost-task-if-task-is-null-and-is-requested-b.patch"

  if [ "${OP_RUST_BUILD:-false}" = "true" ]; then
    echo "Add IPC NS missing symbols for rust binder"
    if ! grep -q 'EXPORT_SYMBOL.*put_ipc_ns' "${COMMON_KERNEL_FOLDER}/ipc/namespace.c"; then
      echo -e '\nEXPORT_SYMBOL_GPL(put_ipc_ns);' >> "${COMMON_KERNEL_FOLDER}/ipc/namespace.c"
    fi
    if ! grep -q 'EXPORT_SYMBOL.*init_ipc_ns' "${COMMON_KERNEL_FOLDER}/ipc/msgutil.c"; then
      echo -e '\nEXPORT_SYMBOL_GPL(init_ipc_ns);' >> "${COMMON_KERNEL_FOLDER}/ipc/msgutil.c"
    fi
  fi

  log_success "Droidspaces Support applied"
  log_endgroup
fi

# ==============================================================================
# 8. USB Arsenal Support
# ==============================================================================
if [ "${OP_USB_ARSENAL:-false}" = "true" ]; then
  log_group "Add USB Arsenal Support"
  cd "$COMMON_KERNEL_FOLDER"
  UA_DIR="${KERNEL_PATCHES_FOLDER}/common/usb_arsenal/${KERNEL_VER}"

  if [ -d "$UA_DIR" ]; then
    for p in "$UA_DIR"/*.patch; do
      [ -f "$p" ] || continue
      echo "Applying USB Arsenal patch: $(basename "$p")"
      patch -p1 --forward < "$p"
    done
    log_success "USB Arsenal patches applied for kernel ${KERNEL_VER}"
  else
    log_warn "No USB Arsenal patches found for kernel ${KERNEL_VER}, skipping"
  fi
  log_endgroup
fi

# ==============================================================================
# 9. Disable GPUEB (MTK 5.10 only)
# ==============================================================================
if [[ "$KERNEL_VER" == "5.10" && ("$OP_SOC" == dimensity* || "$OP_SOC" == helio*) ]]; then
  log_group "Disable GPUEB for MTK kernel 5.10"
  sed -i '/obj-y.*gpueb/d' "${COMMON_KERNEL_FOLDER}/drivers/gpu/mediatek/Makefile"
  log_endgroup
fi

# ==============================================================================
# 10. Fake config.gz Patch
# ==============================================================================
log_group "Apply Fake config.gz Patch"
cd "$COMMON_KERNEL_FOLDER"
patch -p1 < "${KERNEL_PATCHES_FOLDER}/common/fake_config.patch"

OPTIONS=()

if [ "${OP_BBR:-false}" = "true" ] || [ "${OP_BBR3:-false}" = "true" ]; then
  OPTIONS+=("CONFIG_TCP_CONG_ADVANCED")
fi

if [ "${OP_IP_SET:-false}" = "true" ]; then
  OPTIONS+=("CONFIG_IP6_NF_NAT")
fi

CONFIG_STRING="${OPTIONS[*]}"
export_env "CONFIG_FAKE_DISABLE" "$CONFIG_STRING"
log_success "Fake config.gz patch applied (CONFIG_FAKE_DISABLE='${CONFIG_STRING}')"
log_endgroup
