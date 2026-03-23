#!/usr/bin/env bash
# install_fastapi.sh — Detect and/or install FastAPI inside a Python env.
# Part of the LASH modular installer framework.
#
# Consumer config: config/fastapi.json
# Provider configs consumed (by reference ID only):
#   config/python.json

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

FA_CONFIG="${LASH_CONFIG_DIR}/fastapi.json"
PYTHON_CONFIG="${LASH_CONFIG_DIR}/python.json"

log_section "FastAPI Installer"

# ---------------------------------------------------------------------------
# 1. Initialise config file
# ---------------------------------------------------------------------------
init_json_file "$FA_CONFIG" '{
  "installation_id": null,
  "selected_python_id": null,
  "resolved_python_executable": null,
  "dependency_ready": {"python": false},
  "install_status": "pending",
  "version": null
}'

# ---------------------------------------------------------------------------
# 2. Python dependency
# ---------------------------------------------------------------------------
call_installer "install_python.sh"

python_ids=()
while IFS= read -r k; do python_ids+=("$k"); done < \
    <(json_get "$PYTHON_CONFIG" '.installations | keys[]')

if [[ ${#python_ids[@]} -eq 1 ]]; then
    SELECTED_PYTHON_ID="${python_ids[0]}"
else
    labels=()
    for k in "${python_ids[@]}"; do
        exe=$(json_get "$PYTHON_CONFIG" ".installations[\"$k\"].executable")
        ver=$(json_get "$PYTHON_CONFIG" ".installations[\"$k\"].version")
        labels+=("$k  [${exe}  v${ver}]")
    done
    selection=$(ask_choice "Which Python should FastAPI use?" "${labels[@]}")
    SELECTED_PYTHON_ID="${selection%% *}"
fi

SELECTED_PYTHON_EXE=$(json_get "$PYTHON_CONFIG" ".installations[\"${SELECTED_PYTHON_ID}\"].executable")
APP_VENV_DIR="${LASH_INSTALLER_DIR}/.venv/apps/${SELECTED_PYTHON_ID}"
APP_PYTHON_EXE=$(resolve_managed_python_runtime "$SELECTED_PYTHON_EXE" "$APP_VENV_DIR")
json_set_key "$FA_CONFIG" '.selected_python_id'         "\"${SELECTED_PYTHON_ID}\""
json_set_key "$FA_CONFIG" '.resolved_python_executable' "\"${APP_PYTHON_EXE}\""
json_set_key "$FA_CONFIG" '.dependency_ready.python'    'true'

# ---------------------------------------------------------------------------
# 3. Install FastAPI
# ---------------------------------------------------------------------------
log_info "Installing FastAPI into ${APP_PYTHON_EXE}..."
FA_VERSION=$(ensure_python_package_installed "$APP_PYTHON_EXE" "fastapi" "fastapi")

log_info "FastAPI ${FA_VERSION} installed."

FA_ID=$(generate_id "fastapi")
json_set_key "$FA_CONFIG" '.installation_id' "\"${FA_ID}\""
json_set_key "$FA_CONFIG" '.version'          "\"${FA_VERSION}\""
json_set_key "$FA_CONFIG" '.install_status'   '"installed"'

export RESOLVED_FASTAPI_ID="$FA_ID"
export RESOLVED_FASTAPI_PYTHON_ID="$SELECTED_PYTHON_ID"
export RESOLVED_FASTAPI_PYTHON="$APP_PYTHON_EXE"
log_info "FastAPI installer complete. ID: ${FA_ID}"
