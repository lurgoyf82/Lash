#!/usr/bin/env bash
# install_sqlalchemy.sh — Discover dependencies and install SQLAlchemy.
# Part of the LASH modular installer framework.
#
# Consumer config: config/sqlalchemy.json
# Provider configs consumed (by reference ID only):
#   config/python.json
#   config/postgresql.json
#   config/psycopg.json
#
# Dependency resolution order:
#   1. Python  (mandatory local)
#   2. PostgreSQL  (local or remote)
#   3. Psycopg  (mandatory local, inside selected Python env)
#   4. SQLAlchemy installation

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

SA_CONFIG="${LASH_CONFIG_DIR}/sqlalchemy.json"
PYTHON_CONFIG="${LASH_CONFIG_DIR}/python.json"
PG_CONFIG="${LASH_CONFIG_DIR}/postgresql.json"
PSYCOPG_CONFIG="${LASH_CONFIG_DIR}/psycopg.json"

log_section "SQLAlchemy Installer"

# ---------------------------------------------------------------------------
# 1. Initialise consumer config file
# ---------------------------------------------------------------------------
init_json_file "$SA_CONFIG" '{
  "installation_id": null,
  "selected_python_id": null,
  "python_runtime": null,
  "resolved_python_executable": null,
  "selected_postgresql_id": null,
  "selected_psycopg_id": null,
  "database_name": null,
  "schema": null,
  "tables": [],
  "sqlalchemy_options": {},
  "dependency_ready": {
    "python": false,
    "postgresql": false,
    "psycopg": false
  },
  "install_status": "pending",
  "version": null
}'

# ===========================================================================
# PHASE 1 — Python dependency
# ===========================================================================
log_section "Phase 1: Python"

init_json_file "$PYTHON_CONFIG" '{"installations":{}}'

# Run discovery (install_python.sh always updates config/python.json safely)
call_installer "install_python.sh"

# Gather valid Python installations
python_ids=()
while IFS= read -r k; do python_ids+=("$k"); done < \
    <(json_get "$PYTHON_CONFIG" '.installations | keys[]')

if [[ ${#python_ids[@]} -eq 0 ]]; then
    log_error "No Python installation available after running install_python.sh."
    exit 1
fi

if [[ ${#python_ids[@]} -eq 1 ]]; then
    SELECTED_PYTHON_ID="${python_ids[0]}"
else
    labels=()
    for k in "${python_ids[@]}"; do
        exe=$(json_get "$PYTHON_CONFIG" ".installations[\"$k\"].executable")
        ver=$(json_get "$PYTHON_CONFIG" ".installations[\"$k\"].version")
        labels+=("$k  [${exe}  v${ver}]")
    done
    selection=$(ask_choice "Multiple Python installations found. Which one should SQLAlchemy use?" "${labels[@]}")
    SELECTED_PYTHON_ID="${selection%% *}"
fi

SELECTED_PYTHON_EXE=$(json_get "$PYTHON_CONFIG" ".installations[\"${SELECTED_PYTHON_ID}\"].executable")
log_info "Selected Python: ${SELECTED_PYTHON_EXE} (${SELECTED_PYTHON_ID})"

# Write selected_python_id into consumer config (reference only).
# The effective runtime may later be updated after Psycopg resolves whether a venv is required.
json_set_key "$SA_CONFIG" '.selected_python_id' "\"${SELECTED_PYTHON_ID}\""
json_set_key "$SA_CONFIG" '.resolved_python_executable' "\"${SELECTED_PYTHON_EXE}\""
json_set_key "$SA_CONFIG" '.dependency_ready.python' 'true'

# ===========================================================================
# PHASE 2 — PostgreSQL dependency
# ===========================================================================
log_section "Phase 2: PostgreSQL"

init_json_file "$PG_CONFIG" '{"servers":{}}'

# Count existing PG servers
pg_count=$(json_get "$PG_CONFIG" '.servers | length')

if [[ "$pg_count" == "0" ]]; then
    log_info "No PostgreSQL server configured yet."
    call_installer "install_postgresql.sh"
    pg_count=$(json_get "$PG_CONFIG" '.servers | length')
fi

pg_ids=()
while IFS= read -r k; do pg_ids+=("$k"); done < \
    <(json_get "$PG_CONFIG" '.servers | keys[]')

if [[ ${#pg_ids[@]} -eq 0 ]]; then
    log_error "No PostgreSQL server available after running install_postgresql.sh."
    exit 1
fi

if [[ ${#pg_ids[@]} -eq 1 ]]; then
    SELECTED_PG_ID="${pg_ids[0]}"
else
    labels=()
    for k in "${pg_ids[@]}"; do
        host=$(json_get "$PG_CONFIG" ".servers[\"$k\"].host")
        port=$(json_get "$PG_CONFIG" ".servers[\"$k\"].port")
        loc=$(json_get  "$PG_CONFIG" ".servers[\"$k\"].location")
        labels+=("$k  [${loc}  ${host}:${port}]")
    done
    selection=$(ask_choice "Multiple PostgreSQL servers found. Which one should SQLAlchemy use?" "${labels[@]}")
    SELECTED_PG_ID="${selection%% *}"
fi

log_info "Selected PostgreSQL server: ${SELECTED_PG_ID}"

# Collect SQLAlchemy-specific connection details (NOT stored in postgresql.json)
log_info "Collecting SQLAlchemy-specific database settings..."
DB_NAME=$(ask_input "Database name for SQLAlchemy to use" "lash_db")
DB_SCHEMA=$(ask_input "Schema" "public")
TABLES_RAW=$(ask_input "Comma-separated table names (leave blank to skip)" "")
if ask_yes_no "Enable SQLAlchemy echo (SQL logging)?"; then
    SA_ECHO_VAL="true"
else
    SA_ECHO_VAL="false"
fi
POOL_SIZE=$(ask_input "Connection pool size" "5")
MAX_OVERFLOW=$(ask_input "Max overflow" "10")

# Build tables array
tables_json="[]"
if [[ -n "$TABLES_RAW" ]]; then
    tables_json=$(echo "$TABLES_RAW" | jq -R 'split(",") | map(ltrimstr(" ") | rtrimstr(" "))')
fi

# Write consumer-owned PostgreSQL settings into sqlalchemy.json (NOT into postgresql.json)
json_set_key "$SA_CONFIG" '.selected_postgresql_id' "\"${SELECTED_PG_ID}\""
json_set_key "$SA_CONFIG" '.database_name'          "\"${DB_NAME}\""
json_set_key "$SA_CONFIG" '.schema'                 "\"${DB_SCHEMA}\""
json_set_key "$SA_CONFIG" '.tables'                 "${tables_json}"
json_set_key "$SA_CONFIG" '.sqlalchemy_options'     \
    "{\"pool_size\":${POOL_SIZE},\"max_overflow\":${MAX_OVERFLOW},\"echo\":${SA_ECHO_VAL}}"
json_set_key "$SA_CONFIG" '.dependency_ready.postgresql' 'true'

# ===========================================================================
# PHASE 3 — Psycopg dependency
# ===========================================================================
log_section "Phase 3: Psycopg"

init_json_file "$PSYCOPG_CONFIG" '{"installations":{}}'

# Pass the selected Python to the psycopg installer via environment
export SELECTED_PYTHON_ID
export SELECTED_PYTHON_EXE
call_installer "install_psycopg.sh"

# RESOLVED_PSYCOPG_ID is exported by install_psycopg.sh
if [[ -z "${RESOLVED_PSYCOPG_ID:-}" ]]; then
    # Fall back: read from config
    RESOLVED_PSYCOPG_ID=$(json_get "$PSYCOPG_CONFIG" \
        ".installations | to_entries[] | select(.value.python_id == \"${SELECTED_PYTHON_ID}\") | .key" | head -1)
fi

if [[ -z "$RESOLVED_PSYCOPG_ID" || "$RESOLVED_PSYCOPG_ID" == "null" ]]; then
    log_error "Psycopg installation could not be resolved."
    exit 1
fi

log_info "Selected Psycopg: ${RESOLVED_PSYCOPG_ID}"

RESOLVED_PSYCOPG_VENV_DIR=$(json_get "$PSYCOPG_CONFIG" \
    ".installations[\"${RESOLVED_PSYCOPG_ID}\"].venv_dir")

if [[ -n "${RESOLVED_PSYCOPG_VENV_DIR:-}" && "$RESOLVED_PSYCOPG_VENV_DIR" != "null" ]]; then
    SQLALCHEMY_RUNTIME_PYTHON="${RESOLVED_PSYCOPG_VENV_DIR}/bin/python"
elif [[ -n "${RESOLVED_PSYCOPG_PYTHON:-}" && "$RESOLVED_PSYCOPG_PYTHON" != "null" ]]; then
    SQLALCHEMY_RUNTIME_PYTHON="$RESOLVED_PSYCOPG_PYTHON"
else
    SQLALCHEMY_RUNTIME_PYTHON="$SELECTED_PYTHON_EXE"
fi

if [[ ! -x "$SQLALCHEMY_RUNTIME_PYTHON" ]]; then
    log_error "Resolved SQLAlchemy runtime is not executable: ${SQLALCHEMY_RUNTIME_PYTHON}"
    exit 1
fi

log_info "Resolved SQLAlchemy runtime: ${SQLALCHEMY_RUNTIME_PYTHON}"
json_set_key "$SA_CONFIG" '.selected_psycopg_id'        "\"${RESOLVED_PSYCOPG_ID}\""
json_set_key "$SA_CONFIG" '.python_runtime'             "\"${SQLALCHEMY_RUNTIME_PYTHON}\""
json_set_key "$SA_CONFIG" '.resolved_python_executable' "\"${SQLALCHEMY_RUNTIME_PYTHON}\""
json_set_key "$SA_CONFIG" '.dependency_ready.psycopg'   'true'

# ===========================================================================
# PHASE 4 — SQLAlchemy installation
# ===========================================================================
log_section "Phase 4: SQLAlchemy"

# Verify all dependencies are ready before installing
python_ready=$(json_get "$SA_CONFIG" '.dependency_ready.python')
pg_ready=$(json_get    "$SA_CONFIG" '.dependency_ready.postgresql')
psycopg_ready=$(json_get "$SA_CONFIG" '.dependency_ready.psycopg')

if [[ "$python_ready" != "true" || "$pg_ready" != "true" || "$psycopg_ready" != "true" ]]; then
    log_error "Not all dependencies are ready. Aborting."
    log_error "  python=$python_ready  postgresql=$pg_ready  psycopg=$psycopg_ready"
    exit 1
fi


log_info "Installing SQLAlchemy into ${SQLALCHEMY_RUNTIME_PYTHON}..."
"$SQLALCHEMY_RUNTIME_PYTHON" -m pip install --quiet "sqlalchemy"

# Detect installed version
SA_VERSION=$("$SQLALCHEMY_RUNTIME_PYTHON" -c "import sqlalchemy; print(sqlalchemy.__version__)" 2>/dev/null)
log_info "SQLAlchemy ${SA_VERSION} installed."

# ---------------------------------------------------------------------------
# Record final state in consumer config
# ---------------------------------------------------------------------------
SA_ID=$(generate_id "sqlalchemy")
json_set_key "$SA_CONFIG" '.installation_id' "\"${SA_ID}\""
json_set_key "$SA_CONFIG" '.version'          "\"${SA_VERSION}\""
json_set_key "$SA_CONFIG" '.install_status'   '"installed"'

log_section "SQLAlchemy Install Complete"
log_info "Installation ID : ${SA_ID}"
log_info "Version         : ${SA_VERSION}"
log_info "Python selection: ${SELECTED_PYTHON_EXE} (${SELECTED_PYTHON_ID})"
log_info "Python runtime  : ${SQLALCHEMY_RUNTIME_PYTHON}"
log_info "PostgreSQL      : ${SELECTED_PG_ID}"
log_info "Psycopg         : ${RESOLVED_PSYCOPG_ID}"
log_info "Database        : ${DB_NAME} (schema: ${DB_SCHEMA})"
log_info "Config saved to : ${SA_CONFIG}"
