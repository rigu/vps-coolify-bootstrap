---
title: Security Trust Boundaries
nav_order: 20
---

# Security Trust Boundaries

This document describes the external dependencies and trust boundaries
involved in the VPS bootstrap process.

## Cloud-Init Trust Boundary (P2 #27)

**Trust assumption:** The cloud provider delivers user-data to the VPS without
tampering during the boot process.

**Risk:** If the provider's metadata service is compromised, malicious user-data
could be injected.

**Mitigation:**
- Use HTTPS-only provider APIs
- Verify provider's security practices
- Monitor first-boot logs for anomalies

Reference: [cloud-init security](https://docs.cloud-init.io/en/latest/explanation/security.html)

## Coolify Installer Trust Boundary (P2 #9)

**Trust assumption:** The official Coolify installer at `cdn.coollabs.io` is
delivered securely and has not been tampered with.

**What bootstrap does:**
```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

**Risks:**
1. CDN compromise could serve malicious installer
2. MITM attacks (mitigated by HTTPS)
3. Supply chain attacks on Coolify dependencies

**Mitigations in place:**
- HTTPS-only download
- Coolify version guard (COOLIFY_MIN_VERSION / COOLIFY_MAX_VERSION)
- AUTOUPDATE=false prevents unexpected version changes

**Additional hardening (recommended for high-security environments):**
- Download installer, audit contents, host on private infrastructure
- Pin to specific Coolify release SHA
- Run installer in isolated environment first

Reference: [Coolify installation](https://coolify.io/docs/installation)

## Bootstrap Repository Trust Boundary (P1 #3)

**Trust assumption:** The bootstrap repository content matches the expected SHA.

**Mitigation:**
- `BOOTSTRAP_EXPECTED_SHA` variable for supply-chain integrity
- If set, bootstrap aborts when fetched commit doesn't match
- Tags/branches can be moved; SHA provides immutable reference

**Best practice:**
```bash
# Get current SHA for production deployment
git ls-remote https://github.com/rigu/vps-coolify-bootstrap.git main

# Set in bootstrap.env
BOOTSTRAP_EXPECTED_SHA=abc123def456...
```

## Provider Firewall vs Host Firewall (P2 #16)

**Important:** UFW (host firewall) protects against traffic that reaches the
VPS. Provider-level firewalls (Hetzner Firewall, AWS Security Groups, etc.)
filter traffic before it reaches the VPS.

**Recommendation:**
- Configure provider firewall as first line of defense
- Keep UFW as defense-in-depth
- Ensure both are consistent

**Provider firewall should allow:**
- TCP ${SSH_PORT} (from MANAGEMENT_CIDRS if provider supports)
- TCP 80, 443 (HTTP/HTTPS)
- Additional ports as needed (EXTRA_ALLOWED_TCP_PORTS, EXTRA_ALLOWED_UDP_PORTS)

Reference: Provider-specific documentation:
- [Hetzner Cloud Firewalls](https://docs.hetzner.com/cloud/firewalls/overview/)
- [AWS Security Groups](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_SecurityGroups.html)

## Port 80/443 Access Policy (P2 #19)

**Default policy:** Open to all (0.0.0.0/0, ::/0)

**Rationale:**
- Ports 80/443 are managed by Traefik (reverse proxy)
- Traefik handles TLS termination and routing
- Application-level access control is done via Coolify/Traefik

**For restricted access:**
- Use Traefik middleware for IP allowlisting
- Configure Coolify application-level restrictions
- Consider provider firewall for geographic restrictions

## APP_KEY Backup Considerations (P2 #21)

**Critical:** Coolify's APP_KEY is used for encryption. Losing it means:
- Unable to decrypt stored secrets
- Need to reconfigure all applications

**Backup strategy:**
1. After initial Coolify setup, backup `/data/coolify/source/.env`
2. Store APP_KEY in secure vault (HashiCorp Vault, AWS Secrets Manager, etc.)
3. Document recovery procedure

**Recovery:**
```bash
# From backup
grep APP_KEY /path/to/backup/.env
# Set in Coolify .env
vim /data/coolify/source/.env
# Restart Coolify
docker restart coolify
```

## SSH Keys Recovery (P2 #22)

**Authorized keys locations:**
- `/home/${DEVOPS_USER}/.ssh/authorized_keys`
- `/home/${COOLIFY_SUDO_NOPASSWD_USER}/.ssh/authorized_keys`
- `/data/coolify/ssh/keys/` (Coolify localhost keys)

**Recovery procedure:**
1. Use provider console access
2. Run `recover-ssh-access.sh` with backup keys
3. Verify with `verify-bootstrap-state.sh`

**Prevention:**
- Always maintain multiple SSH key copies
- Test key rotation procedure before production
- Keep provider console access credentials secure

## Coolify Version Compatibility (P2 #10, #23)

**Bootstrap tested range:** ${COOLIFY_MIN_VERSION:-4.0.0} - ${COOLIFY_MAX_VERSION:-4.99.99}

**Version guard behavior:**
- Version within range: proceed normally
- Version outside range: warn and proceed (operators responsibility)
- Version unknown: warn and proceed

**For disaster recovery:**
- Record Coolify version in deployment manifest
- Document Coolify version in infrastructure runbook
- Test recovery with matching version

## Summary Checklist

Before production deployment:

- [ ] Review Coolify installer (or use audited copy)
- [ ] Set BOOTSTRAP_EXPECTED_SHA for repository integrity
- [ ] Configure provider firewall alongside UFW
- [ ] Backup APP_KEY after Coolify initialization
- [ ] Document SSH key recovery procedure
- [ ] Record Coolify version in deployment manifest
- [ ] Test recovery procedure in staging environment
