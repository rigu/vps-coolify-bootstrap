# Bootstrap Failure Recovery

Use this runbook when first-boot cloud-init did not finish successfully.
The sequence is explicit and safe to execute end-to-end.

## 0) Preparation (do not skip)

1. Keep provider web console access open (rescue path if SSH is broken).
2. Run recovery as `root` or with `sudo`.
3. Keep local source of truth ready:
   - local repo: `public-vps-coolify-bootstrap`
   - local env file: `env/bootstrap.env`
4. Set shell variables on your machine for faster copy/paste:

```bash
export SERVER_IP="<server-ip>"
export SSH_PORT="<ssh-port>"
export PRIMARY_SUDO_USER="<primary-sudo-user>"
```

## 1) Confirm cloud-init failure state

```bash
sudo cloud-init status --wait
sudo cloud-init status --long
sudo cloud-init query --all | head -n 40
```

If status is `done`, cloud-init finished and you should troubleshoot service-level issues instead.
If status is `error` or still not complete, continue.

## 2) Collect first error evidence

```bash
sudo tail -n 250 /var/log/cloud-init-output.log
sudo journalctl -u cloud-init -u cloud-config -u cloud-final --no-pager -n 250
sudo grep -Rni "error\\|failed\\|traceback" /var/log/cloud-init* 2>/dev/null | tail -n 80
```

Typical root causes:
- unresolved `CHANGE_ME` values in generated cloud-init
- invalid `SSH_PUBLIC_KEY` format
- clone failure for `BOOTSTRAP_REPO_URL` / `BOOTSTRAP_REPO_REF`
- transient apt/network failures during bootstrap

## 3) Validate minimum host baseline

```bash
primary_user="$(sudo sed -n 's/^PRIMARY_SUDO_USER=//p' /etc/vps-coolify-bootstrap/bootstrap.env | tr -d \"'\\r\")"
secondary_user="$(sudo sed -n 's/^SECONDARY_SUDO_USER=//p' /etc/vps-coolify-bootstrap/bootstrap.env | tr -d \"'\\r\")"
primary_user="${primary_user:-deploy}"
secondary_user="${secondary_user:-coolify}"
id "$primary_user" || true
id "$secondary_user" || true
command -v docker || true
sudo systemctl is-active ssh.socket ssh fail2ban unattended-upgrades || true
sudo ufw status verbose || true
```

If core services are missing/inactive, continue with manual bootstrap replay.

## 4) Ensure bootstrap repo exists on server

Check if cloud-init cloned the bootstrap repo:

```bash
sudo test -d /opt/vps-coolify-bootstrap && echo "repo present" || echo "repo missing"
```

If missing, recreate it with the same ref used by your env:

```bash
sudo rm -rf /opt/vps-coolify-bootstrap
sudo git clone --depth 1 --branch <BOOTSTRAP_REPO_REF> <BOOTSTRAP_REPO_URL> /opt/vps-coolify-bootstrap
```

Validate script path:

```bash
sudo test -f /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh && echo "script ok"
```

## 5) Ensure server env file exists and is correct

Required server env path:
- `/etc/vps-coolify-bootstrap/bootstrap.env`

If missing or incorrect, recreate it from your local `env/bootstrap.env` values.
Then verify required keys on server:

```bash
sudo awk -F= '/^(SSH_PORT|PRIMARY_SUDO_USER|SECONDARY_SUDO_USER|SSH_PUBLIC_KEY|CREATE_USERS|SUDO_USERS|DOCKER_USERS|COOLIFY_GROUP_USERS|COOLIFY_PUBLIC_DOMAIN|COOLIFY_ROOT_USERNAME|COOLIFY_ROOT_USER_EMAIL|COOLIFY_ROOT_USER_PASSWORD|USER_PASSWORDS_ENCRYPTION_PASSWORD)=/{print $1"=<set>"}' /etc/vps-coolify-bootstrap/bootstrap.env
```

Hard checks before replay:

```bash
if sudo grep -n "CHANGE_ME" /etc/vps-coolify-bootstrap/bootstrap.env; then
  echo "replace placeholders first"
fi
sudo sed -n 's/^COOLIFY_ROOT_USER_PASSWORD=//p' /etc/vps-coolify-bootstrap/bootstrap.env | tr -d "'\r" | awk '{print length($0)}'
sudo sed -n 's/^USER_PASSWORDS_ENCRYPTION_PASSWORD=//p' /etc/vps-coolify-bootstrap/bootstrap.env | tr -d "'\r" | awk '{print length($0)}'
```

Password length must be at least 16.

## 6) Replay bootstrap manually (authoritative recovery step)

Run:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/bootstrap-host.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

This script is idempotent and will:
- create/repair users and SSH keys
- enforce SSH runtime/config checks
- sync `AllowUsers` from `CREATE_USERS`
- reset/apply UFW baseline rules (`SSH_PORT`, `80`, `443`)
- enable `fail2ban` and `unattended-upgrades`
- install/start Coolify if missing
- enforce sudo/docker/coolify group memberships
- write sudo policy (passwordless only for primary sudo user by default)
- set passwords for users in `CREATE_USERS` if account password was locked/unset
- store generated credentials encrypted in `/etc/vps-coolify-bootstrap/user-passwords.enc`

Important: Docker-published ports can bypass UFW rules. Validate exposed ports
after recovery with `ss -tulpen` and `docker ps --format 'table {{.Names}}\t{{.Ports}}'`.

## 7) Validate recovery on server

```bash
sudo systemctl is-active ssh.socket ssh fail2ban unattended-upgrades
sudo ufw status verbose
sudo docker ps --format 'table {{.Names}}\t{{.Status}}'
primary_user="$(sudo sed -n 's/^PRIMARY_SUDO_USER=//p' /etc/vps-coolify-bootstrap/bootstrap.env | tr -d \"'\\r\")"
primary_user="${primary_user:-deploy}"
id "$primary_user" || true
getent group sudo docker coolify
```

Expected:
- SSH services active
- UFW enabled and allowing configured SSH port + `80/443`
- Docker available
- Coolify container running (name usually `coolify`)

## 8) Validate remote access from your machine

```bash
ssh -p "$SSH_PORT" "$PRIMARY_SUDO_USER@$SERVER_IP" "whoami && hostname && id"
```

If login fails but provider console works, re-check:
- `SSH_PORT` value in server env
- firewall rule for that port (`ufw status`)
- user presence in `/etc/passwd` and authorized key content

## 9) If replay still fails, capture focused diagnostics

```bash
sudo journalctl -xe --no-pager -n 200
sudo tail -n 200 /var/log/auth.log
sudo tail -n 200 /var/log/ufw.log 2>/dev/null || true
sudo docker logs coolify --tail 200 2>/dev/null || true
```

Fix the specific failing cause, then rerun Step 6.

## 10) Clean rebuild path (last resort)

Use this only if server state is inconsistent or unrecoverable.

1. On local machine, reset to clean env baseline:
```bash
cp env/bootstrap.env.example env/bootstrap.env
bash scripts/generate-secrets.sh --env-file env/bootstrap.env
```
   Windows PowerShell alternative:
```powershell
Copy-Item env/bootstrap.env.example env/bootstrap.env
pwsh -File scripts/generate-secrets.ps1 -EnvFile env/bootstrap.env
```
2. Fill all required values in `env/bootstrap.env` (no `CHANGE_ME`).
3. Regenerate cloud-init:
```bash
bash scripts/prepare-cloud-init.sh --env-file env/bootstrap.env --overwrite
```
   Windows PowerShell alternative:
```powershell
pwsh -File scripts/prepare-cloud-init.ps1 -EnvFile env/bootstrap.env -Overwrite
```
4. Verify generated file is placeholder-free:
```bash
if grep -n "CHANGE_ME\\|_HERE" cloud-init.generated.yml; then
  echo "fix placeholders before provisioning"
fi
```
5. Recreate VPS with `cloud-init.generated.yml` as user-data.
6. Re-validate using Steps 1, 7, and 8.

## Decrypt generated user credentials (when needed)

```bash
export USER_PASSWORDS_ENCRYPTION_PASSWORD="<value-from-bootstrap.env>"
sudo openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in /etc/vps-coolify-bootstrap/user-passwords.enc \
  -pass env:USER_PASSWORDS_ENCRYPTION_PASSWORD
```
