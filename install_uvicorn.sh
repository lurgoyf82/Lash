#!/usr/bin/env bash
# install_uvicorn.sh — Detect and/or install Uvicorn inside a Python env.
# Part of the LASH modular installer framework.
#
# Consumer config: config/uvicorn.json
# Provider configs consumed (by reference ID only):
#   config/python.json
#   config/fastapi.json

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

UV_CONFIG="${LASH_CONFIG_DIR}/uvicorn.json"
PYTHON_CONFIG="${LASH_CONFIG_DIR}/python.json"
FA_CONFIG="${LASH_CONFIG_DIR}/fastapi.json"

log_section "Uvicorn Installer"

# ---------------------------------------------------------------------------
# 1. Initialise config file
# ---------------------------------------------------------------------------
init_json_file "$UV_CONFIG" '{
  "installation_id": null,
  "selected_python_id": null,
  "selected_fastapi_id": null,
  "host": "0.0.0.0",
  "port": 8000,
  "workers": 1,
  "dependency_ready": {"python": false, "fastapi": false},
  "install_status": "pending",
  "version": null
}'

# ---------------------------------------------------------------------------
# 2. FastAPI dependency (which in turn resolves Python)
# ---------------------------------------------------------------------------
call_installer "install_fastapi.sh"

SELECTED_PYTHON_ID="${RESOLVED_FASTAPI_PYTHON_ID:-}"
if [[ -z "$SELECTED_PYTHON_ID" ]]; then
    SELECTED_PYTHON_ID=$(json_get "$FA_CONFIG" '.selected_python_id')
fi
SELECTED_FASTAPI_ID="${RESOLVED_FASTAPI_ID:-}"
if [[ -z "$SELECTED_FASTAPI_ID" ]]; then
    SELECTED_FASTAPI_ID=$(json_get "$FA_CONFIG" '.installation_id')
fi

SELECTED_PYTHON_EXE=$(json_get "$PYTHON_CONFIG" ".installations[\"${SELECTED_PYTHON_ID}\"].executable")

json_set_key "$UV_CONFIG" '.selected_python_id'       "\"${SELECTED_PYTHON_ID}\""
json_set_key "$UV_CONFIG" '.selected_fastapi_id'      "\"${SELECTED_FASTAPI_ID}\""
json_set_key "$UV_CONFIG" '.dependency_ready.python'  'true'
json_set_key "$UV_CONFIG" '.dependency_ready.fastapi' 'true'

# ---------------------------------------------------------------------------
# 3. Collect runtime settings
# ---------------------------------------------------------------------------
CURRENT_UV_HOST=$(json_get "$UV_CONFIG" '.host')
CURRENT_UV_PORT=$(json_get "$UV_CONFIG" '.port')
CURRENT_UV_WORKERS=$(json_get "$UV_CONFIG" '.workers')

[[ "$CURRENT_UV_HOST" == "null" || -z "$CURRENT_UV_HOST" ]] && CURRENT_UV_HOST="0.0.0.0"
[[ "$CURRENT_UV_PORT" == "null" || -z "$CURRENT_UV_PORT" ]] && CURRENT_UV_PORT="8000"
[[ "$CURRENT_UV_WORKERS" == "null" || -z "$CURRENT_UV_WORKERS" ]] && CURRENT_UV_WORKERS="1"

UV_HOST=$(ask_input "Uvicorn bind host" "${CURRENT_UV_HOST}")
UV_PORT=$(ask_input "Uvicorn port" "${CURRENT_UV_PORT}")
UV_WORKERS=$(ask_input "Number of Uvicorn workers" "${CURRENT_UV_WORKERS}")

json_set_key "$UV_CONFIG" '.host'    "\"${UV_HOST}\""
json_set_key "$UV_CONFIG" '.port'    "${UV_PORT}"
json_set_key "$UV_CONFIG" '.workers' "${UV_WORKERS}"

# ---------------------------------------------------------------------------
# 4. Install Uvicorn
# ---------------------------------------------------------------------------
log_info "Installing Uvicorn into ${SELECTED_PYTHON_EXE}..."
"$SELECTED_PYTHON_EXE" -m pip install --quiet "uvicorn[standard]"

UV_VERSION=$("$SELECTED_PYTHON_EXE" -c "import uvicorn; print(uvicorn.__version__)" 2>/dev/null)
log_info "Uvicorn ${UV_VERSION} installed."

UV_ID=$(generate_id "uvicorn")
json_set_key "$UV_CONFIG" '.installation_id' "\"${UV_ID}\""
json_set_key "$UV_CONFIG" '.version'          "\"${UV_VERSION}\""
json_set_key "$UV_CONFIG" '.install_status'   '"installed"'

log_info "Uvicorn installer complete. ID: ${UV_ID}"
