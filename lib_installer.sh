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
    echo "$prompt"
    for i in "${!options[@]}"; do
        echo "  $((i+1))) ${options[$i]}"
    done
    local choice
    while true; do
        read -r -p "Enter number [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "${options[$((choice-1))]}"
            return 0
        fi
        echo "Invalid choice. Please enter a number between 1 and ${#options[@]}."
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
    echo ""   # newline after hidden input
    echo "$value"
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

# is_port_free <port>
# Returns 0 if the port is not in use, 1 otherwise.
is_port_free() {
    local port="$1"
    if ss -tlnp "sport = :${port}" 2>/dev/null | grep -q ":${port}"; then
        return 1
    fi
    return 0
}

# assert_port_free <port> <service_name>
# Exits with an error message if the port is occupied.
assert_port_free() {
    local port="$1"
    local name="$2"
    if ! is_port_free "$port"; then
        echo "[lib] ERROR: Port ${port} required by ${name} is already in use." >&2
        ss -tlnp "sport = :${port}" >&2
        exit 1
    fi
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

log_info()    { echo "[INFO]  $*"; }
log_warn()    { echo "[WARN]  $*" >&2; }
log_error()   { echo "[ERROR] $*" >&2; }
log_section() { echo ""; echo "======================================"; echo "  $*"; echo "======================================"; }

# ---------------------------------------------------------------------------
# Initialisation guard
# ---------------------------------------------------------------------------
ensure_jq
ensure_config_dir
