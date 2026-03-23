#!/usr/bin/env bash
# install_psycopg.sh — Detect and/or install Psycopg (v2 or v3) inside a Python env.
# Part of the LASH modular installer framework.
#
# Provider config: config/psycopg.json
# Schema:
#   installations.<psycopg_id>.id
#   installations.<psycopg_id>.python_id
#   installations.<psycopg_id>.package_name   (psycopg2-binary | psycopg | psycopg[binary])
#   installations.<psycopg_id>.version
#   installations.<psycopg_id>.install_status
#
# This script expects SELECTED_PYTHON_ID and SELECTED_PYTHON_EXE to be set in
# the calling environment, or it will read them from config/python.json interactively.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

PSYCOPG_CONFIG="${LASH_CONFIG_DIR}/psycopg.json"
PYTHON_CONFIG="${LASH_CONFIG_DIR}/python.json"

log_section "Psycopg Installer"

# ---------------------------------------------------------------------------
# 1. Initialise config file
# ---------------------------------------------------------------------------
init_json_file "$PSYCOPG_CONFIG" '{"installations":{}}'

# ---------------------------------------------------------------------------
# 2. Resolve which Python to use
# ---------------------------------------------------------------------------
if [[ -z "${SELECTED_PYTHON_ID:-}" ]]; then
    ids=()
    while IFS= read -r k; do ids+=("$k"); done < <(json_get "$PYTHON_CONFIG" '.installations | keys[]')
    if [[ ${#ids[@]} -eq 0 ]]; then
        log_warn "No Python installation found. Running install_python.sh first..."
        call_installer "install_python.sh"
        while IFS= read -r k; do ids+=("$k"); done < <(json_get "$PYTHON_CONFIG" '.installations | keys[]')
    fi
    if [[ ${#ids[@]} -eq 1 ]]; then
        SELECTED_PYTHON_ID="${ids[0]}"
    else
        labels=()
        for k in "${ids[@]}"; do
            exe=$(json_get "$PYTHON_CONFIG" ".installations[\"$k\"].executable")
            ver=$(json_get "$PYTHON_CONFIG" ".installations[\"$k\"].version")
            labels+=("$k ($exe, $ver)")
        done
        selection=$(ask_choice "Which Python should Psycopg be installed into?" "${labels[@]}")
        SELECTED_PYTHON_ID="${selection%% *}"
    fi
fi

SELECTED_PYTHON_EXE=$(json_get "$PYTHON_CONFIG" ".installations[\"${SELECTED_PYTHON_ID}\"].executable")
log_info "Using Python: ${SELECTED_PYTHON_EXE} (${SELECTED_PYTHON_ID})"

# ---------------------------------------------------------------------------
# 3. Detect Psycopg inside the selected Python environment
# ---------------------------------------------------------------------------
detect_psycopg() {
    local python_exe="$1"
    # Try psycopg (v3) first, then psycopg2.
    for pkg in psycopg psycopg2; do
        ver=$("$python_exe" -c "import ${pkg}; print(${pkg}.__version__)" 2>/dev/null) && {
            echo "${pkg}|${ver}"
            return 0
        }
    done
    return 1
}

existing_pkg_info=$(detect_psycopg "$SELECTED_PYTHON_EXE" || true)

if [[ -n "$existing_pkg_info" ]]; then
    pkg_name="${existing_pkg_info%%|*}"
    pkg_ver="${existing_pkg_info##*|}"
    log_info "Psycopg already installed: ${pkg_name} ${pkg_ver}"
else
    log_info "Psycopg not found. Installing psycopg[binary] (v3)..."
    "$SELECTED_PYTHON_EXE" -m pip install --quiet "psycopg[binary]"
    existing_pkg_info=$(detect_psycopg "$SELECTED_PYTHON_EXE")
    pkg_name="${existing_pkg_info%%|*}"
    pkg_ver="${existing_pkg_info##*|}"
    log_info "Installed: ${pkg_name} ${pkg_ver}"
fi

# ---------------------------------------------------------------------------
# 4. Record in config/psycopg.json
# ---------------------------------------------------------------------------
existing_id=$(json_get "$PSYCOPG_CONFIG" \
    ".installations | to_entries[] | select(.value.python_id == \"${SELECTED_PYTHON_ID}\") | .key" | head -1)

if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
    psycopg_id="$existing_id"
    log_info "Updating existing Psycopg record: $psycopg_id"
else
    psycopg_id=$(generate_id "psycopg")
    log_info "Recording new Psycopg: $psycopg_id"
fi

record=$(jq -n \
    --arg id    "$psycopg_id" \
    --arg pyid  "$SELECTED_PYTHON_ID" \
    --arg pkg   "$pkg_name" \
    --arg ver   "$pkg_ver" \
    '{id:$id, python_id:$pyid, package_name:$pkg,
      version:$ver, install_status:"installed"}')
json_upsert_record "$PSYCOPG_CONFIG" ".installations" "$psycopg_id" "$record"

# Export for the calling script
export RESOLVED_PSYCOPG_ID="$psycopg_id"
log_info "Psycopg installer complete. Resolved ID: ${psycopg_id}"
