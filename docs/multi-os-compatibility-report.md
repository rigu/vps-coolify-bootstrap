# Multi-OS Compatibility & Security Audit Report

**Document Version:** 2.1  
**Analysis Date:** September 9, 2026  
**Last Updated:** September 9, 2026  
**Analyst:** Kiro AI + External Security Review  
**Target Operating Systems:** Ubuntu 24.04 LTS, Ubuntu 26.04 LTS, Debian 13 (Trixie)

---

## Executive Summary

This report provides a comprehensive analysis of the `public-vps-coolify-bootstrap` project's compatibility and security posture. **Version 2.0** integrates findings from an external security audit that identified critical risks beyond OS compatibility.

### Overall Assessment

| Category | Score | Notes |
|----------|:-----:|-------|
| Security Baseline | 8/10 | Strong foundation, critical gaps remain |
| Operational Robustness | 8.5/10 | Excellent verification tooling |
| Debian 13 Compatibility | 7/10 | OS detection broken, rest works |
| Supply-Chain Hardening | 5.5/10 | **Critical gap** - mutable refs |

### Key Findings (Priority Order)

| Priority | Finding | Impact |
|:--------:|---------|--------|
| **P0** | Bootstrap executed from mutable Git ref | Supply-chain compromise risk |
| **P0/P1** | SSH accessible publicly, rate-limited only | Management plane exposure |
| **P1** | `DEVOPS_USER` has `NOPASSWD:ALL` | Compromised SSH key = instant root |
| **P1** | All managed users in `docker` group | Docker = root-equivalent |
| **P1** | UFW reset on replay | Custom rules lost |
| **P1** | Coolify ports `6001/6002/8000` not hardened by default | Direct Internet exposure |
| **P1** | Debian 13 OS detection broken | `UBUNTU_CODENAME` doesn't exist |
| **P2** | Vault + encryption key on same host | Limited protection if host compromised |
| **P2** | Coolify localhost key allows all RFC1918 | Should restrict to actual Docker subnet |
| **P2** | `sysctl rp_filter=1` may cause issues | Docker/WireGuard routing conflicts |
| **P2** | `80/443` always allowed on management VPS | Consider VPN-only for admin services |
| **P3** | Docker IPv6 workaround has no expiry | May persist indefinitely |
| **P3** | Ubuntu-specific comments in code | Should be generalized |

### What's Already Good

The repository has several excellent security practices:

1. ✅ **Strict env parser** - `load_env_file_strict()` manually parses env files and rejects:
   - `$(...)`
   - `${...}`
   - Backticks
   
   Instead of dangerous `source bootstrap.env`. This eliminates a class of command injection vulnerabilities. **One of the best security choices in the repo.**

2. ✅ **SSH socket handling** - Correctly disables `ssh.socket` on all OSes (lines 609-625)

3. ✅ **Comprehensive verifier** - `verify-bootstrap-state.sh` checks 20+ security properties including:
   - SSH socket/service state
   - Port bindings
   - UFW status
   - Users/groups
   - Sudo configuration
   - Docker version
   - Coolify container
   - SSH key restrictions

4. ✅ **Coolify SSH key restrictions** - The localhost key is placed in `authorized_keys` with:
   ```
   from="<private ranges>",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc
   ```
   And operator key is removed from Coolify user. **Good design.**

5. ✅ **Docker/UFW bypass documented** - DOCKER-USER chain properly managed with explicit documentation about the bypass

6. ✅ **UFW already in packages list** - Works on Debian 13 *(corrected from v1.x)*

---

## Critical Security Findings

### 1. Supply-Chain Risk: Mutable Git Ref (P0)

**Current Behavior:**

Cloud-init executes:
```bash
git clone --depth 1 --branch "$repo_ref" "$repo_url" "$repo_dir"
bash "$repo_dir/scripts/bootstrap-host.sh" ...
```

If `BOOTSTRAP_REPO_REF=main`, bootstrap executes **whatever `main` means at that moment**.

**Attack Scenario:**
```
GitHub account compromised
        ↓
Malicious commit pushed to main
        ↓
New VPS boots
        ↓
cloud-init clones main
        ↓
Malicious script executes as root
```

**Same Problem with Updates:**
```bash
# docs/operations-security.md recommends:
sudo git pull --ff-only origin main
sudo bash scripts/bootstrap-host.sh ...
```

**Recommended Fix:**

```bash
# Production bootstrap MUST use immutable ref
BOOTSTRAP_REPO_REF=v1.3.0  # signed tag
BOOTSTRAP_EXPECTED_SHA=7b4f33e712...  # exact commit

# Verify after clone
actual_sha=$(git rev-parse HEAD)
if [[ "$actual_sha" != "$BOOTSTRAP_EXPECTED_SHA" ]]; then
    echo "FATAL: Bootstrap ref mismatch!" >&2
    exit 1
fi
```

**Priority:** 🔴 **P0 - CRITICAL**

---

### 2. SSH Public Access (P0/P1)

**Current Behavior:**
```
Internet → SSH_PORT (rate-limited) → Server
```

**For a management VPS** that controls other production servers:
```
Internet → SSH → Management VPS → All production VPSes
```

**Recommended Fix:**

Add VPN-only mode:
```bash
# bootstrap.env
SSH_PUBLIC_ACCESS=false  # default for management servers
MANAGEMENT_CIDRS="10.100.0.0/24"  # WireGuard subnet

# When SSH_PUBLIC_ACCESS=false:
# - No UFW limit on public interface
# - SSH allowed only from MANAGEMENT_CIDRS
```

**Priority:** 🔴 **P0/P1 - CRITICAL for management VPS**

---

### 3. Secrets Storage Model (P2 - Context Dependent)

**Current Behavior:**

`/etc/vps-coolify-bootstrap/bootstrap.env` is stored with:
- `chmod 0600`
- `owner root:root`

This is **standard and acceptable** for most configuration secrets. A non-root user cannot read them.

**Nuance - Vault + Key on Same Host:**

If you have simultaneously:
```
/etc/vps-coolify-bootstrap/bootstrap.env
  USER_PASSWORDS_ENCRYPTION_PASSWORD=ABC

/etc/vps-coolify-bootstrap/user-passwords.enc
  <vault encrypted with ABC>
```

Then an attacker with **root access** can decrypt the vault.

**Perspective:** If an attacker already has root, you have much bigger problems (Docker secrets, SSH keys, Coolify config). This is **not a critical vulnerability**.

**Risk Classification:**

| Situation | Risk Level |
|-----------|:----------:|
| Secret in Git repository | 🔴 Serious |
| Secret in cloud-init user-data retained by provider | 🟠 Analyze |
| Secret in `/etc/...` with `root:root 0600` | 🟢 Normal |
| Vault + encryption key on same host | 🟡 Limited protection |
| Temporary bootstrap secret no longer needed | Ideal to remove |

**Recommendation (Nice-to-Have):**

For values that are strictly temporary and not needed after bootstrap completes:
```bash
# Optional cleanup after bootstrap
sed -i '/COOLIFY_ROOT_USER_PASSWORD/d' /etc/vps-coolify-bootstrap/bootstrap.env
```

**This is not a production blocker.**

**Priority:** 🟢 **P2 - MINOR (Not a production requirement)**

---

### 4. NOPASSWD:ALL for DEVOPS_USER (P1)

**Current Behavior:**
```
DEVOPS_USER → NOPASSWD:ALL
COOLIFY_SUDO_NOPASSWD_USER → NOPASSWD:ALL
```

**Impact:** If `DEVOPS_USER`'s SSH key is compromised:
```
attacker SSH as devops
        ↓
sudo -n anything
        ↓
root immediately
```

The local password doesn't matter.

**Recommended Fix:**

```bash
# bootstrap.env
DEVOPS_USER_NOPASSWD=false  # default

# Only COOLIFY_USER gets NOPASSWD (required by platform)
# DEVOPS_USER requires password for sudo
```

**Priority:** 🟠 **P1 - IMPORTANT**

---

### 5. Docker Group Membership (P1)

**Current Behavior:**

`verify-bootstrap-state.sh` requires every managed user to be in:
- `sudo`
- `docker`
- `coolify`

**Impact:** Docker group membership is **root-equivalent**:
```bash
docker run --rm -v /:/host alpine cat /host/etc/shadow
```

**Question:** Why do `DEVOPS_USER` and every `ADDITIONAL_SUDO_USER` need Docker access?

**Recommended Fix:**

```bash
# Separate Docker access
DOCKER_USERS=""  # explicit list, not automatic

# Default: only Coolify user gets docker
# DEVOPS_USER uses sudo for docker commands if needed
```

**Priority:** 🟠 **P1 - IMPORTANT**

---

### 6. UFW Reset on Replay (P1)

**Current Behavior:**
```bash
# bootstrap-host.sh
ufw --force reset
```

**Impact:** Any custom rules added after bootstrap are lost:
- WireGuard rules
- Monitoring allowlists
- Backup network access
- Provider private networks

**Recommended Fix:**

Option A: **Idempotent rule management**
```bash
# Don't reset, manage specific rules
ufw_ensure_rule() {
    local rule="$1"
    if ! ufw status | grep -qF "$rule"; then
        ufw $rule
    fi
}
```

Option B: **Declarative firewall from config**
```bash
# Generate complete ruleset from bootstrap.env
# No reset, complete replacement
```

**Priority:** 🟠 **P1 - OPERATIONAL SECURITY**

---

### 7. Coolify Ports Default (P1)

**Current Behavior:**
- `CLOSE_COOLIFY_REALTIME_PORTS=false` (default)
- Ports `6001`, `6002` are publicly accessible
- Port `8000` remains open for onboarding

**Note:** Docker published ports bypass UFW (documented, but still a risk).

**Recommended Fix:**

```bash
# Change defaults
CLOSE_COOLIFY_REALTIME_PORTS=true  # hardened default

# Port 8000 during onboarding:
# - Restrict to operator IP/VPN
# - Close immediately after domain configuration
```

**Priority:** 🟠 **P1 - IMPORTANT**

---

## Additional Findings (P2/P3)

### 8. Coolify Localhost Key Subnet (P2)

**Current Behavior:**

The Coolify SSH key `from=` restriction includes all RFC1918 ranges:
```
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
fc00::/7
```

**Issue:** This allows any private-range IP that can reach the host, not just the actual Coolify Docker subnet.

**Recommended Fix:**
```bash
# Restrict to actual Docker bridge/Coolify subnet
from="172.17.0.0/16"  # Docker default bridge
# or specific Coolify network range
```

**Priority:** 🟡 **P2 - MINOR**

---

### 9. sysctl rp_filter=1 Strict Mode (P2)

**Current Behavior:**
```bash
# vps-init.template.yml
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
```

**Issue:** Strict reverse path filtering (`rp_filter=1`) may cause issues with:
- Docker bridge networking
- WireGuard VPN
- Asymmetric routing
- Multi-homing

**Recommended:**
- For hosts with WireGuard: verify if `rp_filter=2` (loose) is needed for WG interface
- Don't change globally without testing

**Priority:** 🟡 **P2 - VERIFY BEFORE VPN SETUP**

---

### 10. 80/443 Always Allowed (P2)

**Current Behavior:**

UFW allows ports 80 and 443 unconditionally:
```bash
ufw allow 80/tcp
ufw allow 443/tcp
```

**Issue:** For a "management security-first" server, consider:
- Which services actually need public access?
- Should Coolify UI / Forgejo admin be VPN-only?

**Architectural Decision Needed:**
```
Public services → 80/443 via Traefik
Admin services → VPN-only
```

**Note:** This is not a bug, but an architectural choice that may need revisiting for management VPS.

**Priority:** 🟡 **P2 - ARCHITECTURAL DECISION**

---

### 11. Docker IPv6 Workaround Lifecycle (P3)

**Current Behavior:**

Bootstrap contains conditional logic to set `"ipv6": false` for affected Docker versions due to a `ParseAddr` bug.

**Issue:** No expiry condition documented. Workaround may persist indefinitely.

**Recommended:**
```bash
# Document clearly:
# - Affected Docker versions: X.Y.Z - A.B.C
# - Fixed in: version D.E.F
# - Remove workaround after: date/version
```

**Priority:** 🟢 **P3 - TECHNICAL DEBT**

---

## OS Compatibility Analysis

### Compatibility Matrix (Current State)

| Component | Ubuntu 24.04 LTS | Ubuntu 26.04 LTS | Debian 13 (Trixie) |
|-----------|:----------------:|:----------------:|:------------------:|
| OS Detection | ✅ Full | ⚠️ Warning Only | ❌ Broken |
| SSH Configuration | ✅ Full | ✅ Full | ✅ Full |
| Firewall (UFW) | ✅ Full | ✅ Full | ✅ Full |
| fail2ban | ✅ Full | ✅ Full | ✅ Full |
| Docker iptables | ✅ Full | ✅ Full | ✅ Full |
| Packages | ✅ Full | ✅ Full | ✅ Full |

**Legend:** ✅ Full Support | ⚠️ Works with Warnings | ❌ Broken

### OS Detection Issue (P1)

**Current Code:**
```bash
# prepare-existing-server.sh
CODENAME="$(
    . /etc/os-release &&
    echo "${UBUNTU_CODENAME:-}"
)"
```

**On Debian 13:**
```
ID=debian
VERSION_CODENAME=trixie
# UBUNTU_CODENAME does not exist!
```

**Result:** `CODENAME=""`, script shows incorrect Ubuntu warning.

**Recommended Fix:**

```bash
# Simple, correct approach
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        BOOTSTRAP_OS_ID="${ID:-unknown}"
        BOOTSTRAP_OS_VERSION="${VERSION_ID:-unknown}"
        BOOTSTRAP_OS_CODENAME="${VERSION_CODENAME:-unknown}"
    fi
    
    export BOOTSTRAP_OS_ID BOOTSTRAP_OS_VERSION BOOTSTRAP_OS_CODENAME
}

validate_os() {
    detect_os
    
    case "${BOOTSTRAP_OS_ID}-${BOOTSTRAP_OS_CODENAME}" in
        ubuntu-noble|ubuntu-resolute|debian-trixie)
            bootstrap_info "Detected: $BOOTSTRAP_OS_ID $BOOTSTRAP_OS_VERSION ($BOOTSTRAP_OS_CODENAME)"
            ;;
        *)
            bootstrap_warn "Untested OS: $BOOTSTRAP_OS_ID $BOOTSTRAP_OS_CODENAME"
            read -rp "Continue anyway? (y/N): " choice
            [[ ! "$choice" =~ ^[Yy]$ ]] && exit 1
            ;;
    esac
}
```

**Note:** Don't over-engineer this. Three supported OSes don't need a generic framework.

---

### SSH Socket Activation ✅ ALREADY HANDLED

The bootstrap correctly handles `ssh.socket` on all three OSes:

```bash
# bootstrap-host.sh (lines 609-625)
systemctl disable --now ssh.socket 2>/dev/null || true
rm -f /etc/systemd/system/ssh.socket.d/override.conf
systemctl daemon-reload
systemctl restart ssh.service
```

**Verification:**
```bash
# verify-bootstrap-state.sh
check_service_enabled_state ssh.socket disabled
check_service_state ssh.socket inactive
check_service_enabled_state ssh.service enabled
check_service_state ssh.service active
```

**No changes required.**

---

### fail2ban Configuration ✅ KEEP SIMPLE

**Current config uses `banaction = ufw`.**

The previous report recommended complex fallback logic. **Don't implement that.**

Since UFW is installed on all target OSes:
- Ubuntu 24.04/26.04: pre-installed
- Debian 13: installed via packages list

**Keep the simple approach:**
```yaml
banaction = ufw
```

Multiple fallbacks increase test matrix without benefit.

---

## Implementation Roadmap

### Phase 1: Critical Security (Before Production)

| # | Change | Effort | Impact |
|---|--------|--------|--------|
| 1 | Pin bootstrap to immutable Git SHA/tag | 30m | Supply-chain security |
| 2 | Implement VPN-only SSH mode | 2h | Management plane security |

### Phase 2: Important Hardening

| # | Change | Effort | Impact |
|---|--------|--------|--------|
| 3 | Configurable `NOPASSWD` for `DEVOPS_USER` | 30m | Least privilege |
| 4 | Separate `DOCKER_USERS` from managed users | 1h | Least privilege |
| 5 | Hardened Coolify ports default | 30m | Reduce exposure |
| 6 | Idempotent UFW rule management | 2h | Operational safety |
| 7 | Debian 13 OS detection fix | 30m | Correct operation |

### Phase 3: Quality Improvements

| # | Change | Effort | Impact |
|---|--------|--------|--------|
| 8 | Restrict Coolify SSH key to actual Docker subnet | 30m | Least privilege |
| 9 | Verify `rp_filter` compatibility with WireGuard | 30m | VPN functionality |
| 10 | Document 80/443 architectural decision | 30m | Clarity |
| 11 | Docker IPv6 workaround expiry documentation | 15m | Technical debt |
| 12 | Generalize Ubuntu-specific comments | 30m | Documentation |
| 13 | Optional secrets cleanup post-bootstrap | 15m | Hygiene (nice-to-have) |

---

## Complete Code Changes

### File: `scripts/common.sh` (Additions)

```bash
# =============================================================================
# OS Detection
# =============================================================================

detect_os() {
    local os_id="unknown"
    local os_version="unknown"
    local os_codename="unknown"
    
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-unknown}"
        os_version="${VERSION_ID:-unknown}"
        os_codename="${VERSION_CODENAME:-unknown}"
    elif command -v lsb_release &>/dev/null; then
        os_id=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        os_version=$(lsb_release -sr)
        os_codename=$(lsb_release -sc)
    fi
    
    export BOOTSTRAP_OS_ID="$os_id"
    export BOOTSTRAP_OS_VERSION="$os_version"
    export BOOTSTRAP_OS_CODENAME="$os_codename"
}

validate_os() {
    detect_os
    
    case "${BOOTSTRAP_OS_ID}-${BOOTSTRAP_OS_CODENAME}" in
        ubuntu-noble)     bootstrap_info "Detected: Ubuntu 24.04 LTS (Noble)" ;;
        ubuntu-resolute)  bootstrap_info "Detected: Ubuntu 26.04 LTS (Resolute)" ;;
        debian-trixie)    bootstrap_info "Detected: Debian 13 (Trixie)" ;;
        ubuntu-*|debian-*)
            bootstrap_warn "Untested OS: $BOOTSTRAP_OS_ID $BOOTSTRAP_OS_VERSION ($BOOTSTRAP_OS_CODENAME)"
            read -rp "Continue anyway? (y/N): " continue_choice
            [[ ! "$continue_choice" =~ ^[Yy]$ ]] && bootstrap_error "Cancelled."
            ;;
        *)
            bootstrap_error "Unsupported OS: $BOOTSTRAP_OS_ID"
            exit 1
            ;;
    esac
}

is_ubuntu() { [[ "$BOOTSTRAP_OS_ID" == "ubuntu" ]]; }
is_debian() { [[ "$BOOTSTRAP_OS_ID" == "debian" ]]; }
```

### File: `scripts/prepare-existing-server.sh` (Modifications)

Replace OS detection (lines ~56-66):

```bash
# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Validate OS at start
validate_os
```

---

## Verification Checklist Additions

Add to `verify-bootstrap-state.sh`:

```bash
# Security-critical checks
check_no_public_port 8000 "Coolify onboarding should be closed"
check_no_public_port 6001 "Coolify realtime should be closed"
check_no_public_port 6002 "Coolify realtime should be closed"

# If VPN-only mode
if [[ "$SSH_PUBLIC_ACCESS" == "false" ]]; then
    check_ssh_not_public "SSH should not be accessible from Internet"
fi
```

---

## Testing Recommendations

### Critical Test Cases

| Test Case | All OSes | Notes |
|-----------|:--------:|-------|
| Bootstrap from pinned SHA | ⬜ | Supply-chain |
| Bootstrap from tag | ⬜ | Supply-chain |
| Reject tampered ref | ⬜ | Supply-chain |
| SSH accessible only from VPN | ⬜ | If VPN-mode |
| UFW replay preserves custom rules | ⬜ | Operational |
| Coolify ports closed after onboard | ⬜ | Hardening |

### OS-Specific Test Cases

| Test Case | Ubuntu 24.04 | Ubuntu 26.04 | Debian 13 |
|-----------|:------------:|:------------:|:---------:|
| OS detection correct | ⬜ | ⬜ | ⬜ |
| Fresh cloud-init bootstrap | ⬜ | ⬜ | ⬜ |
| Bootstrap replay | ⬜ | ⬜ | ⬜ |
| SSH hardening | ⬜ | ⬜ | ⬜ |
| fail2ban banning | ⬜ | ⬜ | ⬜ |
| Docker DOCKER-USER | ⬜ | ⬜ | ⬜ |

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

### Security
- [Docker - Packet Filtering and Firewalls](https://docs.docker.com/network/packet-filtering-firewalls/)
- [Coolify - Firewall Configuration](https://coolify.io/docs/knowledge-base/server/firewall)

### SSH Socket Issues
- [Debian Bug #1128329](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1128329)
- [SSH reload error on Debian 13](https://www.claudiokuenzler.com/blog/1522/debian-13-trixie-ssh-service-reload-error-cannot-bind-address)

### fail2ban
- [fail2ban GitHub](https://github.com/fail2ban/fail2ban)
- [LinuxCapable - Fail2Ban on Debian](https://linuxcapable.com/how-to-install-fail2ban-on-debian-linux/)

### Official Documentation
- [Debian 13 Release Notes](https://www.debian.org/releases/trixie/releasenotes)
- [Ubuntu Security - Firewall](https://documentation.ubuntu.com/security/security-features/network/firewall/)

---

## Changelog

### v2.1 (September 9, 2026)
- **FIXED:** Section numbering (duplicate section 3)
- **EXPANDED:** "What's Already Good" with details about strict env parser and Coolify SSH key restrictions
- **ADDED:** P2 - Coolify localhost key should restrict to actual Docker subnet (not all RFC1918)
- **ADDED:** P2 - `sysctl rp_filter=1` may conflict with Docker/WireGuard
- **ADDED:** P2 - 80/443 architectural decision for management VPS
- **ADDED:** P3 - Docker IPv6 workaround needs expiry documentation
- **ADDED:** P3 - Ubuntu-specific comments should be generalized

### v2.0 (September 9, 2026)
- **MAJOR:** Integrated external security audit findings
- **REMOVED:** UFW packages list recommendation (already implemented)
- **REMOVED:** Complex fail2ban fallback logic (keep simple)
- **ADDED:** P0 supply-chain risk (mutable Git ref)
- **ADDED:** P0/P1 SSH public access risk
- **ADDED:** P1 NOPASSWD privilege escalation
- **ADDED:** P1 Docker group membership risk
- **ADDED:** P1 UFW reset operational risk
- **ADDED:** P1 Coolify ports hardening
- **CORRECTED:** Secrets storage model - downgraded from P1 to P2 (root:root 0600 is standard)
- **RESTRUCTURED:** Priority order based on actual security impact, not OS compatibility

### v1.2 (September 9, 2026)
- Fixed SSH status in compatibility matrix
- Removed redundant SSH handling code

### v1.1 (September 9, 2026)
- Initial compatibility analysis

---

**Document End**
