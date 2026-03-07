param()

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = (Resolve-Path $ScriptDir).Path
$EnvConfig = Join-Path $RootDir 'env_config.ps1'
if (-not (Test-Path $EnvConfig)) {
    throw "未找到 env_config.ps1: $EnvConfig"
}
. $EnvConfig

$EnvFile = Join-Path $RootDir '.env'
$EnvExample = Join-Path $RootDir '.env.example'
$InstallScript = Join-Path $RootDir 'install.win.ps1'
$Q8RelativePath = '.tmp/models/crossrepo/lmstudio-community__Qwen3.5-9B-GGUF/Qwen3.5-9B-Q8_0.gguf'
$MmprojRelativePath = '.tmp/models/crossrepo/lmstudio-community__Qwen3.5-9B-GGUF/mmproj-Qwen3.5-9B-BF16.gguf'
$Q8Url = 'https://huggingface.co/lmstudio-community/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q8_0.gguf'
$MmprojUrl = 'https://huggingface.co/lmstudio-community/Qwen3.5-9B-GGUF/resolve/main/mmproj-Qwen3.5-9B-BF16.gguf'

function Write-Step {
    param([string]$Message)
    Write-Host "[install_q8] $Message"
}

function Set-ProcessEnvValue {
    param(
        [string]$Key,
        [string]$Value
    )
    [Environment]::SetEnvironmentVariable($Key, $Value, 'Process')
}

function Update-Q8Env {
    Ensure-EnvFile -Path $EnvFile -TemplatePath $EnvExample
    Set-EnvFileValue -Path $EnvFile -Key 'MODEL_PATH' -Value $Q8RelativePath
    Set-EnvFileValue -Path $EnvFile -Key 'MMPROJ_PATH' -Value $MmprojRelativePath
    Set-EnvFileValue -Path $EnvFile -Key 'MODEL_GGUF_URL' -Value $Q8Url
    Set-EnvFileValue -Path $EnvFile -Key 'MODEL_MMPROJ_URL' -Value $MmprojUrl
    Set-EnvFileValue -Path $EnvFile -Key 'MODEL_GGUF_SHA256' -Value ''
    Set-EnvFileValue -Path $EnvFile -Key 'MODEL_MMPROJ_SHA256' -Value ''
}

function Main {
    if (-not (Test-Path $InstallScript)) {
        throw "未找到安装脚本: $InstallScript"
    }
    Update-Q8Env
    Set-ProcessEnvValue -Key 'MODEL_PATH' -Value $Q8RelativePath
    Set-ProcessEnvValue -Key 'MMPROJ_PATH' -Value $MmprojRelativePath
    Set-ProcessEnvValue -Key 'MODEL_GGUF_URL' -Value $Q8Url
    Set-ProcessEnvValue -Key 'MODEL_MMPROJ_URL' -Value $MmprojUrl
    Set-ProcessEnvValue -Key 'MODEL_GGUF_SHA256' -Value ''
    Set-ProcessEnvValue -Key 'MODEL_MMPROJ_SHA256' -Value ''
    Write-Step "已写入 .env: MODEL_PATH=$Q8RelativePath"
    Write-Step '已切换到 Q8 量化下载源，开始执行 install.win.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallScript
    if ($LASTEXITCODE -ne 0) {
        throw "Q8 安装失败，exit code: $LASTEXITCODE"
    }
}

Main
