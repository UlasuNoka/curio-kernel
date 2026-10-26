#!/usr/bin/env bash
set -euo pipefail

echo "::group::Runner Provisioning"

if [ "${PRUNE_DISK:-false}" = "true" ]; then
  echo "[INFO] Reclaiming runner disk space in background..."
  RECLAIM_PATHS=(
    /usr/share/dotnet
    /usr/local/lib/android
    /opt/ghc
    /opt/hostedtoolcache/CodeQL
    /opt/hostedtoolcache/go
    /opt/hostedtoolcache/PyPy
    /opt/hostedtoolcache/node
    /usr/local/share/chromium
    /usr/local/share/powershell
    /opt/az
    /opt/microsoft/powershell
  )
  (
    for target in "${RECLAIM_PATHS[@]}"; do
      [ -e "$target" ] && sudo rm -rf "$target" || true
    done
  ) >/dev/null 2>&1 &
  disown
fi

echo "[INFO] Installing kernel build packages..."
sudo apt-get -o Acquire::Retries=3 update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  aria2 bc bison build-essential ca-certificates ccache clang curl dos2unix dwarves \
  elfutils file flex git jq kmod libdw-dev libelf-dev libssl-dev libncurses-dev \
  libxml2-utils lz4 pigz python3 rsync unzip wget xz-utils zip zlib1g-dev zstd
sudo apt-get clean

CCACHE_URL="https://github.com/ccache/ccache/releases/download/v4.14.3/ccache-4.14.3-linux-x86_64-musl-static.tar.xz"
CCACHE_SHA="d553fac006ed93a37342cee9228cf4e13dd66690fa1a8075c54c7bace9b72ae6"
CCACHE_TMP=$(mktemp -d)
if curl -LfsS --retry 3 --connect-timeout 20 --max-time 60 "$CCACHE_URL" -o "${CCACHE_TMP}/ccache.tar.xz"; then
  echo "${CCACHE_SHA}  ${CCACHE_TMP}/ccache.tar.xz" | sha256sum -c -
  tar -xJf "${CCACHE_TMP}/ccache.tar.xz" -C "$CCACHE_TMP"
  CCACHE_BIN=$(find "$CCACHE_TMP" -maxdepth 2 -type f -name ccache | head -n 1)
  sudo install -m 0755 "$CCACHE_BIN" /usr/bin/ccache
  echo "[OK] Installed official ccache: $(ccache --version | head -n1)"
else
  echo "[WARN] Failed to fetch ccache v4.14.3; using distro ccache: $(ccache --version | head -n1)"
fi
rm -rf "$CCACHE_TMP"

CACHE_ROOT="${GITHUB_WORKSPACE}/.ccache"
mkdir -p "$CACHE_ROOT"

{
  echo "CCACHE_DIR=${CACHE_ROOT}"
  echo "CCACHE_MAXSIZE=${CCACHE_LIMIT:-12G}"
  echo "CCACHE_COMPILERCHECK=content"
  echo "CCACHE_BASEDIR=${GITHUB_WORKSPACE}"
  echo "CCACHE_NOHASHDIR=true"
  echo "CCACHE_IGNOREOPTIONS=--sysroot*"
  echo "CCACHE_COMPRESS=true"
  echo "CCACHE_COMPRESSLEVEL=3"
  echo "CCACHE_DIRECT=true"
  echo "CCACHE_FILECLONE=true"
  echo "CCACHE_INODECACHE=true"
  echo "CCACHE_DEPEND=true"
  echo "CCACHE_UMASK=002"
  echo "CCACHE_LOGFILE=${GITHUB_WORKSPACE}/ccache.log"
  echo "CCACHE_SLOPPINESS=file_macro,time_macros,include_file_mtime,include_file_ctime,incbin,locale"
} >> "$GITHUB_ENV"

echo "[OK] Runner environment ready"
echo "::endgroup::"
