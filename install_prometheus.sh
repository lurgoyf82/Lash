#!/usr/bin/env bash
# install_prometheus.sh — Detect and/or install Prometheus on Debian 13 bare metal.
# Part of the LASH modular installer framework.
#
# Provider config: config/prometheus.json
# Schema:
#   installation_id
#   binary_path
#   config_path
#   data_dir
#   port
#   service_name
#   version
#   install_status

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

PROM_CONFIG="${LASH_CONFIG_DIR}/prometheus.json"
DEFAULT_PORT=9090
CURRENT_PROM_PORT=""

log_section "Prometheus Installer"

# ---------------------------------------------------------------------------
# 1. Initialise config file
# ---------------------------------------------------------------------------
init_json_file "$PROM_CONFIG" '{
  "installation_id": null,
  "binary_path": null,
  "config_path": null,
  "data_dir": null,
  "port": 9090,
  "service_name": null,
  "version": null,
  "install_status": "pending"
}'
CURRENT_PROM_PORT=$(json_get "$PROM_CONFIG" '.port')
if [[ "$CURRENT_PROM_PORT" == "null" || -z "$CURRENT_PROM_PORT" ]]; then
    CURRENT_PROM_PORT="$DEFAULT_PORT"
fi

# ---------------------------------------------------------------------------
# 2. Detect existing Prometheus
# ---------------------------------------------------------------------------
prom_exe=$(command -v prometheus 2>/dev/null || true)

if [[ -n "$prom_exe" ]]; then
    prom_ver=$("$prom_exe" --version 2>&1 | grep -oP 'version \K[\d.]+' | head -1 || echo "unknown")
    log_info "Found existing Prometheus: $prom_exe ($prom_ver)"
else
    log_warn "Prometheus not found. Installing from GitHub releases..."

    PROM_VERSION=$(curl -s https://api.github.com/repos/prometheus/prometheus/releases/latest \
                   | jq -r '.tag_name' | tr -d 'v')
    ARCH=$(dpkg --print-architecture)
    [[ "$ARCH" == "amd64" ]] && PROM_ARCH="amd64" || PROM_ARCH="$ARCH"

    PROM_URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-${PROM_ARCH}.tar.gz"
    TMP_DIR=$(mktemp -d)
    curl -fsSL "$PROM_URL" -o "${TMP_DIR}/prometheus.tar.gz"
    tar -xzf "${TMP_DIR}/prometheus.tar.gz" -C "$TMP_DIR"
    PROM_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name 'prometheus-*' | head -1)

    sudo install -m 0755 "${PROM_DIR}/prometheus"  /usr/local/bin/prometheus
    sudo install -m 0755 "${PROM_DIR}/promtool"    /usr/local/bin/promtool

    sudo mkdir -p /etc/prometheus /var/lib/prometheus
    sudo cp -r "${PROM_DIR}/consoles" "${PROM_DIR}/console_libraries" /etc/prometheus/

    # Write minimal config if none exists
    if [[ ! -f /etc/prometheus/prometheus.yml ]]; then
        sudo tee /etc/prometheus/prometheus.yml > /dev/null <<'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]
EOF
    fi

    # Ask for port once here (used in systemd unit and recorded in config)
    PROM_PORT=$(ask_input "Prometheus port" "${CURRENT_PROM_PORT}")

    # Create systemd unit
    sudo tee /etc/systemd/system/prometheus.service > /dev/null <<EOF
[Unit]
Description=Prometheus Monitoring System
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/prometheus \\
    --config.file=/etc/prometheus/prometheus.yml \\
    --storage.tsdb.path=/var/lib/prometheus \\
    --web.listen-address=0.0.0.0:${PROM_PORT}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now prometheus
    rm -rf "$TMP_DIR"

    prom_exe="/usr/local/bin/prometheus"
    prom_ver="${PROM_VERSION}"
fi

# Only prompt for port if it was not already collected during installation above
if [[ -z "${PROM_PORT:-}" ]]; then
    PROM_PORT=$(ask_input "Prometheus port" "${CURRENT_PROM_PORT}")
fi
PROM_ID=$(generate_id "prometheus")

json_set_key "$PROM_CONFIG" '.installation_id' "\"${PROM_ID}\""
json_set_key "$PROM_CONFIG" '.binary_path'      "\"${prom_exe}\""
json_set_key "$PROM_CONFIG" '.config_path'      '"/etc/prometheus/prometheus.yml"'
json_set_key "$PROM_CONFIG" '.data_dir'         '"/var/lib/prometheus"'
json_set_key "$PROM_CONFIG" '.port'             "${PROM_PORT}"
json_set_key "$PROM_CONFIG" '.service_name'     '"prometheus"'
json_set_key "$PROM_CONFIG" '.version'          "\"${prom_ver}\""
json_set_key "$PROM_CONFIG" '.install_status'   '"installed"'

export RESOLVED_PROMETHEUS_ID="$PROM_ID"
log_info "Prometheus installer complete. ID: ${PROM_ID}"
