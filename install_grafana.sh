#!/usr/bin/env bash
# install_grafana.sh — Detect and/or install Grafana on Debian 13 bare metal.
# Part of the LASH modular installer framework.
#
# Consumer config: config/grafana.json
# Provider configs consumed (by reference ID only):
#   config/prometheus.json

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

GF_CONFIG="${LASH_CONFIG_DIR}/grafana.json"
PROM_CONFIG="${LASH_CONFIG_DIR}/prometheus.json"
DEFAULT_PORT=3000

log_section "Grafana Installer"

# ---------------------------------------------------------------------------
# 1. Initialise config file
# ---------------------------------------------------------------------------
init_json_file "$GF_CONFIG" '{
  "installation_id": null,
  "config_dir": null,
  "port": 3000,
  "service_name": null,
  "selected_prometheus_id": null,
  "dependency_ready": {"prometheus": false},
  "install_status": "pending",
  "version": null
}'

# ---------------------------------------------------------------------------
# 2. Prometheus dependency
# ---------------------------------------------------------------------------
init_json_file "$PROM_CONFIG" '{
  "installation_id": null, "binary_path": null, "config_path": null,
  "data_dir": null, "port": 9090, "service_name": null, "version": null,
  "install_status": "pending"
}'

prom_status=$(json_get "$PROM_CONFIG" '.install_status')
if [[ "$prom_status" != "installed" ]]; then
    log_info "Prometheus not installed yet. Running install_prometheus.sh..."
    call_installer "install_prometheus.sh"
fi

SELECTED_PROMETHEUS_ID=$(json_get "$PROM_CONFIG" '.installation_id')
json_set_key "$GF_CONFIG" '.selected_prometheus_id'       "\"${SELECTED_PROMETHEUS_ID}\""
json_set_key "$GF_CONFIG" '.dependency_ready.prometheus'  'true'

# ---------------------------------------------------------------------------
# 3. Detect existing Grafana
# ---------------------------------------------------------------------------
if command -v grafana-server &>/dev/null; then
    gf_ver=$(grafana-server -v 2>&1 | grep -oP 'Version \K[\d.]+' | head -1 || echo "unknown")
    log_info "Grafana already installed: ${gf_ver}"
else
    log_warn "Grafana not found. Installing via official apt repository..."

    sudo apt-get install -y -qq apt-transport-https software-properties-common wget
    sudo mkdir -p /etc/apt/keyrings
    wget -q -O - https://apt.grafana.com/gpg.key | \
        gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | \
        sudo tee /etc/apt/sources.list.d/grafana.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y grafana

    sudo systemctl enable --now grafana-server
    gf_ver=$(grafana-server -v 2>&1 | grep -oP 'Version \K[\d.]+' | head -1 || echo "unknown")
fi

CURRENT_GF_PORT=$(json_get "$GF_CONFIG" '.port')
[[ "$CURRENT_GF_PORT" == "null" || -z "$CURRENT_GF_PORT" ]] && CURRENT_GF_PORT="${DEFAULT_PORT}"
GF_PORT=$(ask_input "Grafana port" "${CURRENT_GF_PORT}")
GF_ID=$(generate_id "grafana")

json_set_key "$GF_CONFIG" '.installation_id' "\"${GF_ID}\""
json_set_key "$GF_CONFIG" '.config_dir'       '"/etc/grafana"'
json_set_key "$GF_CONFIG" '.port'             "${GF_PORT}"
json_set_key "$GF_CONFIG" '.service_name'     '"grafana-server"'
json_set_key "$GF_CONFIG" '.version'          "\"${gf_ver}\""
json_set_key "$GF_CONFIG" '.install_status'   '"installed"'

log_info "Grafana installer complete. ID: ${GF_ID}"
