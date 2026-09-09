# Multi-OS Compatibility Report

**Document Version:** 1.2  
**Analysis Date:** September 9, 2026  
**Last Updated:** September 9, 2026  
**Analyst:** Kiro AI  
**Target Operating Systems:** Ubuntu 24.04 LTS, Ubuntu 26.04 LTS, Debian 13 (Trixie)

---

## Executive Summary

This report provides a comprehensive analysis of the `public-vps-coolify-bootstrap` project's compatibility with three target operating systems. The analysis reveals that while the bootstrap is well-designed for Ubuntu 24.04 LTS (Noble Numbat), it requires **moderate modifications** to fully support Ubuntu 26.04 LTS (Resolute Raccoon) and **significant modifications** for Debian 13 (Trixie) support.

### Key Findings

1. **SSH socket activation is already handled** - `bootstrap-host.sh` correctly disables `ssh.socket` on all three target OSes, preventing the reload failure documented in Debian Bug #1128329
2. **fail2ban defaults changed significantly** - Debian 13 defaults to native `nftables` action (not `iptables-multiport`)
3. **All three OSes use nftables** as the kernel firewall backend; iptables commands work via `iptables-nft` compatibility layer
4. **UFW not pre-installed on Debian** - must be added to cloud-init packages
5. **OS detection is broken for Debian** - `prepare-existing-server.sh` uses `UBUNTU_CODENAME` which doesn't exist on Debian

### Compatibility Matrix (Current State)

| Component | Ubuntu 24.04 LTS | Ubuntu 26.04 LTS | Debian 13 (Trixie) |
|-----------|:----------------:|:----------------:|:------------------:|
| OS Detection | ✅ Full | ⚠️ Partial | ❌ Broken |
| SSH Configuration | ✅ Full | ✅ Full | ✅ Full |
| Firewall (UFW) | ✅ Full | ✅ Full | ❌ Not Installed |
| fail2ban | ✅ Full | ✅ Full | ⚠️ Different Defaults |
| Docker iptables Rules | ✅ Full | ✅ Full | ✅ Full |
| Package Installation | ✅ Full | ✅ Full | ⚠️ UFW Missing |
| PostgreSQL Backup | ✅ Full | ✅ Full | ✅ Full |

**Legend:** ✅ Full Support | ⚠️ Partial (Works with Warnings) | ❌ Broken/Missing

**Note on SSH:** All three OSes have `ssh.socket` enabled by default on fresh installs. The existing `bootstrap-host.sh` already handles socket activation correctly by disabling `ssh.socket` and restarting `ssh.service` (lines 609-625). This works identically on Ubuntu 24.04, Ubuntu 26.04, and Debian 13.

---

## Detailed Analysis

### 1. Operating System Detection

**Files Affected:**
- `scripts/prepare-existing-server.sh` (lines 56-66)
- `scripts/common.sh`

**Current Behavior:**
```bash
# prepare-existing-server.sh lines 56-66
CODENAME=$(lsb_release -sc 2>/dev/null || grep UBUNTU_CODENAME /etc/os-release | cut -d= -f2)
if [[ "$CODENAME" != "noble" ]]; then
  bootstrap_warn "This bootstrap is designed for Ubuntu 24.04 LTS (noble)."
  bootstrap_warn "You are running: $CODENAME"
  bootstrap_warn "Some features may not work correctly."
  read -rp "Continue anyway? (y/N): " continue_choice
  if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
    bootstrap_error "Bootstrap cancelled."
  fi
fi
```

**Issues:**
1. **Ubuntu 26.04 LTS:** Codename is "resolute" - will trigger warning but continue
2. **Debian 13:** `UBUNTU_CODENAME` doesn't exist in `/etc/os-release`; uses `VERSION_CODENAME` instead. Codename is "trixie"
3. No actual OS family detection (Ubuntu vs Debian)

**Priority:** 🔴 CRITICAL

**Recommended Fix:**

See the **Complete Code Changes** section at the end of this document for the full implementation of `detect_os()` and `validate_os()` functions with proper fallback handling.

---

### 2. SSH Socket Activation

**Files Affected:**
- `scripts/bootstrap-host.sh`
- `scripts/prepare-existing-server.sh`
- `scripts/recover-ssh-access.sh`
- `scripts/verify-bootstrap-state.sh`
- `templates/vps-init.template.yml`

**Current Behavior:**
✅ **The bootstrap already handles ssh.socket correctly!**

From `bootstrap-host.sh` (lines 609-625):
```bash
# Ubuntu 24.04 defaults to ssh.socket (systemd socket activation).
# Socket activation + sshd_config Port directive can conflict, causing sshd
# to not listen on the custom port. Disable socket activation and use the
# classic ssh.service for reliable custom-port operation.
systemctl daemon-reload
systemctl disable --now ssh.socket 2>/dev/null || true
rm -f /etc/systemd/system/ssh.socket.d/override.conf
# ... cleanup ...
systemctl daemon-reload
systemctl restart ssh.service
bootstrap_success "ssh.socket disabled; ssh.service validated/restarted on configured port."
```

And `verify-bootstrap-state.sh` explicitly checks for this:
```bash
check_service_enabled_state ssh.socket disabled
check_service_state ssh.socket inactive
check_service_enabled_state ssh.service enabled
check_service_state ssh.service active
```

**OS Differences:**
| OS | Default SSH Activation | Service Name | Bootstrap Status |
|----|----------------------|--------------|------------------|
| Ubuntu 24.04 | Socket (`ssh.socket`) | `ssh.service` / `ssh.socket` | ✅ Handled |
| Ubuntu 26.04 | Socket (`ssh.socket`) | `ssh.service` / `ssh.socket` | ✅ Handled |
| Debian 13 | Socket (`ssh.socket`) | `ssh.service` / `ssh.socket` | ✅ Handled |

**Why This Matters (for context):**

On **fresh installations** of all three target OSes, `ssh.socket` is enabled by default. If not disabled, this causes:
```
systemctl reload ssh
# Error: fatal: Cannot bind any address.
```

**Root Cause:** When `ssh.socket` owns the listening port, sending SIGHUP to sshd causes it to try to bind the port again, which fails because systemd (via ssh.socket) already holds it.

**Reference:** [Debian Bug #1128329](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1128329), documented at [claudiokuenzler.com](https://www.claudiokuenzler.com/blog/1522/debian-13-trixie-ssh-service-reload-error-cannot-bind-address)

**Priority:** ✅ ALREADY HANDLED

**Verification for Debian 13:**
The existing code in `bootstrap-host.sh` will work correctly on Debian 13 because:
1. It uses `systemctl disable --now ssh.socket` which works on all systemd-based systems
2. The `2>/dev/null || true` pattern handles cases where socket might not exist
3. `verify-bootstrap-state.sh` validates the expected state

**No changes required** for SSH socket handling.

---

### 3. Firewall (UFW) Compatibility

**Files Affected:**
- `scripts/bootstrap-host.sh` (UFW configuration)
- `scripts/prepare-existing-server.sh` (UFW setup)
- `templates/vps-init.template.yml` (cloud-init UFW rules)

**Current Behavior:**
The bootstrap assumes UFW is pre-installed and available.

**OS Differences:**
| OS | UFW Pre-installed | iptables Command | Kernel Backend |
|----|-------------------|------------------|----------------|
| Ubuntu 24.04 | ✅ Yes | `iptables-nft` | nftables |
| Ubuntu 26.04 | ✅ Yes | `iptables-nft` | nftables |
| Debian 13 | ❌ **No** | `iptables-nft` | nftables |

**Technical Note:** On all three target OSes:
- The `iptables` command is actually `iptables-nft` (a wrapper)
- Rules are stored in the nftables kernel subsystem
- UFW generates iptables commands which translate to nftables rules
- This is **not a problem** - the compatibility layer works seamlessly

**Issues:**
1. **Debian 13:** UFW must be installed explicitly via packages list
2. **Debian 13:** Users familiar with pure nftables may prefer native rules

**Priority:** 🔴 CRITICAL (for Debian 13)

**Recommended Fix:**
```bash
# Add to common.sh
ensure_firewall_installed() {
    case "$BOOTSTRAP_OS_ID" in
        ubuntu)
            # UFW is pre-installed on Ubuntu
            if ! command -v ufw &>/dev/null; then
                bootstrap_error "UFW not found on Ubuntu - this is unexpected"
                apt-get update && apt-get install -y ufw
            fi
            ;;
        debian)
            if ! command -v ufw &>/dev/null; then
                bootstrap_info "Installing UFW on Debian..."
                apt-get update && apt-get install -y ufw
            fi
            ;;
    esac
}

# Alternative: Support both UFW and native nftables
get_firewall_backend() {
    if command -v ufw &>/dev/null; then
        echo "ufw"
    elif command -v nft &>/dev/null; then
        echo "nftables"
    else
        echo "unknown"
    fi
}
```

**For `vps-init.template.yml`:**
```yaml
packages:
  - ufw  # Now explicit - ensures UFW is installed on all distros
  - fail2ban
  # ... other packages
```

---

### 4. fail2ban Backend and Ban Action

**Files Affected:**
- `scripts/prepare-existing-server.sh`
- `templates/vps-init.template.yml`

**Current Behavior:**
```yaml
# vps-init.template.yml
- path: /etc/fail2ban/jail.local
  content: |
    [DEFAULT]
    bantime = 1h
    findtime = 10m
    maxretry = 5
    backend = systemd
    banaction = ufw
```

**OS Defaults (as packaged by distributions):**

| OS | fail2ban Version | Default Backend | Default banaction |
|----|-----------------|-----------------|-------------------|
| Ubuntu 24.04 | 1.0.2 | file (auto) | `iptables-multiport` |
| Ubuntu 26.04 | 1.1.0+ | systemd | `iptables-multiport` |
| Debian 13 | 1.1.0 | **systemd** | **`nftables`** |

**Source:** [linuxcapable.com - Install Fail2Ban on Debian](https://linuxcapable.com/how-to-install-fail2ban-on-debian-linux/)

**Key Insight:** The bootstrap's current `banaction = ufw` works correctly when UFW is active because:
- UFW action creates rules that UFW manages
- On Ubuntu, UFW is pre-installed and the bootstrap activates it
- On Debian 13, UFW must be installed first (via packages list), then activated

**Issues:**
1. **Debian 13 without UFW:** If UFW installation fails, `banaction = ufw` will fail
2. **Fallback needed:** Should detect UFW availability and fall back to nftables

**Priority:** 🟡 IMPORTANT (not critical if UFW is in packages list)

**Recommended Fix:**
```bash
# Add to common.sh
get_fail2ban_banaction() {
    # If UFW is installed and will be activated, use ufw action
    if command -v ufw &>/dev/null; then
        echo "ufw"
        return 0
    fi
    
    # Fallback: use native nftables on modern systems
    # Note: "nftables" (not "nftables-multiport") is the correct action name
    if command -v nft &>/dev/null; then
        echo "nftables"
        return 0
    fi
    
    # Last resort fallback
    echo "iptables-multiport"
}

# Generate fail2ban config dynamically
generate_fail2ban_config() {
    local ssh_port="${1:-22}"
    local banaction
    
    banaction=$(get_fail2ban_banaction)
    bootstrap_info "Configuring fail2ban with banaction: $banaction"
    
    cat > /etc/fail2ban/jail.local <<EOF
# Generated by vps-coolify-bootstrap
# OS: $BOOTSTRAP_OS_ID $BOOTSTRAP_OS_VERSION ($BOOTSTRAP_OS_CODENAME)

[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
banaction = ${banaction}
banaction_allports = ${banaction}[type=allports]

[sshd]
enabled = true
port = ${ssh_port}
filter = sshd
maxretry = 3
bantime = 2h
EOF

    bootstrap_info "fail2ban configuration written to /etc/fail2ban/jail.local"
}
```

**Simpler approach for cloud-init (recommended):**

Since the bootstrap installs UFW on all target OSes (via packages list), the current `banaction = ufw` is correct. The key is ensuring UFW is in the packages list:

```yaml
# vps-init.template.yml
packages:
  - ufw                    # REQUIRED: ensures fail2ban banaction=ufw works
  - fail2ban
  # ... other packages
```

---

### 5. Docker iptables/nftables Rules

**Files Affected:**
- `scripts/bootstrap-host.sh` (DOCKER-USER chain rules)

**Current Behavior:**
```bash
# bootstrap-host.sh uses iptables directly
iptables -I DOCKER-USER -i eth0 -j DROP
iptables -I DOCKER-USER -i eth0 -p tcp --dport 80 -j ACCEPT
# ... etc
ip6tables -I DOCKER-USER -i eth0 -j DROP
```

**OS Differences:**

| OS | iptables Command | Backend | Status |
|----|-----------------|---------|--------|
| Ubuntu 24.04 | `iptables` → `iptables-nft` | nftables | ✅ Works |
| Ubuntu 26.04 | `iptables` → `iptables-nft` | nftables | ✅ Works |
| Debian 13 | `iptables` → `iptables-nft` | nftables | ✅ Works |

**Status:** ✅ **Fully Compatible**

All three target OSes use `iptables-nft`, which is an iptables-compatible CLI that writes rules to the nftables kernel subsystem. The current iptables commands work unchanged across all OSes.

**How to verify:**
```bash
iptables --version
# Output: iptables v1.8.10 (nf_tables)
#                         ^^^^^^^^^^^ this indicates nftables backend
```

**Priority:** 🟢 LOW (works as-is)

**Recommendation:**
Add a check to verify iptables-nft is in use (informational only):
```bash
# Add to common.sh (optional, informational)
verify_iptables_backend() {
    local version_output
    version_output=$(iptables --version 2>/dev/null || echo "")
    
    if echo "$version_output" | grep -q "nf_tables"; then
        bootstrap_info "iptables backend: nftables (iptables-nft) ✓"
        return 0
    elif echo "$version_output" | grep -q "legacy"; then
        bootstrap_warn "iptables backend: legacy"
        bootstrap_warn "This may cause issues with Docker. Consider switching to iptables-nft."
        return 1
    else
        bootstrap_debug "iptables backend: could not determine"
        return 0
    fi
}
```

---

### 6. Package Names and Availability

**Files Affected:**
- `templates/vps-init.template.yml`
- `scripts/prepare-existing-server.sh`
- `scripts/bootstrap-host.sh`

**Current Packages (from vps-init.template.yml):**
```yaml
packages:
  - curl
  - wget
  - git
  - unattended-upgrades
  - fail2ban
  - jq
  - htop
  - ncdu
  - tree
```

**Compatibility Matrix:**

| Package | Ubuntu 24.04 | Ubuntu 26.04 | Debian 13 | Notes |
|---------|:------------:|:------------:|:---------:|-------|
| curl | ✅ | ✅ | ✅ | |
| wget | ✅ | ✅ | ✅ | |
| git | ✅ | ✅ | ✅ | |
| unattended-upgrades | ✅ | ✅ | ✅ | Same package name |
| fail2ban | ✅ | ✅ | ✅ | |
| jq | ✅ | ✅ | ✅ | |
| htop | ✅ | ✅ | ✅ | |
| ncdu | ✅ | ✅ | ✅ | |
| tree | ✅ | ✅ | ✅ | |
| ufw | Pre-installed | Pre-installed | ❌ Needs install | Add to list |

**Priority:** 🟡 IMPORTANT

**Recommended Fix:**
```yaml
# vps-init.template.yml - Add UFW explicitly
packages:
  - curl
  - wget
  - git
  - ufw                    # Explicit install for Debian compatibility
  - unattended-upgrades
  - fail2ban
  - jq
  - htop
  - ncdu
  - tree
  - rsync                  # Often needed for backups
```

---

### 7. unattended-upgrades Configuration

**Files Affected:**
- `templates/vps-init.template.yml`

**Current Behavior:**
The bootstrap relies on Ubuntu's default `unattended-upgrades` behavior.

**OS Differences:**

| OS | Default Origins Pattern |
|----|------------------------|
| Ubuntu 24.04 | `${distro_id}:${distro_codename}-security` |
| Ubuntu 26.04 | `${distro_id}:${distro_codename}-security` |
| Debian 13 | `origin=Debian,codename=${distro_codename}-security` |

**Priority:** 🟡 IMPORTANT

**Recommended Fix:**
Add explicit unattended-upgrades configuration:
```yaml
# vps-init.template.yml - Add OS-aware config
- path: /etc/apt/apt.conf.d/50unattended-upgrades
  content: |
    // Auto-generated by vps-coolify-bootstrap
    Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}";
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    };
    Unattended-Upgrade::AutoFixInterruptedDpkg "true";
    Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
    Unattended-Upgrade::Remove-Unused-Dependencies "true";
```

---

### 8. PostgreSQL Backup Script Compatibility

**Files Affected:**
- `scripts/pg-backup-infra.sh`
- `systemd/pg-backup-infra.service`
- `systemd/pg-backup-infra.timer`

**Current Status:** ✅ **Fully Compatible**

The PostgreSQL backup infrastructure uses:
- Docker exec for pg_dump (container-independent of host OS)
- Standard bash commands (portable)
- systemd timers (available on all target OSes)

No modifications required.

---

## Implementation Roadmap

### Phase 1: Critical Fixes (Required for Debian 13 Support)

| # | Change | Files | Effort | Impact |
|---|--------|-------|--------|--------|
| 1 | **Add UFW to packages list** | `vps-init.template.yml` | 5m | Enables fail2ban on Debian |
| 2 | **Implement universal OS detection** | `common.sh`, `prepare-existing-server.sh` | 1h | Proper support detection |

### Phase 2: Important Improvements (Recommended)

| # | Change | Files | Effort | Impact |
|---|--------|-------|--------|--------|
| 3 | Ensure UFW installed in scripts | `common.sh`, `prepare-existing-server.sh` | 20m | Script safety |
| 4 | fail2ban banaction fallback | `common.sh` | 20m | Graceful degradation |

### Phase 3: Quality Improvements (Nice-to-Have)

| # | Change | Files | Effort | Impact |
|---|--------|-------|--------|--------|
| 5 | iptables backend verification | `common.sh` | 15m | Informational logging |
| 6 | Explicit unattended-upgrades config | `vps-init.template.yml` | 30m | Predictable updates |
| 7 | Documentation updates | `README.md`, `docs/` | 1h | User guidance |
| 8 | Automated OS compatibility tests | `tests/` | 3h | Regression prevention |

---

## Complete Code Changes

### File: `scripts/common.sh` (Additions)

Add the following functions to `common.sh`:

```bash
# =============================================================================
# OS Detection and Validation
# =============================================================================

# Detect operating system and set global variables
# Sets: BOOTSTRAP_OS_ID, BOOTSTRAP_OS_VERSION, BOOTSTRAP_OS_CODENAME, BOOTSTRAP_OS_SUPPORTED
detect_os() {
    local os_id="unknown"
    local os_version="unknown"
    local os_codename="unknown"
    
    # Primary source: /etc/os-release (systemd standard)
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-unknown}"
        os_version="${VERSION_ID:-unknown}"
        os_codename="${VERSION_CODENAME:-unknown}"
    # Fallback: lsb_release
    elif command -v lsb_release &>/dev/null; then
        os_id=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        os_version=$(lsb_release -sr)
        os_codename=$(lsb_release -sc)
    fi
    
    export BOOTSTRAP_OS_ID="$os_id"
    export BOOTSTRAP_OS_VERSION="$os_version"
    export BOOTSTRAP_OS_CODENAME="$os_codename"
    
    # Determine support level
    case "${os_id}-${os_codename}" in
        ubuntu-noble)     export BOOTSTRAP_OS_SUPPORTED="full" ;;      # Ubuntu 24.04
        ubuntu-resolute)  export BOOTSTRAP_OS_SUPPORTED="full" ;;      # Ubuntu 26.04
        debian-trixie)    export BOOTSTRAP_OS_SUPPORTED="full" ;;      # Debian 13
        ubuntu-*)         export BOOTSTRAP_OS_SUPPORTED="untested" ;;
        debian-*)         export BOOTSTRAP_OS_SUPPORTED="untested" ;;
        *)                export BOOTSTRAP_OS_SUPPORTED="unsupported" ;;
    esac
    
    bootstrap_debug "OS Detection: $BOOTSTRAP_OS_ID $BOOTSTRAP_OS_VERSION ($BOOTSTRAP_OS_CODENAME) - $BOOTSTRAP_OS_SUPPORTED"
}

# Validate OS and prompt user if untested/unsupported
validate_os() {
    detect_os
    
    case "$BOOTSTRAP_OS_SUPPORTED" in
        full)
            bootstrap_info "Detected: $BOOTSTRAP_OS_ID $BOOTSTRAP_OS_VERSION ($BOOTSTRAP_OS_CODENAME) - Fully supported"
            ;;
        untested)
            bootstrap_warn "Detected: $BOOTSTRAP_OS_ID $BOOTSTRAP_OS_VERSION ($BOOTSTRAP_OS_CODENAME)"
            bootstrap_warn "This OS version is untested. Proceed with caution."
            read -rp "Continue anyway? (y/N): " continue_choice
            [[ ! "$continue_choice" =~ ^[Yy]$ ]] && bootstrap_error "Bootstrap cancelled by user."
            ;;
        unsupported)
            bootstrap_error "Unsupported OS: $BOOTSTRAP_OS_ID $BOOTSTRAP_OS_VERSION ($BOOTSTRAP_OS_CODENAME)"
            bootstrap_error "Supported operating systems:"
            bootstrap_error "  - Ubuntu 24.04 LTS (Noble Numbat)"
            bootstrap_error "  - Ubuntu 26.04 LTS (Resolute Raccoon)"
            bootstrap_error "  - Debian 13 (Trixie)"
            exit 1
            ;;
    esac
}

# Helper functions
is_ubuntu() { [[ "$BOOTSTRAP_OS_ID" == "ubuntu" ]]; }
is_debian() { [[ "$BOOTSTRAP_OS_ID" == "debian" ]]; }

# =============================================================================
# Firewall Detection and Configuration
# =============================================================================

# Ensure UFW is installed (required for Debian)
ensure_ufw_installed() {
    if command -v ufw &>/dev/null; then
        bootstrap_debug "UFW is already installed"
        return 0
    fi
    
    bootstrap_info "Installing UFW..."
    apt-get update -qq
    apt-get install -y ufw
    
    if ! command -v ufw &>/dev/null; then
        bootstrap_error "Failed to install UFW"
        return 1
    fi
    
    bootstrap_info "UFW installed successfully"
}

# Get the appropriate fail2ban banaction
get_fail2ban_banaction() {
    # If UFW is installed, use ufw action (bootstrap installs UFW on all OSes)
    if command -v ufw &>/dev/null; then
        echo "ufw"
        return 0
    fi
    
    # Fallback: use native nftables (Debian 13 default)
    if command -v nft &>/dev/null; then
        echo "nftables"
        return 0
    fi
    
    # Last resort
    echo "iptables-multiport"
}

# Generate fail2ban jail.local with correct settings
generate_fail2ban_config() {
    local ssh_port="${1:-22}"
    local banaction
    
    banaction=$(get_fail2ban_banaction)
    bootstrap_info "Configuring fail2ban with banaction: $banaction"
    
    cat > /etc/fail2ban/jail.local <<EOF
# Generated by vps-coolify-bootstrap
# OS: ${BOOTSTRAP_OS_ID:-unknown} ${BOOTSTRAP_OS_VERSION:-unknown} (${BOOTSTRAP_OS_CODENAME:-unknown})

[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
banaction = ${banaction}
banaction_allports = ${banaction}[type=allports]

[sshd]
enabled = true
port = ${ssh_port}
filter = sshd
maxretry = 3
bantime = 2h
EOF

    bootstrap_info "fail2ban configuration written to /etc/fail2ban/jail.local"
}

# =============================================================================
# iptables Backend Verification (informational)
# =============================================================================

verify_iptables_backend() {
    local version_output
    version_output=$(iptables --version 2>/dev/null || echo "")
    
    if echo "$version_output" | grep -q "nf_tables"; then
        bootstrap_info "iptables backend: nftables (iptables-nft) ✓"
        return 0
    elif echo "$version_output" | grep -q "legacy"; then
        bootstrap_warn "iptables backend: legacy"
        bootstrap_warn "This may cause issues with Docker. Consider switching to iptables-nft."
        return 1
    else
        bootstrap_debug "iptables backend: could not determine"
        return 0
    fi
}
```

### File: `scripts/prepare-existing-server.sh` (Modifications)

Replace lines 56-66 with:

```bash
# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Validate OS at the start of the script
validate_os

# Ensure UFW is installed (critical for Debian)
ensure_ufw_installed

# Verify iptables backend
verify_iptables_backend
```

### File: `templates/vps-init.template.yml` (Modifications)

**1. Add UFW to packages (CRITICAL for Debian 13):**
```yaml
packages:
  - curl
  - wget
  - git
  - ufw                    # CRITICAL: Required for Debian 13 (not pre-installed)
  - unattended-upgrades
  - fail2ban
  - jq
  - htop
  - ncdu
  - tree
  - rsync                  # Useful for backups
```

**2. Update fail2ban configuration (optional improvement):**

The current `banaction = ufw` is correct since UFW is now in the packages list. However, for robustness, you can add OS detection:

```yaml
runcmd:
  # ... other commands ...
  
  # Configure fail2ban with appropriate banaction
  - |
    # Determine banaction based on available tools
    if command -v ufw >/dev/null 2>&1; then
      BANACTION="ufw"
    elif command -v nft >/dev/null 2>&1; then
      BANACTION="nftables"
    else
      BANACTION="iptables-multiport"
    fi
    
    cat > /etc/fail2ban/jail.local <<FAIL2BAN
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
banaction = ${BANACTION}
banaction_allports = ${BANACTION}[type=allports]

[sshd]
enabled = true
port = %%SSH_PORT%%
maxretry = 3
bantime = 2h
FAIL2BAN
  
  - systemctl enable fail2ban
  - systemctl restart fail2ban
```

---

## Testing Recommendations

### Critical Test Cases (Must Pass)

| Test Case | Ubuntu 24.04 | Ubuntu 26.04 | Debian 13 | Notes |
|-----------|:------------:|:------------:|:---------:|-------|
| UFW installed and active | ⬜ | ⬜ | ⬜ | Critical for Debian 13 (not pre-installed) |
| ssh.socket disabled | ⬜ | ⬜ | ⬜ | All OSes - handled by bootstrap-host.sh |
| `systemctl reload ssh` works | ⬜ | ⬜ | ⬜ | Fails if socket active |
| fail2ban banning works | ⬜ | ⬜ | ⬜ | Test with `fail2ban-client set sshd banip 1.2.3.4` |
| Docker DOCKER-USER chain | ⬜ | ⬜ | ⬜ | |

### Full Test Matrix

| Test Case | Ubuntu 24.04 | Ubuntu 26.04 | Debian 13 |
|-----------|:------------:|:------------:|:---------:|
| Fresh cloud-init bootstrap | ⬜ | ⬜ | ⬜ |
| prepare-existing-server.sh | ⬜ | ⬜ | ⬜ |
| OS detection correct | ⬜ | ⬜ | ⬜ |
| SSH hardening applied | ⬜ | ⬜ | ⬜ |
| UFW rules applied | ⬜ | ⬜ | ⬜ |
| fail2ban running | ⬜ | ⬜ | ⬜ |
| Coolify installation | ⬜ | ⬜ | ⬜ |
| PostgreSQL backup works | ⬜ | ⬜ | ⬜ |

### Automated Test Script

Create `tests/test-os-compatibility.sh`:

```bash
#!/bin/bash
set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/common.sh" 2>/dev/null || {
    echo "Warning: Could not source common.sh, using inline functions"
}

PASS=0
FAIL=0

test_result() {
    local name="$1"
    local result="$2"
    if [[ "$result" == "pass" ]]; then
        echo "✅ PASS: $name"
        ((PASS++))
    else
        echo "❌ FAIL: $name"
        ((FAIL++))
    fi
}

echo "=== OS Compatibility Tests ==="
echo ""

# Test 1: OS Detection
echo "--- OS Detection ---"
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "ID: $ID"
    echo "VERSION_ID: ${VERSION_ID:-unknown}"
    echo "VERSION_CODENAME: ${VERSION_CODENAME:-unknown}"
    test_result "OS release file exists" "pass"
else
    test_result "OS release file exists" "fail"
fi

# Test 2: SSH Socket Status
echo ""
echo "--- SSH Socket Status ---"
if systemctl is-active ssh.socket &>/dev/null; then
    echo "ssh.socket is ACTIVE (this may cause reload issues)"
    test_result "ssh.socket is disabled" "fail"
else
    echo "ssh.socket is not active"
    test_result "ssh.socket is disabled" "pass"
fi

# Test 3: SSH Reload Test
echo ""
echo "--- SSH Reload Test ---"
if systemctl reload ssh 2>/dev/null; then
    test_result "SSH reload works" "pass"
else
    test_result "SSH reload works" "fail"
fi

# Test 4: UFW Status
echo ""
echo "--- UFW Status ---"
if command -v ufw &>/dev/null; then
    ufw status
    test_result "UFW installed" "pass"
else
    echo "UFW not installed"
    test_result "UFW installed" "fail"
fi

# Test 5: fail2ban Status
echo ""
echo "--- fail2ban Status ---"
if systemctl is-active fail2ban &>/dev/null; then
    fail2ban-client status
    test_result "fail2ban running" "pass"
else
    test_result "fail2ban running" "fail"
fi

# Test 6: iptables Backend
echo ""
echo "--- iptables Backend ---"
iptables --version
if iptables --version 2>/dev/null | grep -q "nf_tables"; then
    test_result "iptables uses nftables backend" "pass"
else
    test_result "iptables uses nftables backend" "fail"
fi

# Summary
echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

exit $FAIL
```

---

## Appendix A: OS Release Information

### Ubuntu 24.04 LTS (Noble Numbat)
```
ID=ubuntu
VERSION_ID="24.04"
VERSION_CODENAME=noble
```

### Ubuntu 26.04 LTS (Resolute Raccoon)
```
ID=ubuntu
VERSION_ID="26.04"
VERSION_CODENAME=resolute
```

### Debian 13 (Trixie)
```
ID=debian
VERSION_ID="13"
VERSION_CODENAME=trixie
```

---

## Appendix B: References

### Official Documentation
- [Debian 13 (Trixie) Release Notes](https://www.debian.org/releases/trixie/releasenotes)
- [Ubuntu Security - Firewall Documentation](https://documentation.ubuntu.com/security/security-features/network/firewall/)
- [Ubuntu Security - nftables Documentation](https://documentation.ubuntu.com/security/security-features/network/firewall/nftables/)
- [Docker - Packet Filtering and Firewalls](https://docs.docker.com/network/packet-filtering-firewalls/)

### fail2ban
- [fail2ban GitHub Repository](https://github.com/fail2ban/fail2ban)
- [fail2ban with nftables Discussion](https://github.com/fail2ban/fail2ban/discussions/3575)
- [LinuxCapable - Install Fail2Ban on Debian](https://linuxcapable.com/how-to-install-fail2ban-on-debian-linux/)

### SSH Socket Issues
- [Debian Bug #1128329 - SSH reload fails on Debian 13](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1128329)
- [SSH service reload not working in Debian 13](https://www.claudiokuenzler.com/blog/1522/debian-13-trixie-ssh-service-reload-error-cannot-bind-address)

### iptables/nftables
- [SSD Nodes - iptables vs nftables on Ubuntu](https://www.ssdnodes.com/learn/iptables-vs-nftables-on-ubuntu)
- [Better Stack - UFW vs nftables](https://betterstack.com/community/guides/linux/ufw-vs-nftables/)

### Community Guides
- [LinuxCapable - Install SSH on Debian](https://linuxcapable.com/how-to-install-ssh-and-enable-on-debian/)
- [LinuxCapable - Install nftables on Ubuntu](https://linuxcapable.com/how-to-install-nftables-on-ubuntu-linux/)

---

**Document End**
