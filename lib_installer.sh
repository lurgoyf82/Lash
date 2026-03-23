#!/usr/bin/env bash
# lib_installer.sh — Shared helper library for the LASH modular installer framework.
# Source this file at the top of every installer script.
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib_installer.sh"

set -euo pipefail

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------
LASH_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LASH_CONFIG_DIR="${LASH_INSTALLER_DIR}/config"
LASH_DEBUG="${LASH_DEBUG:-0}"

is_truthy() {
    local value="${1:-}"
    [[ "${value,,}" =~ ^(1|true|yes|on)$ ]]
}

enable_debug_mode() {
    if ! is_truthy "$LASH_DEBUG"; then
        return 0
    fi

    export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
    export BASH_XTRACEFD=2
    set -x
}

# ---------------------------------------------------------------------------
# Bootstrap: ensure jq is available (required for all JSON operations)
# ---------------------------------------------------------------------------
ensure_jq() {
    if ! command -v jq &>/dev/null; then
        echo "[lib] jq not found — installing via apt-get..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq jq
    fi
}

# ---------------------------------------------------------------------------
# Filesystem helpers
# ---------------------------------------------------------------------------
ensure_config_dir() {
    mkdir -p "${LASH_CONFIG_DIR}"
}

# init_json_file <path> <initial_json>
# Creates the file with initial_json only if the file does not yet exist.
init_json_file() {
    local path="$1"
    local initial_json="$2"
    ensure_config_dir
    if [[ ! -f "$path" ]]; then
        echo "$initial_json" | jq '.' > "$path"
        echo "[lib] Initialized config file: $path"
    fi
}

# ---------------------------------------------------------------------------
# JSON read / write helpers (all via jq — no sed/awk manipulation of JSON)
# ---------------------------------------------------------------------------

# json_get <file> <jq_filter>
# Prints the raw jq result (no quoting).
json_get() {
    local file="$1"
    local filter="$2"
    jq -r "$filter" "$file" 2>/dev/null || echo "null"
}

# json_set <file> <jq_filter_producing_new_root>
# Replaces the entire file with the result of applying the filter to the current content.
json_set() {
    local file="$1"
    local filter="$2"
    local tmp
    tmp="$(mktemp)"
    jq "$filter" "$file" > "$tmp"
    mv "$tmp" "$file"
}

# json_merge_object <file> <json_fragment>
# Merges a JSON object fragment into the top-level object of the file.
json_merge_object() {
    local file="$1"
    local fragment="$2"
    local tmp
    tmp="$(mktemp)"
    jq --argjson frag "$fragment" '. * $frag' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# json_set_key <file> <key_path> <json_value>
# Sets an arbitrary nested key using jq path syntax.
# Example: json_set_key config/foo.json '.servers["pg_001"].host' '"localhost"'
json_set_key() {
    local file="$1"
    local key_path="$2"
    local json_value="$3"
    local tmp
    tmp="$(mktemp)"
    jq "${key_path} = ${json_value}" "$file" > "$tmp"
    mv "$tmp" "$file"
}

# json_append_to_array <file> <jq_array_path> <json_element>
# Appends an element to a JSON array inside the file.
json_append_to_array() {
    local file="$1"
    local array_path="$2"
    local element="$3"
    local tmp
    tmp="$(mktemp)"
    jq --argjson el "$element" "${array_path} += [\$el]" "$file" > "$tmp"
    mv "$tmp" "$file"
}

# json_upsert_record <file> <object_path> <record_id> <json_record>
# Inserts or replaces a record inside a JSON object keyed by record_id.
json_upsert_record() {
    local file="$1"
    local object_path="$2"   # e.g. '.installations'
    local record_id="$3"
    local json_record="$4"
    local tmp
    tmp="$(mktemp)"
    jq --arg id "$record_id" \
       --argjson rec "$json_record" \
       "${object_path}[\$id] = \$rec" "$file" > "$tmp"
    mv "$tmp" "$file"
}

# resolve_component_python_executable <component_config> [python_config]
# Returns the explicit resolved runtime for a component.
# Falls back to config/python.json via selected_python_id for backward compatibility.
resolve_component_python_executable() {
    local component_config="$1"
    local python_config="${2:-${LASH_CONFIG_DIR}/python.json}"
    local resolved_python
    local python_id

    resolved_python=$(json_get "$component_config" '.resolved_python_executable')
    if [[ "$resolved_python" != "null" && -n "$resolved_python" ]]; then
        echo "$resolved_python"
        return 0
    fi

    python_id=$(json_get "$component_config" '.selected_python_id')
    if [[ "$python_id" == "null" || -z "$python_id" ]]; then
        log_error "No resolved_python_executable or selected_python_id found in ${component_config}."
        return 1
    fi

    resolved_python=$(json_get "$python_config" ".installations[\"${python_id}\"].executable")
    if [[ "$resolved_python" == "null" || -z "$resolved_python" ]]; then
        log_error "Could not resolve Python executable for ${python_id} from ${python_config}."
        return 1
    fi

    echo "$resolved_python"
}

# ---------------------------------------------------------------------------
# ID generation
# ---------------------------------------------------------------------------

# generate_id <prefix>
# Returns a short deterministic-looking but collision-resistant ID.
generate_id() {
    local prefix="$1"
    local suffix
    suffix="$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 8 \
              || date +%s%N | sha256sum | cut -d' ' -f1 | head -c 8)"
    echo "${prefix}_${suffix}"
}

# ---------------------------------------------------------------------------
# User-interaction helpers
# ---------------------------------------------------------------------------

# ask_yes_no <prompt>
# Returns 0 (yes) or 1 (no).
ask_yes_no() {
    local prompt="$1"
    local answer
    while true; do
        read -r -p "${prompt} [y/n]: " answer
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# ask_choice <prompt> <option1> <option2> ...
# Prints the selected value to stdout.
ask_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local i
    >&2 echo "$prompt"
    for i in "${!options[@]}"; do
        >&2 echo "  $((i+1))) ${options[$i]}"
    done
    local choice
    while true; do
        read -r -p "Enter number [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "${options[$((choice-1))]}"
            return 0
        fi
        >&2 echo "Invalid choice. Please enter a number between 1 and ${#options[@]}."
    done
}

# ask_input <prompt> [default]
# Reads a line of free-form input, with an optional default.
ask_input() {
    local prompt="$1"
    local default="${2:-}"
    local value
    if [[ -n "$default" ]]; then
        read -r -p "${prompt} [${default}]: " value
        echo "${value:-$default}"
    else
        read -r -p "${prompt}: " value
        echo "$value"
    fi
}

# ask_secret <prompt>
# Reads a secret without echoing. Returns via stdout (capture with $(...)).
ask_secret() {
    local prompt="$1"
    local value
    read -r -s -p "${prompt}: " value
    >&2 echo ""   # newline after hidden input (do not pollute stdout)
    echo -n "$value"
}

# ---------------------------------------------------------------------------
# Installer delegation
# ---------------------------------------------------------------------------

# call_installer <script_name>
# Runs a sibling installer script and waits for it to finish.
# The sibling must live in LASH_INSTALLER_DIR.
call_installer() {
    local script="$1"
    local full_path="${LASH_INSTALLER_DIR}/${script}"
    if [[ ! -f "$full_path" ]]; then
        echo "[lib] ERROR: Installer not found: $full_path" >&2
        exit 1
    fi
    if [[ ! -x "$full_path" ]]; then
        chmod +x "$full_path"
    fi
    echo "[lib] Delegating to: $script"
    bash "$full_path"
    echo "[lib] Returned from: $script"
}

# ---------------------------------------------------------------------------
# Port conflict detection
# ---------------------------------------------------------------------------

validate_port_number() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

# is_port_free <port>
# Returns 0 if the port is not in use, 1 otherwise.
is_port_free() {
    local port="$1"
    if ss -tlnp "sport = :${port}" 2>/dev/null | grep -q ":${port}"; then
        return 1
    fi
    return 0
}

port_usage_report() {
    local port="$1"
    ss -tlnp "sport = :${port}" 2>/dev/null || true
}

port_pids() {
    local port="$1"
    port_usage_report "$port" | grep -o 'pid=[0-9]\+' | cut -d= -f2 | sort -u
}

kill_processes_on_port() {
    local port="$1"
    mapfile -t pids < <(port_pids "$port")

    if [[ ${#pids[@]} -eq 0 ]]; then
        log_error "No process IDs could be resolved for port ${port}."
        return 1
    fi

    log_warn "Stopping processes on port ${port}: ${pids[*]}"
    kill "${pids[@]}" 2>/dev/null || true
    sleep 1

    if is_port_free "$port"; then
        log_info "Port ${port} is now free."
        return 0
    fi

    log_warn "Processes on port ${port} ignored SIGTERM. Sending SIGKILL..."
    kill -9 "${pids[@]}" 2>/dev/null || true
    sleep 1

    if is_port_free "$port"; then
        log_info "Port ${port} is now free after SIGKILL."
        return 0
    fi

    log_error "Port ${port} is still busy after attempting to stop the owning processes."
    return 1
}

prompt_for_free_port() {
    local current_port="$1"
    local service_name="$2"
    local candidate

    while true; do
        candidate=$(ask_input "${service_name} port" "$current_port")
        if ! validate_port_number "$candidate"; then
            log_warn "Port '${candidate}' is invalid. Enter a value between 1 and 65535."
            continue
        fi
        if ! is_port_free "$candidate"; then
            log_warn "Port ${candidate} is still busy. Choose another port or free it first."
            port_usage_report "$candidate" >&2
            continue
        fi
        echo "$candidate"
        return 0
    done
}

persist_port_value() {
    local config_file="$1"
    local jq_path="$2"
    local port="$3"

    [[ -z "$config_file" || -z "$jq_path" ]] && return 0

    init_json_file "$config_file" '{}'
    json_set_key "$config_file" "$jq_path" "$port"
    log_info "Saved ${port} to ${config_file} (${jq_path})."
}

ensure_port_available() {
    local port="$1"
    local service_name="$2"
    local config_file="${3:-}"
    local jq_path="${4:-}"
    local chosen_port="$port"
    local action

    if is_port_free "$port"; then
        echo "$port"
        return 0
    fi

    echo "[lib] ERROR: Port ${port} required by ${service_name} is already in use." >&2
    port_usage_report "$port" >&2

    action=$(ask_choice \
        "Port ${port} for ${service_name} is occupied. What do you want to do?" \
        "Nuke the process using port ${port}" \
        "Use a different port")

    case "$action" in
        "Nuke the process using port ${port}")
            kill_processes_on_port "$port" || exit 1
            ;;
        "Use a different port")
            chosen_port=$(prompt_for_free_port "$port" "$service_name")
            persist_port_value "$config_file" "$jq_path" "$chosen_port"
            ;;
        *)
            log_error "Unsupported port-conflict action: ${action}"
            exit 1
            ;;
    esac

    echo "$chosen_port"
}

# assert_port_free <port> <service_name>
# Exits with an error message if the port is occupied.
assert_port_free() {
    local port="$1"
    local name="$2"
    if ! is_port_free "$port"; then
        echo "[lib] ERROR: Port ${port} required by ${name} is already in use." >&2
        port_usage_report "$port" >&2
        exit 1
    fi
}

resolve_secret_value_from_json() {
    local file="$1"
    local object_path="$2"
    local inline_secret
    local secret_env_name

    inline_secret=$(json_get "$file" "${object_path}.password")
    if [[ "$inline_secret" != "null" && -n "$inline_secret" ]]; then
        echo "$inline_secret"
        return 0
    fi

    secret_env_name=$(json_get "$file" "${object_path}.password_env")
    if [[ "$secret_env_name" != "null" && -n "$secret_env_name" && -n "${!secret_env_name:-}" ]]; then
        echo "${!secret_env_name}"
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# Service status helpers
# ---------------------------------------------------------------------------

# systemd_service_active <service>
systemd_service_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

# systemd_enable_start <service>
systemd_enable_start() {
    sudo systemctl enable --now "$1"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_info()    { echo "[INFO]  $*" >&2; }
log_warn()    { echo "[WARN]  $*" >&2; }
log_error()   { echo "[ERROR] $*" >&2; }
log_section() { echo "" >&2; echo "======================================" >&2; echo "  $*" >&2; echo "======================================" >&2; }

# ---------------------------------------------------------------------------
# Initialisation guard
# ---------------------------------------------------------------------------
ensure_jq
ensure_config_dir
enable_debug_mode
if is_truthy "$LASH_DEBUG"; then
    log_info "Installer debug mode enabled (LASH_DEBUG=${LASH_DEBUG}). Commands and logs will be printed to screen."
fi
