# Contributing

Thanks for contributing.

## Scope

This is a **public generic bootstrap repo**. Contributions must stay generic and reusable.

Do not include:

- real domains/IPs/hostnames
- real credentials, tokens, private keys
- provider-account-specific data
- internal/private architecture notes

## Development flow

1. Fork and create a branch.
2. Make focused changes.
3. Run checks locally:

```bash
bash -n scripts/*.sh
shellcheck scripts/*.sh
python3 - <<'PY'
import yaml
for p in ("templates/vps-init.template.yml", "docs/_config.yml"):
    with open(p, "r", encoding="utf-8") as f:
        yaml.safe_load(f)
print("YAML OK")
PY
bash scripts/prepare-vps-coolify-init.sh --help
bash scripts/generate-secrets.sh --help
```

If you modify `.ps1` scripts, also validate PowerShell syntax locally:

```powershell
$parseErrors = @()
Get-ChildItem scripts/*.ps1 | ForEach-Object {
  $errors = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
  if ($errors -and $errors.Count -gt 0) {
    $parseErrors += "$($_.Name): $($errors | ForEach-Object { $_.Message } | Select-Object -First 1)"
  }
}
if ($parseErrors.Count -gt 0) { $parseErrors | ForEach-Object { Write-Error $_ }; exit 1 }
```

Run the same block in `pwsh` (PowerShell 7) or `powershell` (Windows PowerShell 5.x).

If you have a provisioned test VPS, also run server-side state verification:

```bash
sudo bash /opt/vps-coolify-bootstrap/scripts/verify-bootstrap-state.sh /etc/vps-coolify-bootstrap/bootstrap.env
```

4. Update docs when behavior changes.
5. Open PR with:
   - context/problem
   - change summary
   - verification steps

## Commit style

Use short imperative messages, for example:

- `docs: add post-onboarding security guidance`
- `feat: harden bootstrap ssh user policy`
- `fix: validate quoted env parsing in prepare script`

## Pull request checklist

- no private/sensitive data introduced
- docs and scripts are consistent
- bash syntax checks pass
- recovery path remains valid
