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
#   servers.<pg_id>.password        (inline password, if the operator wants it persisted)
#   servers.<pg_id>.password_env    (fallback env-var name for legacy compatibility)
#   servers.<pg_id>.version
#   servers.<pg_id>.binary_path     (null for remote)
#   servers.<pg_id>.service_name    (systemd unit, null for remote)
#   servers.<pg_id>.available

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

PG_CONFIG="${LASH_CONFIG_DIR}/postgresql.json"

resolve_psql_client() {
    if command -v psql &>/dev/null; then
        command -v psql
        return 0
    fi

    log_warn "psql client not found. Installing postgresql-client so I can test the connection..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq postgresql-client
    command -v psql
}

test_postgresql_connection() {
    local psql_bin="$1"
    local host="$2"
    local port="$3"
    local username="$4"
    local password="$5"
    local output
    local tried_ipv4_fallback="false"

    while true; do
        if output=$(PGPASSWORD="$password" "$psql_bin" \
            -h "$host" \
            -p "$port" \
            -U "$username" \
            -d postgres \
            -v ON_ERROR_STOP=1 \
            -Atqc 'SELECT 1;' 2>&1); then
            if [[ "$output" != "1" ]]; then
                log_warn "Connection test returned unexpected output: ${output}"
                return 1
            fi

            log_info "Connection test succeeded for ${username}@${host}:${port}."
            return 0
        fi

        log_warn "Connection test failed: ${output}"

        # If localhost resolves to ::1 and IPv6 auth/listen differs, retry on IPv4 loopback.
        if [[ "$tried_ipv4_fallback" == "false" && "$host" == "localhost" ]]; then
            tried_ipv4_fallback="true"
            host="127.0.0.1"
            continue
        fi

        return 1
    done
}

collect_postgresql_credentials() {
    local psql_bin="$1"
    local host="$2"
    local default_port="$3"
    local default_user="$4"
    local resolved_port
    local resolved_user
    local resolved_password

    while true; do
        resolved_port=$(ask_input "PostgreSQL port" "$default_port")
        if ! validate_port_number "$resolved_port"; then
            log_warn "Port '${resolved_port}' is invalid. Enter a value between 1 and 65535."
            continue
        fi

        resolved_user=$(ask_input "PostgreSQL admin username" "$default_user")
        resolved_password=$(ask_secret "PostgreSQL password (will be stored in config/postgresql.json)")

        if [[ -z "$resolved_password" ]]; then
            log_warn "Password cannot be empty."
            continue
        fi

        if test_postgresql_connection "$psql_bin" "$host" "$resolved_port" "$resolved_user" "$resolved_password"; then
            printf '%s|%s|%s\n' "$resolved_port" "$resolved_user" "$resolved_password"
            return 0
        fi

        if ! ask_yes_no "Connection failed. Do you want to retry with different PostgreSQL credentials?"; then
            log_error "PostgreSQL connection details were not validated. Aborting."
            exit 1
        fi
    done
}

build_postgresql_record() {
    local pgid="$1"
    local location="$2"
    local host="$3"
    local port="$4"
    local username="$5"
    local password="$6"
    local version="$7"
    local binary_path="$8"
    local service_name="$9"

    jq -n \
        --arg id "$pgid" \
        --arg loc "$location" \
        --arg host "$host" \
        --argjson port "$port" \
        --arg user "$username" \
        --arg password "$password" \
        --arg version "$version" \
        --arg binary_path "$binary_path" \
        --arg service_name "$service_name" \
        '{
          id: $id,
          location: $loc,
          host: $host,
          port: $port,
          username: $user,
          password: $password,
          password_env: null,
          version: ($version | if . == "" then null else . end),
          binary_path: ($binary_path | if . == "" then null else . end),
          service_name: ($service_name | if . == "" then null else . end),
          available: true
        }'
}

configure_local_postgresql() {
    local found_local=()
    local entry
    local psql_exe
    local ver
    local svc
    local host
    local port
    local existing_id
    local pgid
    local pg_port
    local pg_user
    local pg_password
    local record
    local default_port

    log_info "Scanning for local PostgreSQL installations..."

    while IFS= read -r psql_exe; do
        [[ -z "$psql_exe" ]] && continue
        ver=$("$psql_exe" --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1) || continue
        svc=$(systemctl list-units --type=service --all --plain --no-legend 2>/dev/null \
            | awk '{print $1}' | grep -E '^postgresql' | head -1 || true)
        found_local+=("$psql_exe|$ver|${svc:-postgresql}")
    done < <({ command -v psql 2>/dev/null; \
        find /usr/bin /usr/local/bin /usr/lib/postgresql -maxdepth 2 -name 'psql' 2>/dev/null; } | sort -u)

    if [[ ${#found_local[@]} -eq 0 ]]; then
        log_warn "No local PostgreSQL found. Installing via apt-get..."
        sudo apt-get update -qq
        sudo apt-get install -y postgresql postgresql-client
        psql_exe=$(command -v psql)
        ver=$("$psql_exe" --version | grep -oP '\d+\.\d+' | head -1)
        svc=$(systemctl list-units --type=service --all --plain --no-legend 2>/dev/null \
            | awk '{print $1}' | grep -E '^postgresql' | head -1 || echo "postgresql")
        found_local+=("${psql_exe}|${ver}|${svc}")
        sudo systemctl enable --now "$svc" || true
    fi

    default_port="${LASH_POSTGRESQL_PORT:-5432}"

    for entry in "${found_local[@]}"; do
        IFS='|' read -r psql_exe ver svc <<< "$entry"
        host="127.0.0.1"
        port="$default_port"

        existing_id=$(json_get "$PG_CONFIG" \
            ".servers | to_entries[] | select(.value.binary_path == \"$psql_exe\") | .key" | head -1)

        if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
            pgid="$existing_id"
            log_info "Updating existing PostgreSQL record $pgid"
        else
            pgid=$(generate_id "pg")
            log_info "Recording new local PostgreSQL: $pgid ($psql_exe, $ver)"
        fi

        IFS='|' read -r pg_port pg_user pg_password <<< "$(collect_postgresql_credentials "$psql_exe" "$host" "$port" "postgres")"
        record=$(build_postgresql_record "$pgid" "local" "$host" "$pg_port" "$pg_user" "$pg_password" "$ver" "$psql_exe" "${svc:-postgresql}")
        json_upsert_record "$PG_CONFIG" ".servers" "$pgid" "$record"
    done
}

configure_remote_postgresql() {
    local host
    local psql_exe
    local port
    local pg_user
    local pg_password
    local pgid
    local record

    log_info "Collecting remote PostgreSQL connection details..."
    host=$(ask_input "PostgreSQL host (IP or FQDN)" "127.0.0.1")
    psql_exe=$(resolve_psql_client)
    IFS='|' read -r port pg_user pg_password <<< "$(collect_postgresql_credentials "$psql_exe" "$host" "5432" "postgres")"
    pgid=$(generate_id "pg")

    record=$(build_postgresql_record "$pgid" "remote" "$host" "$port" "$pg_user" "$pg_password" "" "" "")
    json_upsert_record "$PG_CONFIG" ".servers" "$pgid" "$record"
    log_info "Remote PostgreSQL server recorded as $pgid."
}

main() {
    log_section "PostgreSQL Installer"

    # -----------------------------------------------------------------------
    # 1. Initialise config file
    # -----------------------------------------------------------------------
    init_json_file "$PG_CONFIG" '{"servers":{}}'

    # -----------------------------------------------------------------------
    # 2. Ask: local or remote?
    # -----------------------------------------------------------------------
    if ask_yes_no "Is the PostgreSQL server LOCAL on this machine?"; then
        configure_local_postgresql
    else
        configure_remote_postgresql
    fi

    log_info "PostgreSQL installer complete. config/postgresql.json updated with validated credentials."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
