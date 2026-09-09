# Multi-OS Compatibility & Security Audit Report

**Document Version:** 3.0  
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
| **P2** | Medium | Hardening recommendation. Defense-in-depth. Should fix but not blocker. | Broader-than-needed permissions, missing validation |
| **P3** | Low | Quality/documentation. Nice-to-have improvements. | Code comments, formatting, technical debt |

---

## Executive Summary

This report provides a comprehensive security audit of the `public-vps-coolify-bootstrap` project. Version 3.0 integrates findings from multiple review iterations and external security analysis.

### Overall Assessment

| Category | Status | Notes |
|----------|:------:|-------|
| Security Baseline | **PARTIAL** | Strong foundation, critical gaps in SSH persistence and group permissions |
| Operational Robustness | **VERIFIED** | Excellent verification tooling |
| Debian 13 Compatibility | **PARTIAL** | OS detection broken, core functionality works |
| Ubuntu 26.04 Compatibility | **UNTESTED** | Not validated by Coolify or this project |
| Supply-Chain Hardening | **GAP** | Mutable refs, external installers not audited |

### Key Findings Summary

| Priority | Count | Most Critical |
|:--------:|:-----:|---------------|
| **P1** | 12 | SSH socket generator not masked, `/data/coolify` group permissions, supply-chain boundaries |
| **P2** | 10 | RFC1918 SSH trust, Coolify auto-update, Docker preinstall recommendation |
| **P3** | 5 | Documentation, comments, technical debt |

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
Bootstrap sets root account credentials and seeds root user, reducing the risk of instance takeover via open registration. ([Coolify docs][1])

### 6. ✅ UFW in Packages List
Works on Debian 13 (not pre-installed there).

---

## P1 Findings (High Priority)

### 1. SSH Socket Generator Not Masked (P1) ⚠️ NEW

**Current Behavior:**
```bash
# bootstrap-host.sh
systemctl disable --now ssh.socket 2>/dev/null || true
```

**Problem:** On Ubuntu 24.04, `sshd-socket-generator` exists. Simply disabling `ssh.socket` is **not sufficient for persistent deactivation**. The generator can re-enable socket activation on boot.

**Evidence:** [Launchpad Ubuntu Noble openssh changelog][2]

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

### 2. `/data/coolify` Group Permissions Too Broad (P1) ⚠️ NEW

**Current Behavior:**
```bash
chgrp -R coolify /data/coolify
chmod -R g+rwX /data/coolify
# + all managed users added to coolify group
```

**Problem:** Combined with automatic `coolify` group membership for all managed users, a compromised SSH key grants **write access to Coolify runtime/config without sudo**.

**Required Fix:**
```bash
# Separate group roles
SUDO_USERS="..."
DOCKER_USERS="..."           # Explicit, default empty
COOLIFY_RUNTIME_USERS="..."  # Explicit, only Coolify user

# /data/coolify permissions
chown -R coolify:coolify /data/coolify
chmod -R o-rwx /data/coolify
# Sensitive files: owner-only (0600/0700)
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

### 4. Supply-Chain: External Coolify Installer (P1) ⚠️ NEW

**Current Behavior:**
```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

This installer can install Docker and download other artifacts. The repository documents `curl|bash` as a trade-off.

**Trust Boundaries (must be explicit):**

| Boundary | Trust Level | Notes |
|----------|:-----------:|-------|
| Own repository | Full | Pinned SHA required |
| Coolify installer | Accepted | Official, documented |
| Docker via Coolify | Transitive | Could be isolated |

**Recommendation (P2 hardening):** Pre-install Docker from official Docker repository, then Coolify installer doesn't need to bootstrap Docker via another remote installer.

---

### 5. Coupling to Coolify Internals (P1) ⚠️ NEW

**Current Behavior:**
Bootstrap runs PHP in container and directly accesses:
```php
\App\Models\Server
\App\Models\PrivateKey
InstanceSettings
id=0
```

**Problem:** These are not stable public APIs. A Coolify upgrade may break bootstrap.

**Required:**
- Use public API if available
- Add version guard
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

### 6. DEVOPS_USER has NOPASSWD:ALL (P1)

**Current Behavior:**
```
DEVOPS_USER → NOPASSWD:ALL
COOLIFY_USER → NOPASSWD:ALL
```

**Distinction:**
- `COOLIFY_USER`: NOPASSWD:ALL is **required** by Coolify non-root mode ([Coolify docs][3])
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

### 7. All Managed Users in Docker Group (P1)

**Current Behavior:**
`verify-bootstrap-state.sh` requires every managed user in `sudo`, `docker`, `coolify`.

**Problem:** Docker group is **root-equivalent** ([Docker docs][4]):
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

### 8. UFW Reset on Replay (P1 Operational)

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
# Make firewall fully declarative
MANAGEMENT_CIDRS="10.100.0.0/24"
EXTRA_ALLOWED_TCP_PORTS="51820"
EXTRA_ALLOWED_UDP_PORTS="51820"
EXTRA_UFW_RULES="allow from 10.200.0.0/24 to any port 9100"

# Generate complete ruleset deterministically
# reset + regenerate becomes reconciliation mechanism
```

---

### 9. Coolify Ports Not Hardened by Default (P1)

**Current Behavior:**
- `CLOSE_COOLIFY_REALTIME_PORTS=false` (default)
- Ports 6001, 6002 publicly accessible
- Port 8000 open during/after onboarding

**Coolify docs:** 8000/6001/6002 can be closed when dashboard served via custom domain ([Coolify docs][5])

**Required Fix:**
```bash
# Change defaults
CLOSE_COOLIFY_REALTIME_PORTS=true

# Port 8000 policy
# onboarding: operator CIDR/VPN only
# post-onboarding: deny public
```

---

### 10. Debian 13 OS Detection Broken (P1)

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

### 11. Coolify Auto-Update Not Disabled (P1) ⚠️ NEW

**Current Behavior:** Bootstrap doesn't pass `AUTOUPDATE=false` to Coolify installer.

**Problem:** Coolify self-hosted has auto-update enabled by default. Coolify docs recommend disabling for production ([Coolify docs][6]).

**Required Fix:**
```bash
# Pass to installer or configure after
COOLIFY_AUTOUPDATE=false

# Add verifier check
```

---

### 12. Missing `fuser` Dependency (P1) ⚠️ NEW

**Current Behavior:** `prepare-existing-server.sh` uses `fuser` for APT lock checks before installing prerequisites.

**Problem:** `fuser` (from `psmisc`) is not guaranteed on minimal images.

**Required Fix:**
```bash
# Add to prerequisites or check
command -v fuser &>/dev/null || apt-get install -y psmisc

# Audit all commands used before package installation:
# fuser, ss, visudo, systemctl, sysctl
```

---

## P2 Findings (Medium Priority - Hardening)

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

### 16. Docker Preinstall Recommendation (P2)

Pre-installing Docker from official Docker repository before running Coolify installer reduces supply-chain chaining.

**Status:** Hardening recommendation, not blocker. Coolify installer is accepted trust boundary.

---

### 17. Provider Firewall Layer (P2)

Coolify recommends provider firewall when available ([Coolify docs][5]).

For management VPS:
```
provider firewall + UFW + DOCKER-USER
```
is more robust than UFW alone.

---

### 18. `rp_filter=1` Verification (P2)

**Current:**
```bash
net.ipv4.conf.all.rp_filter=1
```

**Note:** Strict mode (`1`) is recommended for source spoofing protection. Loose mode (`2`) needed only for asymmetric/complex routing ([Kernel docs][7]).

**Required:** Verify per-interface if using WireGuard policy routing, multi-homing, or asymmetric routing. Don't reduce globally without demonstrated need.

---

### 19. unattended-upgrades Incomplete (P2)

**Current:** Only enables service.

**Required verification:**
```bash
apt-daily.timer enabled
apt-daily-upgrade.timer enabled
APT::Periodic::Update-Package-Lists != 0
APT::Periodic::Unattended-Upgrade != 0
Allowed-Origins not empty
```

Reference: [Ubuntu automatic updates][8]

---

### 20. 80/443 Architectural Decision (P2)

80/443 are normal for Coolify reverse-proxy ([Coolify docs][9]).

**Distinguish:**
- Public reverse-proxy endpoints → 80/443 ✓
- Administrative endpoints → access policy decision

Coolify UI exposure is policy decision, not bug.

---

### 21. Docker IPv6 Workaround Validation (P2)

**Current:** Heuristic may set `"ipv6": false` globally.

**Required:**
- Document upstream bug/issue ID
- Exact affected versions
- Exact fixed versions
- Regression test
- Don't disable IPv6 globally without demonstrating bug

---

### 22. Recovery: APP_KEY Off-Host (P2)

Coolify requires `APP_KEY` for secret decryption. Without it, restored secrets cannot be decrypted ([Coolify docs][10]).

**Required:** Document APP_KEY backup requirement.

---

## P3 Findings (Low Priority - Quality)

### 23. Ubuntu-Specific Comments (P3)
Comments like "Ubuntu 24.04 defaults to ssh.socket" should be generalized for multi-OS.

### 24. Recovery: SSH Keys Coolify (P3)
For migrated/recreated instance, Coolify SSH keys to remote servers must be recovered ([Coolify docs][11]).

### 25. Cloud-Init Secrets Trust Boundary (P3)
If values transmitted via provider user-data, document provider as trust boundary. If generated only on host, mark N/A.

### 26. Kernel Reboot Check (P3)
`package_upgrade: true` may install kernel without running it. Add post-bootstrap check for `/var/run/reboot-required`.

### 27. Document Traceability (P3)
Always include repository commit SHA in audit documents.

---

## OS Compatibility Matrix

### Support Levels Defined

| Level | Meaning |
|-------|---------|
| **VERIFIED** | Tested end-to-end by this project |
| **RECOGNIZED** | Bootstrap recognizes and accepts OS |
| **COOLIFY-SUPPORTED** | Listed in Coolify official docs |
| **UNTESTED** | Not validated |

### Current Status

| OS | Bootstrap Recognition | Coolify Support | Project Testing | Overall |
|----|:---------------------:|:---------------:|:---------------:|:-------:|
| Ubuntu 24.04 LTS | ✅ | ✅ ([docs][12]) | ⬜ NEEDED | **PARTIAL** |
| Ubuntu 26.04 LTS | ⚠️ Warning | ❓ Not listed | ⬜ NEEDED | **UNTESTED** |
| Debian 13 | ❌ Broken | ❓ Not listed | ⬜ NEEDED | **PARTIAL** |

**Note:** Ubuntu 26.04 should not be marked "Full" until:
1. Coolify officially supports it
2. End-to-end test completed by this project

### Component Compatibility

| Component | Ubuntu 24.04 | Ubuntu 26.04 | Debian 13 |
|-----------|:------------:|:------------:|:---------:|
| OS Detection | ✅ | ⚠️ | ❌ |
| SSH Socket | ⚠️ Generator | ⚠️ Generator | ✅ |
| UFW | ✅ | ✅ | ✅ |
| fail2ban | ✅ | ✅ | ✅ |
| Docker | ✅ | ⬜ | ✅ |
| Packages | ✅ | ✅ | ⚠️ `psmisc` |

---

## Implementation Roadmap

### Phase 1: P1 Fixes (Before Production)

| # | Change | Effort | Finding |
|---|--------|--------|---------|
| 1 | Mask `sshd-socket-generator` + reboot test | 1h | #1 |
| 2 | Fix `/data/coolify` permissions + separate groups | 2h | #2 |
| 3 | Pin bootstrap to SHA + verify | 30m | #3 |
| 4 | Document Coolify installer trust boundary | 30m | #4 |
| 5 | Add Coolify version guard + upgrade test | 2h | #5 |
| 6 | Configurable `DEVOPS_USER_NOPASSWD` + cloud-init fix | 1h | #6 |
| 7 | Separate `DOCKER_USERS`, default empty | 1h | #7 |
| 8 | Declarative firewall model | 3h | #8 |
| 9 | Hardened Coolify ports default + 8000 policy | 1h | #9 |
| 10 | Fix Debian 13 OS detection | 30m | #10 |
| 11 | Coolify `AUTOUPDATE=false` | 30m | #11 |
| 12 | Add `psmisc` dependency | 15m | #12 |

### Phase 2: P2 Hardening

| # | Change | Effort | Finding |
|---|--------|--------|---------|
| 13 | SSH access modes (public/allowlist/vpn-only) | 2h | #13 |
| 14 | `SSH_TRUSTED_CIDRS` | 1h | #14 |
| 15 | Coolify localhost key subnet detection | 1h | #15 |
| 16 | Docker preinstall option | 1h | #16 |
| 17 | Provider firewall documentation | 30m | #17 |
| 18 | `rp_filter` per-interface verification | 30m | #18 |
| 19 | unattended-upgrades full verification | 1h | #19 |
| 20 | 80/443 access policy documentation | 30m | #20 |
| 21 | Docker IPv6 workaround validation | 1h | #21 |
| 22 | APP_KEY backup documentation | 30m | #22 |

### Phase 3: P3 Quality

| # | Change | Effort | Finding |
|---|--------|--------|---------|
| 23 | Generalize Ubuntu-specific comments | 30m | #23 |
| 24 | SSH keys recovery documentation | 30m | #24 |
| 25 | Cloud-init trust boundary documentation | 30m | #25 |
| 26 | Kernel reboot check | 15m | #26 |
| 27 | Audit traceability standards | 15m | #27 |

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

### Effective Exposure Testing

`check_no_public_port()` must test **effective exposure**, not just `ss` output:
- Port may bind `0.0.0.0` but blocked by DOCKER-USER
- Port may bind `0.0.0.0` but blocked by provider firewall

---

## Testing Matrix

### Required Fresh Image Tests

| OS | Image Source | Provider | Status |
|----|--------------|----------|:------:|
| Ubuntu 24.04 | Official minimal | Hetzner | ⬜ |
| Ubuntu 26.04 | Official minimal | Hetzner | ⬜ |
| Debian 13 | Official minimal | Hetzner | ⬜ |

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

#### Firewall
- [ ] Custom rules preserved after declarative replay
- [ ] 8000/6001/6002 external reachability blocked
- [ ] DOCKER-USER rules effective

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
- [ ] SSH keys recovery

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

[1]: https://next.coolify.io/docs/start-with-self-hosted "Start with Self-hosted | Coolify Docs"
[2]: https://launchpad.net/ubuntu/noble/+source/openssh/+changelog "Ubuntu Noble openssh changelog"
[3]: https://coolify.io/docs/knowledge-base/server/non-root-user "Non-root user | Coolify Docs"
[4]: https://docs.docker.com/engine/install/linux-postinstall "Docker post-installation"
[5]: https://coolify.io/docs/knowledge-base/server/firewall "Firewall | Coolify Docs"
[6]: https://coolify.io/docs/knowledge-base/self-update "Coolify Self-Update"
[7]: https://www.kernel.org/doc/html/v6.12/networking/ip-sysctl.html "Linux Kernel IP Sysctl"
[8]: https://ubuntu.com/server/docs/how-to/software/automatic-updates "Ubuntu Automatic Updates"
[9]: https://next.coolify.io/docs/core/infrastructure/servers/firewall "Coolify Firewall"
[10]: https://next.coolify.io/docs/core/security-model "Coolify Security Model"
[11]: https://coolify.io/docs/knowledge-base/how-to/backup-restore-coolify "Backup and Restore Coolify"
[12]: https://coolify.io/docs/get-started/installation "Coolify Installation"

---

## Changelog

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

### v2.1 (September 9, 2026)
- Added P2/P3 findings from audit

### v2.0 (September 9, 2026)
- Integrated external security audit findings

### v1.x (September 9, 2026)
- Initial OS compatibility analysis

---

**Document End**
