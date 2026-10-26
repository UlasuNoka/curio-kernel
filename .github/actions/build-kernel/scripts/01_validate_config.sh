#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

log_group "Parse and Validate Configuration"

if [ -z "${RAW_OP_CONFIG_JSON:-}" ]; then
  log_error "Input 'op_config_json' is empty or not provided."
  exit 1
fi

printf '%s\n' "$RAW_OP_CONFIG_JSON" > /tmp/config.json

echo "Parsed device configuration:"
jq '.' /tmp/config.json

# Export all JSON keys as OP_<KEY> to current shell and GITHUB_ENV
while IFS='=' read -r key val; do
  [ -z "$key" ] && continue
  export_env "$key" "$val"
done < <(jq -r 'to_entries[] | "OP_\(.key | ascii_upcase)=\(.value)"' /tmp/config.json)

model="${OP_MODEL:-}"
soc="${OP_SOC:-}"
branch="${OP_BRANCH:-}"
manifest="${OP_MANIFEST:-}"
android_version="${OP_ANDROID_VERSION:-}"
kernel_version="${OP_KERNEL_VERSION:-}"
os_version="${OP_OS_VERSION:-}"
hmbird="${OP_HMBIRD:-}"
opt="${OP_OPT:-}"
bbg="${OP_BBG:-}"
bbr="${OP_BBR:-}"
bbr3="${OP_BBR3:-}"
ttl="${OP_TTL:-}"
ip_set="${OP_IP_SET:-}"
rust_build="${OP_RUST_BUILD:-}"
lto="${OP_LTO:-}"
unicode="${OP_UNICODE:-}"
ds="${OP_DS:-}"
ntsync="${OP_NTSYNC:-}"
zram="${OP_ZRAM_COMPRESSION:-}"
localver="${OP_KERNEL_LOCALVERSION:-}"
optimize="${OP_OPTIMIZE_LEVEL:-O2}"

errors=()

if [[ -z "$model" ]]; then
  errors+=("Input 'model' cannot be empty")
elif [[ ! "$model" =~ ^[A-Za-z0-9._-]+$ ]]; then
  errors+=("Input 'model' contains invalid characters. Allowed: letters, digits, ., _, -. Got: '$model'")
fi

if [[ -z "$soc" ]]; then
  errors+=("Input 'soc' cannot be empty")
elif [[ ! "$soc" =~ ^[A-Za-z0-9_-]+$ ]]; then
  errors+=("Input 'soc' contains invalid characters. Allowed: letters, digits, underscore, dash. Got: '$soc'")
fi

if [[ -z "$branch" ]]; then
  errors+=("Input 'branch' cannot be empty")
elif [[ ! "$branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  errors+=("Input 'branch' contains invalid characters. Allowed: letters, digits, ., _, -, /. Got: '$branch'")
fi

if [[ -z "$manifest" ]]; then
  errors+=("Input 'manifest' cannot be empty")
elif [[ "$manifest" == http*://* ]]; then
  if [[ ! "$manifest" =~ ^https:// ]]; then
    errors+=("Manifest URL must be HTTPS. Got: '$manifest'")
  fi
  if [[ ! "$manifest" =~ \.xml($|\?) ]]; then
    errors+=("Manifest URL should point to an XML file (.xml). Got: '$manifest'")
  fi
else
  if [[ ! "$manifest" =~ \.xml$ ]]; then
    errors+=("Manifest filename must end with .xml. Got: '$manifest'")
  fi
  if [[ "$manifest" =~ [[:space:]] ]]; then
    errors+=("Manifest filename cannot contain spaces. Got: '$manifest'")
  fi
fi

if [[ -z "$android_version" ]]; then
  errors+=("Input 'android_version' cannot be empty")
elif [[ ! "$android_version" =~ ^android[0-9]+$ ]]; then
  errors+=("Input 'android_version' contains invalid characters. Allowed: android followed by a number. Got: '$android_version'")
fi

if [[ -z "$kernel_version" ]]; then
  errors+=("Input 'kernel_version' cannot be empty")
elif [[ ! "$kernel_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
  errors+=("Input 'kernel_version' contains invalid characters. Allowed: number in X.Y format. Got: '$kernel_version'")
fi

if [[ -z "$os_version" ]]; then
  errors+=("Input 'os_version' cannot be empty")
elif [[ ! "$os_version" =~ ^A ]]; then
  errors+=("Input 'os_version' does not start with 'A'. Got: '$os_version'")
fi

validate_bool() {
  local name="$1"
  local val="$2"
  if [[ -z "$val" ]]; then
    errors+=("Input '$name' cannot be empty")
  elif [[ "$val" != "true" && "$val" != "false" ]]; then
    errors+=("Input '$name' contains invalid characters. Allowed: 'true' or 'false'. Got: '$val'")
  fi
}

validate_bool "hmbird" "$hmbird"
validate_bool "opt" "$opt"
validate_bool "bbg" "$bbg"
validate_bool "bbr" "$bbr"
validate_bool "bbr3" "$bbr3"
validate_bool "ttl" "$ttl"
validate_bool "ip_set" "$ip_set"
validate_bool "rust_build" "$rust_build"
validate_bool "unicode" "$unicode"
validate_bool "ds" "$ds"
validate_bool "ntsync" "$ntsync"

if [[ -z "$lto" ]]; then
  errors+=("Input 'lto' cannot be empty")
elif [[ "$lto" != "none" && "$lto" != "thin" && "$lto" != "full" ]]; then
  errors+=("Input 'lto' contains invalid characters. Allowed: 'thin', 'full' or 'none'. Got: '$lto'")
fi

if [[ -n "$zram" && "$zram" != "null" && "$zram" != "default" && \
      "$zram" != "lzo" && "$zram" != "lzo-rle" && \
      "$zram" != "lz4" && "$zram" != "zstd" && \
      "$zram" != "lz4k" && "$zram" != "zstdn" && "$zram" != "zstdn_o" ]]; then
  errors+=("Input 'zram_compression' contains invalid algorithm. Got: '$zram'")
fi

if [[ -n "$localver" && "$localver" != "null" && "$localver" =~ [[:space:]] ]]; then
  errors+=("Input 'kernel_localversion' cannot contain spaces. Got: '$localver'")
fi

case "$optimize" in
  O2|O3) ;;
  *) errors+=("optimize_level must be O2 or O3. Got: '$optimize'") ;;
esac

if [ ${#errors[@]} -ne 0 ]; then
  echo "Found ${#errors[@]} validation error(s):" >&2
  for error in "${errors[@]}"; do
    echo "  - $error" >&2
  done
  log_error "Input validation failed. See logs for details."
  exit 1
fi

log_success "Input validation passed"

# Extract normalized platform identifier (e.g. "wild/sm8750" -> "sm8750", "sm8750" -> "sm8750")
OP_PLATFORM="${OP_BRANCH#*/}"
export_env "OP_PLATFORM" "$OP_PLATFORM"

# Create base configuration folder required by kernel-source-sync
CONFIG="$OP_MODEL"
echo "Creating folder for configuration: $CONFIG"
mkdir -p "$CONFIG"
export_env "CONFIG" "$CONFIG"

log_endgroup
