[CmdletBinding()]
param(
    [string]$EnvFile = "bootstrap-artifacts/plane.env",
    [string]$TemplateFile = "templates/plane-coolify-compose.community.v1.2.3.full-with-proxy.yml",
    [string]$OutputFile = "bootstrap-artifacts/plane-coolify-compose.community.v1.2.3.full-with-proxy.yml",
    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Host "[$Level] [$ts] [prepare-plane-compose.ps1] $Message"
}

function Write-Info([string]$Message) { Write-Log -Level "INFO" -Message $Message }
function Write-Success([string]$Message) { Write-Log -Level "SUCCESS" -Message $Message }
function Write-ErrorLog([string]$Message) { Write-Log -Level "ERROR" -Message $Message }

function Strip-EnvQuotes {
    param([string]$Value)
    if ($Value.StartsWith("'") -and $Value.EndsWith("'")) { return $Value.Substring(1, $Value.Length - 2) }
    if ($Value.StartsWith('"') -and $Value.EndsWith('"')) { return $Value.Substring(1, $Value.Length - 2) }
    return $Value
}

function Load-EnvMap {
    param([string]$Path)
    $map = @{}
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { continue }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { throw "Invalid env line: $rawLine" }
        $key = $line.Substring(0, $idx).Trim()
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Invalid env key: $key"
        }
        $value = $line.Substring($idx + 1).Trim()
        $map[$key] = Strip-EnvQuotes -Value $value
    }
    return $map
}

function Resolve-ComposeExpr {
    param(
        [string]$Expr,
        [hashtable]$EnvMap
    )
    $m = [regex]::Match($Expr, '^(?<name>[A-Za-z_][A-Za-z0-9_]*)(?:(?<op>:\-|\-|:\?|\?|:\+|\+)(?<arg>.*))?$', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) {
        throw "unsupported compose interpolation expression: `${$Expr}"
    }

    $name = $m.Groups["name"].Value
    $op = $m.Groups["op"].Value
    $arg = $m.Groups["arg"].Value
    $isSet = $EnvMap.ContainsKey($name)
    $value = if ($isSet) { [string]$EnvMap[$name] } else { "" }

    switch ($op) {
        "" {
            if ($isSet) { return $value }
            return ""
        }
        ":-" {
            if ($isSet -and -not [string]::IsNullOrEmpty($value)) { return $value }
            return $arg
        }
        "-" {
            if ($isSet) { return $value }
            return $arg
        }
        ":?" {
            if ($isSet -and -not [string]::IsNullOrEmpty($value)) { return $value }
            if (-not [string]::IsNullOrWhiteSpace($arg)) { throw $arg }
            throw "$name is required"
        }
        "?" {
            if ($isSet) { return $value }
            if (-not [string]::IsNullOrWhiteSpace($arg)) { throw $arg }
            throw "$name is required"
        }
        ":+" {
            if ($isSet -and -not [string]::IsNullOrEmpty($value)) { return $arg }
            return ""
        }
        "+" {
            if ($isSet) { return $arg }
            return ""
        }
        default {
            throw "unsupported compose interpolation operator in: `${$Expr}"
        }
    }
}

function Interpolate-ComposeLine {
    param(
        [string]$Line,
        [hashtable]$EnvMap
    )

    if ($Line.TrimStart().StartsWith("#")) {
        return $Line
    }

    $result = $Line
    for ($i = 0; $i -lt 1000; $i++) {
        $state = [pscustomobject]@{ Changed = $false }
        $result = [regex]::Replace($result, '\$\{([^{}]+)\}', {
            param($match)
            $state.Changed = $true
            Resolve-ComposeExpr -Expr $match.Groups[1].Value -EnvMap $EnvMap
        })

        if (-not $state.Changed) {
            return $result
        }
    }

    throw "interpolation depth exceeded (possible recursive expression)"
}

try {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $envPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $repoRoot $EnvFile }
    $templatePath = if ([System.IO.Path]::IsPathRooted($TemplateFile)) { $TemplateFile } else { Join-Path $repoRoot $TemplateFile }
    $outputPath = if ([System.IO.Path]::IsPathRooted($OutputFile)) { $OutputFile } else { Join-Path $repoRoot $OutputFile }
    $envExamplePath = Join-Path $repoRoot "env/plane-coolify.env.example"

    Write-Info "prepare-plane-compose parameters: env_file=$envPath, template_file=$templatePath, output_file=$outputPath, overwrite=$([bool]$Overwrite)"

    if (Test-Path -LiteralPath $envPath -PathType Container) { throw "--env-file points to a directory, expected a file: $envPath" }
    if (Test-Path -LiteralPath $templatePath -PathType Container) { throw "--template-file points to a directory, expected a file: $templatePath" }
    if (Test-Path -LiteralPath $outputPath -PathType Container) { throw "--output-file points to a directory, expected a file path: $outputPath" }

    if (-not (Test-Path -LiteralPath $envExamplePath -PathType Leaf)) { throw "required env example missing: $envExamplePath" }
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw "required template missing: $templatePath" }

    $envDir = Split-Path -Parent $envPath
    if (-not [string]::IsNullOrWhiteSpace($envDir) -and -not (Test-Path -LiteralPath $envDir -PathType Container)) {
        New-Item -ItemType Directory -Path $envDir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        Copy-Item -LiteralPath $envExamplePath -Destination $envPath
        Write-Success "Created env file from template: $envPath"
    }

    if ((Test-Path -LiteralPath $outputPath -PathType Leaf) -and -not $Overwrite) {
        throw "output already exists: $outputPath (use -Overwrite)"
    }

    $outputDir = Split-Path -Parent $outputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    Write-Info "Loading Plane env from: $envPath"
    $envMap = Load-EnvMap -Path $envPath
    Write-Success "Plane env loaded."

    Write-Info "Rendering template compose interpolation values."
    $templateText = Get-Content -LiteralPath $templatePath -Raw

    # Preserve original line endings by normalizing to LF in rendered output.
    $rendered = New-Object System.Collections.Generic.List[string]
    foreach ($line in $templateText -split "`r`n|`n|`r") {
        $rendered.Add((Interpolate-ComposeLine -Line $line -EnvMap $envMap))
    }
    $final = ($rendered -join "`n")

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($outputPath, $final, $utf8NoBom)

    Write-Success "Rendered Plane compose written to: $outputPath"
    Write-Info "Source template: $templatePath"
    Write-Info "Source env: $envPath"
    Write-Success "prepare-plane-compose.ps1 completed successfully."
} catch {
    Write-ErrorLog $_.Exception.Message
    exit 1
}
