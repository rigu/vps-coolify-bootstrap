#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Script: test-os-matrix.sh
# Purpose: Test bootstrap OS detection and support across all target distros
# Usage: ./test-os-matrix.sh [--no-cleanup]
# ============================================================================

SCRIPT_DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SCRIPT_NAME="${0##*/}"

# --- Configuration ---
NO_CLEANUP="${NO_CLEANUP:-0}"

# OS matrix: image|expected_id|expected_version|expected_support
# expected_support: 0=supported, 1=unsupported, 2=untested
# Using | as delimiter to avoid conflict with docker image:tag
readonly OS_MATRIX=(
    "ubuntu:22.04|ubuntu|22.04|0"
    "ubuntu:24.04|ubuntu|24.04|0"
    "debian:12|debian|12|0"
    "debian:13|debian|13|0"
    "ubuntu:20.04|ubuntu|20.04|1"
    "debian:11|debian|11|1"
)

# Track created containers for cleanup
CONTAINERS_CREATED=()

# --- Functions ---
log_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}: $*"; }
log_success() { echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}: $*"; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}: $*" >&2; }
log_warn() { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}: $*" >&2; }

# shellcheck disable=SC2317  # Cleanup is called via trap, not directly
cleanup() {
    if [[ "$NO_CLEANUP" == "1" ]]; then
        log_warn "Skipping cleanup (--no-cleanup specified)"
        if [[ ${#CONTAINERS_CREATED[@]} -gt 0 ]]; then
            log_warn "Containers left behind: ${CONTAINERS_CREATED[*]}"
        fi
        return 0
    fi
    
    log_info "Cleaning up Docker resources..."
    
    # Remove containers created during test
    for container in "${CONTAINERS_CREATED[@]}"; do
        if docker ps -aq -f "name=${container}" | grep -q .; then
            docker rm -f "$container" >/dev/null 2>&1 || true
        fi
    done
    
    # Prune dangling images from test (optional, conservative)
    # docker image prune -f >/dev/null 2>&1 || true
    
    log_info "Cleanup complete"
}
trap cleanup EXIT

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Test bootstrap OS detection and support functions across all target distributions
using Docker containers.

Options:
    -h, --help       Show this help message
    --no-cleanup     Don't remove containers after test (for debugging)

Tested OS Matrix:
    - Ubuntu 22.04 LTS (supported)
    - Ubuntu 24.04 LTS (supported)
    - Debian 12 Bookworm (supported)
    - Debian 13 Trixie (supported)
    - Ubuntu 20.04 LTS (unsupported - negative test)
    - Debian 11 Bullseye (unsupported - negative test)

Requirements:
    - Docker installed and running
    - scripts/common.sh in same directory

Exit Codes:
    0  All tests passed
    1  One or more tests failed
    2  Prerequisites not met
EOF
}

check_prerequisites() {
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is required but not installed"
        exit 2
    fi
    
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        exit 2
    fi
    
    if [[ ! -f "${SCRIPT_DIR}/common.sh" ]]; then
        log_error "common.sh not found in ${SCRIPT_DIR}"
        exit 2
    fi
}

# Run OS detection test in container
# Arguments: image, expected_id, expected_version, expected_support
run_os_test() {
    local image="$1"
    local expected_id="$2"
    local expected_version="$3"
    local expected_support="$4"
    
    local container_name="bootstrap-test-${image//[:.]/-}"
    CONTAINERS_CREATED+=("$container_name")
    
    log_info "Testing ${image}..."
    
    # Create test script that sources common.sh and runs detection
    local test_script
    test_script=$(cat <<'TESTSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Source common.sh from mounted volume
source /bootstrap/scripts/common.sh

# Run detection
detect_os

echo "DETECTED_ID=${BOOTSTRAP_OS_ID}"
echo "DETECTED_VERSION=${BOOTSTRAP_OS_VERSION}"
echo "DETECTED_CODENAME=${BOOTSTRAP_OS_CODENAME}"

# Run support check
set +e
check_os_support
support_result=$?
set -e

echo "SUPPORT_RESULT=${support_result}"
TESTSCRIPT
)
    
    # Run container with bootstrap repo mounted
    local output
    if ! output=$(docker run --rm \
        --name "$container_name" \
        -v "${SCRIPT_DIR}/..:/bootstrap:ro" \
        "$image" \
        bash -c "$test_script" 2>&1); then
        log_error "Container execution failed for ${image}"
        echo "$output" >&2
        return 1
    fi
    
    # Parse results
    local detected_id detected_version support_result
    detected_id=$(echo "$output" | grep "^DETECTED_ID=" | cut -d= -f2)
    detected_version=$(echo "$output" | grep "^DETECTED_VERSION=" | cut -d= -f2)
    support_result=$(echo "$output" | grep "^SUPPORT_RESULT=" | cut -d= -f2)
    
    # Validate results
    local test_passed=1
    
    if [[ "$detected_id" != "$expected_id" ]]; then
        log_error "${image}: OS ID mismatch - expected '${expected_id}', got '${detected_id}'"
        test_passed=0
    fi
    
    if [[ "$detected_version" != "$expected_version" ]]; then
        log_error "${image}: Version mismatch - expected '${expected_version}', got '${detected_version}'"
        test_passed=0
    fi
    
    if [[ "$support_result" != "$expected_support" ]]; then
        local support_label
        case "$expected_support" in
            0) support_label="supported" ;;
            1) support_label="unsupported" ;;
            2) support_label="untested" ;;
            *) support_label="unknown" ;;
        esac
        log_error "${image}: Support check mismatch - expected ${expected_support} (${support_label}), got ${support_result}"
        test_passed=0
    fi
    
    if [[ "$test_passed" == "1" ]]; then
        local support_desc
        case "$expected_support" in
            0) support_desc="supported" ;;
            1) support_desc="unsupported (expected)" ;;
            2) support_desc="untested" ;;
        esac
        log_success "${image}: PASS (${detected_id} ${detected_version}, ${support_desc})"
        return 0
    else
        return 1
    fi
}

# Run shellcheck on all bash scripts
run_shellcheck() {
    log_info "Running shellcheck on scripts..."
    
    if ! command -v shellcheck >/dev/null 2>&1; then
        log_warn "shellcheck not installed locally, running in container..."
        
        local container_name="bootstrap-test-shellcheck"
        CONTAINERS_CREATED+=("$container_name")
        
        # Only fail on warnings and errors, not info (SC1091 is info level)
        if ! docker run --rm \
            --name "$container_name" \
            -v "${SCRIPT_DIR}/..:/bootstrap:ro" \
            koalaman/shellcheck-alpine:stable \
            sh -c "find /bootstrap/scripts -name '*.sh' -exec shellcheck -x --severity=warning {} +" 2>&1; then
            log_error "shellcheck found issues"
            return 1
        fi
    else
        # Only fail on warnings and errors, not info
        if ! find "${SCRIPT_DIR}" -name '*.sh' -exec shellcheck -x --severity=warning {} +; then
            log_error "shellcheck found issues"
            return 1
        fi
    fi
    
    log_success "shellcheck: PASS"
    return 0
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --no-cleanup)
                NO_CLEANUP=1
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done
    
    log_info "Starting OS compatibility matrix tests..."
    log_info "Repository: ${SCRIPT_DIR}/.."
    
    check_prerequisites
    
    local total_tests=0
    local passed_tests=0
    local failed_tests=0
    
    # Run OS matrix tests
    for entry in "${OS_MATRIX[@]}"; do
        IFS='|' read -r image expected_id expected_version expected_support <<< "$entry"
        total_tests=$((total_tests + 1))
        
        if run_os_test "$image" "$expected_id" "$expected_version" "$expected_support"; then
            passed_tests=$((passed_tests + 1))
        else
            failed_tests=$((failed_tests + 1))
        fi
    done
    
    # Run shellcheck
    total_tests=$((total_tests + 1))
    if run_shellcheck; then
        passed_tests=$((passed_tests + 1))
    else
        failed_tests=$((failed_tests + 1))
    fi
    
    # Summary
    echo ""
    log_info "=========================================="
    log_info "Test Summary: ${passed_tests}/${total_tests} passed"
    
    if [[ "$failed_tests" -gt 0 ]]; then
        log_error "${failed_tests} test(s) failed"
        exit 1
    else
        log_success "All tests passed!"
        exit 0
    fi
}

# --- Entry Point ---
main "$@"
