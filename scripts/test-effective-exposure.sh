#!/usr/bin/env bash
# =============================================================================
# Script: test-effective-exposure.sh
# Purpose: P2 #25 - Verify effective network exposure matches expected policy
# Usage: ./test-effective-exposure.sh [bootstrap.env]
#
# Tests what ports are actually listening and compares against policy.
# Run this AFTER bootstrap completes to validate effective exposure.
# =============================================================================
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="${0##*/}"

# Source common functions
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh" 2>/dev/null || {
  # Minimal fallback if common.sh not available
  log_info() { echo "[INFO] $*"; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  log_pass() { echo "[PASS] $*"; }
  log_fail() { echo "[FAIL] $*" >&2; }
}

# Load env if provided
ENV_FILE="${1:-/etc/vps-coolify-bootstrap/bootstrap.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE" 2>/dev/null || true
fi

# Defaults
SSH_PORT="${SSH_PORT:-2222}"
SSH_ACCESS_MODE="${SSH_ACCESS_MODE:-public}"
CLOSE_COOLIFY_REALTIME_PORTS="${CLOSE_COOLIFY_REALTIME_PORTS:-true}"

echo "=========================================="
echo "Effective Network Exposure Test"
echo "=========================================="
echo "SSH_PORT: $SSH_PORT"
echo "SSH_ACCESS_MODE: $SSH_ACCESS_MODE"
echo "CLOSE_COOLIFY_REALTIME_PORTS: $CLOSE_COOLIFY_REALTIME_PORTS"
echo ""

failures=0
warnings=0

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*" >&2; ((failures++)); }
warn() { echo "[WARN] $*" >&2; ((warnings++)); }

# =============================================================================
# Test 1: Verify listening ports
# =============================================================================
echo "=== Listening Ports ==="

# Get all listening TCP ports
listening_tcp="$(ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -u)"

# SSH should be listening
if echo "$listening_tcp" | grep -qx "$SSH_PORT"; then
  pass "SSH listening on port $SSH_PORT"
else
  fail "SSH NOT listening on port $SSH_PORT"
fi

# HTTP/HTTPS should be listening (via Docker/Traefik)
if echo "$listening_tcp" | grep -qx "80"; then
  pass "HTTP (80) is listening"
else
  warn "HTTP (80) not directly listening (may be via Docker)"
fi

if echo "$listening_tcp" | grep -qx "443"; then
  pass "HTTPS (443) is listening"
else
  warn "HTTPS (443) not directly listening (may be via Docker)"
fi

# Check Coolify realtime ports policy
if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "true" ]]; then
  # Ports may listen internally but should be blocked by iptables
  echo "Realtime ports policy: closed (should be blocked by DOCKER-USER)"
else
  echo "Realtime ports policy: open"
fi

# =============================================================================
# Test 2: Verify UFW rules
# =============================================================================
echo ""
echo "=== UFW Rules ==="

if ! command -v ufw >/dev/null 2>&1; then
  fail "UFW not installed"
else
  ufw_status="$(ufw status verbose 2>/dev/null || true)"
  
  if grep -q "Status: active" <<< "$ufw_status"; then
    pass "UFW is active"
  else
    fail "UFW is NOT active"
  fi
  
  # SSH rule based on access mode
  case "$SSH_ACCESS_MODE" in
    public)
      if grep -Eq "^[[:space:]]*${SSH_PORT}/tcp[[:space:]]+LIMIT" <<< "$ufw_status"; then
        pass "SSH port $SSH_PORT has LIMIT rule (public mode)"
      else
        fail "SSH port $SSH_PORT missing LIMIT rule for public mode"
      fi
      ;;
    allowlist|vpn-only)
      # Should NOT have public LIMIT rule
      if grep -Eq "^[[:space:]]*${SSH_PORT}/tcp[[:space:]]+LIMIT" <<< "$ufw_status"; then
        warn "SSH port $SSH_PORT has public LIMIT rule (expected allowlist/vpn-only mode)"
      else
        pass "SSH port $SSH_PORT restricted (no public LIMIT rule)"
      fi
      ;;
  esac
  
  # HTTP/HTTPS should be allowed
  if grep -Eq "^[[:space:]]*80/tcp[[:space:]]+ALLOW" <<< "$ufw_status"; then
    pass "Port 80/tcp allowed"
  else
    fail "Port 80/tcp not allowed"
  fi
  
  if grep -Eq "^[[:space:]]*443/tcp[[:space:]]+ALLOW" <<< "$ufw_status"; then
    pass "Port 443/tcp allowed"
  else
    fail "Port 443/tcp not allowed"
  fi
fi

# =============================================================================
# Test 3: Verify DOCKER-USER chain (if Docker present)
# =============================================================================
echo ""
echo "=== Docker Firewall (DOCKER-USER) ==="

if command -v docker >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1; then
  docker_user_rules="$(iptables -L DOCKER-USER -n -v 2>/dev/null || true)"
  
  if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "true" ]]; then
    # Should have DROP rules for 6001/6002
    if grep -q "dpt:6001" <<< "$docker_user_rules" && grep -q "DROP" <<< "$docker_user_rules"; then
      pass "DOCKER-USER has DROP rule for port 6001"
    else
      warn "DOCKER-USER missing explicit DROP for port 6001"
    fi
    
    if grep -q "dpt:6002" <<< "$docker_user_rules" && grep -q "DROP" <<< "$docker_user_rules"; then
      pass "DOCKER-USER has DROP rule for port 6002"
    else
      warn "DOCKER-USER missing explicit DROP for port 6002"
    fi
  else
    pass "Realtime ports policy is open (no DOCKER-USER blocks expected)"
  fi
else
  warn "Docker or iptables not available; skipping DOCKER-USER checks"
fi

# =============================================================================
# Test 4: Verify sysctl security settings
# =============================================================================
echo ""
echo "=== Kernel Security (sysctl) ==="

check_sysctl() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(sysctl -n "$key" 2>/dev/null || echo "NOT_SET")"
  if [[ "$actual" == "$expected" ]]; then
    pass "sysctl $key = $expected"
  else
    warn "sysctl $key = $actual (expected $expected)"
  fi
}

check_sysctl "net.ipv4.conf.all.rp_filter" "1"
check_sysctl "net.ipv4.tcp_syncookies" "1"
check_sysctl "net.ipv4.conf.all.accept_redirects" "0"

# =============================================================================
# Test 5: External connectivity test (optional)
# =============================================================================
echo ""
echo "=== External Connectivity ==="

# Test if we can reach external services
if curl -s --connect-timeout 5 https://api.ipify.org >/dev/null 2>&1; then
  pass "External HTTPS connectivity OK"
else
  warn "Cannot reach external HTTPS (may be expected in isolated networks)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
echo "Failures: $failures"
echo "Warnings: $warnings"

if (( failures > 0 )); then
  echo ""
  echo "RESULT: FAILED - $failures critical issue(s) found"
  exit 1
elif (( warnings > 0 )); then
  echo ""
  echo "RESULT: PASSED with warnings"
  exit 0
else
  echo ""
  echo "RESULT: PASSED - effective exposure matches policy"
  exit 0
fi
