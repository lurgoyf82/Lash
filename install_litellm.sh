#!/usr/bin/env bash
# install_litellm.sh — Detect and/or install LiteLLM inside a Python env.
# Part of the LASH modular installer framework.
#
# Consumer config: config/litellm.json
# Provider configs consumed (by reference ID only):
#   config/python.json

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

LL_CONFIG="${LASH_CONFIG_DIR}/litellm.json"
PYTHON_CONFIG="${LASH_CONFIG_DIR}/python.json"

log_section "LiteLLM Installer"

# ---------------------------------------------------------------------------
# 1. Initialise config file
# ---------------------------------------------------------------------------
init_json_file "$LL_CONFIG" '{
  "installation_id": null,
  "selected_python_id": null,
  "resolved_python_executable": null,
  "port": 4000,
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
    selection=$(ask_choice "Which Python should LiteLLM use?" "${labels[@]}")
    SELECTED_PYTHON_ID="${selection%% *}"
fi

SELECTED_PYTHON_EXE=$(json_get "$PYTHON_CONFIG" ".installations[\"${SELECTED_PYTHON_ID}\"].executable")

# ---------------------------------------------------------------------------
# 3. Collect LiteLLM settings
# ---------------------------------------------------------------------------
CURRENT_LL_PORT=$(json_get "$LL_CONFIG" '.port')
[[ "$CURRENT_LL_PORT" == "null" || -z "$CURRENT_LL_PORT" ]] && CURRENT_LL_PORT="4000"
LL_PORT=$(ask_input "LiteLLM proxy port" "${CURRENT_LL_PORT}")

json_set_key "$LL_CONFIG" '.selected_python_id'      "\"${SELECTED_PYTHON_ID}\""
json_set_key "$LL_CONFIG" '.resolved_python_executable' "\"${SELECTED_PYTHON_EXE}\""
json_set_key "$LL_CONFIG" '.port'                    "${LL_PORT}"
json_set_key "$LL_CONFIG" '.dependency_ready.python' 'true'

# ---------------------------------------------------------------------------
# 4. Install LiteLLM
# ---------------------------------------------------------------------------
log_info "Installing LiteLLM into ${SELECTED_PYTHON_EXE}..."
"$SELECTED_PYTHON_EXE" -m pip install --quiet "litellm[proxy]"

LL_VERSION=$("$SELECTED_PYTHON_EXE" -c "import litellm; print(litellm.__version__)" 2>/dev/null || echo "unknown")
log_info "LiteLLM ${LL_VERSION} installed."

LL_ID=$(generate_id "litellm")
json_set_key "$LL_CONFIG" '.installation_id' "\"${LL_ID}\""
json_set_key "$LL_CONFIG" '.version'          "\"${LL_VERSION}\""
json_set_key "$LL_CONFIG" '.install_status'   '"installed"'

log_info "LiteLLM installer complete. ID: ${LL_ID}"
