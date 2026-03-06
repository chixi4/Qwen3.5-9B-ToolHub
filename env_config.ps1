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
