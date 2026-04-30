[CmdletBinding()]
param(
    [string]$EnvFile = "bootstrap-artifacts/docmost.env",
    [string]$TemplateFile = "templates/docmost-coolify-compose.community.template.yml",
    [string]$OutputFile = "bootstrap-artifacts/docmost-coolify-compose.community.yml",
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
    Write-Host "[$Level] [$ts] [prepare-docmost-compose.ps1] $Message"
}

function Write-Info([string]$Message) { Write-Log -Level "INFO" -Message $Message }
function Write-Success([string]$Message) { Write-Log -Level "SUCCESS" -Message $Message }
function Write-Warn([string]$Message) { Write-Log -Level "WARNING" -Message $Message }
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
        $line = [string]$rawLine
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.TrimStart().StartsWith("#")) { continue }

        $m = [regex]::Match($line, '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$')
        if (-not $m.Success) { throw "Invalid env line: $rawLine" }

        $key = $m.Groups[1].Value
        $value = $m.Groups[2].Value.Trim()
        $map[$key] = Strip-EnvQuotes -Value $value
    }
    return $map
}

function Resolve-ComposeExpr {
    param(
        [string]$Expr,
        [hashtable]$EnvMap,
        [switch]$PreserveToken
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
    $preserveRuntimeToken = (-not $isSet) -and [string]::IsNullOrEmpty($op) -and $name.StartsWith("COOLIFY_")

    if (-not [string]::IsNullOrEmpty($arg) -and $arg.Contains('${')) {
        $arg = Process-ComposeText -Text $arg -EnvMap $EnvMap -PreserveTokens:$false
    }

    if ($PreserveToken) {
        if ($preserveRuntimeToken) {
            return ('${' + $name + '}')
        }
        $defaultValue = ""
        switch ($op) {
            ":?" {
                if ($isSet -and -not [string]::IsNullOrEmpty($value)) {
                    $defaultValue = $value
                } else {
                    if (-not [string]::IsNullOrWhiteSpace($arg)) { throw $arg }
                    throw "$name is required"
                }
            }
            "?" {
                if ($isSet) {
                    $defaultValue = $value
                } else {
                    if (-not [string]::IsNullOrWhiteSpace($arg)) { throw $arg }
                    throw "$name is required"
                }
            }
            default {
                if ($isSet) {
                    $defaultValue = $value
                } elseif ($op -eq ":-" -or $op -eq "-") {
                    $defaultValue = $arg
                } elseif ($op -eq ":+" -or $op -eq "+") {
                    $defaultValue = ""
                } else {
                    $defaultValue = ""
                }
            }
        }

        if ($defaultValue.Contains("`n") -or $defaultValue.Contains("`r")) {
            throw "$name default value contains a newline and cannot be used in interpolation."
        }
        if ($defaultValue.Contains("}")) {
            throw "$name default value contains '}' and cannot be used in interpolation."
        }

        return ('${' + $name + ':-' + $defaultValue + '}')
    }

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

function Parse-ComposeToken {
    param(
        [string]$Text,
        [int]$StartIndex
    )

    if (($StartIndex + 1) -ge $Text.Length -or $Text[$StartIndex] -ne '$' -or $Text[$StartIndex + 1] -ne '{') {
        throw "internal parse error: token does not start with `${"
    }

    $i = $StartIndex + 2
    $depth = 1

    while ($i -lt $Text.Length) {
        if (($i + 1) -lt $Text.Length -and $Text[$i] -eq '$' -and $Text[$i + 1] -eq '{') {
            $depth++
            $i += 2
            continue
        }
        if ($Text[$i] -eq '}') {
            $depth--
            if ($depth -eq 0) {
                $exprStart = $StartIndex + 2
                $expr = $Text.Substring($exprStart, $i - $exprStart)
                return [pscustomobject]@{
                    Expression = $expr
                    EndIndex = $i + 1
                }
            }
        }
        $i++
    }

    throw "unclosed compose interpolation token"
}

function Process-ComposeText {
    param(
        [string]$Text,
        [hashtable]$EnvMap,
        [switch]$PreserveTokens
    )

    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $Text.Length) {
        if (($i + 1) -lt $Text.Length -and $Text[$i] -eq '$' -and $Text[$i + 1] -eq '{') {
            $token = Parse-ComposeToken -Text $Text -StartIndex $i
            $resolved = Resolve-ComposeExpr -Expr $token.Expression -EnvMap $EnvMap -PreserveToken:$PreserveTokens
            [void]$sb.Append($resolved)
            $i = [int]$token.EndIndex
            continue
        }
        [void]$sb.Append($Text[$i])
        $i++
    }
    return $sb.ToString()
}

try {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $envPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $repoRoot $EnvFile }
    $templatePath = if ([System.IO.Path]::IsPathRooted($TemplateFile)) { $TemplateFile } else { Join-Path $repoRoot $TemplateFile }
    $outputPath = if ([System.IO.Path]::IsPathRooted($OutputFile)) { $OutputFile } else { Join-Path $repoRoot $OutputFile }
    $envExamplePath = Join-Path $repoRoot "env/docmost-coolify.env.example"

    Write-Info "prepare-docmost-compose parameters: env_file=$envPath, template_file=$templatePath, output_file=$outputPath, overwrite=$([bool]$Overwrite)"

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

    Write-Info "Loading Docmost env from: $envPath"
    $envMap = Load-EnvMap -Path $envPath
    Write-Success "Docmost env loaded."

    Write-Info "Rendering template compose interpolation values."
    $templateText = Get-Content -LiteralPath $templatePath -Raw

    $rendered = New-Object System.Collections.Generic.List[string]
    foreach ($line in $templateText -split "`r`n|`n|`r") {
        if ($line.TrimStart().StartsWith("#")) {
            $rendered.Add($line)
            continue
        }
        $rendered.Add((Process-ComposeText -Text $line -EnvMap $envMap -PreserveTokens:$true))
    }
    $final = ($rendered -join "`n")

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($outputPath, $final, $utf8NoBom)
    if ($IsLinux -or $IsMacOS) {
        if (Get-Command chmod -ErrorAction SilentlyContinue) {
            & chmod 600 -- $outputPath *> $null
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "Could not apply chmod 600 to rendered output: $outputPath"
            }
        }
    }

    Write-Success "Rendered Docmost compose written to: $outputPath"
    Write-Info "Source template: $templatePath"
    Write-Info "Source env: $envPath"
    Write-Success "prepare-docmost-compose.ps1 completed successfully."
} catch {
    Write-ErrorLog $_.Exception.Message
    exit 1
}
