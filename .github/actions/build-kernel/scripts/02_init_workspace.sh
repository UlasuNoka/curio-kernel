#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

log_group "Initialize Workspace Directories & Build Tools"

CONFIG_DIR="${GITHUB_WORKSPACE}/${CONFIG}"
ARTIFACTS_DIR="${CONFIG_DIR}/artifacts"
KERNEL_PLATFORM_DIR="${CONFIG_DIR}/kernel_platform"
COMMON_KERNEL_DIR="${KERNEL_PLATFORM_DIR}/common"
MSM_KERNEL_DIR="${KERNEL_PLATFORM_DIR}/msm-kernel"
AK3_DIR="${CONFIG_DIR}/AnyKernel3"
DEBUG_ARTIFACTS_DIR="${GITHUB_WORKSPACE}/debug_artifacts"
KERNEL_PATCHES_DIR="${GITHUB_WORKSPACE}/kernel_patches"

mkdir -p "$ARTIFACTS_DIR"
mkdir -p "$DEBUG_ARTIFACTS_DIR"

export_env "CONFIG_FOLDER" "$CONFIG_DIR"
export_env "ARTIFACTS_FOLDER" "$ARTIFACTS_DIR"
export_env "KERNEL_PLATFORM_FOLDER" "$KERNEL_PLATFORM_DIR"
export_env "COMMON_KERNEL_FOLDER" "$COMMON_KERNEL_DIR"
export_env "MSM_KERNEL_FOLDER" "$MSM_KERNEL_DIR"
export_env "AK3_FOLDER" "$AK3_DIR"
export_env "DEBUG_ARTIFACTS_FOLDER" "$DEBUG_ARTIFACTS_DIR"
export_env "KERNEL_PATCHES_FOLDER" "$KERNEL_PATCHES_DIR"

ZIP_MODEL=$(echo "$OP_MODEL" | sed 's/-[0-9]\+\.[0-9]\+\.[0-9]\+$//')
VARIANT="${OP_VARIANT:-}"

if [ -n "$VARIANT" ] && [ "${VARIANT,,}" != "${OP_MODEL,,}" ] && [ "${VARIANT,,}" != "${ZIP_MODEL,,}" ] && [ "${VARIANT,,}" != "default" ]; then
  ARTIFACT_TAG="${ZIP_MODEL}_${VARIANT}"
else
  ARTIFACT_TAG="${ZIP_MODEL}"
fi

export_env "ARTIFACT_TAG" "$ARTIFACT_TAG"

DEBUG_ZIP_NAME="debug_${ARTIFACT_TAG}_${OP_OS_VERSION}.zip"
export_env "DEBUG_ZIP_NAME" "$DEBUG_ZIP_NAME"

# Add kernel build-tools to PATH
add_path "${KERNEL_PLATFORM_DIR}/prebuilts/kernel-build-tools/linux-x86/bin/"
add_path "${KERNEL_PLATFORM_DIR}/prebuilts/kernel-build-tools/linux_musl-x86/bin/"

log_endgroup

log_group "Configure Kernel Localversion"

LOCALVER="${OP_KERNEL_LOCALVERSION:-}"
if [ -n "$LOCALVER" ] && [ "$LOCALVER" != "null" ]; then
  cd "$COMMON_KERNEL_DIR"

  printf '#!/bin/sh\necho "%s"\n' "$LOCALVER" > scripts/setlocalversion
  chmod +x scripts/setlocalversion

  log_success "Kernel localversion override: ${LOCALVER}"
else
  log_info "Localversion: auto (kernel tree default)"
fi

log_endgroup

log_group "Get Kernel Version Info"

cd "$COMMON_KERNEL_DIR"

CONFIG_FILES=("build.config.common" "build.config.constants")
BRANCH_LINE=""
for f in "${CONFIG_FILES[@]}"; do
  if [ -f "$f" ]; then
    l=$(grep '^[[:space:]]*BRANCH=' "$f" || true)
    if [ -n "$l" ]; then
      BRANCH_LINE="$l"
      break
    fi
  fi
done

if [ -z "$BRANCH_LINE" ]; then
  log_error "No BRANCH= found in config files"
  exit 1
fi

BRANCH_VALUE="${BRANCH_LINE#*=}"
ANDROID_VERSION="${BRANCH_VALUE%-*}"

if [ -z "$ANDROID_VERSION" ]; then
  log_error "Could not parse android version from BRANCH=$BRANCH_VALUE"
  exit 1
fi

VERSION=$(grep '^VERSION *=' Makefile | awk '{print $3}')
PATCHLEVEL=$(grep '^PATCHLEVEL *=' Makefile | awk '{print $3}')
SUBLEVEL=$(grep '^SUBLEVEL *=' Makefile | awk '{print $3}')
FULL_VERSION="${VERSION}.${PATCHLEVEL}.${SUBLEVEL}"

cd "$ARTIFACTS_DIR"
echo "${ANDROID_VERSION}-${FULL_VERSION}" > "${OP_MODEL}_${OP_OS_VERSION}.txt"
echo "${OP_OS_VERSION}" >> "${OP_MODEL}_${OP_OS_VERSION}.txt"

export_env "ANDROID_VER" "$ANDROID_VERSION"
export_env "KERNEL_VER" "${VERSION}.${PATCHLEVEL}"
export_env "TKERNEL_VER" "$FULL_VERSION"
export_env "KERNEL_FULL_VER" "${ANDROID_VERSION}-${FULL_VERSION}"

log_success "Detected: ${ANDROID_VERSION}-${FULL_VERSION}"
log_endgroup

log_group "Set Build Identity"

BUILD_USER="${DEFAULT_BUILD_USER:-kleaf}"
BUILD_HOST="${DEFAULT_BUILD_HOST:-build-host}"

export_env "BUILD_USER" "$BUILD_USER"
export_env "BUILD_HOST" "$BUILD_HOST"

log_success "Build identity configured: ${BUILD_USER}@${BUILD_HOST}"
log_endgroup
