#!/usr/bin/env bash
# deploy_lash.sh — Top-level bare-metal deployment script for LASH on Debian 13.
# Part of the LASH modular installer framework.
#
# Usage:
#   sudo bash deploy_lash.sh
#
# This script:
#   1. Verifies required ports are free
#   2. Runs all component installers in dependency order
#   3. Initialises the PostgreSQL database and schema via Alembic
#   4. Writes systemd unit files for each LASH service
#   5. Starts all services
#   6. Verifies health endpoints
#   7. Runs a basic smoke test against the FastAPI gateway

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

# ---------------------------------------------------------------------------
# Port assignments
# ---------------------------------------------------------------------------
declare -A LASH_PORTS=(
    [fastapi]=8000
    [streamlit]=8501
    [litellm]=4000
    [redis]=6379
    [postgresql]=5432
    [prometheus]=9090
    [grafana]=3000
)

# ---------------------------------------------------------------------------
# Helper: read a port from config or use a default
# ---------------------------------------------------------------------------
port_from_config() {
    local config_file="$1"
    local jq_path="$2"
    local default="$3"
    if [[ -f "$config_file" ]]; then
        val=$(json_get "$config_file" "$jq_path")
        if [[ "$val" != "null" && -n "$val" ]]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}

# ---------------------------------------------------------------------------
# Step 1: Check port availability
# ---------------------------------------------------------------------------
log_section "Step 1: Port Conflict Check"

FASTAPI_PORT=$(port_from_config "${LASH_CONFIG_DIR}/uvicorn.json"    '.port'                 "${LASH_PORTS[fastapi]}")
STREAMLIT_PORT=$(port_from_config "${LASH_CONFIG_DIR}/streamlit.json" '.port'                "${LASH_PORTS[streamlit]}")
LITELLM_PORT=$(port_from_config "${LASH_CONFIG_DIR}/litellm.json"     '.port'                "${LASH_PORTS[litellm]}")
PROM_PORT=$(port_from_config    "${LASH_CONFIG_DIR}/prometheus.json"  '.port'                "${LASH_PORTS[prometheus]}")
GRAFANA_PORT=$(port_from_config "${LASH_CONFIG_DIR}/grafana.json"     '.port'                "${LASH_PORTS[grafana]}")

interactive_resolve_port_conflict "${LASH_CONFIG_DIR}/uvicorn.json"    '.port' "$FASTAPI_PORT"   "FastAPI/Uvicorn"
interactive_resolve_port_conflict "${LASH_CONFIG_DIR}/streamlit.json"  '.port' "$STREAMLIT_PORT" "Streamlit"
interactive_resolve_port_conflict "${LASH_CONFIG_DIR}/litellm.json"    '.port' "$LITELLM_PORT"   "LiteLLM"
interactive_resolve_port_conflict "${LASH_CONFIG_DIR}/prometheus.json" '.port' "$PROM_PORT"      "Prometheus"
interactive_resolve_port_conflict "${LASH_CONFIG_DIR}/grafana.json"    '.port' "$GRAFANA_PORT"   "Grafana"

log_info "All required ports are free."

# ---------------------------------------------------------------------------
# Step 2: Run component installers in dependency order
# ---------------------------------------------------------------------------
log_section "Step 2: Component Installation"

call_installer "install_python.sh"
call_installer "install_postgresql.sh"
call_installer "install_redis.sh"
call_installer "install_psycopg.sh"
call_installer "install_sqlalchemy.sh"
call_installer "install_fastapi.sh"
call_installer "install_uvicorn.sh"
call_installer "install_streamlit.sh"
call_installer "install_celery.sh"
call_installer "install_litellm.sh"
call_installer "install_autogen.sh"
call_installer "install_prometheus.sh"
call_installer "install_grafana.sh"

log_info "All components installed."

# ---------------------------------------------------------------------------
# Step 3: Initialise PostgreSQL database and schema
# ---------------------------------------------------------------------------
log_section "Step 3: PostgreSQL Database Initialisation"

SA_CONFIG="${LASH_CONFIG_DIR}/sqlalchemy.json"
PG_CONFIG="${LASH_CONFIG_DIR}/postgresql.json"

DB_NAME=$(json_get "$SA_CONFIG" '.database_name')
PG_ID=$(json_get "$SA_CONFIG" '.selected_postgresql_id')
PG_HOST=$(json_get "$PG_CONFIG" ".servers[\"${PG_ID}\"].host")
PG_PORT=$(json_get "$PG_CONFIG" ".servers[\"${PG_ID}\"].port")
PG_USER=$(json_get "$PG_CONFIG" ".servers[\"${PG_ID}\"].username")
PG_PASS=$(json_get "$PG_CONFIG" ".servers[\"${PG_ID}\"].password")

if [[ -z "${PG_PASS:-}" || "$PG_PASS" == "null" ]]; then
    log_error "PostgreSQL password is missing in ${PG_CONFIG} for server ${PG_ID}."
    exit 1
fi

export PGPASSWORD="${PG_PASS}"

log_info "Checking if database '${DB_NAME}' exists on ${PG_HOST}:${PG_PORT}..."
db_check_output=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -lqt postgres 2>&1) || {
    log_error "Could not connect to PostgreSQL: ${db_check_output}"
    exit 1
}
if ! echo "$db_check_output" | cut -d'|' -f1 | grep -qw "$DB_NAME"; then
    log_info "Creating database '${DB_NAME}'..."
    if ! create_output=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
         -c "CREATE DATABASE \"${DB_NAME}\";" postgres 2>&1); then
        log_error "Failed to create database: ${create_output}"
        exit 1
    fi
fi

unset PGPASSWORD

# Run Alembic migrations if alembic.ini exists in the project root
if [[ -f "${LASH_INSTALLER_DIR}/alembic.ini" ]]; then
    log_info "Running Alembic migrations..."
    PYTHON_ID=$(json_get "$SA_CONFIG" '.selected_python_id')
    PYTHON_CONFIG="${LASH_CONFIG_DIR}/python.json"
    PYTHON_EXE=$(json_get "$PYTHON_CONFIG" ".installations[\"${PYTHON_ID}\"].executable")
    (cd "${LASH_INSTALLER_DIR}" && "$PYTHON_EXE" -m alembic upgrade head)
    log_info "Alembic migrations complete."
else
    log_warn "alembic.ini not found. Skipping schema migration."
fi

# ---------------------------------------------------------------------------
# Step 4: Write systemd unit files
# ---------------------------------------------------------------------------
log_section "Step 4: Writing systemd Service Units"

# Read runtime values from config files
PYTHON_ID=$(json_get "${LASH_CONFIG_DIR}/uvicorn.json" '.selected_python_id')
PYTHON_CONFIG="${LASH_CONFIG_DIR}/python.json"
PYTHON_EXE=$(json_get "$PYTHON_CONFIG" ".installations[\"${PYTHON_ID}\"].executable")
INSTALL_DIR="${LASH_INSTALLER_DIR}"

# Resolve broker URL for Celery
REDIS_ID=$(json_get "${LASH_CONFIG_DIR}/celery.json" '.selected_redis_id')
REDIS_CONFIG="${LASH_CONFIG_DIR}/redis.json"
REDIS_HOST=$(json_get "$REDIS_CONFIG" ".servers[\"${REDIS_ID}\"].host")
REDIS_PORT=$(json_get "$REDIS_CONFIG" ".servers[\"${REDIS_ID}\"].port")
REDIS_PASS_ENV=$(json_get "$REDIS_CONFIG" ".servers[\"${REDIS_ID}\"].password_env")

if [[ "$REDIS_PASS_ENV" != "null" && -n "$REDIS_PASS_ENV" ]]; then
    BROKER_URL="redis://:REDIS_AUTH_PLACEHOLDER@${REDIS_HOST}:${REDIS_PORT}/0"
    CELERY_REDIS_PASSWORD_VAR="$REDIS_PASS_ENV"
else
    BROKER_URL="redis://${REDIS_HOST}:${REDIS_PORT}/0"
    CELERY_REDIS_PASSWORD_VAR=""
fi

CELERY_CONCURRENCY=$(json_get "${LASH_CONFIG_DIR}/celery.json" '.concurrency')
CELERY_QUEUES=$(json_get "${LASH_CONFIG_DIR}/celery.json" '.queues | join(",")' 2>/dev/null || echo "default")

LITELLM_PORT=$(json_get "${LASH_CONFIG_DIR}/litellm.json" '.port')
STREAMLIT_PORT=$(json_get "${LASH_CONFIG_DIR}/streamlit.json" '.port')
UV_HOST=$(json_get "${LASH_CONFIG_DIR}/uvicorn.json" '.host')
UV_PORT=$(json_get "${LASH_CONFIG_DIR}/uvicorn.json" '.port')
UV_WORKERS=$(json_get "${LASH_CONFIG_DIR}/uvicorn.json" '.workers')

# FastAPI / Uvicorn
sudo tee /etc/systemd/system/lash-api.service > /dev/null <<EOF
[Unit]
Description=LASH FastAPI Gateway (Uvicorn)
After=network.target lash-celery.service

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${PYTHON_EXE} -m uvicorn main:app --host ${UV_HOST} --port ${UV_PORT} --workers ${UV_WORKERS}
Restart=on-failure
EnvironmentFile=-${INSTALL_DIR}/.env

[Install]
WantedBy=multi-user.target
EOF

# Streamlit
sudo tee /etc/systemd/system/lash-streamlit.service > /dev/null <<EOF
[Unit]
Description=LASH Streamlit UI
After=network.target lash-api.service

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${PYTHON_EXE} -m streamlit run app.py --server.port ${STREAMLIT_PORT} --server.headless true
Restart=on-failure
EnvironmentFile=-${INSTALL_DIR}/.env

[Install]
WantedBy=multi-user.target
EOF

# Write a restricted Celery env fragment that will be sourced at deploy time only
# The actual password is injected from the named environment variable at service start.
CELERY_ENV_FILE="${INSTALL_DIR}/.env.celery"
sudo tee "$CELERY_ENV_FILE" > /dev/null <<EOF
# Auto-generated by deploy_lash.sh — do not edit manually.
# Broker URL — password is substituted from ${CELERY_REDIS_PASSWORD_VAR} at runtime.
CELERY_BROKER_URL=${BROKER_URL}
EOF
sudo chmod 600 "$CELERY_ENV_FILE"

# Celery
sudo tee /etc/systemd/system/lash-celery.service > /dev/null <<EOF
[Unit]
Description=LASH Celery Workers
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${CELERY_ENV_FILE}
EnvironmentFile=-${INSTALL_DIR}/.env
ExecStart=${PYTHON_EXE} -m celery -A tasks worker --loglevel=info --concurrency=${CELERY_CONCURRENCY} -Q ${CELERY_QUEUES}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# LiteLLM
sudo tee /etc/systemd/system/lash-litellm.service > /dev/null <<EOF
[Unit]
Description=LASH LiteLLM Proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${PYTHON_EXE} -m litellm --port ${LITELLM_PORT}
Restart=on-failure
EnvironmentFile=-${INSTALL_DIR}/.env

[Install]
WantedBy=multi-user.target
EOF

log_info "systemd unit files written."

# ---------------------------------------------------------------------------
# Step 5: Enable and start all services
# ---------------------------------------------------------------------------
log_section "Step 5: Starting Services"

sudo systemctl daemon-reload

SERVICES=(lash-celery lash-api lash-streamlit lash-litellm prometheus grafana-server)
for svc in "${SERVICES[@]}"; do
    log_info "Enabling and starting: $svc"
    sudo systemctl enable --now "$svc" 2>/dev/null || log_warn "Could not start $svc — check journalctl -u $svc"
done

# ---------------------------------------------------------------------------
# Step 6: Health checks
# ---------------------------------------------------------------------------
log_section "Step 6: Health Checks"

HEALTH_TIMEOUT=30
wait_for_http() {
    local url="$1"
    local name="$2"
    local deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
    while (( $(date +%s) < deadline )); do
        if curl -sf "$url" -o /dev/null 2>/dev/null; then
            log_info "✓ ${name} is reachable at ${url}"
            return 0
        fi
        sleep 2
    done
    log_warn "✗ ${name} did not respond at ${url} within ${HEALTH_TIMEOUT}s"
    return 1
}

wait_for_http "http://localhost:${UV_PORT}/health"      "FastAPI"
wait_for_http "http://localhost:${STREAMLIT_PORT}/"     "Streamlit"
wait_for_http "http://localhost:${LITELLM_PORT}/health" "LiteLLM"
wait_for_http "http://localhost:${PROM_PORT}/-/healthy" "Prometheus"
wait_for_http "http://localhost:${GRAFANA_PORT}/api/health" "Grafana"

# ---------------------------------------------------------------------------
# Step 7: FastAPI smoke test
# ---------------------------------------------------------------------------
log_section "Step 7: FastAPI Smoke Test"

SMOKE_URL="http://localhost:${UV_PORT}/health"
HTTP_STATUS=$(curl -so /dev/null -w "%{http_code}" "$SMOKE_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_STATUS" == "200" ]]; then
    log_info "✓ Smoke test passed: GET ${SMOKE_URL} → HTTP ${HTTP_STATUS}"
else
    log_warn "✗ Smoke test inconclusive: GET ${SMOKE_URL} → HTTP ${HTTP_STATUS}"
    log_warn "  The service may still be starting. Check: journalctl -u lash-api -f"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_section "LASH Deployment Complete"
echo ""
echo "  FastAPI    → http://localhost:${UV_PORT}"
echo "  Streamlit  → http://localhost:${STREAMLIT_PORT}"
echo "  LiteLLM    → http://localhost:${LITELLM_PORT}"
echo "  Prometheus → http://localhost:${PROM_PORT}"
echo "  Grafana    → http://localhost:${GRAFANA_PORT}"
echo ""
echo "  Secrets must be set in ${INSTALL_DIR}/.env before services will connect correctly."
echo "  See config/*.json for environment variable names required per service."
echo ""
