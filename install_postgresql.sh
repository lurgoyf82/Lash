#!/usr/bin/env bash
# install_postgresql.sh — Discover and/or install a PostgreSQL server.
# Part of the LASH modular installer framework.
#
# Provider config: config/postgresql.json
# Schema:
#   servers.<pg_id>.id
#   servers.<pg_id>.location        (local | remote)
#   servers.<pg_id>.host
#   servers.<pg_id>.port
#   servers.<pg_id>.username
#   servers.<pg_id>.password_env    (env-var name that holds the password)
#   servers.<pg_id>.version
#   servers.<pg_id>.binary_path     (null for remote)
#   servers.<pg_id>.service_name    (systemd unit, null for remote)
#   servers.<pg_id>.available

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

PG_CONFIG="${LASH_CONFIG_DIR}/postgresql.json"

log_section "PostgreSQL Installer"

# ---------------------------------------------------------------------------
# 1. Initialise config file
# ---------------------------------------------------------------------------
init_json_file "$PG_CONFIG" '{"servers":{}}'

# ---------------------------------------------------------------------------
# 2. Ask: local or remote?
# ---------------------------------------------------------------------------
if ask_yes_no "Is the PostgreSQL server LOCAL on this machine?"; then
    LOCATION="local"
else
    LOCATION="remote"
fi

# ---------------------------------------------------------------------------
# 3a. LOCAL path — discover existing local installations
# ---------------------------------------------------------------------------
if [[ "$LOCATION" == "local" ]]; then
    log_info "Scanning for local PostgreSQL installations..."

    FOUND_LOCAL=()
    while IFS= read -r psql_exe; do
        [[ -z "$psql_exe" ]] && continue
        ver=$("$psql_exe" --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1) || continue
        svc=$(systemctl list-units --type=service --all --plain --no-legend 2>/dev/null \
              | awk '{print $1}' | grep -E '^postgresql' | head -1 || true)
        FOUND_LOCAL+=("$psql_exe|$ver|${svc:-postgresql}")
    done < <({ command -v psql 2>/dev/null; \
               find /usr/bin /usr/local/bin /usr/lib/postgresql -maxdepth 2 -name 'psql' 2>/dev/null; } | sort -u)

    if [[ ${#FOUND_LOCAL[@]} -eq 0 ]]; then
        log_warn "No local PostgreSQL found. Installing via apt-get..."
        sudo apt-get update -qq
        sudo apt-get install -y postgresql postgresql-client
        psql_exe=$(command -v psql)
        ver=$("$psql_exe" --version | grep -oP '\d+\.\d+' | head -1)
        svc=$(systemctl list-units --type=service --all --plain --no-legend 2>/dev/null \
              | awk '{print $1}' | grep -E '^postgresql' | head -1 || echo "postgresql")
        FOUND_LOCAL+=("${psql_exe}|${ver}|${svc}")
        sudo systemctl enable --now "$svc" || true
    fi

    for entry in "${FOUND_LOCAL[@]}"; do
        IFS='|' read -r psql_exe ver svc <<< "$entry"
        host="localhost"
        port=5432

        existing_id=$(json_get "$PG_CONFIG" \
            ".servers | to_entries[] | select(.value.binary_path == \"$psql_exe\") | .key" | head -1)

        if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
            pgid="$existing_id"
            log_info "Updating existing PostgreSQL record $pgid"
        else
            pgid=$(generate_id "pg")
            log_info "Recording new local PostgreSQL: $pgid ($psql_exe, $ver)"
        fi

        # Collect credentials
        pg_user=$(ask_input "PostgreSQL admin username" "postgres")
        pg_pass_env="PG_PASSWORD_${pgid^^}"
        log_info "Paste the password into environment variable: ${pg_pass_env}"
        log_info "(You can set it in a secrets file — never hardcode it)"

        record=$(jq -n \
            --arg id        "$pgid" \
            --arg loc       "local" \
            --arg host      "$host" \
            --argjson port  "$port" \
            --arg user      "$pg_user" \
            --arg penv      "$pg_pass_env" \
            --arg ver       "$ver" \
            --arg bin       "$psql_exe" \
            --arg svc       "$svc" \
            '{id:$id, location:$loc, host:$host, port:$port,
              username:$user, password_env:$penv,
              version:$ver, binary_path:$bin,
              service_name:$svc, available:true}')
        json_upsert_record "$PG_CONFIG" ".servers" "$pgid" "$record"
    done

# ---------------------------------------------------------------------------
# 3b. REMOTE path — collect connection data from the operator
# ---------------------------------------------------------------------------
else
    log_info "Collecting remote PostgreSQL connection details..."
    host=$(ask_input "PostgreSQL host (IP or FQDN)")
    port=$(ask_input "PostgreSQL port" "5432")
    pg_user=$(ask_input "PostgreSQL username" "postgres")
    pgid=$(generate_id "pg")
    pg_pass_env="PG_PASSWORD_${pgid^^}"
    log_info "Set environment variable ${pg_pass_env} to the PostgreSQL password before starting LASH."

    record=$(jq -n \
        --arg id        "$pgid" \
        --arg loc       "remote" \
        --arg host      "$host" \
        --argjson port  "$port" \
        --arg user      "$pg_user" \
        --arg penv      "$pg_pass_env" \
        '{id:$id, location:$loc, host:$host, port:($port|tonumber),
          username:$user, password_env:$penv,
          version:null, binary_path:null,
          service_name:null, available:true}')
    json_upsert_record "$PG_CONFIG" ".servers" "$pgid" "$record"
    log_info "Remote PostgreSQL server recorded as $pgid."
fi

log_info "PostgreSQL installer complete. config/postgresql.json updated."
