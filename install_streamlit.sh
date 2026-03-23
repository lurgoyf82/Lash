#!/usr/bin/env bash
# install_streamlit.sh — Detect and/or install Streamlit inside a Python env.
# Part of the LASH modular installer framework.
#
# Consumer config: config/streamlit.json
# Provider configs consumed (by reference ID only):
#   config/python.json

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

ST_CONFIG="${LASH_CONFIG_DIR}/streamlit.json"
PYTHON_CONFIG="${LASH_CONFIG_DIR}/python.json"

log_section "Streamlit Installer"

# ---------------------------------------------------------------------------
# 1. Initialise config file
# ---------------------------------------------------------------------------
init_json_file "$ST_CONFIG" '{
  "installation_id": null,
  "selected_python_id": null,
  "port": 8501,
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
    selection=$(ask_choice "Which Python should Streamlit use?" "${labels[@]}")
    SELECTED_PYTHON_ID="${selection%% *}"
fi

SELECTED_PYTHON_EXE=$(json_get "$PYTHON_CONFIG" ".installations[\"${SELECTED_PYTHON_ID}\"].executable")

# ---------------------------------------------------------------------------
# 3. Collect runtime settings
# ---------------------------------------------------------------------------
CURRENT_ST_PORT=$(json_get "$ST_CONFIG" '.port')
[[ "$CURRENT_ST_PORT" == "null" || -z "$CURRENT_ST_PORT" ]] && CURRENT_ST_PORT="8501"
ST_PORT=$(ask_input "Streamlit port" "${CURRENT_ST_PORT}")

json_set_key "$ST_CONFIG" '.selected_python_id'      "\"${SELECTED_PYTHON_ID}\""
json_set_key "$ST_CONFIG" '.port'                    "${ST_PORT}"
json_set_key "$ST_CONFIG" '.dependency_ready.python' 'true'

# ---------------------------------------------------------------------------
# 4. Install Streamlit
# ---------------------------------------------------------------------------
log_info "Installing Streamlit into ${SELECTED_PYTHON_EXE}..."
"$SELECTED_PYTHON_EXE" -m pip install --quiet streamlit

ST_VERSION=$("$SELECTED_PYTHON_EXE" -c "import streamlit; print(streamlit.__version__)" 2>/dev/null)
log_info "Streamlit ${ST_VERSION} installed."

ST_ID=$(generate_id "streamlit")
json_set_key "$ST_CONFIG" '.installation_id' "\"${ST_ID}\""
json_set_key "$ST_CONFIG" '.version'          "\"${ST_VERSION}\""
json_set_key "$ST_CONFIG" '.install_status'   '"installed"'

log_info "Streamlit installer complete. ID: ${ST_ID}"
