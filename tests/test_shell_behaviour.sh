#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "ASSERTION FAILED: ${message}" >&2
        echo "  expected: ${expected}" >&2
        echo "  actual  : ${actual}" >&2
        exit 1
    fi
}

assert_file_contains() {
    local file="$1"
    local jq_filter="$2"
    local expected="$3"
    local actual
    actual=$(jq -r "$jq_filter" "$file")
    assert_eq "$expected" "$actual" "$file => $jq_filter"
}

run_inline_password_resolution_test() {
    local temp_dir
    temp_dir=$(mktemp -d)

    cat > "${temp_dir}/postgresql.json" <<'JSON'
{
  "servers": {
    "pg_inline": {
      "password": "supersecret",
      "password_env": null
    },
    "pg_env": {
      "password": null,
      "password_env": "PG_ENV_SECRET"
    }
  }
}
JSON

    export PG_ENV_SECRET="from-env"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib_installer.sh"

    local inline_password
    local env_password
    inline_password=$(resolve_secret_value_from_json "${temp_dir}/postgresql.json" '.servers["pg_inline"]')
    env_password=$(resolve_secret_value_from_json "${temp_dir}/postgresql.json" '.servers["pg_env"]')

    assert_eq "supersecret" "$inline_password" "inline PostgreSQL password should win"
    assert_eq "from-env" "$env_password" "environment fallback should still work"
    rm -rf "$temp_dir"
}

run_change_port_flow_test() {
    local temp_dir
    temp_dir=$(mktemp -d)

    cat > "${temp_dir}/uvicorn.json" <<'JSON'
{}
JSON

    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib_installer.sh"

    ask_choice() { echo "Use a different port"; }
    ask_input() { echo "9191"; }
    port_usage_report() { echo 'LISTEN 0 4096 *:9090'; }
    is_port_free() {
        case "$1" in
            9090) return 1 ;;
            9191) return 0 ;;
            *) return 1 ;;
        esac
    }

    local resolved
    resolved=$(ensure_port_available "9090" "Prometheus" "${temp_dir}/uvicorn.json" '.port' | tail -n 1)
    assert_eq "9191" "$resolved" "changed port should be returned"
    assert_file_contains "${temp_dir}/uvicorn.json" '.port' '9191'
    rm -rf "$temp_dir"
}

run_nuke_port_flow_test() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib_installer.sh"

    local kill_called="false"
    ask_choice() { echo "Nuke the process using port 9090"; }
    port_usage_report() { echo 'LISTEN 0 4096 *:9090 users:(("prometheus",pid=2660,fd=6))'; }
    is_port_free() {
        if [[ "$kill_called" == "true" ]]; then
            return 0
        fi
        return 1
    }
    kill_processes_on_port() {
        local port="$1"
        assert_eq "9090" "$port" "nuke path should target the conflicting port"
        kill_called="true"
        return 0
    }

    local resolved
    resolved=$(ensure_port_available "9090" "Prometheus" | tail -n 1)
    assert_eq "9090" "$resolved" "nuke path should keep the original port"
}

run_build_postgresql_record_test() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/install_postgresql.sh"

    local default_record_file
    local verified_record_file
    default_record_file=$(mktemp)
    verified_record_file=$(mktemp)

    build_postgresql_record "pg_123" "remote" "db.internal" "5433" "postgres" "hunter2" "" "" "" > "$default_record_file"
    build_postgresql_record "pg_124" "local" "127.0.0.1" "5432" "postgres" "hunter2" "16.3" "/usr/bin/psql" "postgresql" true > "$verified_record_file"

    assert_file_contains "$default_record_file" '.id' 'pg_123'
    assert_file_contains "$default_record_file" '.password' 'hunter2'
    assert_file_contains "$default_record_file" '.password_env' 'null'
    assert_file_contains "$default_record_file" '.binary_path' 'null'
    assert_file_contains "$default_record_file" '.available' 'false'
    assert_file_contains "$verified_record_file" '.available' 'true'
    rm -f "$default_record_file" "$verified_record_file"
}

run_collect_postgresql_credentials_output_test() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/install_postgresql.sh"

    ask_input() {
        case "$1" in
            "PostgreSQL port") echo "5432" ;;
            "PostgreSQL admin username") echo "postgres" ;;
            *) echo "" ;;
        esac
    }
    ask_secret() { echo -n "supersecret"; }
    test_postgresql_connection() {
        log_info "connection ok"
        return 0
    }

    local captured
    captured=$(collect_postgresql_credentials "/usr/bin/psql" "127.0.0.1" "5432" "postgres" 2>/dev/null)
    assert_eq "5432|postgres|supersecret" "$captured" "credential collection should only emit machine-readable stdout"
}


run_collect_postgresql_credentials_with_existing_password_test() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/install_postgresql.sh"

    ask_input() {
        case "$1" in
            "PostgreSQL port") echo "5432" ;;
            "PostgreSQL admin username") echo "postgres" ;;
            *) echo "" ;;
        esac
    }
    ask_secret() { echo -n ""; }
    test_postgresql_connection() {
        assert_eq "existing-secret" "$5" "blank password input should keep the existing secret"
        return 0
    }

    local captured
    captured=$(collect_postgresql_credentials "/usr/bin/psql" "127.0.0.1" "5432" "postgres" "existing-secret" 2>/dev/null)
    assert_eq "5432|postgres|existing-secret" "$captured" "existing password should be reusable during re-verification"
}

run_resolve_managed_python_runtime_test() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib_installer.sh"

    local temp_dir
    local fake_python
    temp_dir=$(mktemp -d)
    fake_python="${temp_dir}/python3"

    cat > "$fake_python" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$1" == "-m" && "\$2" == "venv" ]]; then
    target="\$3"
    mkdir -p "\${target}/bin"
    cat > "\${target}/bin/python" <<'PYEOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$1" == "-m" && "\$2" == "pip" ]]; then
    exit 0
fi
exit 0
PYEOF
    chmod +x "\${target}/bin/python"
    exit 0
fi
exit 1
EOF
    chmod +x "$fake_python"

    local runtime
    runtime=$(resolve_managed_python_runtime "$fake_python" "${temp_dir}/apps/python_test")
    assert_eq "${temp_dir}/apps/python_test/bin/python" "$runtime" "managed runtime should point at the venv python"
    [[ -x "$runtime" ]] || {
        echo "ASSERTION FAILED: managed runtime should be executable" >&2
        exit 1
    }

    rm -rf "$temp_dir"
}

run_ensure_python_package_installed_test() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib_installer.sh"

    local temp_dir
    local fake_python
    temp_dir=$(mktemp -d)
    fake_python="${temp_dir}/python3"

    cat > "$fake_python" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
marker_dir="$(dirname "$0")"
marker_file="${marker_dir}/fastapi.installed"
if [[ "$1" == "-c" ]]; then
    if [[ -f "$marker_file" ]]; then
        echo "9.9.9"
        exit 0
    fi
    exit 1
fi
if [[ "$1" == "-m" && "$2" == "pip" && "$3" == "install" ]]; then
    touch "$marker_file"
    exit 0
fi
exit 1
EOF
    chmod +x "$fake_python"

    local version
    version=$(ensure_python_package_installed "$fake_python" "fastapi" "fastapi")
    assert_eq "9.9.9" "$version" "package install helper should return the detected module version"

    rm -rf "$temp_dir"
}


run_runtime_entrypoint_files_test() {

    python - <<'PYEOF' "${REPO_ROOT}"
from pathlib import Path
import sys

repo_root = Path(sys.argv[1])
main_text = (repo_root / "main.py").read_text()
app_text = (repo_root / "app.py").read_text()
tasks_text = (repo_root / "tasks.py").read_text()
deploy_text = (repo_root / "deploy_lash.sh").read_text()

assert 'app = FastAPI(title="LASH Gateway")' in main_text, 'FastAPI app bootstrap missing'
assert '@app.get("/health"' in main_text, 'FastAPI health route missing'
assert 'render_dashboard()' in app_text, 'Streamlit bootstrap missing'
assert 'def create_celery_app()' in tasks_text, 'Celery factory missing'
assert '@celery_app.task(name="lash.ping")' in tasks_text, 'Celery smoke task missing'
assert '-A tasks:celery_app worker' in deploy_text, 'Celery systemd entrypoint should target celery_app'
assert '/health/liveliness' in deploy_text, 'LiteLLM health check should target the liveliness endpoint'
PYEOF
}

run_configure_local_postgresql_reuse_existing_record_test() {
    local temp_dir
    local fake_bin
    local config_file
    temp_dir=$(mktemp -d)
    fake_bin="${temp_dir}/bin"
    mkdir -p "$fake_bin"
    printf '#!/usr/bin/env bash
echo "psql (PostgreSQL) 16.3"
' > "${fake_bin}/psql"
    chmod +x "${fake_bin}/psql"
    config_file="${temp_dir}/postgresql.json"

    cat > "$config_file" <<JSON
{
  "servers": {
    "pg_existing": {
      "id": "pg_existing",
      "location": "local",
      "host": "localhost",
      "port": 5432,
      "username": "postgres",
      "password": "stored-secret",
      "password_env": null,
      "version": "16.3",
      "binary_path": "${fake_bin}/psql",
      "service_name": "postgresql",
      "available": false
    }
  }
}
JSON

    # shellcheck disable=SC1091
    source "${REPO_ROOT}/install_postgresql.sh"
    PG_CONFIG="$config_file"
    PATH="${fake_bin}:$PATH"

    systemctl() { return 0; }
    find() { return 0; }
    prompt_existing_postgresql_action() { echo "Use the existing configuration"; }
    ask_input() { echo "unexpected"; }
    ask_secret() { echo -n "unexpected"; }
    test_postgresql_connection() {
        assert_eq "${fake_bin}/psql" "$1" "reuse flow should validate using the discovered binary"
        assert_eq "localhost" "$2" "reuse flow should keep the stored host"
        assert_eq "5432" "$3" "reuse flow should keep the stored port"
        assert_eq "postgres" "$4" "reuse flow should keep the stored username"
        assert_eq "stored-secret" "$5" "reuse flow should keep the stored password"
        return 0
    }

    configure_local_postgresql

    assert_file_contains "$config_file" '.servers["pg_existing"].host' 'localhost'
    assert_file_contains "$config_file" '.servers["pg_existing"].password' 'stored-secret'
    assert_file_contains "$config_file" '.servers["pg_existing"].available' 'true'
    rm -rf "$temp_dir"
}

run_configure_local_postgresql_failed_reuse_does_not_overwrite_test() {
    local temp_dir
    local fake_bin
    local config_file
    local before
    local after
    local status=0
    temp_dir=$(mktemp -d)
    fake_bin="${temp_dir}/bin"
    mkdir -p "$fake_bin"
    printf '#!/usr/bin/env bash
echo "psql (PostgreSQL) 16.3"
' > "${fake_bin}/psql"
    chmod +x "${fake_bin}/psql"
    config_file="${temp_dir}/postgresql.json"

    cat > "$config_file" <<JSON
{
  "servers": {
    "pg_existing": {
      "id": "pg_existing",
      "location": "local",
      "host": "localhost",
      "port": 5432,
      "username": "postgres",
      "password": "stored-secret",
      "password_env": null,
      "version": "16.3",
      "binary_path": "${fake_bin}/psql",
      "service_name": "postgresql",
      "available": true
    }
  }
}
JSON
    before=$(cat "$config_file")

    # shellcheck disable=SC1091
    source "${REPO_ROOT}/install_postgresql.sh"
    PG_CONFIG="$config_file"
    PATH="${fake_bin}:$PATH"

    systemctl() { return 0; }
    find() { return 0; }
    prompt_existing_postgresql_action() { echo "Use the existing configuration"; }
    ask_yes_no() { return 1; }
    test_postgresql_connection() { return 1; }

    set +e
    ( configure_local_postgresql ) >/dev/null 2>&1
    status=$?
    set -e

    if [[ $status -eq 0 ]]; then
        echo "ASSERTION FAILED: configure_local_postgresql should abort when reuse validation fails and the operator declines to modify" >&2
        exit 1
    fi

    after=$(cat "$config_file")
    assert_eq "$before" "$after" "failed reuse path must not overwrite the existing PostgreSQL record"
    rm -rf "$temp_dir"
}

run_inline_password_resolution_test
run_change_port_flow_test
run_nuke_port_flow_test
run_build_postgresql_record_test
run_collect_postgresql_credentials_output_test
run_collect_postgresql_credentials_with_existing_password_test
run_resolve_managed_python_runtime_test
run_ensure_python_package_installed_test
run_runtime_entrypoint_files_test
run_configure_local_postgresql_reuse_existing_record_test
run_configure_local_postgresql_failed_reuse_does_not_overwrite_test

echo "All shell behaviour tests passed."
