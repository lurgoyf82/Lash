#!/usr/bin/env bash
# install_autogen.sh — Detect and/or install AutoGen (AG2) inside a Python env.
# Part of the LASH modular installer framework.
#
# Consumer config: config/autogen.json
# Provider configs consumed (by reference ID only):
#   config/python.json
#   config/litellm.json  (model access layer)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

AG_CONFIG="${LASH_CONFIG_DIR}/autogen.json"
PYTHON_CONFIG="${LASH_CONFIG_DIR}/python.json"
LL_CONFIG="${LASH_CONFIG_DIR}/litellm.json"

log_section "AutoGen / AG2 Installer"

# ---------------------------------------------------------------------------
# 1. Initialise config file
# ---------------------------------------------------------------------------
init_json_file "$AG_CONFIG" '{
  "installation_id": null,
  "selected_python_id": null,
  "resolved_python_executable": null,
  "selected_litellm_id": null,
  "dependency_ready": {"python": false, "litellm": false},
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
    selection=$(ask_choice "Which Python should AutoGen use?" "${labels[@]}")
    SELECTED_PYTHON_ID="${selection%% *}"
fi

SELECTED_PYTHON_EXE=$(json_get "$PYTHON_CONFIG" ".installations[\"${SELECTED_PYTHON_ID}\"].executable")
APP_VENV_DIR="${LASH_INSTALLER_DIR}/.venv/apps/${SELECTED_PYTHON_ID}"
APP_PYTHON_EXE=$(resolve_managed_python_runtime "$SELECTED_PYTHON_EXE" "$APP_VENV_DIR")
json_set_key "$AG_CONFIG" '.selected_python_id'         "\"${SELECTED_PYTHON_ID}\""
json_set_key "$AG_CONFIG" '.resolved_python_executable' "\"${APP_PYTHON_EXE}\""
json_set_key "$AG_CONFIG" '.dependency_ready.python'    'true'

# ---------------------------------------------------------------------------
# 3. LiteLLM dependency (model access layer)
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

ll_status=$(json_get "$LL_CONFIG" '.install_status')
if [[ "$ll_status" != "installed" ]]; then
    log_info "LiteLLM not installed yet. Running install_litellm.sh..."
    call_installer "install_litellm.sh"
fi

SELECTED_LITELLM_ID=$(json_get "$LL_CONFIG" '.installation_id')
json_set_key "$AG_CONFIG" '.selected_litellm_id'       "\"${SELECTED_LITELLM_ID}\""
json_set_key "$AG_CONFIG" '.dependency_ready.litellm'  'true'

# ---------------------------------------------------------------------------
# 4. Install AutoGen (ag2 package)
# ---------------------------------------------------------------------------
log_info "Installing AutoGen (ag2) into ${APP_PYTHON_EXE}..."
# ag2 is the community-maintained fork of AutoGen
AG_VERSION=$(ensure_python_package_installed "$APP_PYTHON_EXE" "ag2[openai]" "autogen" 'print(getattr(autogen, "__version__", "unknown"))')

log_info "AutoGen ${AG_VERSION} installed."

AG_ID=$(generate_id "autogen")
json_set_key "$AG_CONFIG" '.installation_id' "\"${AG_ID}\""
json_set_key "$AG_CONFIG" '.version'          "\"${AG_VERSION}\""
json_set_key "$AG_CONFIG" '.install_status'   '"installed"'

log_info "AutoGen installer complete. ID: ${AG_ID}"
