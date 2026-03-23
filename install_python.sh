#!/usr/bin/env bash
# install_python.sh — Discover and/or install a Python interpreter.
# Part of the LASH modular installer framework.
#
# Provider config: config/python.json
# Schema:
#   installations.<python_id>.id
#   installations.<python_id>.executable
#   installations.<python_id>.version
#   installations.<python_id>.venv_path        (null unless a venv is selected)
#   installations.<python_id>.install_type     (system | pyenv | venv | conda)
#   installations.<python_id>.available

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

PYTHON_CONFIG="${LASH_CONFIG_DIR}/python.json"
MIN_MAJOR=3
MIN_MINOR=10

log_section "Python Installer"

# ---------------------------------------------------------------------------
# 1. Initialise config file
# ---------------------------------------------------------------------------
init_json_file "$PYTHON_CONFIG" '{"installations":{}}'

# ---------------------------------------------------------------------------
# 2. Discover existing Python installations
# ---------------------------------------------------------------------------
log_info "Scanning for Python installations..."

discover_python_installations() {
    # Collect candidate executables from well-known locations and PATH.
    local candidates=()

    # From PATH — iterate each directory individually to avoid word-splitting
    local IFS_ORIG="$IFS"
    IFS=':'
    for dir in $PATH; do
        IFS="$IFS_ORIG"
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' exe; do
            candidates+=("$exe")
        done < <(find "$dir" -maxdepth 1 -name 'python3*' -type f -print0 2>/dev/null)
    done
    IFS="$IFS_ORIG"

    # Additional well-known paths
    for extra in /usr/bin/python3 /usr/local/bin/python3 \
                 /opt/homebrew/bin/python3 \
                 ~/.pyenv/shims/python3; do
        [[ -x "$extra" ]] && candidates+=("$extra")
    done

    # Deduplicate via realpath
    local seen=()
    local unique=()
    for c in "${candidates[@]}"; do
        local real
        real=$(realpath "$c" 2>/dev/null) || continue
        local already=0
        for s in "${seen[@]:-}"; do [[ "$s" == "$real" ]] && already=1 && break; done
        if [[ $already -eq 0 ]]; then
            seen+=("$real")
            unique+=("$c")
        fi
    done

    printf '%s\n' "${unique[@]:-}"
}

VALID_PYTHONS=()

while IFS= read -r exe; do
    [[ -z "$exe" ]] && continue
    version_str=$("$exe" --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1) || continue
    major=$(echo "$version_str" | cut -d. -f1)
    minor=$(echo "$version_str" | cut -d. -f2)
    if (( major >= MIN_MAJOR && minor >= MIN_MINOR )); then
        VALID_PYTHONS+=("$exe|$version_str")
    fi
done < <(discover_python_installations)

# ---------------------------------------------------------------------------
# 3. Save all discovered installations to config/python.json
# ---------------------------------------------------------------------------
for entry in "${VALID_PYTHONS[@]:-}"; do
    exe="${entry%%|*}"
    ver="${entry##*|}"

    # Check if this executable is already recorded.
    existing_id=$(json_get "$PYTHON_CONFIG" \
        ".installations | to_entries[] | select(.value.executable == \"$exe\") | .key" | head -1)

    if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
        pid="$existing_id"
        log_info "Updating existing Python record $pid ($exe, $ver)"
    else
        pid=$(generate_id "python")
        log_info "Recording new Python: $pid ($exe, $ver)"
    fi

    record=$(jq -n \
        --arg id    "$pid" \
        --arg exe   "$exe" \
        --arg ver   "$ver" \
        '{id:$id, executable:$exe, version:$ver,
          venv_path:null, install_type:"system", available:true}')
    json_upsert_record "$PYTHON_CONFIG" ".installations" "$pid" "$record"
done

# ---------------------------------------------------------------------------
# 4. If no valid Python found, install one
# ---------------------------------------------------------------------------
if [[ ${#VALID_PYTHONS[@]} -eq 0 ]]; then
    log_warn "No compatible Python (>= ${MIN_MAJOR}.${MIN_MINOR}) found. Installing via apt-get..."
    sudo apt-get update -qq
    sudo apt-get install -y python3 python3-pip python3-venv

    exe=$(command -v python3)
    ver=$("$exe" --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
    pid=$(generate_id "python")
    record=$(jq -n \
        --arg id    "$pid" \
        --arg exe   "$exe" \
        --arg ver   "$ver" \
        '{id:$id, executable:$exe, version:$ver,
          venv_path:null, install_type:"system", available:true}')
    json_upsert_record "$PYTHON_CONFIG" ".installations" "$pid" "$record"
    VALID_PYTHONS+=("${exe}|${ver}")
fi

log_info "Python installer complete. config/python.json updated."
json_get "$PYTHON_CONFIG" '.installations | keys[]' | while read -r k; do
    exe=$(json_get "$PYTHON_CONFIG" ".installations[\"$k\"].executable")
    ver=$(json_get "$PYTHON_CONFIG" ".installations[\"$k\"].version")
    echo "  [$k] $exe ($ver)"
done
