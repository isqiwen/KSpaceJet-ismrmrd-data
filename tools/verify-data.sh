#!/usr/bin/env bash
# Verify the layout and integrity metadata of ISMRMRD dataset directories.

set -u
set -o pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf '%s\n' 'ERROR: verify-data.sh requires Bash 4 or newer.' >&2
  exit 2
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
DATASETS_DIR=${DATASETS_DIR:-"$REPO_ROOT/datasets"}

errors=0
dataset_count=0
checksum_tool=''
declare -a raw_paths
declare -A raw_seen
declare -A manifest_hashes

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  errors=$((errors + 1))
}

is_raw_data() {
  case "$1" in
    *.mrd|*.h5) return 0 ;;
    *) return 1 ;;
  esac
}

require_regular_file() {
  local dataset=$1 name=$2 path="$1/$2"

  if [[ -L "$path" || ! -f "$path" ]]; then
    fail "$(basename -- "$dataset"): missing or invalid required file: $name"
  fi
}

validate_yaml() {
  local dataset=$1 file="$1/dataset.yaml"

  [[ -L "$file" || ! -f "$file" ]] && return

  if [[ ! -s "$file" ]]; then
    fail "$(basename -- "$dataset"): dataset.yaml is empty"
    return
  fi

  # Ruby's Psych parser is present on many developer machines and gives a real
  # syntax check.  Without it, retain a dependency-free mapping sanity check.
  if command -v ruby >/dev/null 2>&1; then
    if ! ruby -ryaml -e '
      value = YAML.safe_load(File.read(ARGV.fetch(0)))
      exit(value.is_a?(Hash) && !value.empty? ? 0 : 1)
    ' "$file" >/dev/null 2>&1; then
      fail "$(basename -- "$dataset"): dataset.yaml must be a non-empty YAML mapping"
    fi
  elif ! awk '
    /^[[:space:]]*($|#|---|%YAML)/ { next }
    /^[[:space:]]*[^[:space:]#][^:]*:[[:space:]]*/ { found = 1; exit }
    END { exit !found }
  ' "$file"; then
    fail "$(basename -- "$dataset"): dataset.yaml has no apparent YAML mapping"
  fi
}

add_raw_file() {
  local dataset=$1 path=$2 relative=${2#"$1/"}

  if [[ -n ${raw_seen["$relative"]+present} ]]; then
    fail "$(basename -- "$dataset"): duplicate raw-data path: $relative"
    return
  fi

  raw_seen["$relative"]=1
  raw_paths+=("$relative")
}

scan_ocmr_group() {
  local dataset=$1 group=$2 path relative

  while IFS= read -r -d '' path; do
    relative=${path#"$dataset/"}

    if [[ -L "$path" ]]; then
      fail "$(basename -- "$dataset"): symlinks are not allowed: $relative"
    elif [[ -d "$path" ]]; then
      : # Nested directories may only contain raw data, checked below.
    elif [[ -f "$path" ]]; then
      if is_raw_data "$path"; then
        add_raw_file "$dataset" "$path"
      else
        fail "$(basename -- "$dataset"): unsupported file in raw-data group: $relative"
      fi
    else
      fail "$(basename -- "$dataset"): unsupported filesystem entry: $relative"
    fi
  done < <(find -P "$group" -mindepth 1 -print0)
}

ensure_checksum_tool() {
  if [[ -n "$checksum_tool" ]]; then
    return 0
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    checksum_tool=sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    checksum_tool=shasum
  else
    fail 'neither sha256sum nor shasum is available to verify raw-data checksums'
    return 1
  fi
}

hash_file() {
  local file=$1

  case "$checksum_tool" in
    sha256sum) sha256sum -- "$file" | awk '{ print $1 }' ;;
    shasum) shasum -a 256 -- "$file" | awk '{ print $1 }' ;;
    *) return 1 ;;
  esac
}

validate_checksums() {
  local dataset=$1 manifest="$1/SHA256SUMS" line line_number=0
  local expected relative actual normalized_expected

  [[ -L "$manifest" || ! -f "$manifest" ]] && return

  manifest_hashes=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))

    # Comment-only manifests are valid for template datasets with no payload.
    if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    # Accept conventional sha256sum output (including the optional binary '*')
    # and the common single-space form used by hand-maintained manifests.
    if [[ ! "$line" =~ ^([[:xdigit:]]{64})[[:space:]]+\*?(.+)$ ]]; then
      fail "$(basename -- "$dataset"): SHA256SUMS:$line_number is not a sha256sum entry"
      continue
    fi

    expected=${BASH_REMATCH[1]}
    relative=${BASH_REMATCH[2]}

    if [[ -z ${raw_seen["$relative"]+present} ]]; then
      fail "$(basename -- "$dataset"): SHA256SUMS:$line_number references a non-payload path: $relative"
    elif [[ -n ${manifest_hashes["$relative"]+present} ]]; then
      fail "$(basename -- "$dataset"): SHA256SUMS has a duplicate entry for: $relative"
    else
      manifest_hashes["$relative"]=$expected
    fi
  done < "$manifest"

  (( ${#raw_paths[@]} == 0 )) && return

  ensure_checksum_tool || return
  for relative in "${raw_paths[@]}"; do
    if [[ -z ${manifest_hashes["$relative"]+present} ]]; then
      fail "$(basename -- "$dataset"): SHA256SUMS is missing: $relative"
      continue
    fi

    if ! actual=$(hash_file "$dataset/$relative"); then
      fail "$(basename -- "$dataset"): could not hash: $relative"
      continue
    fi
    normalized_expected=$(printf '%s' "${manifest_hashes["$relative"]}" | tr '[:upper:]' '[:lower:]')
    if [[ "$actual" != "$normalized_expected" ]]; then
      fail "$(basename -- "$dataset"): checksum mismatch: $relative"
    fi
  done
}

validate_dataset() {
  local dataset=$1 name entry base

  name=$(basename -- "$dataset")
  raw_paths=()
  raw_seen=()

  require_regular_file "$dataset" dataset.yaml
  require_regular_file "$dataset" SHA256SUMS
  require_regular_file "$dataset" LICENSE.txt
  validate_yaml "$dataset"

  while IFS= read -r -d '' entry; do
    base=$(basename -- "$entry")

    if [[ -L "$entry" ]]; then
      fail "$name: symlinks are not allowed: $base"
    elif [[ -f "$entry" ]]; then
      case "$base" in
        dataset.yaml|SHA256SUMS|LICENSE.txt) ;;
        *)
          if is_raw_data "$base"; then
            add_raw_file "$dataset" "$entry"
          else
            fail "$name: unsupported file: $base"
          fi
          ;;
      esac
    elif [[ -d "$entry" ]]; then
      if [[ "$name" == ocmr-cardiac && ( "$base" == fully-sampled || "$base" == undersampled ) ]]; then
        scan_ocmr_group "$dataset" "$entry"
      else
        fail "$name: unsupported directory: $base"
      fi
    else
      fail "$name: unsupported filesystem entry: $base"
    fi
  done < <(find -P "$dataset" -mindepth 1 -maxdepth 1 -print0)

  validate_checksums "$dataset"
}

if [[ ! -d "$DATASETS_DIR" || -L "$DATASETS_DIR" ]]; then
  fail "datasets directory does not exist or is a symlink: $DATASETS_DIR"
else
  while IFS= read -r -d '' entry; do
    if [[ -L "$entry" || ! -d "$entry" ]]; then
      fail "datasets/: only dataset directories are allowed: $(basename -- "$entry")"
      continue
    fi

    dataset_count=$((dataset_count + 1))
    validate_dataset "$entry"
  done < <(find -P "$DATASETS_DIR" -mindepth 1 -maxdepth 1 -print0)

  if (( dataset_count == 0 )); then
    fail 'datasets/: no dataset directories found'
  fi
fi

if (( errors > 0 )); then
  printf 'Verification failed with %d error(s).\n' "$errors" >&2
  exit 1
fi

printf 'Verified %d dataset director%s.\n' "$dataset_count" "$([[ $dataset_count == 1 ]] && printf y || printf ies)"
