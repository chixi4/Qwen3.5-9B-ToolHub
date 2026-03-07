function Normalize-EnvValue {
    param([string]$Value)

    $trimmed = $Value.Trim()
    if (-not $trimmed) {
        return ''
    }

    if ($trimmed.StartsWith('#')) {
        return ''
    }

    $hashIndex = $trimmed.IndexOf(' #')
    if ($hashIndex -ge 0) {
        $trimmed = $trimmed.Substring(0, $hashIndex).TrimEnd()
    }

    $hasQuotes = (
        ($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) -or
        ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'"))
    )
    if ($hasQuotes -and $trimmed.Length -ge 2) {
        return $trimmed.Substring(1, $trimmed.Length - 2)
    }
    return $trimmed
}

function Import-EnvFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return
    }

    foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) {
            continue
        }

        $delimiter = $trimmed.IndexOf('=')
        if ($delimiter -lt 1) {
            continue
        }

        $key = $trimmed.Substring(0, $delimiter).Trim()
        $value = Normalize-EnvValue -Value ($trimmed.Substring($delimiter + 1))
        if (-not $key -or (Test-Path "Env:$key")) {
            continue
        }
        [Environment]::SetEnvironmentVariable($key, $value, 'Process')
    }
}

function Resolve-ManagedPath {
    param(
        [string]$BaseDir,
        [string]$Value,
        [string]$DefaultRelativePath
    )

    $effective = if ([string]::IsNullOrWhiteSpace($Value)) { $DefaultRelativePath } else { $Value.Trim() }
    if ([string]::IsNullOrWhiteSpace($effective)) {
        return ''
    }
    if ([System.IO.Path]::IsPathRooted($effective)) {
        return $effective
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDir $effective))
}

function Ensure-EnvFile {
    param(
        [string]$Path,
        [string]$TemplatePath
    )

    if (Test-Path $Path) {
        return
    }
    if (Test-Path $TemplatePath) {
        Copy-Item -Path $TemplatePath -Destination $Path -Force
        return
    }
    Set-Content -Path $Path -Value @() -Encoding UTF8
}

function Set-EnvFileValue {
    param(
        [string]$Path,
        [string]$Key,
        [string]$Value
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $Path) {
        foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
            $lines.Add([string]$line)
        }
    }

    $replacement = "$Key=$Value"
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $updated = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) {
            $lines[$i] = $replacement
            $updated = $true
            break
        }
    }

    if (-not $updated) {
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines.Add('')
        }
        $lines.Add($replacement)
    }
    Set-Content -Path $Path -Value $lines -Encoding UTF8
}
