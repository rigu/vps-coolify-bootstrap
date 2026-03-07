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
bash scripts/prepare-cloud-init.sh --help
bash scripts/generate-secrets.sh --help
```

If you modify `.ps1` scripts, also validate PowerShell syntax locally:

```powershell
$parseErrors = $null
Get-ChildItem scripts/*.ps1 | ForEach-Object {
  $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$parseErrors)
}
if ($parseErrors) { $parseErrors | ForEach-Object { Write-Error $_.Message }; exit 1 }
```

Run the same block in `pwsh` (PowerShell 7) or `powershell` (Windows PowerShell 5.x).

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
