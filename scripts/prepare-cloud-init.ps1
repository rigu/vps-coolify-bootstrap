[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

Write-Warning "scripts/prepare-cloud-init.ps1 is deprecated. Use scripts/prepare-vps-coolify-init.ps1 instead."

$target = Join-Path $PSScriptRoot "prepare-vps-coolify-init.ps1"
& $target @RemainingArgs
exit $LASTEXITCODE
