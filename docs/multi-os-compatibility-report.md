# Multi-OS Compatibility & Security Audit Report

**Document Version:** 3.3  
**Audit Date:** September 9, 2026  
**Repository Commit:** `fa5732148f51822679e8d3c65c90cd56fc03cc3d`  
**Analyst:** Kiro AI + External Security Review  
**Target Operating Systems:** Ubuntu 24.04 LTS, Ubuntu 26.04 LTS, Debian 13 (Trixie)

**Note:** The commit SHA above references the private repository state at audit time. For external reproducibility, a release tag or archive hash should be published alongside.

---

## Priority Definitions

| Priority | Name | Definition | Examples |
|:--------:|------|------------|----------|
| **P0** | Critical | Production blocker. Direct exploitation with critical impact. Immediate fix required. | Remote code execution, authentication bypass |
| **P1** | High | Significant security or operational risk. Fix before production use. | Privilege escalation path, supply-chain risk, data exposure |
| **P2** | Medium | Hardening recommendation. Defense-in-depth. Should fix but not blocker. | Broader-than-needed permissions, missing validation, compatibility |
| **P3** | Low | Quality/documentation. Nice-to-have improvements. | Code comments, formatting, technical debt |

---

## Executive Summary

This report provides a comprehensive security audit of the `vps-coolify-bootstrap` project. Version 3.3 integrates findings from multiple review iterations and external security analysis.

### Overall Assessment

| Category | Status | Notes |
|----------|:------:|-------|
| Security Baseline | **PARTIAL** | Strong foundation, high-priority gaps in SSH persistence and group permissions |
| Operational Robustness | **PARTIAL** | Excellent verification tooling, but UFW replay risk, missing dependencies, tests pending |
| Debian 13 Compatibility | **PARTIAL** | OS detection broken, core components appear compatible; E2E validation pending |
| Ubuntu 26.04 Compatibility | **UNTESTED** | Coolify supports Debian/Ubuntu generically, but Quick Installer lists only 20.04/22.04/24.04 |
| Supply-Chain Hardening | **PARTIAL** | Bootstrap ref currently mutable; external installer is an accepted unpinned trust boundary |

### Key Findings Summary

| Priority | Count | Most Critical |
|:--------:|:-----:|---------------|
| **P1** | 8 | SSH socket generator not masked, managed users in coolify group, mutable Git ref, Docker group membership |
| **P2** | 17 | Coolify internals coupling, auto-update, RFC1918 SSH trust, recovery procedures, needrestart policy |
| **P3** | 3 | Documentation, comments |

---

## What's Already Good

The repository demonstrates several excellent security practices:

### 1. ✅ Strict Environment Parser
`load_env_file_strict()` manually parses env files and **rejects dangerous patterns**:
- `$(...)`
- `${...}`
- Backticks

Instead of dangerous `source bootstrap.env`. **This prevents shell evaluation while loading environment files and eliminates a class of env-file command-injection vulnerabilities.**

### 2. ✅ Comprehensive Verifier
`verify-bootstrap-state.sh` checks 20+ security properties including SSH state, ports, users, groups, sudo, Docker, Coolify container, and SSH key restrictions.

### 3. ✅ Coolify SSH Key Restrictions
The localhost key uses `authorized_keys` restrictions:
```
from="<private ranges>",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc
```
Operator key is removed from Coolify user.

### 4. ✅ Docker/UFW Bypass Documented
DOCKER-USER chain properly managed with explicit documentation about the UFW bypass.

### 5. ✅ Registration Race Mitigation
Bootstrap sets root account credentials and seeds root user, reducing the risk of instance takeover via open registration. Coolify warns that without an admin created, the first visitor to the registration page can create the admin account. ([Coolify docs][1])

### 6. ✅ UFW in Packages List
Works on Debian 13 (not pre-installed there).

---

## P1 Findings (High Priority)

### 1. SSH Socket Generator Not Masked (P1)

**Current Behavior:**
```bash
# bootstrap-host.sh
systemctl disable --now ssh.socket 2>/dev/null || true
```

**Problem:** Ubuntu 24.04 and Ubuntu 26.04 ship `sshd-socket-generator`. Simply disabling `ssh.socket` is **not sufficient for persistent deactivation**. The generator can generate runtime drop-ins for `ssh.socket`; socket-activation configuration may be regenerated after boot or package operations unless the generator is masked. ([Launchpad][2], [Ubuntu Community Hub][3])

**Required Fix:**
```bash
# Mask the generator to prevent configuration regeneration
# Applies to Ubuntu 24.04 and 26.04
if [[ -f /usr/lib/systemd/system-generators/sshd-socket-generator ]]; then
    ln -sf /dev/null /etc/systemd/system-generators/sshd-socket-generator
fi
systemctl daemon-reload
systemctl disable --now ssh.socket
systemctl enable --now ssh.service
```

**Required Test:**
```
bootstrap → reboot → ssh.socket inactive → ssh.service active → only SSH_PORT listening
```

**Impact:** Without masking, socket-activation configuration may be regenerated after boot/package operations, causing `systemctl reload ssh` failures.

---

### 2. Managed Users Have Write Access to Coolify Control-Plane Data (P1)

**Current Behavior:**
```bash
chgrp -R coolify /data/coolify
chmod -R g+rwX /data/coolify
# + all managed users added to coolify group
```

**Problem:** Human/managed users are unnecessarily members of the `coolify` group and therefore gain write access to Coolify control-plane data without sudo.

**Important Distinction:**

| Scenario | Required Ownership | Source |
|----------|-------------------|--------|
| Server managed via non-root SSH user | `coolify:coolify` | [Coolify non-root docs][4] |
| Localhost Coolify host (self-hosted) | `9999:root` with `chmod 700` | [Coolify installation docs][1] |

The management VPS is **both**: it hosts the Coolify instance AND is a managed server. The current `group=coolify` with `g+rwX` may be an intentional workaround for this dual role.

**The real problem:** Human operators are members of that group.

**Required Fix:**
```bash
# Do NOT change ownership - preserve what Coolify requires
# Remove human users from coolify group
for user in $MANAGED_HUMAN_USERS; do
    gpasswd -d "$user" coolify 2>/dev/null || true
done

# If dedicated non-root SSH account is used for Coolify's localhost server,
# grant only the filesystem access actually required
# Regression-test across Coolify upgrades
```

---

### 3. Supply-Chain: Mutable Git Ref (P1)

**Current Behavior:**
```bash
git clone --depth 1 --branch "$repo_ref" "$repo_url" "$repo_dir"
bash "$repo_dir/scripts/bootstrap-host.sh" ...
```

If `BOOTSTRAP_REPO_REF=main`, bootstrap executes whatever `main` means at that moment.

**Note:** A Git tag can also be moved. Only commit SHA is truly immutable.

**Important Implementation Detail:** Git `--branch` does not reliably accept commit SHA. Some servers may also refuse fetch of unadvertised SHA.

**Robust Implementation:**
```bash
# Fetch through a server-supported reachable ref, then verify SHA
BOOTSTRAP_EXPECTED_SHA=fa5732148f51822679e8d3c65c90cd56fc03cc3d

# Option 1: Direct SHA fetch (if server supports)
git init "$repo_dir"
git -C "$repo_dir" remote add origin "$repo_url"
git -C "$repo_dir" fetch --depth=1 origin "$BOOTSTRAP_EXPECTED_SHA"
git -C "$repo_dir" checkout --detach FETCH_HEAD

# Option 2: Fetch via tag/branch, then verify
git clone --depth=1 --branch "$BOOTSTRAP_REF" "$repo_url" "$repo_dir"

# Always verify (SHA is source of truth)
actual_sha="$(git -C "$repo_dir" rev-parse HEAD)"
if [[ "$actual_sha" != "$BOOTSTRAP_EXPECTED_SHA" ]]; then
    echo "FATAL: Bootstrap ref mismatch! Expected $BOOTSTRAP_EXPECTED_SHA, got $actual_sha" >&2
    exit 1
fi
```

---

### 4. DEVOPS_USER has NOPASSWD:ALL (P1)

**Current Behavior:**
```
DEVOPS_USER → NOPASSWD:ALL
COOLIFY_USER → NOPASSWD:ALL
```

**Distinction:**
- `COOLIFY_USER`: NOPASSWD:ALL is **required** by Coolify non-root mode. Coolify itself warns this is not the most secure solution. ([Coolify docs][5])
- `DEVOPS_USER`: NOPASSWD:ALL is **not required**

**Impact:** Compromised `DEVOPS_USER` SSH key = immediate root.

**Required Fix:**
```bash
# bootstrap.env
DEVOPS_USER_NOPASSWD=false  # default

# cloud-init template must also change
# to avoid permissive window before apply_sudo_policy()
```

---

### 5. All Managed Users in Docker Group (P1)

**Current Behavior:**
`verify-bootstrap-state.sh` requires every managed user in `sudo`, `docker`, `coolify`.

**Problem:** Docker group is **root-equivalent** ([Docker docs][6]):
```bash
docker run --rm -v /:/host alpine cat /host/etc/shadow
```

**Required Fix:**
```bash
# Explicit, default empty
DOCKER_USERS=""

# Only add users who genuinely need ambient Docker access
# Others use: sudo docker ...
```

---

### 6. UFW Reset on Replay (P1 Operational)

**Current Behavior:**
```bash
ufw --force reset
```

**Problem:** In current model where custom rules are permitted out-of-band, replay eliminates:
- WireGuard rules
- Monitoring allowlists
- Backup network access

**Note:** `ufw reset` is **acceptable** if bootstrap is complete source of truth for firewall.

**Required Fix (until declarative firewall):**
```bash
# Make firewall fully declarative with structured config (not shell strings)
MANAGEMENT_CIDRS="10.100.0.0/24"
EXTRA_ALLOWED_TCP_PORTS="9100"           # e.g., Prometheus
EXTRA_ALLOWED_UDP_PORTS="51820"          # e.g., WireGuard

# For complex rules, use structured format:
# EXTRA_RULES_FILE=/etc/vps-bootstrap/extra-ufw-rules.conf
# MVP Format: CIDR|PORT|PROTOCOL|DIRECTION
# Full format may need: ACTION|CIDR|DEST|PORT|PROTOCOL|INTERFACE|DIRECTION|COMMENT

# Generate complete ruleset deterministically
# reset + regenerate becomes reconciliation mechanism
```

---

### 7. Coolify Ports Not Hardened by Default (P1)

**Current Behavior:**
- `CLOSE_COOLIFY_REALTIME_PORTS=false` (default)
- Bootstrap does not implicitly close Docker-published ports 6001, 6002
- Port 8000 open during/after onboarding

**Coolify docs:** 8000/6001/6002 can be closed when dashboard served via custom domain ([Coolify docs][7])

**Required Fix:**
```bash
# Change defaults
CLOSE_COOLIFY_REALTIME_PORTS=true

# Port 8000 policy
# onboarding: operator CIDR/VPN only
# post-onboarding: deny public
```

---

### 8. Debian 13 OS Detection Broken (P1)

**Current Behavior:**
```bash
CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-}")"
```

**Problem:** Debian has `VERSION_CODENAME`, not `UBUNTU_CODENAME`. Script logs "Detected Ubuntu" incorrectly.

**Required Fix:**
```bash
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        BOOTSTRAP_OS_ID="${ID:-unknown}"
        BOOTSTRAP_OS_VERSION="${VERSION_ID:-unknown}"
        BOOTSTRAP_OS_CODENAME="${VERSION_CODENAME:-unknown}"
    fi
    export BOOTSTRAP_OS_ID BOOTSTRAP_OS_VERSION BOOTSTRAP_OS_CODENAME
}
```

**Note:** Don't use interactive `read -rp` in generic function - may block cloud-init. Use:
```bash
# unsupported → fail
# untested → fail unless ALLOW_UNTESTED_OS=true
```

---

## P2 Findings (Medium Priority - Hardening)

### 9. Supply-Chain: External Coolify Installer (P2)

**Current Behavior:**
```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

This installer can install Docker and download other artifacts. The repository documents `curl|bash` as a trade-off.

**Trust Boundaries (must be explicit):**

| Boundary | Trust Level | Notes |
|----------|:-----------:|-------|
| Own repository | Full | Pinned SHA required |
| Coolify installer | Accepted | Official, documented, not version-pinned |
| Docker via Coolify | Transitive | Could be isolated |

**Recommendation:** Pre-install Docker from official Docker repository reduces supply-chain chaining. Coolify installer is accepted trust boundary.

---

### 10. Coupling to Coolify Internals (P2)

**Current Behavior:**
Bootstrap runs PHP in container and directly accesses:
```php
\App\Models\Server
\App\Models\PrivateKey
InstanceSettings
id=0
```

**Problem:** These are not stable public APIs. A Coolify upgrade may break bootstrap.

**Better Alternative:** Coolify has documented public API for these operations:
- Private keys: list, create ([Coolify API docs][8])
- Servers: list, create ([Coolify API docs][9])
- API tokens and permissions ([Coolify API docs][10])

**Required:**
- Evaluate migration to the documented Coolify API for private-key and server operations
- Retain internal-model access only for bootstrap operations not exposed by the API
- Add version guard with explicit range: `SUPPORTED_COOLIFY_MIN/MAX` or `TESTED_COOLIFY_VERSION`
- Add smoke tests after each Coolify upgrade

**Required Test:**
```
bootstrap supported Coolify version
→ upgrade to next version
→ replay bootstrap
→ verify localhost Server/PrivateKey
→ verify proxy
→ verify deploy
```

---

### 11. Coolify Auto-Update Not Disabled (P2)

**Current Behavior:** Bootstrap doesn't configure auto-update policy.

**Problem:** Coolify self-hosted has auto-update enabled by default. Coolify docs recommend disabling for production. ([Coolify docs][11])

**Required Fix:**
```bash
# Set in /data/coolify/source/.env (documented method):
AUTOUPDATE=false

# Or use dashboard Settings equivalent for current Coolify version
# Verify state after configuration
```

---

### 12. Missing `fuser` Dependency (P2)

**Current Behavior:** `prepare-existing-server.sh` uses `fuser` for APT lock checks before installing prerequisites.

**Problem:** `fuser` (from `psmisc`) is not guaranteed on minimal images.

**Impact:** Bootstrap failure/retry, not privilege escalation.

**Important:** There is a chicken-and-egg problem, and **lock-file existence does not indicate lock state**.

**Required Fix:**
```bash
# 1. Do not depend on fuser before prerequisites are installed

# 2. Use APT/DPkg lock timeout where supported
apt-get -o DPkg::Lock::Timeout=60 update
apt-get -o DPkg::Lock::Timeout=60 install -y psmisc

# 3. Retry apt update/install on known lock-acquisition failures with bounded backoff

# 4. NEVER determine lock state merely from lock-file existence
#    Lock file can exist without being locked!

# Key principle:
# fuser must not be required to bootstrap the prerequisites that provide fuser
```

Reference: [Debian Bug #864681][12]

---

### 13. SSH Public Access Model (P2)

**Current:** Public SSH with key-only authentication, appropriate rate limiting and current OpenSSH is **not inherently a security misconfiguration**, but it increases externally reachable attack surface.

For Tier-0 management VPS, VPN-only is **hardening recommendation**, not blocker.

**Recommended:** Three modes instead of boolean:
```bash
SSH_ACCESS_MODE=public-key-limited  # default, safe bootstrap
SSH_ACCESS_MODE=allowlist           # SSH_TRUSTED_CIDRS
SSH_ACCESS_MODE=vpn-only            # after WireGuard setup
```

---

### 14. RFC1918 SSH Trust Too Broad (P2)

**Current:** SSH allowed without rate-limit from all private ranges:
```
10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, fc00::/7, fe80::/10
```

**Required:** Add `SSH_TRUSTED_CIDRS` and allow only actually used subnets.

---

### 15. Coolify Localhost Key Subnet (P2)

**Current:** `from=` allows all RFC1918.

**Problem:** Too broad. Should restrict to actual Docker/Coolify network.

**Note:** Don't hardcode `172.17.0.0/16` - detect actual subnet or make configurable.

---

### 16. Provider Firewall Layer (P2)

Coolify recommends provider firewall when available, especially because Docker NAT can bypass UFW. ([Coolify docs][7])

For management VPS:
```
provider firewall + UFW + DOCKER-USER
```
is more robust than UFW alone.

---

### 17. `rp_filter=1` Verification (P2)

**Current:**
```bash
net.ipv4.conf.all.rp_filter=1
```

**Note:** Strict mode (`1`) is recommended for source spoofing protection. Loose mode (`2`) needed only for asymmetric/complex routing. ([Kernel docs][13])

**Required:** Verify per-interface if using WireGuard policy routing, multi-homing, or asymmetric routing. Don't reduce globally without demonstrated need.

---

### 18. Unattended Upgrades and Service Restart Policy (P2)

**Current:** Only enables unattended-upgrades service.

**Note:** `unattended-upgrades.service` is not a permanent daemon; periodic execution is tied to APT/systemd timers.

**Additional Concern (Ubuntu 24.04+):** `needrestart` automatically restarts services after updates by default. For production/management VPS, this may cause unexpected restarts. ([Ubuntu docs][14])

**Required verification:**
```bash
# Check timer status
systemctl status apt-daily-upgrade.timer
systemctl list-timers apt-daily*

# Check APT periodic configuration
apt-config dump | grep -i periodic

# Verify configuration actually works (most valuable test)
unattended-upgrade --dry-run --debug

# Required states:
apt-daily.timer enabled
apt-daily-upgrade.timer enabled
APT::Periodic::Update-Package-Lists != 0
APT::Periodic::Unattended-Upgrade != 0
# Effective allowed origins non-empty (Allowed-Origins and/or Origins-Pattern)
```

**Recommended policy for control plane:**
```text
security updates: automatically installed
automatic full reboot: disabled
service restart policy (needrestart): explicitly reviewed
controlled reboot/maintenance: scheduled
```

Reference: [Ubuntu automatic updates][14], [Debian unattended-upgrades config][15]

---

### 19. 80/443 Architectural Decision (P2)

80/443 are normal for Coolify reverse-proxy. ([Coolify docs][16])

**Distinguish:**
- Public reverse-proxy endpoints → 80/443 ✓
- Administrative endpoints → access policy decision

Coolify UI exposure is policy decision, not bug.

---

### 20. Docker IPv6 Workaround Validation (P2)

**Current:** Heuristic may set `"ipv6": false` globally.

**Required:**
- Document upstream bug/issue ID
- Exact affected versions
- Exact fixed versions
- Regression test
- Don't disable IPv6 globally without demonstrating bug

---

### 21. Recovery: APP_KEY Off-Host (P2)

Coolify requires `APP_KEY` for secret decryption. Without it, restored secrets cannot be decrypted. ([Coolify docs][17])

**Required:** Document APP_KEY backup requirement. This is essential for successful control-plane recovery.

---

### 22. Recovery: SSH Keys Coolify (P2)

For migrated/recreated instance, Coolify SSH keys to remote servers must be recovered. Without these keys, control plane cannot connect to production VPS instances. ([Coolify docs][18])

**Required:** Include in restore test and documentation.

---

### 23. Recovery: Coolify Version Compatibility (P2)

Coolify recommends installing the **same version** on replacement server before restoring backup. ([Coolify docs][18])

**Required Recovery Manifest:**
```text
- Database backup
- APP_KEY
- /data/coolify/ssh/keys
- Relevant authorized_keys
- Coolify version at backup time
- Bootstrap commit SHA
```

**Full DR Test:**
```text
install compatible/same Coolify version
→ restore backup
→ validate connections
→ upgrade separately if needed
```

Not "restore directly into latest".

---

### 24. Kernel Reboot Check (P2)

`package_upgrade: true` may install kernel without running it.

**Problem:** "Bootstrap complete" does not mean updated kernel/security stack is running.

**Required:**
```bash
# Bootstrap reports reboot requirement, does not auto-reboot
# (auto-reboot in cloud-init causes resume/re-entry complexity)

if [[ -f /var/run/reboot-required ]]; then
    echo "REBOOT_REQUIRED=true"
    # Log which packages require reboot
    cat /var/run/reboot-required.pkgs 2>/dev/null || true
fi

# Production-ready verification occurs only after:
# 1. Manual/controlled reboot
# 2. Verifier rerun post-reboot
```

---

### 25. Verifier Effective Exposure (P2)

`check_no_public_port()` must test **effective exposure**, not just `ss` output:
- Port may bind `0.0.0.0` but blocked by DOCKER-USER
- Port may bind `0.0.0.0` but blocked by provider firewall

**Note:** Provider firewall cannot be verified generically from host. This is **external/integration test**, not local verifier check.

---

## P3 Findings (Low Priority - Quality)

### 26. Ubuntu-Specific Comments (P3)
Comments like "Ubuntu 24.04 defaults to ssh.socket" should be generalized for multi-OS.

### 27. Cloud-Init Secrets Trust Boundary (P3)
If values transmitted via provider user-data, document provider as trust boundary. If generated only on host, mark N/A.

### 28. Traceability: Release Tag (P3)
For audit reproducibility:
- **Commit SHA** is canonical identifier (immutable)
- **Release tag** is informational only (can be moved)
- **Archive SHA256** useful if bootstrap uses archive artifacts

---

## OS Compatibility Matrix

### Support Levels Defined

| Level | Meaning |
|-------|---------|
| **VERIFIED** | Tested end-to-end by this project |
| **RECOGNIZED** | Bootstrap recognizes and accepts OS |
| **COOLIFY-SUPPORTED** | Listed in Coolify official docs |
| **UNTESTED** | Not validated |

### Coolify OS Support Clarification

Coolify documentation states:
> Debian-based: Debian, Ubuntu — all versions supported

However, the Quick Installer explicitly lists only:
> Ubuntu LTS: 20.04, 22.04, 24.04

([Coolify Installation docs][1])

### Current Status

| OS | Bootstrap Recognition | Coolify OS Family | Quick Installer Listed | Project E2E | Overall |
|----|:---------------------:|:-----------------:|:----------------------:|:-----------:|:-------:|
| Ubuntu 24.04 LTS | ✅ | ✅ | ✅ | ⬜ NEEDED | **PARTIAL** |
| Ubuntu 26.04 LTS | ⚠️ Warning | ✅ | ❓ Not listed | ⬜ NEEDED | **UNTESTED** |
| Debian 13 | ❌ Broken | ✅ | N/A | ⬜ NEEDED | **PARTIAL** |

**Notes:**
- Ubuntu 26.04 overall is UNTESTED because Quick Installer doesn't list it and no E2E test exists
- Debian 13 is PARTIAL because OS detection is broken, not because Coolify doesn't support it
- Quick Installer column is N/A for Debian (column refers to Ubuntu LTS list specifically)

### Component Compatibility

| Component | Ubuntu 24.04 | Ubuntu 26.04 | Debian 13 |
|-----------|:------------:|:------------:|:---------:|
| OS Detection | ✅ | ⚠️ | ❌ |
| SSH Socket | ⚠️ Generator needs masking | ⚠️ Generator needs masking | ⚠️ May have ssh.socket active; test pending |
| UFW | ✅ | ✅ | ✅ |
| fail2ban | ✅ | ✅ | ✅ |
| Docker upstream support | ✅ | ✅ | ✅ |
| Packages | ✅ | ✅ | ⚠️ `psmisc` may be missing |
| **Project E2E validation** | ⬜ | ⬜ | ⬜ |

**Note:** Docker officially supports Ubuntu 26.04 Resolute ([Docker docs][19]) and Debian 13 Trixie ([Docker docs][20]). All OS require project E2E testing.

---

## Implementation Roadmap

### Phase 1: P1 Fixes (Before Production)

| # | Change | Effort | Finding | Status |
|---|--------|--------|---------|:------:|
| 1 | Mask `sshd-socket-generator` on Ubuntu 24.04/26.04 + reboot test | 1h | #1 | ✅ |
| 2 | Remove human users from coolify group (preserve Coolify ownership) | 1h | #2 | ✅ |
| 3 | Pin bootstrap to SHA with correct fetch + verify method | 1h | #3 | ✅ |
| 4 | Configurable `DEVOPS_USER_NOPASSWD` + cloud-init fix | 1h | #4 | ✅ |
| 5 | Separate `DOCKER_USERS`, default empty | 1h | #5 | ✅ |
| 6 | Declarative firewall model (structured config) | 3h | #6 | ✅ |
| 7 | Hardened Coolify ports default + 8000 policy | 1h | #7 | ✅ |
| 8 | Fix Debian 13 OS detection | 30m | #8 | ✅ |

### Phase 2: P2 Hardening

| # | Change | Effort | Finding | Status |
|---|--------|--------|---------|:------:|
| 9 | Document Coolify installer trust boundary | 30m | #9 | ⬜ |
| 10 | Evaluate Coolify public API + version guard (MIN/MAX) | 2h | #10 | ✅ |
| 11 | Coolify auto-update configuration (AUTOUPDATE=false) | 30m | #11 | ✅ |
| 12 | Fix `fuser` with APT timeout + retry (no lock-file existence check) | 1h | #12 | ⬜ |
| 13 | SSH access modes (public/allowlist/vpn-only) | 2h | #13 | ⬜ |
| 14 | `SSH_TRUSTED_CIDRS` | 1h | #14 | ⬜ |
| 15 | Coolify localhost key subnet detection | 1h | #15 | ⬜ |
| 16 | Provider firewall documentation | 30m | #16 | ⬜ |
| 17 | `rp_filter` per-interface verification | 30m | #17 | ⬜ |
| 18 | Unattended-upgrades + needrestart policy | 1h | #18 | ✅ |
| 19 | 80/443 access policy documentation | 30m | #19 | ⬜ |
| 20 | Docker IPv6 workaround validation | 1h | #20 | ⬜ |
| 21 | APP_KEY backup documentation | 30m | #21 | ⬜ |
| 22 | SSH keys recovery documentation + test | 30m | #22 | ⬜ |
| 23 | Coolify version in recovery manifest + DR test | 1h | #23 | ⬜ |
| 24 | Kernel reboot-required reporting (not auto-reboot) | 30m | #24 | ✅ |
| 25 | Effective exposure integration test | 1h | #25 | ⬜ |

### Phase 3: P3 Quality

| # | Change | Effort | Finding |
|---|--------|--------|---------|
| 26 | Generalize Ubuntu-specific comments | 30m | #26 |
| 27 | Cloud-init trust boundary documentation | 30m | #27 |
| 28 | Add release tag (informational) alongside canonical SHA | 15m | #28 |

---

## Verifier Requirements

The verifier must become **policy-aware**. Current assertions become incorrect after hardening.

### Derive Expectations From Config

```bash
# Instead of hardcoded group checks:
# check_user_in_groups "$user" "sudo,docker,coolify"

# Policy-aware (DOCKER_USERS explicit, no coolify group for human users):
expected_groups="sudo"
if [[ -n "$DOCKER_USERS" ]] && user_in_list "$user" "$DOCKER_USERS"; then
    expected_groups+=",docker"
fi
# Note: human users should NOT be in coolify group
# Coolify user ownership replaces shared group model for human access
check_user_in_groups "$user" "$expected_groups"
```

---

## Testing Matrix

### Required Fresh Image Tests

| OS | Image Source | Provider | Status |
|----|--------------|----------|:------:|
| Ubuntu 24.04 | Official minimal | Production provider | ⬜ |
| Ubuntu 26.04 | Official minimal | Production provider | ⬜ |
| Debian 13 | Official minimal | Production provider | ⬜ |

**Note:** Test on actual production provider, not only Hetzner. Provider images differ in cloud-init/packages/networking.

### Required Test Cases

#### Bootstrap Flow
- [ ] Fresh cloud-init bootstrap
- [ ] Bootstrap replay
- [ ] Bootstrap interrupted halfway + replay
- [ ] Reboot after bootstrap
- [ ] SSH socket stays disabled after reboot

#### SSH
- [ ] SSH port change
- [ ] SSH key rotation
- [ ] Only SSH_PORT listening (not 22)

#### Package Upgrades
- [ ] Package upgrade after bootstrap
- [ ] OpenSSH package upgrade → reboot → SSH still reachable
- [ ] unattended-upgrades OpenSSH update → reboot → SSH still reachable

#### Firewall
- [ ] Custom rules preserved after declarative replay
- [ ] 8000/6001/6002 external reachability blocked
- [ ] DOCKER-USER rules effective
- [ ] Provider firewall unavailable scenario
- [ ] Provider firewall enabled scenario

#### Coolify
- [ ] Coolify upgrade
- [ ] Bootstrap replay after Coolify upgrade
- [ ] localhost Server/PrivateKey verification
- [ ] Proxy functional
- [ ] Deploy functional

#### Docker
- [ ] Docker upgrade
- [ ] IPv4-only VPS
- [ ] Dual-stack IPv4/IPv6

#### Recovery
- [ ] Restore Coolify from backup (same version)
- [ ] APP_KEY recovery
- [ ] SSH keys recovery (control plane to remote servers)
- [ ] Coolify version compatibility after restore

#### Disaster Recovery (Full Rebuild)
- [ ] Full management VPS rebuild from zero
- [ ] Install same Coolify version as backup
- [ ] Restore Coolify DB/config
- [ ] Restore APP_KEY
- [ ] Restore SSH keys
- [ ] Verify Prod VPS1 connection
- [ ] Verify Prod VPS2 connection
- [ ] Deploy test container
- [ ] Upgrade Coolify separately if needed

#### Security
- [ ] Invalid/tampered Git SHA rejected
- [ ] Human user cannot write `/data/coolify` (after fix)

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

[1]: https://coolify.io/docs/get-started/installation "Coolify Installation"
[2]: https://launchpad.net/ubuntu/noble/+source/openssh/+changelog "Ubuntu Noble openssh changelog"
[3]: https://discourse.ubuntu.com/t/sshd-now-uses-socket-based-activation-ubuntu-22-10-and-later/30189/47 "Ubuntu Community Hub - SSH socket activation"
[4]: https://next.coolify.io/docs/core/infrastructure/servers/non-root-user "Coolify Non-root User"
[5]: https://coolify.io/docs/knowledge-base/server/non-root-user "Non-root user | Coolify Docs"
[6]: https://docs.docker.com/engine/install/linux-postinstall "Docker post-installation"
[7]: https://coolify.io/docs/knowledge-base/server/firewall "Firewall | Coolify Docs"
[8]: https://next.coolify.io/docs/api/endpoints/private-keys/list-private-keys "Coolify API - Private Keys"
[9]: https://next.coolify.io/docs/api/endpoints/servers/create-server "Coolify API - Servers"
[10]: https://next.coolify.io/docs/core/security/credentials/api-tokens "Coolify API Tokens"
[11]: https://coolify.io/docs/knowledge-base/self-update "Coolify Self-Update"
[12]: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=864681 "Debian Bug #864681 - APT lock timeout"
[13]: https://www.kernel.org/doc/html/v6.12/networking/ip-sysctl.html "Linux Kernel IP Sysctl"
[14]: https://ubuntu.com/server/docs/how-to/software/automatic-updates "Ubuntu Automatic Updates"
[15]: https://sources.debian.org/src/unattended-upgrades/2.12/data/50unattended-upgrades.Debian "Debian unattended-upgrades config"
[16]: https://next.coolify.io/docs/core/infrastructure/servers/firewall "Coolify Firewall"
[17]: https://next.coolify.io/docs/core/security-model "Coolify Security Model"
[18]: https://coolify.io/docs/knowledge-base/how-to/backup-restore-coolify "Backup and Restore Coolify"
[19]: https://docs.docker.com/engine/install/ubuntu "Docker Engine on Ubuntu"
[20]: https://docs.docker.com/engine/install/debian "Docker Engine on Debian"

---

## Changelog

### v3.3 (September 9, 2026)
- **FIXED:** Finding #2 `/data/coolify`: corrected solution - do NOT change ownership, remove human users from coolify group instead
- **FIXED:** "eliminates command injection" → "eliminates env-file command-injection class"
- **FIXED:** Docker Ubuntu 26.04: ⬜ Expected → ✅ officially supported
- **FIXED:** Finding #10: replaced GitHub issue with official Coolify API documentation
- **FIXED:** Finding #12 `fuser`: don't test lock-file existence; use APT timeout + retry
- **FIXED:** unattended-upgrades: `Allowed-Origins` → `Allowed-Origins and/or Origins-Pattern`
- **FIXED:** SSH generator: explicitly covers Ubuntu 24.04 AND 26.04
- **IMPROVED:** SHA pinning: "fetch through reachable ref, then verify SHA"
- **IMPROVED:** Public SSH wording: "not inherently a misconfiguration, but increases attack surface"
- **ADDED:** Recovery manifest now includes Coolify version (Finding #23)
- **ADDED:** `needrestart` policy to Finding #18
- **ADDED:** Full disaster recovery test with version compatibility
- **UPDATED:** P2 count 16→17 (added needrestart to #18, added #23)
- **UPDATED:** Project name in Executive Summary

### v3.2 (September 9, 2026)
- **FIXED:** Supply-Chain Hardening: GAP→PARTIAL
- **FIXED:** Git SHA fetch implementation
- **FIXED:** Removed implicit `COOLIFY_RUNTIME_USERS` from Verifier
- **FIXED:** `fuser` chicken-and-egg with alternative lock detection
- **FIXED:** Debian Quick Installer: ❓→N/A
- **ADDED:** Full disaster recovery rebuild test case

### v3.1 (September 9, 2026)
- **RECLASSIFIED:** Multiple findings P1→P2 and P3→P2
- **FIXED:** Coolify Debian 13 support, Executive Summary, WireGuard UDP

### v3.0 (September 9, 2026)
- **MAJOR REWRITE** integrating 48 external audit findings

### v2.x (September 9, 2026)
- Initial versions and iterations

---

**Document End**
