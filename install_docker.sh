#!/usr/bin/env bash
# install_docker.sh — Detect and/or install Docker Engine (optional infrastructure dep).
# Part of the LASH modular installer framework.
#
# Docker is treated as an optional infrastructure dependency only if the project
# explicitly requires local container/sandbox job execution.
#
# Provider config: config/docker.json
# Schema:
#   installations.<docker_id>.id
#   installations.<docker_id>.binary_path
#   installations.<docker_id>.version
#   installations.<docker_id>.socket_path
#   installations.<docker_id>.service_name
#   installations.<docker_id>.available

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

DOCKER_CONFIG="${LASH_CONFIG_DIR}/docker.json"

log_section "Docker Engine Installer (Optional)"

# ---------------------------------------------------------------------------
# 1. Initialise config file
# ---------------------------------------------------------------------------
init_json_file "$DOCKER_CONFIG" '{"installations":{}}'

# ---------------------------------------------------------------------------
# 2. Detect existing Docker installation
# ---------------------------------------------------------------------------
docker_exe=$(command -v docker 2>/dev/null || true)

if [[ -n "$docker_exe" ]]; then
    docker_ver=$("$docker_exe" version --format '{{.Server.Version}}' 2>/dev/null || \
                 "$docker_exe" --version | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
    log_info "Found existing Docker: $docker_exe (${docker_ver})"

    existing_id=$(json_get "$DOCKER_CONFIG" \
        ".installations | to_entries[] | select(.value.binary_path == \"$docker_exe\") | .key" | head -1)

    if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
        docker_id="$existing_id"
        log_info "Updating existing Docker record: $docker_id"
    else
        docker_id=$(generate_id "docker")
        log_info "Recording new Docker installation: $docker_id"
    fi
else
    log_warn "Docker Engine not found."
    if ! ask_yes_no "Install Docker Engine now? (Only if LASH requires container/sandbox job execution)"; then
        log_info "Docker installation skipped."
        exit 0
    fi

    log_info "Installing Docker Engine via official script..."
    curl -fsSL https://get.docker.com | sudo sh

    docker_exe=$(command -v docker)
    docker_ver=$("$docker_exe" version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    sudo systemctl enable --now docker
    docker_id=$(generate_id "docker")
fi

socket_path="/var/run/docker.sock"
svc=$(systemctl list-units --type=service --all --plain --no-legend 2>/dev/null \
      | awk '{print $1}' | grep -E '^docker' | head -1 || echo "docker")

record=$(jq -n \
    --arg  id   "$docker_id" \
    --arg  bin  "$docker_exe" \
    --arg  ver  "$docker_ver" \
    --arg  sock "$socket_path" \
    --arg  svc  "$svc" \
    '{id:$id, binary_path:$bin, version:$ver,
      socket_path:$sock, service_name:$svc, available:true}')
json_upsert_record "$DOCKER_CONFIG" ".installations" "$docker_id" "$record"

export RESOLVED_DOCKER_ID="$docker_id"
log_info "Docker installer complete. ID: ${docker_id}"
