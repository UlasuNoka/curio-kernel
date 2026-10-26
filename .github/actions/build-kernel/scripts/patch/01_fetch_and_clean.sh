#!/usr/bin/env bash
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

log_group "Fetch Patches & Packaging Dependencies"

cd "$GITHUB_WORKSPACE"

retry_clone "$PATCHES_REPO_URL" "$PATCHES_REPO_REF" "$KERNEL_PATCHES_FOLDER" "1"

# Ensure all patch files have Unix LF line endings
find "$KERNEL_PATCHES_FOLDER" -type f \( -name "*.patch" -o -name "*.sh" \) -exec dos2unix -q {} + 2>/dev/null || true

# Clone AnyKernel3 if not already populated by manifest
if [ ! -f "${AK3_FOLDER}/anykernel.sh" ]; then
  log_info "Cloning AnyKernel3 template into ${AK3_FOLDER}..."
  retry_clone "$AK3_REPO_URL" "$AK3_REPO_REF" "$AK3_FOLDER" "1"
  find "$AK3_FOLDER" -type f -name "*.sh" -exec dos2unix -q {} + 2>/dev/null || true
fi

log_success "Dependencies fetched successfully"
log_endgroup

log_group "Clean Up ABI Protected Exports"

cd "$KERNEL_PLATFORM_FOLDER"
rm -f common/android/abi_gki_protected_exports_* || true
sed -i 's/protected_modules = \[.*\]/protected_modules = []/' common/modules.bzl || true

log_success "ABI protected exports cleaned"
log_endgroup
