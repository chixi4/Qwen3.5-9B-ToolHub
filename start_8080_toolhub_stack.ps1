param(
    [string]$Command = 'status'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = (Resolve-Path $ScriptDir).Path
$EnvConfig = Join-Path $RootDir 'env_config.ps1'
if (Test-Path $EnvConfig) {
    . $EnvConfig
    Import-EnvFile -Path (Join-Path $RootDir '.env')
}
$PythonBin = Join-Path $RootDir '.venv-qwen35\Scripts\python.exe'
$GatewayRun = Join-Path $RootDir 'run_8080_toolhub_gateway.py'
$RuntimeDir = Join-Path $RootDir '.tmp\toolhub_gateway'
$PidFile = Join-Path $RuntimeDir 'gateway.pid'
$LogFile = Join-Path $RuntimeDir 'gateway.log'
$ErrLogFile = Join-Path $RuntimeDir 'gateway.err.log'
$ModelSwitch = Join-Path $RootDir 'switch_qwen35_webui.ps1'

$GatewayHost = if ($env:GATEWAY_HOST) { $env:GATEWAY_HOST } else { '127.0.0.1' }
$GatewayPort = if ($env:GATEWAY_PORT) { $env:GATEWAY_PORT } else { '8080' }
$BackendHost = if ($env:BACKEND_HOST) { $env:BACKEND_HOST } else { '127.0.0.1' }
$BackendPort = if ($env:BACKEND_PORT) { $env:BACKEND_PORT } else { '8081' }
$ThinkMode = if ($env:THINK_MODE) { $env:THINK_MODE } else { 'think-on' }

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Test-GatewayRunning {
    if (-not (Test-Path $PidFile)) {
        return $false
    }
    $raw = Get-Content -Path $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $gatewayPid = 0
    if (-not [int]::TryParse([string]$raw, [ref]$gatewayPid)) {
        return $false
    }
    $proc = Get-Process -Id $gatewayPid -ErrorAction SilentlyContinue
    return $null -ne $proc
}

function Test-GatewayReady {
    try {
        $null = Invoke-RestMethod -Uri "http://$GatewayHost`:$GatewayPort/gateway/health" -Method Get -TimeoutSec 2
        return $true
    } catch {
        return $false
    }
}

function Write-SpinnerLine {
    param(
        [string]$Label,
        [int]$Current,
        [int]$Total,
        [int]$Tick
    )
    $frames = @('|', '/', '-', '\')
    $frame = $frames[$Tick % $frames.Count]
    Write-Host -NoNewline "`r$Label $frame $Current/$Total 秒"
}

function Complete-SpinnerLine {
    Write-Host ''
}

function Stop-OrphanGatewayProcesses {
    try {
        $rootPattern = [regex]::Escape($RootDir)
        $targets = Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $cmd = [string]$_.CommandLine
            $cmd -match 'run_8080_toolhub_gateway\.py' -and $cmd -match $rootPattern
        }
        foreach ($proc in $targets) {
            if ($proc.ProcessId) {
                Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
}

function Start-Backend {
    if ($env:MODEL_KEY -and $env:MODEL_KEY -ne '9b') {
        throw "当前交付包仅支持 MODEL_KEY=9b，收到: $($env:MODEL_KEY)"
    }
    $oldHost = $env:HOST
    $oldPort = $env:PORT
    try {
        $env:HOST = $BackendHost
        $env:PORT = $BackendPort
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ModelSwitch '9b' $ThinkMode
        if ($LASTEXITCODE -ne 0) {
            throw "后端启动失败，exit code: $LASTEXITCODE"
        }
    } finally {
        $env:HOST = $oldHost
        $env:PORT = $oldPort
    }
}

function Start-Gateway {
    Ensure-Dir $RuntimeDir
    Stop-OrphanGatewayProcesses
    if (Test-GatewayRunning) {
        Write-Host '网关状态: 已运行'
        Write-Host "PID: $(Get-Content -Path $PidFile)"
        return
    }
    if (-not (Test-Path $PythonBin)) {
        throw "Python 环境不存在: $PythonBin"
    }

    $args = @(
        $GatewayRun,
        '--host', $GatewayHost,
        '--port', $GatewayPort,
        '--backend-base', "http://$BackendHost`:$BackendPort",
        '--model-server', "http://$BackendHost`:$BackendPort/v1"
    )
    if (Test-Path $ErrLogFile) {
        Remove-Item -Path $ErrLogFile -Force -ErrorAction SilentlyContinue
    }
    $proc = Start-Process -FilePath $PythonBin -ArgumentList $args -RedirectStandardOutput $LogFile -RedirectStandardError $ErrLogFile -PassThru
    Set-Content -Path $PidFile -Value $proc.Id -Encoding ascii

    for ($i = 0; $i -lt 60; $i++) {
        Write-SpinnerLine -Label '网关启动中...' -Current ($i + 1) -Total 60 -Tick $i
        if ((Test-GatewayRunning) -and (Test-GatewayReady)) {
            Complete-SpinnerLine
            return
        }
        Start-Sleep -Seconds 1
    }
    Complete-SpinnerLine

    if (Test-Path $LogFile) {
        Write-Host '网关启动失败，日志如下:'
        Get-Content -Path $LogFile -Tail 120
    }
    throw '网关启动失败。'
}

function Stop-Gateway {
    Stop-OrphanGatewayProcesses
    if (-not (Test-GatewayRunning)) {
        if (Test-Path $PidFile) {
            Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue
        }
        Write-Host '网关状态: 未运行'
        return
    }

    $gatewayPid = [int](Get-Content -Path $PidFile | Select-Object -First 1)
    Stop-Process -Id $gatewayPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    if (Test-Path $PidFile) {
        Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue
    }
    Write-Host '网关状态: 已停止'
}

function Show-Status {
    Write-Host '=== 网关 ==='
    if (Test-GatewayRunning) {
        $state = if (Test-GatewayReady) { '可访问' } else { '初始化中' }
        Write-Host '状态: 运行中'
        Write-Host "PID: $(Get-Content -Path $PidFile)"
        Write-Host "地址: http://$GatewayHost`:$GatewayPort"
        Write-Host "健康: $state"
        Write-Host "日志: $LogFile"
        Write-Host "错误日志: $ErrLogFile"
    } else {
        Write-Host '状态: 未运行'
    }

    Write-Host ''
    Write-Host '=== 模型后端 ==='
    $oldHost = $env:HOST
    $oldPort = $env:PORT
    try {
        $env:HOST = $BackendHost
        $env:PORT = $BackendPort
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ModelSwitch 'status'
    } finally {
        $env:HOST = $oldHost
        $env:PORT = $oldPort
    }
}

function Show-Logs {
    Write-Host '=== 网关日志 ==='
    if (Test-Path $LogFile) {
        Get-Content -Path $LogFile -Tail 120
    }
    if (Test-Path $ErrLogFile) {
        Write-Host '=== 网关错误日志 ==='
        Get-Content -Path $ErrLogFile -Tail 120
        return
    }
    Write-Host '暂无日志'
}

function Stop-Backend {
    $oldHost = $env:HOST
    $oldPort = $env:PORT
    try {
        $env:HOST = $BackendHost
        $env:PORT = $BackendPort
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ModelSwitch 'stop'
    } finally {
        $env:HOST = $oldHost
        $env:PORT = $oldPort
    }
}

function Start-Stack {
    Write-Host '步骤 1/2: 启动模型后端（严格 GPU 校验）'
    Start-Backend
    Write-Host '步骤 2/2: 启动网关服务'
    Start-Gateway
    Write-Host '栈已启动'
    Write-Host "前端入口: http://$GatewayHost`:$GatewayPort"
    Write-Host "模型后端: http://$BackendHost`:$BackendPort"
    Write-Host '可用状态检查命令: .\start_8080_toolhub_stack.cmd status'
}

function Stop-Stack {
    Stop-Gateway
    Stop-Backend
}

switch ($Command) {
    'start' { Start-Stack; break }
    'stop' { Stop-Stack; break }
    'restart' { Stop-Stack; Start-Stack; break }
    'status' { Show-Status; break }
    'logs' { Show-Logs; break }
    default {
        Write-Host '用法:'
        Write-Host '  .\\start_8080_toolhub_stack.cmd {start|stop|restart|status|logs}'
        Write-Host ''
        Write-Host '可选环境变量:'
        Write-Host '  GATEWAY_HOST=127.0.0.1'
        Write-Host '  GATEWAY_PORT=8080'
        Write-Host '  BACKEND_HOST=127.0.0.1'
        Write-Host '  BACKEND_PORT=8081'
        Write-Host '  THINK_MODE=think-on'
        exit 1
    }
}
