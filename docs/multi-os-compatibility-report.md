# Multi-OS Compatibility & Security Audit Report

**Document Version:** 3.1  
**Audit Date:** September 9, 2026  
**Repository Commit:** `fa5732148f51822679e8d3c65c90cd56fc03cc3d`  
**Analyst:** Kiro AI + External Security Review  
**Target Operating Systems:** Ubuntu 24.04 LTS, Ubuntu 26.04 LTS, Debian 13 (Trixie)

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

This report provides a comprehensive security audit of the `public-vps-coolify-bootstrap` project. Version 3.1 integrates findings from multiple review iterations and external security analysis.

### Overall Assessment

| Category | Status | Notes |
|----------|:------:|-------|
| Security Baseline | **PARTIAL** | Strong foundation, high-priority gaps in SSH persistence and group permissions |
| Operational Robustness | **PARTIAL** | Excellent verification tooling, but UFW replay risk, missing dependencies, tests pending |
| Debian 13 Compatibility | **PARTIAL** | OS detection broken, core components appear compatible; E2E validation pending |
| Ubuntu 26.04 Compatibility | **UNTESTED** | Coolify supports Debian/Ubuntu generically, but Quick Installer lists only 20.04/22.04/24.04 |
| Supply-Chain Hardening | **GAP** | Own bootstrap not immutable-pinned; external installer trust boundary accepted but not version-pinned |

### Key Findings Summary

| Priority | Count | Most Critical |
|:--------:|:-----:|---------------|
| **P1** | 8 | SSH socket generator not masked, `/data/coolify` group permissions, mutable Git ref, Docker group membership |
| **P2** | 16 | Coolify internals coupling, auto-update, RFC1918 SSH trust, recovery procedures |
| **P3** | 3 | Documentation, comments |

---

## What's Already Good

The repository demonstrates several excellent security practices:

### 1. ✅ Strict Environment Parser
`load_env_file_strict()` manually parses env files and **rejects dangerous patterns**:
- `$(...)`
- `${...}`
- Backticks

Instead of dangerous `source bootstrap.env`. **This eliminates command injection vulnerabilities.**

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

**Problem:** On Ubuntu 24.04, `sshd-socket-generator` exists. Simply disabling `ssh.socket` is **not sufficient for persistent deactivation**. The generator can generate runtime drop-ins for `ssh.socket`; for complete deactivation of socket-activated mode, Ubuntu documents masking the generator. ([Launchpad][2])

**Required Fix:**
```bash
# Mask the generator to prevent re-activation
ln -sf /dev/null /etc/systemd/system-generators/sshd-socket-generator
systemctl daemon-reload
systemctl disable --now ssh.socket
systemctl enable --now ssh.service
```

**Required Test:**
```
bootstrap → reboot → ssh.socket inactive → ssh.service active → only SSH_PORT listening
```

**Impact:** Without masking, SSH socket may be re-enabled after reboot, causing `systemctl reload ssh` failures.

---

### 2. `/data/coolify` Group Permissions Too Broad (P1)

**Current Behavior:**
```bash
chgrp -R coolify /data/coolify
chmod -R g+rwX /data/coolify
# + all managed users added to coolify group
```

**Problem:** Combined with automatic `coolify` group membership for all managed users, a compromised SSH key grants **write access to Coolify runtime/config without sudo**.

**Required Fix (aligned with Coolify docs):**
```bash
# Coolify documents for non-root server user:
chown -R coolify:coolify /data/coolify
chmod -R o-rwx /data/coolify

# Remove managed users from coolify group
# Dedicated Coolify user ownership is sufficient
# Shared runtime group only if demonstrated use-case
```

Reference: [Coolify non-root user docs][3]

---

### 3. Supply-Chain: Mutable Git Ref (P1)

**Current Behavior:**
```bash
git clone --depth 1 --branch "$repo_ref" "$repo_url" "$repo_dir"
bash "$repo_dir/scripts/bootstrap-host.sh" ...
```

If `BOOTSTRAP_REPO_REF=main`, bootstrap executes whatever `main` means at that moment.

**Note:** A Git tag can also be moved. Only commit SHA is truly immutable.

**Required Fix:**
```bash
# Production MUST use exact SHA
BOOTSTRAP_REPO_REF=fa5732148f51822679e8d3c65c90cd56fc03cc3d
BOOTSTRAP_EXPECTED_SHA=fa5732148f51822679e8d3c65c90cd56fc03cc3d

# Verify after clone
actual_sha=$(git rev-parse HEAD)
if [[ "$actual_sha" != "$BOOTSTRAP_EXPECTED_SHA" ]]; then
    echo "FATAL: Bootstrap ref mismatch!" >&2
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
- `COOLIFY_USER`: NOPASSWD:ALL is **required** by Coolify non-root mode. Coolify itself warns this is not the most secure solution. ([Coolify docs][4])
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

**Problem:** Docker group is **root-equivalent** ([Docker docs][5]):
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
# Format: CIDR|PORT|PROTOCOL|DIRECTION

# Generate complete ruleset deterministically
# reset + regenerate becomes reconciliation mechanism
```

---

### 7. Coolify Ports Not Hardened by Default (P1)

**Current Behavior:**
- `CLOSE_COOLIFY_REALTIME_PORTS=false` (default)
- Bootstrap does not implicitly close Docker-published ports 6001, 6002
- Port 8000 open during/after onboarding

**Coolify docs:** 8000/6001/6002 can be closed when dashboard served via custom domain ([Coolify docs][6])

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

**Problem:** These are not stable public APIs. A Coolify upgrade may break bootstrap. Coolify has usable API for resources/servers. ([GitHub][7])

**Required:**
- Use public API if available
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

**Problem:** Coolify self-hosted has auto-update enabled by default. Coolify docs recommend disabling for production. ([Coolify docs][8])

**Required Fix:**
Configure Auto Update Enabled=false through the mechanism supported by the installed Coolify version and verify the state.

**Note:** Don't assume `COOLIFY_AUTOUPDATE=false` is the correct installer argument without verifying current installer schema.

---

### 12. Missing `fuser` Dependency (P2)

**Current Behavior:** `prepare-existing-server.sh` uses `fuser` for APT lock checks before installing prerequisites.

**Problem:** `fuser` (from `psmisc`) is not guaranteed on minimal images.

**Impact:** Bootstrap failure/retry, not privilege escalation.

**Required Fix:**
```bash
# Add to prerequisites or check
command -v fuser &>/dev/null || apt-get install -y psmisc

# Audit all commands used before package installation:
# fuser, ss, visudo, systemctl, sysctl
```

---

### 13. SSH Public Access Model (P2)

**Current:** SSH public with key-only, rate-limiting, fail2ban is **not a critical vulnerability**.

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

Coolify recommends provider firewall when available, especially because Docker NAT can bypass UFW. ([Coolify docs][6])

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

**Note:** Strict mode (`1`) is recommended for source spoofing protection. Loose mode (`2`) needed only for asymmetric/complex routing. ([Kernel docs][9])

**Required:** Verify per-interface if using WireGuard policy routing, multi-homing, or asymmetric routing. Don't reduce globally without demonstrated need.

---

### 18. unattended-upgrades Incomplete (P2)

**Current:** Only enables service.

**Note:** `unattended-upgrades.service` is not a permanent daemon; periodic execution is tied to APT/systemd timers.

**Required verification:**
```bash
apt-daily.timer enabled
apt-daily-upgrade.timer enabled
APT::Periodic::Update-Package-Lists != 0
APT::Periodic::Unattended-Upgrade != 0
Allowed-Origins not empty
```

Reference: [Ubuntu automatic updates][10]

---

### 19. 80/443 Architectural Decision (P2)

80/443 are normal for Coolify reverse-proxy. ([Coolify docs][11])

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

Coolify requires `APP_KEY` for secret decryption. Without it, restored secrets cannot be decrypted. ([Coolify docs][12])

**Required:** Document APP_KEY backup requirement. This is critical for management control-plane.

---

### 22. Recovery: SSH Keys Coolify (P2)

For migrated/recreated instance, Coolify SSH keys to remote servers must be recovered. Without these keys, control plane cannot connect to production VPS instances. ([Coolify docs][13])

**Required:** Include in restore test and documentation.

---

### 23. Kernel Reboot Check (P2)

`package_upgrade: true` may install kernel without running it.

**Problem:** "Bootstrap complete" does not mean updated kernel/security stack is running.

**Required:** Add post-bootstrap check for `/var/run/reboot-required` and controlled reboot before final `production-ready` verdict.

---

### 24. Verifier Effective Exposure (P2)

`check_no_public_port()` must test **effective exposure**, not just `ss` output:
- Port may bind `0.0.0.0` but blocked by DOCKER-USER
- Port may bind `0.0.0.0` but blocked by provider firewall

**Note:** Provider firewall cannot be verified generically from host. This is **external/integration test**, not local verifier check.

---

## P3 Findings (Low Priority - Quality)

### 25. Ubuntu-Specific Comments (P3)
Comments like "Ubuntu 24.04 defaults to ssh.socket" should be generalized for multi-OS.

### 26. Cloud-Init Secrets Trust Boundary (P3)
If values transmitted via provider user-data, document provider as trust boundary. If generated only on host, mark N/A.

### 27. Traceability: Release Tag (P3)
Include release/tag or archive hash alongside commit SHA for accessibility when SHA is not publicly browsable.

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
| Debian 13 | ❌ Broken | ✅ | ❓ Not listed | ⬜ NEEDED | **PARTIAL** |

**Notes:**
- Ubuntu 26.04 overall is UNTESTED because Quick Installer doesn't list it and no E2E test exists
- Debian 13 is PARTIAL because OS detection is broken, not because Coolify doesn't support it

### Component Compatibility

| Component | Ubuntu 24.04 | Ubuntu 26.04 | Debian 13 |
|-----------|:------------:|:------------:|:---------:|
| OS Detection | ✅ | ⚠️ | ❌ |
| SSH Socket | ⚠️ Generator needs masking | ⚠️ Generator needs masking | ⚠️ May have ssh.socket active; test pending |
| UFW | ✅ | ✅ | ✅ |
| fail2ban | ✅ | ✅ | ✅ |
| Docker | ✅ | ⬜ | ✅ |
| Packages | ✅ | ✅ | ⚠️ `psmisc` may be missing |

---

## Implementation Roadmap

### Phase 1: P1 Fixes (Before Production)

| # | Change | Effort | Finding |
|---|--------|--------|---------|
| 1 | Mask `sshd-socket-generator` + reboot test | 1h | #1 |
| 2 | Fix `/data/coolify` permissions (dedicated user ownership) | 2h | #2 |
| 3 | Pin bootstrap to SHA + verify | 30m | #3 |
| 4 | Configurable `DEVOPS_USER_NOPASSWD` + cloud-init fix | 1h | #4 |
| 5 | Separate `DOCKER_USERS`, default empty | 1h | #5 |
| 6 | Declarative firewall model (structured config) | 3h | #6 |
| 7 | Hardened Coolify ports default + 8000 policy | 1h | #7 |
| 8 | Fix Debian 13 OS detection | 30m | #8 |

### Phase 2: P2 Hardening

| # | Change | Effort | Finding |
|---|--------|--------|---------|
| 9 | Document Coolify installer trust boundary | 30m | #9 |
| 10 | Add Coolify version guard (MIN/MAX) + upgrade test | 2h | #10 |
| 11 | Coolify auto-update configuration | 30m | #11 |
| 12 | Add `psmisc` dependency | 15m | #12 |
| 13 | SSH access modes (public/allowlist/vpn-only) | 2h | #13 |
| 14 | `SSH_TRUSTED_CIDRS` | 1h | #14 |
| 15 | Coolify localhost key subnet detection | 1h | #15 |
| 16 | Provider firewall documentation | 30m | #16 |
| 17 | `rp_filter` per-interface verification | 30m | #17 |
| 18 | unattended-upgrades full verification | 1h | #18 |
| 19 | 80/443 access policy documentation | 30m | #19 |
| 20 | Docker IPv6 workaround validation | 1h | #20 |
| 21 | APP_KEY backup documentation | 30m | #21 |
| 22 | SSH keys recovery documentation + test | 30m | #22 |
| 23 | Kernel reboot-required check | 15m | #23 |
| 24 | Effective exposure integration test | 1h | #24 |

### Phase 3: P3 Quality

| # | Change | Effort | Finding |
|---|--------|--------|---------|
| 25 | Generalize Ubuntu-specific comments | 30m | #25 |
| 26 | Cloud-init trust boundary documentation | 30m | #26 |
| 27 | Add release tag to audit traceability | 15m | #27 |

---

## Verifier Requirements

The verifier must become **policy-aware**. Current assertions become incorrect after hardening.

### Derive Expectations From Config

```bash
# Instead of hardcoded:
check_user_in_groups "$user" "sudo,docker,coolify"

# Policy-aware:
expected_groups="sudo"
[[ "$user" in "$DOCKER_USERS" ]] && expected_groups+=",docker"
[[ "$user" in "$COOLIFY_RUNTIME_USERS" ]] && expected_groups+=",coolify"
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
- [ ] Restore Coolify from backup
- [ ] APP_KEY recovery
- [ ] SSH keys recovery (control plane to remote servers)

#### Security
- [ ] Invalid/tampered Git SHA rejected
- [ ] Compromised user cannot write `/data/coolify` (after fix)

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
[3]: https://next.coolify.io/docs/core/infrastructure/servers/non-root-user "Coolify Non-root User"
[4]: https://coolify.io/docs/knowledge-base/server/non-root-user "Non-root user | Coolify Docs"
[5]: https://docs.docker.com/engine/install/linux-postinstall "Docker post-installation"
[6]: https://coolify.io/docs/knowledge-base/server/firewall "Firewall | Coolify Docs"
[7]: https://github.com/coollabsio/coolify/issues/10898 "Coolify API GitHub Issue"
[8]: https://coolify.io/docs/knowledge-base/self-update "Coolify Self-Update"
[9]: https://www.kernel.org/doc/html/v6.12/networking/ip-sysctl.html "Linux Kernel IP Sysctl"
[10]: https://ubuntu.com/server/docs/how-to/software/automatic-updates "Ubuntu Automatic Updates"
[11]: https://next.coolify.io/docs/core/infrastructure/servers/firewall "Coolify Firewall"
[12]: https://next.coolify.io/docs/core/security-model "Coolify Security Model"
[13]: https://coolify.io/docs/knowledge-base/how-to/backup-restore-coolify "Backup and Restore Coolify"

---

## Changelog

### v3.1 (September 9, 2026)
- **RECLASSIFIED:** #4 External Coolify Installer P1→P2 (accepted trust boundary)
- **RECLASSIFIED:** #5 Coolify Internals Coupling P1→P2 (compatibility risk, not security)
- **RECLASSIFIED:** #11 Coolify Auto-Update P1→P2 (operational hardening)
- **RECLASSIFIED:** #12 Missing fuser P1→P2 (bootstrap failure, not privilege escalation)
- **RECLASSIFIED:** SSH keys recovery P3→P2 (critical for control plane)
- **RECLASSIFIED:** Kernel reboot check P3→P2 (operational correctness)
- **FIXED:** Coolify Debian 13 support: ❓→✅ ("Debian-based...all versions supported")
- **FIXED:** Executive Summary "critical gaps" → "high-priority gaps" (no P0 findings)
- **FIXED:** Operational Robustness VERIFIED→PARTIAL (tests pending)
- **FIXED:** WireGuard example TCP→UDP (WireGuard uses UDP)
- **FIXED:** Debian 13 SSH matrix ✅→⚠️ (ssh.socket may be active, test pending)
- **IMPROVED:** Ubuntu 26.04 matrix: separate OS family support vs Quick Installer listing
- **IMPROVED:** Supply-chain status: "accepted but not version-pinned"
- **IMPROVED:** `EXTRA_UFW_RULES` → structured config recommendation
- **IMPROVED:** Coolify version guard → explicit MIN/MAX range
- **ADDED:** Testing matrix: OpenSSH package upgrade regression test
- **ADDED:** Testing matrix: Provider firewall scenarios
- **ADDED:** Effective exposure as external/integration test note
- **UPDATED:** P1 count 12→8, P2 count 10→16, P3 count 5→3

### v3.0 (September 9, 2026)
- **MAJOR REWRITE** integrating 48 external audit findings
- **ADDED** formal P0/P1/P2/P3 definitions
- **CHANGED** assessment from numeric scores to verifiable states (VERIFIED/PARTIAL/GAP/UNTESTED)
- **ADDED** repository commit SHA for traceability
- **NEW P1:** SSH socket generator masking required on Ubuntu 24.04
- **NEW P1:** `/data/coolify` group permissions too broad
- **NEW P1:** Supply-chain: Coolify installer trust boundary
- **NEW P1:** Coupling to Coolify internals (PHP Models)
- **NEW P1:** Coolify auto-update not disabled
- **NEW P1:** Missing `fuser`/`psmisc` dependency
- **RECLASSIFIED:** Mutable Git ref P0→P1 (requires repo compromise)
- **RECLASSIFIED:** Public SSH P0/P1→P2 (hardening, not vulnerability)
- **RECLASSIFIED:** Docker preinstall P1→P2 (hardening recommendation)
- **CLARIFIED:** UFW reset is P1 operational until declarative firewall
- **CHANGED:** Ubuntu 26.04 from "Full" to "UNTESTED"
- **ADDED** comprehensive testing matrix with failure/recovery cases
- **ADDED** verifier policy-awareness requirements

### v2.x (September 9, 2026)
- Initial versions and iterations

---

**Document End**
