#!/usr/bin/env bash
# install_redis.sh — Discover and/or install a Redis server.
# Part of the LASH modular installer framework.
#
# Provider config: config/redis.json
# Schema:
#   servers.<redis_id>.id
#   servers.<redis_id>.location     (local | remote)
#   servers.<redis_id>.host
#   servers.<redis_id>.port
#   servers.<redis_id>.password_env (env-var name or null if no auth)
#   servers.<redis_id>.version
#   servers.<redis_id>.binary_path  (null for remote)
#   servers.<redis_id>.service_name (systemd unit, null for remote)
#   servers.<redis_id>.available

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

REDIS_CONFIG="${LASH_CONFIG_DIR}/redis.json"

log_section "Redis Installer"

# ---------------------------------------------------------------------------
# 1. Initialise config file
# ---------------------------------------------------------------------------
init_json_file "$REDIS_CONFIG" '{"servers":{}}'

# ---------------------------------------------------------------------------
# 2. Ask: local or remote?
# ---------------------------------------------------------------------------
if ask_yes_no "Is the Redis server LOCAL on this machine?"; then
    LOCATION="local"
else
    LOCATION="remote"
fi

# ---------------------------------------------------------------------------
# 3a. LOCAL path
# ---------------------------------------------------------------------------
if [[ "$LOCATION" == "local" ]]; then
    log_info "Scanning for local Redis installations..."

    redis_exe=$(command -v redis-server 2>/dev/null || true)

    if [[ -z "$redis_exe" ]]; then
        log_warn "Redis not found. Installing via apt-get..."
        sudo apt-get update -qq
        sudo apt-get install -y redis-server
        redis_exe=$(command -v redis-server)
        sudo systemctl enable --now redis-server || sudo systemctl enable --now redis || true
    fi

    ver=$("$redis_exe" --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
    svc=$(systemctl list-units --type=service --all --plain --no-legend 2>/dev/null \
          | awk '{print $1}' | grep -E '^redis' | head -1 || echo "redis-server")
    host="localhost"
    port=6379

    existing_id=$(json_get "$REDIS_CONFIG" \
        ".servers | to_entries[] | select(.value.binary_path == \"$redis_exe\") | .key" | head -1)

    if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
        redis_id="$existing_id"
        log_info "Updating existing Redis record: $redis_id"
    else
        redis_id=$(generate_id "redis")
        log_info "Recording new local Redis: $redis_id"
    fi

    use_auth=false
    redis_pass_env="null"
    if ask_yes_no "Does this Redis instance require a password?"; then
        use_auth=true
        redis_pass_env="\"REDIS_PASSWORD_${redis_id^^}\""
        log_info "Set environment variable REDIS_PASSWORD_${redis_id^^} before starting LASH."
    fi

    record=$(jq -n \
        --arg  id   "$redis_id" \
        --arg  loc  "local" \
        --arg  host "$host" \
        --argjson port "$port" \
        --argjson penv "$redis_pass_env" \
        --arg  ver  "$ver" \
        --arg  bin  "$redis_exe" \
        --arg  svc  "$svc" \
        '{id:$id, location:$loc, host:$host, port:$port,
          password_env:$penv, version:$ver,
          binary_path:$bin, service_name:$svc, available:true}')
    json_upsert_record "$REDIS_CONFIG" ".servers" "$redis_id" "$record"

# ---------------------------------------------------------------------------
# 3b. REMOTE path
# ---------------------------------------------------------------------------
else
    host=$(ask_input "Redis host (IP or FQDN)")
    port=$(ask_input "Redis port" "6379")
    redis_id=$(generate_id "redis")
    redis_pass_env="null"
    if ask_yes_no "Does this Redis instance require a password?"; then
        redis_pass_env="\"REDIS_PASSWORD_${redis_id^^}\""
        log_info "Set environment variable REDIS_PASSWORD_${redis_id^^} before starting LASH."
    fi

    record=$(jq -n \
        --arg  id   "$redis_id" \
        --arg  loc  "remote" \
        --arg  host "$host" \
        --argjson port "$port" \
        --argjson penv "$redis_pass_env" \
        '{id:$id, location:$loc, host:$host, port:($port|tonumber),
          password_env:$penv, version:null,
          binary_path:null, service_name:null, available:true}')
    json_upsert_record "$REDIS_CONFIG" ".servers" "$redis_id" "$record"
    log_info "Remote Redis recorded as $redis_id."
fi

export RESOLVED_REDIS_ID="$redis_id"
log_info "Redis installer complete. Resolved ID: ${redis_id}"
