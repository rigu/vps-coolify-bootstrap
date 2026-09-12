#!/usr/bin/env bash
# =============================================================================
# Script: test-integration-full.sh
# Purpose: Full integration test of bootstrap across all supported OS using Docker
# Usage: ./test-integration-full.sh [--no-cleanup] [--os=debian:13] [--keep-images]
#
# This script performs a complete end-to-end test of the bootstrap process:
# 1. Builds systemd-enabled Docker images for each OS
# 2. Starts container with systemd as PID 1
# 3. Sets up bootstrap environment
# 4. Runs prepare-existing-server.sh
# 5. Runs bootstrap-host.sh (first run)
# 6. Runs verify-bootstrap-state.sh (post-bootstrap)
# 7. Runs bootstrap-host.sh (idempotency test)
# 8. Runs verify-bootstrap-state.sh (post-idempotency)
# 9. Restarts container (reboot simulation)
# 10. Runs verify-bootstrap-state.sh (post-reboot)
#
# Requirements:
# - Docker with privileged container support
# - ~30 minutes for full test (all OS)
# - ~5-8 minutes for single OS test
# =============================================================================
set -euo pipefail

# --- Script metadata ---
SCRIPT_DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SCRIPT_NAME="${0##*/}"
REPO_ROOT=""
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT

# --- Configuration ---
NO_CLEANUP="${NO_CLEANUP:-0}"
KEEP_IMAGES="${KEEP_IMAGES:-0}"
SINGLE_OS="${SINGLE_OS:-}"
VERBOSE="${VERBOSE:-0}"

# Test timeout in seconds (per phase) - used by timeout command if available
# shellcheck disable=SC2034
readonly PHASE_TIMEOUT=300

# OS matrix: os_tag|base_image|os_id|os_version
readonly OS_MATRIX=(
    "ubuntu-22.04|ubuntu:22.04|ubuntu|22.04"
    "ubuntu-24.04|ubuntu:24.04|ubuntu|24.04"
    "debian-12|debian:12|debian|12"
    "debian-13|debian:13|debian|13"
)

# Container naming prefix
readonly CONTAINER_PREFIX="bootstrap-integration-test"

# Track resources for cleanup
declare -a CONTAINERS_CREATED=()
declare -a IMAGES_CREATED=()
declare -a LOG_DIRS_CREATED=()

# Test results
declare -A TEST_RESULTS=()
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# --- Logging functions ---
log_ts() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log_info() {
    echo "[INFO] [$(log_ts)] ${SCRIPT_NAME}: $*"
}

log_success() {
    echo "[SUCCESS] [$(log_ts)] ${SCRIPT_NAME}: $*"
}

log_error() {
    echo "[ERROR] [$(log_ts)] ${SCRIPT_NAME}: $*" >&2
}

log_warn() {
    echo "[WARN] [$(log_ts)] ${SCRIPT_NAME}: $*" >&2
}

log_phase() {
    echo ""
    echo "=========================================="
    echo "[PHASE] $*"
    echo "=========================================="
}

log_subphase() {
    echo ""
    echo "--- $* ---"
}

log_verbose() {
    if [[ "$VERBOSE" == "1" ]]; then
        echo "[VERBOSE] $*"
    fi
}

# --- Cleanup function ---
# shellcheck disable=SC2317
cleanup() {
    local exit_code=$?
    
    echo ""
    log_info "Cleanup starting..."
    
    if [[ "$NO_CLEANUP" == "1" ]]; then
        log_warn "Skipping cleanup (--no-cleanup specified)"
        if [[ ${#CONTAINERS_CREATED[@]} -gt 0 ]]; then
            log_warn "Containers left running: ${CONTAINERS_CREATED[*]}"
        fi
        if [[ ${#IMAGES_CREATED[@]} -gt 0 ]]; then
            log_warn "Images created: ${IMAGES_CREATED[*]}"
        fi
        return 0
    fi
    
    # Stop and remove containers
    for container in "${CONTAINERS_CREATED[@]}"; do
        if docker ps -aq -f "name=^${container}$" 2>/dev/null | grep -q .; then
            log_info "Stopping container: $container"
            docker stop "$container" >/dev/null 2>&1 || true
            docker rm -f "$container" >/dev/null 2>&1 || true
        fi
    done
    
    # Remove images if requested
    if [[ "$KEEP_IMAGES" != "1" ]]; then
        for image in "${IMAGES_CREATED[@]}"; do
            if docker images -q "$image" 2>/dev/null | grep -q .; then
                log_info "Removing image: $image"
                docker rmi -f "$image" >/dev/null 2>&1 || true
            fi
        done
    else
        log_info "Keeping images (--keep-images specified): ${IMAGES_CREATED[*]}"
    fi
    
    # Remove log directories (keep on failure for debugging)
    if [[ $exit_code -eq 0 ]] && [[ "$NO_CLEANUP" != "1" ]]; then
        for log_dir in "${LOG_DIRS_CREATED[@]}"; do
            if [[ -d "$log_dir" ]]; then
                log_info "Removing log directory: $log_dir"
                rm -rf "$log_dir"
            fi
        done
    else
        if [[ ${#LOG_DIRS_CREATED[@]} -gt 0 ]]; then
            log_info "Keeping log directories for debugging: ${LOG_DIRS_CREATED[*]}"
        fi
    fi
    
    log_info "Cleanup complete"
    return "$exit_code"
}
trap cleanup EXIT

# --- Usage ---
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Full integration test of VPS bootstrap across supported operating systems.

Options:
    -h, --help          Show this help message
    --no-cleanup        Don't remove containers/images after test (for debugging)
    --keep-images       Keep Docker images but remove containers
    --os=<tag>          Test only specific OS (e.g., --os=debian-13)
    --verbose           Show detailed output from bootstrap scripts
    --list-os           List available OS tags and exit

Available OS:
    ubuntu-22.04    Ubuntu 22.04 LTS (Jammy)
    ubuntu-24.04    Ubuntu 24.04 LTS (Noble)
    debian-12       Debian 12 (Bookworm)
    debian-13       Debian 13 (Trixie)

Test Phases:
    1. Build systemd-enabled Docker image
    2. Start container with systemd as PID 1
    3. Setup bootstrap environment
    4. Run prepare-existing-server.sh
    5. Run bootstrap-host.sh (first run)
    6. Run verify-bootstrap-state.sh (post-bootstrap)
    7. Run bootstrap-host.sh (idempotency test)
    8. Run verify-bootstrap-state.sh (post-idempotency)
    9. Restart container (simulates reboot)
    10. Run verify-bootstrap-state.sh (post-reboot)

Exit Codes:
    0   All tests passed
    1   One or more tests failed
    2   Prerequisites not met or invalid arguments

Examples:
    # Run full test matrix
    ./test-integration-full.sh

    # Test only Debian 13
    ./test-integration-full.sh --os=debian-13

    # Debug mode (keep containers)
    ./test-integration-full.sh --os=debian-13 --no-cleanup --verbose
EOF
}

# --- Prerequisites check ---
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Docker installed
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is required but not installed"
        exit 2
    fi
    
    # Docker daemon running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        exit 2
    fi
    
    # Required scripts exist
    local required_scripts=(
        "prepare-existing-server.sh"
        "bootstrap-host.sh"
        "verify-bootstrap-state.sh"
        "common.sh"
    )
    
    for script in "${required_scripts[@]}"; do
        if [[ ! -f "${SCRIPT_DIR}/${script}" ]]; then
            log_error "Required script not found: ${SCRIPT_DIR}/${script}"
            exit 2
        fi
    done
    
    # Bootstrap env example exists
    if [[ ! -f "${REPO_ROOT}/env/bootstrap.env.example" ]]; then
        log_error "bootstrap.env.example not found"
        exit 2
    fi
    
    log_success "Prerequisites check passed"
}

# --- Generate test bootstrap.env ---
generate_test_env() {
    local env_file="$1"
    
    cat > "$env_file" << 'ENVEOF'
# =============================================================================
# Test bootstrap.env - generated for integration testing
# =============================================================================

# SSH Configuration
SSH_PORT=2222
SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForIntegrationTesting000000000000 test@integration"

# User Configuration
DEVOPS_USER=devops
COOLIFY_SUDO_NOPASSWD_USER=coolify
ADDITIONAL_SUDO_USERS=

# Security Settings
DEVOPS_USER_NOPASSWD=false
DOCKER_USERS=
USER_PASSWORDS_ENCRYPTION_PASSWORD=TestEncryptionPassword123!ForIntegrationTesting

# Coolify Configuration
COOLIFY_PUBLIC_DOMAIN=coolify.test.local
COOLIFY_ROOT_USER_EMAIL=test@example.com
COOLIFY_ROOT_USERNAME=admin
COOLIFY_ROOT_USER_PASSWORD=TestPassword123!@#$%^&*()

# Realtime Ports
CLOSE_COOLIFY_REALTIME_PORTS=true

# Bootstrap Source (not used in container test, but required)
BOOTSTRAP_REPO_URL=https://github.com/rigu/vps-coolify-bootstrap.git
BOOTSTRAP_REPO_REF=main

# Version Compatibility
COOLIFY_MIN_VERSION=4.0.0
COOLIFY_MAX_VERSION=4.99.99
ALLOW_UNTESTED_OS=false

# Test mode - skip Coolify install (Docker-in-Docker not available)
SKIP_COOLIFY_INSTALL=true

# Docker workaround
DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX=true
ENVEOF

    chmod 600 "$env_file"
}

# --- Build systemd-enabled Docker image ---
build_systemd_image() {
    local os_tag="$1"
    local base_image="$2"
    local image_name="systemd-bootstrap-test:${os_tag}"
    
    log_subphase "Building image: ${image_name}"
    
    # Check if image already exists
    if docker images -q "$image_name" 2>/dev/null | grep -q .; then
        log_info "Image already exists: ${image_name}"
        return 0
    fi
    
    local dockerfile_content
    dockerfile_content=$(cat << DOCKERFILE
FROM ${base_image}

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

# Install systemd and required packages
RUN apt-get update && apt-get install -y --no-install-recommends \\
    systemd \\
    systemd-sysv \\
    dbus \\
    ca-certificates \\
    curl \\
    git \\
    sudo \\
    openssh-server \\
    && apt-get clean \\
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Remove unnecessary systemd units that cause issues in containers
RUN rm -f /lib/systemd/system/multi-user.target.wants/* \\
    /etc/systemd/system/*.wants/* \\
    /lib/systemd/system/local-fs.target.wants/* \\
    /lib/systemd/system/sockets.target.wants/*udev* \\
    /lib/systemd/system/sockets.target.wants/*initctl* \\
    /lib/systemd/system/sysinit.target.wants/systemd-tmpfiles-setup* \\
    /lib/systemd/system/systemd-update-utmp* \\
    || true

# Create directories for bootstrap
RUN mkdir -p /opt/vps-coolify-bootstrap \\
    && mkdir -p /etc/vps-coolify-bootstrap \\
    && mkdir -p /var/log

# Volume for cgroup
VOLUME [ "/sys/fs/cgroup" ]

# Systemd as init
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
DOCKERFILE
)
    
    # Build image
    if echo "$dockerfile_content" | docker build -t "$image_name" -f - . >/dev/null 2>&1; then
        IMAGES_CREATED+=("$image_name")
        log_success "Image built: ${image_name}"
        return 0
    else
        log_error "Failed to build image: ${image_name}"
        return 1
    fi
}

# --- Start container with systemd ---
start_container() {
    local container_name="$1"
    local image_name="$2"
    
    log_subphase "Starting container: ${container_name}"
    
    # Stop existing container if any
    if docker ps -aq -f "name=^${container_name}$" 2>/dev/null | grep -q .; then
        log_info "Removing existing container: ${container_name}"
        docker stop "$container_name" >/dev/null 2>&1 || true
        docker rm -f "$container_name" >/dev/null 2>&1 || true
    fi
    
    # Start container with systemd
    if ! docker run -d \
        --privileged \
        --name "$container_name" \
        --cgroupns=host \
        --tmpfs /run \
        --tmpfs /run/lock \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        -v "${REPO_ROOT}:/opt/vps-coolify-bootstrap:ro" \
        "$image_name" >/dev/null 2>&1; then
        log_error "Failed to start container: ${container_name}"
        return 1
    fi
    
    CONTAINERS_CREATED+=("$container_name")
    
    # Wait for systemd to initialize
    log_info "Waiting for systemd to initialize..."
    local max_wait=30
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if docker exec "$container_name" systemctl is-system-running --wait >/dev/null 2>&1; then
            break
        fi
        # Also accept "degraded" as running (some units may fail in container)
        local state
        state=$(docker exec "$container_name" systemctl is-system-running 2>/dev/null || true)
        if [[ "$state" == "running" ]] || [[ "$state" == "degraded" ]]; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    
    if [[ $waited -ge $max_wait ]]; then
        log_warn "Systemd initialization timeout (may still work)"
    fi
    
    # Verify PID 1 is systemd
    local pid1
    pid1=$(docker exec "$container_name" cat /proc/1/comm 2>/dev/null || echo "unknown")
    if [[ "$pid1" != "systemd" ]]; then
        log_error "PID 1 is not systemd: ${pid1}"
        return 1
    fi
    
    log_success "Container started with systemd: ${container_name}"
    return 0
}

# --- Copy bootstrap env to container ---
setup_container_env() {
    local container_name="$1"
    local env_file="$2"
    
    log_subphase "Setting up bootstrap environment"
    
    # Copy env file to container
    docker cp "$env_file" "${container_name}:/etc/vps-coolify-bootstrap/bootstrap.env"
    
    # Set permissions
    docker exec "$container_name" chmod 600 /etc/vps-coolify-bootstrap/bootstrap.env
    
    log_success "Environment configured"
}

# --- Run script in container with timeout ---
run_in_container() {
    local container_name="$1"
    local script_name="$2"
    local description="$3"
    local log_file="$4"
    local timeout_seconds="${PHASE_TIMEOUT:-300}"
    
    log_subphase "Running: ${description}"
    
    local start_time
    start_time=$(date +%s)
    
    # Run script with timeout
    local exit_code=0
    local docker_cmd="
        cd /opt/vps-coolify-bootstrap
        bash scripts/${script_name} /etc/vps-coolify-bootstrap/bootstrap.env 2>&1
    "
    
    if [[ "$VERBOSE" == "1" ]]; then
        timeout "$timeout_seconds" docker exec "$container_name" bash -c "$docker_cmd" | tee -a "$log_file" || exit_code=$?
    else
        timeout "$timeout_seconds" docker exec "$container_name" bash -c "$docker_cmd" >> "$log_file" 2>&1 || exit_code=$?
    fi
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "${description} completed (${duration}s)"
        return 0
    elif [[ $exit_code -eq 124 ]]; then
        log_error "${description} TIMED OUT after ${timeout_seconds}s"
        log_error "See log file: ${log_file}"
        echo "--- Last 20 lines of log ---"
        tail -20 "$log_file"
        echo "---"
        return 1
    else
        log_error "${description} failed with exit code ${exit_code} (${duration}s)"
        log_error "See log file: ${log_file}"
        # Show last 20 lines of log
        echo "--- Last 20 lines of log ---"
        tail -20 "$log_file"
        echo "---"
        return 1
    fi
}

# --- Run verification and capture results ---
run_verification() {
    local container_name="$1"
    local phase_name="$2"
    local log_file="$3"
    
    log_subphase "Verification: ${phase_name}"
    
    local verify_output
    verify_output=$(docker exec "$container_name" bash -c "
        cd /opt/vps-coolify-bootstrap
        bash scripts/verify-bootstrap-state.sh /etc/vps-coolify-bootstrap/bootstrap.env 2>&1
    " 2>&1) || true
    
    echo "$verify_output" >> "$log_file"
    
    # Count PASS/FAIL/WARN
    local pass_count fail_count warn_count
    pass_count=$(echo "$verify_output" | grep -c "^\[.*\] PASS" || true)
    fail_count=$(echo "$verify_output" | grep -c "^\[.*\] FAIL" || true)
    warn_count=$(echo "$verify_output" | grep -c "^\[.*\] WARN" || true)
    
    # In test mode (SKIP_COOLIFY_INSTALL), filter out expected failures
    # These are failures that occur because:
    # - Coolify is not installed (SKIP_COOLIFY_INSTALL=true)
    # - Docker is not installed (Coolify installer skipped)
    # - SSH service not auto-started in container
    local unexpected_failures=0
    local expected_fail_patterns=(
        # Docker not installed (Coolify installer skipped)
        "docker command not found"
        "Docker.*IPv6"
        "Docker network inspect"
        
        # Coolify not installed
        "Coolify localhost SSH key"
        "authorized_keys against Coolify"
        "Coolify localhost public key"
        "Coolify localhost server"
        "Coolify container"
        "coolify container is not running"
        "Coolify root user"
        "cannot reach localhost server"
        "unable to read Coolify localhost server"
        
        # PUSHER config (Coolify env not created)
        "PUSHER_HOST"
        "PUSHER_PORT"
        "PUSHER_SCHEME"
        "closed realtime mode requires"
        
        # SSH service (not auto-started in container)
        "sshd does not listen"
        "port 22 still has a listener"
        
        # DOCKER-USER iptables (Docker not installed)
        "DOCKER-USER DROP guard"
        "iptables DOCKER-USER"
        "ip6tables DOCKER-USER"
        "6001/6002 listen"
    )
    
    # Count unexpected failures (failures not in expected list)
    while IFS= read -r failure_line; do
        local is_expected=0
        for pattern in "${expected_fail_patterns[@]}"; do
            if [[ "$failure_line" == *"$pattern"* ]]; then
                is_expected=1
                break
            fi
        done
        if [[ $is_expected -eq 0 ]] && [[ -n "$failure_line" ]]; then
            unexpected_failures=$((unexpected_failures + 1))
            log_error "Unexpected failure: $failure_line"
        fi
    done < <(echo "$verify_output" | grep "^\[.*\] FAIL" || true)
    
    log_info "Verification results: PASS=${pass_count} FAIL=${fail_count} (${unexpected_failures} unexpected) WARN=${warn_count}"
    
    if [[ "$VERBOSE" == "1" ]]; then
        echo "$verify_output"
    fi
    
    # Show all failures for visibility
    if [[ $fail_count -gt 0 ]]; then
        echo "--- Failures (expected in test mode: Coolify/Docker/SSH related) ---"
        echo "$verify_output" | grep "^\[.*\] FAIL" || true
        echo "---"
    fi
    
    # Only fail if there are unexpected failures
    if [[ $unexpected_failures -gt 0 ]]; then
        log_error "Verification has ${unexpected_failures} unexpected failure(s)"
        return 1
    fi
    
    log_success "Verification passed: ${phase_name} (${fail_count} expected failures ignored)"
    return 0
}

# --- Restart container (simulate reboot) ---
restart_container() {
    local container_name="$1"
    
    log_subphase "Restarting container (simulating reboot)"
    
    docker restart "$container_name" >/dev/null 2>&1
    
    # Wait for systemd to reinitialize
    log_info "Waiting for systemd to reinitialize after restart..."
    local max_wait=30
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local state
        state=$(docker exec "$container_name" systemctl is-system-running 2>/dev/null || true)
        if [[ "$state" == "running" ]] || [[ "$state" == "degraded" ]]; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    
    if [[ $waited -ge $max_wait ]]; then
        log_warn "Systemd reinitialize timeout after restart"
    fi
    
    log_success "Container restarted"
    return 0
}

# --- Run full test for one OS ---
run_os_test() {
    local os_tag="$1"
    local base_image="$2"
    local os_id="$3"
    local os_version="$4"
    
    log_phase "Testing: ${os_tag} (${os_id} ${os_version})"
    
    local container_name="${CONTAINER_PREFIX}-${os_tag}"
    local image_name="systemd-bootstrap-test:${os_tag}"
    local log_dir="/tmp/bootstrap-integration-test-${os_tag}"
    local test_env_file="${log_dir}/bootstrap.env"
    
    # Create log directory
    if ! mkdir -p "$log_dir"; then
        log_error "Failed to create log directory: ${log_dir}"
        return 1
    fi
    LOG_DIRS_CREATED+=("$log_dir")
    
    local overall_result=0
    local phase_results=()
    
    # Phase 1: Build image
    log_info "Phase 1/10: Build systemd image"
    if build_systemd_image "$os_tag" "$base_image"; then
        phase_results+=("build:PASS")
    else
        phase_results+=("build:FAIL")
        overall_result=1
    fi
    
    # Phase 2: Start container
    if [[ $overall_result -eq 0 ]]; then
        log_info "Phase 2/10: Start container"
        if start_container "$container_name" "$image_name"; then
            phase_results+=("start:PASS")
        else
            phase_results+=("start:FAIL")
            overall_result=1
        fi
    fi
    
    # Phase 3: Setup environment
    if [[ $overall_result -eq 0 ]]; then
        log_info "Phase 3/10: Setup environment"
        generate_test_env "$test_env_file"
        if setup_container_env "$container_name" "$test_env_file"; then
            phase_results+=("env:PASS")
        else
            phase_results+=("env:FAIL")
            overall_result=1
        fi
    fi
    
    # Phase 4: Run prepare-existing-server.sh
    if [[ $overall_result -eq 0 ]]; then
        log_info "Phase 4/10: Run prepare-existing-server.sh"
        if run_in_container "$container_name" "prepare-existing-server.sh" \
            "prepare-existing-server.sh" "${log_dir}/prepare.log"; then
            phase_results+=("prepare:PASS")
        else
            phase_results+=("prepare:FAIL")
            overall_result=1
        fi
    fi
    
    # Phase 5: Run bootstrap-host.sh (first run)
    if [[ $overall_result -eq 0 ]]; then
        log_info "Phase 5/10: Run bootstrap-host.sh (first run)"
        if run_in_container "$container_name" "bootstrap-host.sh" \
            "bootstrap-host.sh (first run)" "${log_dir}/bootstrap-first.log"; then
            phase_results+=("bootstrap-1:PASS")
        else
            phase_results+=("bootstrap-1:FAIL")
            overall_result=1
        fi
    fi
    
    # Phase 6: Verify post-bootstrap
    if [[ $overall_result -eq 0 ]]; then
        log_info "Phase 6/10: Verify post-bootstrap"
        if run_verification "$container_name" "post-bootstrap" "${log_dir}/verify-post-bootstrap.log"; then
            phase_results+=("verify-1:PASS")
        else
            phase_results+=("verify-1:FAIL")
            # Continue to test idempotency even if verify fails
            overall_result=1
        fi
    fi
    
    # Phase 7: Run bootstrap-host.sh (idempotency test)
    if [[ $overall_result -eq 0 ]] || [[ "${phase_results[*]}" == *"bootstrap-1:PASS"* ]]; then
        log_info "Phase 7/10: Run bootstrap-host.sh (idempotency)"
        if run_in_container "$container_name" "bootstrap-host.sh" \
            "bootstrap-host.sh (idempotency)" "${log_dir}/bootstrap-idempotent.log"; then
            phase_results+=("bootstrap-2:PASS")
        else
            phase_results+=("bootstrap-2:FAIL")
            overall_result=1
        fi
    fi
    
    # Phase 8: Verify post-idempotency (ensure second run didn't break anything)
    if [[ "${phase_results[*]}" == *"bootstrap-2:PASS"* ]]; then
        log_info "Phase 8/10: Verify post-idempotency"
        if run_verification "$container_name" "post-idempotency" "${log_dir}/verify-post-idempotency.log"; then
            phase_results+=("verify-2:PASS")
        else
            phase_results+=("verify-2:FAIL")
            overall_result=1
        fi
    fi
    
    # Phase 9: Restart container (reboot test)
    # Only run reboot test if idempotency succeeded
    if [[ "${phase_results[*]}" == *"bootstrap-2:PASS"* ]]; then
        log_info "Phase 9/10: Restart container (reboot test)"
        if restart_container "$container_name"; then
            phase_results+=("reboot:PASS")
        else
            phase_results+=("reboot:FAIL")
            overall_result=1
        fi
    fi
    
    # Phase 10: Verify post-reboot
    if [[ "${phase_results[*]}" == *"reboot:PASS"* ]]; then
        log_info "Phase 10/10: Verify post-reboot"
        if run_verification "$container_name" "post-reboot" "${log_dir}/verify-post-reboot.log"; then
            phase_results+=("verify-reboot:PASS")
        else
            phase_results+=("verify-reboot:FAIL")
            overall_result=1
        fi
    fi
    
    # Summary for this OS
    echo ""
    echo "=== Test Summary for ${os_tag} ==="
    for result in "${phase_results[@]}"; do
        local phase="${result%%:*}"
        local status="${result##*:}"
        if [[ "$status" == "PASS" ]]; then
            echo "  ✅ ${phase}"
        else
            echo "  ❌ ${phase}"
        fi
    done
    echo "  Log directory: ${log_dir}"
    echo ""
    
    # Store results
    TEST_RESULTS["$os_tag"]="$overall_result"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ $overall_result -eq 0 ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        log_success "OS test PASSED: ${os_tag}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        log_error "OS test FAILED: ${os_tag}"
    fi
    
    return "$overall_result"
}

# --- Main ---
main() {
    local start_time
    start_time=$(date +%s)
    
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
            --keep-images)
                KEEP_IMAGES=1
                shift
                ;;
            --os=*)
                SINGLE_OS="${1#*=}"
                shift
                ;;
            --verbose)
                VERBOSE=1
                shift
                ;;
            --list-os)
                echo "Available OS tags:"
                for entry in "${OS_MATRIX[@]}"; do
                    IFS='|' read -r os_tag base_image os_id os_version <<< "$entry"
                    echo "  ${os_tag} (${os_id} ${os_version})"
                done
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done
    
    log_phase "Bootstrap Full Integration Test"
    log_info "Repository: ${REPO_ROOT}"
    log_info "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    
    # Check prerequisites
    check_prerequisites
    
    # Determine which OS to test
    local os_to_test=()
    if [[ -n "$SINGLE_OS" ]]; then
        local found=0
        for entry in "${OS_MATRIX[@]}"; do
            IFS='|' read -r os_tag _ _ _ <<< "$entry"
            if [[ "$os_tag" == "$SINGLE_OS" ]]; then
                os_to_test+=("$entry")
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            log_error "Unknown OS tag: ${SINGLE_OS}"
            echo "Available: ubuntu-22.04, ubuntu-24.04, debian-12, debian-13"
            exit 2
        fi
    else
        os_to_test=("${OS_MATRIX[@]}")
    fi
    
    log_info "Testing ${#os_to_test[@]} OS configuration(s)"
    
    # Run tests
    local any_failed=0
    for entry in "${os_to_test[@]}"; do
        IFS='|' read -r os_tag base_image os_id os_version <<< "$entry"
        if ! run_os_test "$os_tag" "$base_image" "$os_id" "$os_version"; then
            any_failed=1
        fi
    done
    
    # Final summary
    local end_time
    end_time=$(date +%s)
    local total_duration=$((end_time - start_time))
    
    log_phase "Final Test Summary"
    echo ""
    echo "Results by OS:"
    for entry in "${os_to_test[@]}"; do
        IFS='|' read -r os_tag _ _ _ <<< "$entry"
        local result="${TEST_RESULTS[$os_tag]:-unknown}"
        if [[ "$result" == "0" ]]; then
            echo "  ✅ ${os_tag}: PASSED"
        else
            echo "  ❌ ${os_tag}: FAILED"
        fi
    done
    echo ""
    echo "Total: ${PASSED_TESTS}/${TOTAL_TESTS} passed"
    echo "Duration: ${total_duration} seconds"
    echo ""
    
    if [[ $any_failed -eq 0 ]]; then
        log_success "All integration tests PASSED!"
        exit 0
    else
        log_error "Some integration tests FAILED"
        exit 1
    fi
}

# --- Entry point ---
main "$@"
