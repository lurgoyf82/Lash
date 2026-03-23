#!/usr/bin/env bash
# install_celery.sh — Detect and/or install Celery inside a Python env.
# Part of the LASH modular installer framework.
#
# Consumer config: config/celery.json
# Provider configs consumed (by reference ID only):
#   config/python.json
#   config/redis.json   (Celery broker)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

CL_CONFIG="${LASH_CONFIG_DIR}/celery.json"
PYTHON_CONFIG="${LASH_CONFIG_DIR}/python.json"
REDIS_CONFIG="${LASH_CONFIG_DIR}/redis.json"

log_section "Celery Installer"

# ---------------------------------------------------------------------------
# 1. Initialise config file
# ---------------------------------------------------------------------------
init_json_file "$CL_CONFIG" '{
  "installation_id": null,
  "selected_python_id": null,
  "resolved_python_executable": null,
  "selected_redis_id": null,
  "concurrency": 4,
  "queues": ["default"],
  "dependency_ready": {"python": false, "redis": false},
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
    selection=$(ask_choice "Which Python should Celery use?" "${labels[@]}")
    SELECTED_PYTHON_ID="${selection%% *}"
fi

SELECTED_PYTHON_EXE=$(json_get "$PYTHON_CONFIG" ".installations[\"${SELECTED_PYTHON_ID}\"].executable")
json_set_key "$CL_CONFIG" '.selected_python_id'      "\"${SELECTED_PYTHON_ID}\""
json_set_key "$CL_CONFIG" '.resolved_python_executable' "\"${SELECTED_PYTHON_EXE}\""
json_set_key "$CL_CONFIG" '.dependency_ready.python' 'true'

# ---------------------------------------------------------------------------
# 3. Redis dependency (broker)
# ---------------------------------------------------------------------------
init_json_file "$REDIS_CONFIG" '{"servers":{}}'
redis_count=$(json_get "$REDIS_CONFIG" '.servers | length')

if [[ "$redis_count" == "0" ]]; then
    log_info "No Redis server configured yet."
    call_installer "install_redis.sh"
fi

redis_ids=()
while IFS= read -r k; do redis_ids+=("$k"); done < \
    <(json_get "$REDIS_CONFIG" '.servers | keys[]')

if [[ ${#redis_ids[@]} -eq 1 ]]; then
    SELECTED_REDIS_ID="${redis_ids[0]}"
else
    labels=()
    for k in "${redis_ids[@]}"; do
        host=$(json_get "$REDIS_CONFIG" ".servers[\"$k\"].host")
        port=$(json_get "$REDIS_CONFIG" ".servers[\"$k\"].port")
        labels+=("$k  [${host}:${port}]")
    done
    selection=$(ask_choice "Which Redis server should Celery use as broker?" "${labels[@]}")
    SELECTED_REDIS_ID="${selection%% *}"
fi

json_set_key "$CL_CONFIG" '.selected_redis_id'       "\"${SELECTED_REDIS_ID}\""
json_set_key "$CL_CONFIG" '.dependency_ready.redis'  'true'

# ---------------------------------------------------------------------------
# 4. Collect Celery-specific settings
# ---------------------------------------------------------------------------
CONCURRENCY=$(ask_input "Celery worker concurrency" "4")
QUEUES_RAW=$(ask_input "Comma-separated queue names" "default")
queues_json=$(echo "$QUEUES_RAW" | jq -R 'split(",") | map(ltrimstr(" ") | rtrimstr(" "))')

json_set_key "$CL_CONFIG" '.concurrency' "${CONCURRENCY}"
json_set_key "$CL_CONFIG" '.queues'      "${queues_json}"

# ---------------------------------------------------------------------------
# 5. Install Celery
# ---------------------------------------------------------------------------
log_info "Installing Celery into ${SELECTED_PYTHON_EXE}..."
"$SELECTED_PYTHON_EXE" -m pip install --quiet "celery[redis]"

CL_VERSION=$("$SELECTED_PYTHON_EXE" -c "import celery; print(celery.__version__)" 2>/dev/null)
log_info "Celery ${CL_VERSION} installed."

CL_ID=$(generate_id "celery")
json_set_key "$CL_CONFIG" '.installation_id' "\"${CL_ID}\""
json_set_key "$CL_CONFIG" '.version'          "\"${CL_VERSION}\""
json_set_key "$CL_CONFIG" '.install_status'   '"installed"'

log_info "Celery installer complete. ID: ${CL_ID}"
