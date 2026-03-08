param(
    [string]$Command = 'status',
    [string]$ThinkMode = 'think-on'
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
$BinPath = if ($env:BIN_PATH) { $env:BIN_PATH } else { Join-Path $RootDir '.tmp\llama_win_cuda\llama-server.exe' }
$HostAddr = if ($env:HOST) { $env:HOST } else { '127.0.0.1' }
$PortNum = if ($env:PORT) { $env:PORT } else { '8081' }
$CtxSize = if ($env:CTX_SIZE) { $env:CTX_SIZE } else { '16384' }
$ImageMinTokens = if ($env:IMAGE_MIN_TOKENS) { $env:IMAGE_MIN_TOKENS } else { '256' }
$ImageMaxTokens = if ($env:IMAGE_MAX_TOKENS) { $env:IMAGE_MAX_TOKENS } else { '1024' }
$MmprojOffload = if ($env:MMPROJ_OFFLOAD) { $env:MMPROJ_OFFLOAD } else { 'off' }
$ModelPath = Resolve-ManagedPath -BaseDir $RootDir -Value $env:MODEL_PATH -DefaultRelativePath '.tmp\models\crossrepo\lmstudio-community__Qwen3.5-9B-GGUF\Qwen3.5-9B-Q4_K_M.gguf'
$MmprojPath = Resolve-ManagedPath -BaseDir $RootDir -Value $env:MMPROJ_PATH -DefaultRelativePath '.tmp\models\crossrepo\lmstudio-community__Qwen3.5-9B-GGUF\mmproj-Qwen3.5-9B-BF16.gguf'
$WebuiDir = Join-Path $RootDir '.tmp\webui'
$PidFile = Join-Path $WebuiDir 'llama_server.pid'
$CurrentLogFile = Join-Path $WebuiDir 'current.log'
$CurrentErrLogFile = Join-Path $WebuiDir 'current.err.log'
$GpuMemoryDeltaMinMiB = if ($env:GPU_MEMORY_DELTA_MIN_MIB) { $env:GPU_MEMORY_DELTA_MIN_MIB } else { '1024' }
$BackendReadyTimeoutSec = if ($env:BACKEND_READY_TIMEOUT_SEC) { $env:BACKEND_READY_TIMEOUT_SEC } else { '180' }
$GpuVerifyTimeoutSec = if ($env:GPU_VERIFY_TIMEOUT_SEC) { $env:GPU_VERIFY_TIMEOUT_SEC } else { '180' }
$SpinnerFrameIntervalMs = 120
$SpinnerProbeIntervalMs = 1000

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Test-Health {
    try {
        $null = Invoke-RestMethod -Uri "http://$HostAddr`:$PortNum/health" -Method Get -TimeoutSec 2
        return $true
    } catch {
        return $false
    }
}

function Get-ModelId {
    try {
        $models = Invoke-RestMethod -Uri "http://$HostAddr`:$PortNum/v1/models" -Method Get -TimeoutSec 3
        if ($models.data -and $models.data.Count -gt 0) {
            return [string]$models.data[0].id
        }
        return ''
    } catch {
        return ''
    }
}

function Write-SpinnerLine {
    param(
        [string]$Label,
        [double]$Current,
        [int]$Total,
        [int]$Tick
    )
    $frames = @('|', '/', '-', '\')
    $frame = $frames[$Tick % $frames.Count]
    $currentText = [string][int][Math]::Floor($Current)
    Write-Host -NoNewline "`r$Label $frame $currentText/$Total 秒"
}

function Complete-SpinnerLine {
    Write-Host ''
}

function Test-ProcessRunning {
    param([int]$ProcessId)
    try {
        $null = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Wait-Ready {
    param([int]$ProcessId)
    $timeoutSec = [int]$BackendReadyTimeoutSec
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $nextProbeMs = 0
    $tick = 0
    while ($stopwatch.Elapsed.TotalSeconds -lt $timeoutSec) {
        Write-SpinnerLine -Label '后端加载中...' -Current $stopwatch.Elapsed.TotalSeconds -Total $timeoutSec -Tick $tick
        if ($stopwatch.ElapsedMilliseconds -ge $nextProbeMs) {
            if (-not (Test-ProcessRunning -ProcessId $ProcessId)) {
                Complete-SpinnerLine
                return @{ Ready = $false; Reason = 'llama-server 进程已提前退出' }
            }
            if (Test-Health) {
                $modelId = Get-ModelId
                if (-not [string]::IsNullOrWhiteSpace($modelId)) {
                    Complete-SpinnerLine
                    return @{ Ready = $true; Reason = "模型已就绪: $modelId" }
                }
            }
            $nextProbeMs += $SpinnerProbeIntervalMs
        }
        Start-Sleep -Milliseconds $SpinnerFrameIntervalMs
        $tick++
    }
    Complete-SpinnerLine
    return @{ Ready = $false; Reason = "后端在 $timeoutSec 秒内未就绪" }
}

function Read-LogText {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return ''
    }
    try {
        $lines = Get-Content -Path $Path -Tail 400 -ErrorAction SilentlyContinue
        if ($null -eq $lines) {
            return ''
        }
        return ($lines -join "`n")
    } catch {
        return ''
    }
}

function Show-RecentServerLogs {
    param(
        [string]$OutLogPath,
        [string]$ErrLogPath
    )
    Write-Host '后端启动失败，最近日志如下:'
    if (Test-Path $OutLogPath) {
        Write-Host '=== 标准输出 ==='
        Get-Content -Path $OutLogPath -Tail 120 -ErrorAction SilentlyContinue
    }
    if (Test-Path $ErrLogPath) {
        Write-Host '=== 标准错误 ==='
        Get-Content -Path $ErrLogPath -Tail 120 -ErrorAction SilentlyContinue
    }
}

function Test-GpuReadyFromLogs {
    param(
        [string]$OutLogPath,
        [string]$ErrLogPath
    )
    $content = (Read-LogText -Path $OutLogPath) + "`n" + (Read-LogText -Path $ErrLogPath)
    if ([string]::IsNullOrWhiteSpace($content)) {
        return @{ Ready = $false; Reason = '日志为空' }
    }

    $match = [regex]::Match($content, 'offloaded\s+(\d+)\/(\d+)\s+layers\s+to\s+GPU', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        $offloaded = [int]$match.Groups[1].Value
        $total = [int]$match.Groups[2].Value
        if ($offloaded -gt 0) {
            return @{ Ready = $true; Reason = "offloaded $offloaded/$total" }
        }
        return @{ Ready = $false; Reason = "offloaded 0/$total" }
    }

    $cpuFallbackPattern = 'cuda[^`n]*failed|no cuda-capable device|unable to initialize cuda|using cpu'
    if ($content -match $cpuFallbackPattern) {
        return @{ Ready = $false; Reason = '检测到 CUDA 初始化失败或 CPU 回退' }
    }

    return @{ Ready = $false; Reason = '未检测到 GPU 卸载证据' }
}

function Ensure-GpuOffload {
    param(
        [int]$ProcessId,
        [int]$BaselineMemoryMiB,
        [string]$OutLogPath,
        [string]$ErrLogPath
    )
    $moduleResult = @{ Ready = $false; Reason = '未执行检查' }
    $result = @{ Ready = $false; Reason = '未知原因' }
    $nvidiaResult = @{ Ready = $false; Reason = '未执行检查' }
    $timeoutSec = [int]$GpuVerifyTimeoutSec
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $nextProbeMs = 0
    $tick = 0
    while ($stopwatch.Elapsed.TotalSeconds -lt $timeoutSec) {
        Write-SpinnerLine -Label 'GPU 校验中...' -Current $stopwatch.Elapsed.TotalSeconds -Total $timeoutSec -Tick $tick
        if ($stopwatch.ElapsedMilliseconds -ge $nextProbeMs) {
            if (-not (Test-ProcessRunning -ProcessId $ProcessId)) {
                Complete-SpinnerLine
                throw 'llama-server 在 GPU 校验期间提前退出'
            }
            $moduleResult = Test-CudaBackendLoaded -ProcessId $ProcessId
            $result = Test-GpuReadyFromLogs -OutLogPath $OutLogPath -ErrLogPath $ErrLogPath
            $nvidiaResult = Test-GpuReadyByNvidiaSmi -BaselineMemoryMiB $BaselineMemoryMiB
            if ($moduleResult.Ready -and ($result.Ready -or $nvidiaResult.Ready)) {
                Complete-SpinnerLine
                if ($result.Ready) {
                    return "$($moduleResult.Reason)；$($result.Reason)"
                }
                return "$($moduleResult.Reason)；$($nvidiaResult.Reason)"
            }
            $nextProbeMs += $SpinnerProbeIntervalMs
        }
        Start-Sleep -Milliseconds $SpinnerFrameIntervalMs
        $tick++
    }
    Complete-SpinnerLine
    throw "已禁止 CPU 回退，但未检测到 GPU 卸载。模块检查: $($moduleResult.Reason)；nvidia-smi: $($nvidiaResult.Reason)；日志检查: $($result.Reason)"
}

function Test-CudaBackendLoaded {
    param([int]$ProcessId)
    try {
        $mods = Get-Process -Id $ProcessId -Module -ErrorAction Stop
        $cuda = $mods | Where-Object { $_.ModuleName -match '^ggml-cuda.*\.dll$' } | Select-Object -First 1
        if ($null -ne $cuda) {
            return @{ Ready = $true; Reason = "检测到 $($cuda.ModuleName) 已加载" }
        }
        return @{ Ready = $false; Reason = '未检测到 ggml-cuda*.dll' }
    } catch {
        return @{ Ready = $false; Reason = '无法读取 llama-server 进程模块' }
    }
}

function Test-GpuReadyByNvidiaSmi {
    param([int]$BaselineMemoryMiB)
    $snapshot = Get-GpuMemoryUsedMiB
    if (-not $snapshot.Ok) {
        return @{ Ready = $false; Reason = $snapshot.Reason }
    }
    $delta = $snapshot.UsedMiB - $BaselineMemoryMiB
    if ($snapshot.UsedMiB -gt 0 -and $delta -ge [int]$GpuMemoryDeltaMinMiB) {
        return @{ Ready = $true; Reason = "nvidia-smi 显存占用 ${snapshot.UsedMiB}MiB，较基线增加 ${delta}MiB" }
    }
    return @{ Ready = $false; Reason = "显存占用 ${snapshot.UsedMiB}MiB，较基线增加 ${delta}MiB，阈值 ${GpuMemoryDeltaMinMiB}MiB" }
}

function Get-GpuMemoryUsedMiB {
    $nvidia = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $nvidia) {
        $nvidia = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    }
    if (-not $nvidia) {
        return @{ Ok = $false; UsedMiB = 0; Reason = 'nvidia-smi 不可用' }
    }

    $output = & $nvidia.Source '--query-gpu=memory.used' '--format=csv,noheader,nounits' 2>&1
    if ($LASTEXITCODE -ne 0) {
        return @{ Ok = $false; UsedMiB = 0; Reason = 'nvidia-smi 执行失败' }
    }

    $rows = @($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[0-9]+$' })
    if ($rows.Count -eq 0) {
        return @{ Ok = $false; UsedMiB = 0; Reason = 'nvidia-smi 未返回显存数据' }
    }
    $maxUsed = 0
    foreach ($row in $rows) {
        $memValue = 0
        if ([int]::TryParse($row, [ref]$memValue)) {
            if ($memValue -gt $maxUsed) {
                $maxUsed = $memValue
            }
        }
    }
    return @{ Ok = $true; UsedMiB = $maxUsed; Reason = 'ok' }
}

function Get-StartupFailureReason {
    param(
        [string]$OutLogPath,
        [string]$ErrLogPath
    )
    $content = (Read-LogText -Path $OutLogPath) + "`n" + (Read-LogText -Path $ErrLogPath)
    if ([string]::IsNullOrWhiteSpace($content)) {
        return ''
    }
    $bindMatch = [regex]::Match($content, "couldn't bind HTTP server socket, hostname:\s*([^,]+), port:\s*([0-9]+)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($bindMatch.Success) {
        $busyPort = $bindMatch.Groups[2].Value
        return "端口 $busyPort 已被占用，请先关闭占用该端口的服务，再重新启动"
    }
    return ''
}

function Get-PortOwnerSummary {
    param([string]$Port)
    try {
        $listeners = Get-NetTCPConnection -LocalPort ([int]$Port) -State Listen -ErrorAction SilentlyContinue
        if (-not $listeners) {
            return ''
        }
        $owners = @()
        foreach ($listener in @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)) {
            $proc = Get-Process -Id $listener -ErrorAction SilentlyContinue
            if ($proc) {
                $owners += ('{0} (PID {1})' -f $proc.ProcessName, $proc.Id)
            } else {
                $owners += ('PID {0}' -f $listener)
            }
        }
        return ($owners -join ', ')
    } catch {
        return ''
    }
}

function Stop-Server {
    if (Test-Path $PidFile) {
        $raw = Get-Content -Path $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
        $serverPid = 0
        if ([int]::TryParse([string]$raw, [ref]$serverPid) -and $serverPid -gt 0) {
            try {
                Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue
            } catch {}
        }
    }

    $procs = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $PidFile) {
        Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $CurrentErrLogFile) {
        Remove-Item -Path $CurrentErrLogFile -Force -ErrorAction SilentlyContinue
    }
}

function Show-Status {
    if (Test-Health) {
        $modelId = Get-ModelId
        if ([string]::IsNullOrWhiteSpace($modelId)) {
            $modelId = 'loading'
        }
        Write-Host '状态: 运行中'
        Write-Host "地址: http://$HostAddr`:$PortNum"
        Write-Host "模型: $modelId"
        if (Test-Path $CurrentLogFile) {
            $p = Get-Content -Path $CurrentLogFile -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($p) {
                Write-Host "日志: $p"
            }
        }
        if (Test-Path $CurrentErrLogFile) {
            $ep = Get-Content -Path $CurrentErrLogFile -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($ep) {
                Write-Host "错误日志: $ep"
            }
        }
        return
    }
    Write-Host '状态: 未运行'
}

function Resolve-RuntimeProfile {
    switch ($ThinkMode) {
        'think-on' { return @{ ReasoningBudget = '-1'; MaxTokens = '-1' } }
        'think-off' { return @{ ReasoningBudget = '0'; MaxTokens = '2048' } }
        default { throw "不支持的思考模式: $ThinkMode" }
    }
}

function Validate-Limits {
    if (($CtxSize -notmatch '^[0-9]+$') -or ($ImageMinTokens -notmatch '^[0-9]+$') -or ($ImageMaxTokens -notmatch '^[0-9]+$')) {
        throw 'CTX_SIZE / IMAGE_MIN_TOKENS / IMAGE_MAX_TOKENS 必须是正整数'
    }
    if ([int]$CtxSize -le 0 -or [int]$ImageMinTokens -le 0 -or [int]$ImageMaxTokens -le 0) {
        throw 'CTX_SIZE / IMAGE_MIN_TOKENS / IMAGE_MAX_TOKENS 必须大于 0'
    }
    if ([int]$ImageMinTokens -gt [int]$ImageMaxTokens) {
        throw 'IMAGE_MIN_TOKENS 不能大于 IMAGE_MAX_TOKENS'
    }
    if ($MmprojOffload -ne 'on' -and $MmprojOffload -ne 'off') {
        throw 'MMPROJ_OFFLOAD 仅支持 on 或 off'
    }
    if (($GpuMemoryDeltaMinMiB -notmatch '^[0-9]+$') -or [int]$GpuMemoryDeltaMinMiB -le 0) {
        throw 'GPU_MEMORY_DELTA_MIN_MIB 必须是正整数'
    }
    if (($BackendReadyTimeoutSec -notmatch '^[0-9]+$') -or [int]$BackendReadyTimeoutSec -le 0) {
        throw 'BACKEND_READY_TIMEOUT_SEC 必须是正整数'
    }
    if (($GpuVerifyTimeoutSec -notmatch '^[0-9]+$') -or [int]$GpuVerifyTimeoutSec -le 0) {
        throw 'GPU_VERIFY_TIMEOUT_SEC 必须是正整数'
    }
}

function Start-Server {
    if (-not (Test-Path $BinPath)) {
        throw "llama-server.exe 不存在: $BinPath"
    }
    if (-not (Test-Path $ModelPath) -or -not (Test-Path $MmprojPath)) {
        throw "模型文件不完整。`nMODEL_PATH=$ModelPath`nMMPROJ_PATH=$MmprojPath"
    }

    Ensure-Dir $WebuiDir
    Validate-Limits
    $profile = Resolve-RuntimeProfile
    Stop-Server
    $portOwner = Get-PortOwnerSummary -Port $PortNum
    if ($portOwner) {
        throw "端口 $PortNum 已被占用: $portOwner"
    }

    $args = @(
        '-m', $ModelPath,
        '-mm', $MmprojPath,
        '--n-gpu-layers', 'all',
        '--flash-attn', 'on',
        '--fit', 'on',
        '--fit-target', '256',
        '--temp', '1.0',
        '--top-p', '0.95',
        '--top-k', '20',
        '--min-p', '0.1',
        '--presence-penalty', '1.5',
        '--repeat-penalty', '1.05',
        '-n', $profile.MaxTokens,
        '--reasoning-budget', $profile.ReasoningBudget,
        '-c', $CtxSize,
        '--image-min-tokens', $ImageMinTokens,
        '--image-max-tokens', $ImageMaxTokens,
        '--host', $HostAddr,
        '--port', $PortNum,
        '--webui'
    )

    if ($MmprojOffload -eq 'off') {
        $args += '--no-mmproj-offload'
    } else {
        $args += '--mmproj-offload'
    }

    $logPath = Join-Path $WebuiDir ("llama_server_9b_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $errLogPath = Join-Path $WebuiDir ("llama_server_9b_{0}.err.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if (Test-Path $logPath) {
        Remove-Item -Path $logPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $errLogPath) {
        Remove-Item -Path $errLogPath -Force -ErrorAction SilentlyContinue
    }
    $baselineGpuMemoryMiB = 0
    $gpuBaseline = Get-GpuMemoryUsedMiB
    if ($gpuBaseline.Ok) {
        $baselineGpuMemoryMiB = [int]$gpuBaseline.UsedMiB
    }
    Write-Host '后端进程启动中，正在装载模型到 GPU...'
    $proc = Start-Process -FilePath $BinPath -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $logPath -RedirectStandardError $errLogPath -PassThru
    Set-Content -Path $PidFile -Value $proc.Id -Encoding ascii
    Set-Content -Path $CurrentLogFile -Value $logPath -Encoding utf8
    Set-Content -Path $CurrentErrLogFile -Value $errLogPath -Encoding utf8

    $startupReady = $false
    try {
        $readyResult = Wait-Ready -ProcessId $proc.Id
        if (-not $readyResult.Ready) {
            $startupFailureReason = Get-StartupFailureReason -OutLogPath $logPath -ErrLogPath $errLogPath
            if ($startupFailureReason) {
                throw "服务启动失败: $startupFailureReason"
            }
            throw "服务启动失败: $($readyResult.Reason)"
        }
        $gpuInfo = Ensure-GpuOffload -ProcessId $proc.Id -BaselineMemoryMiB $baselineGpuMemoryMiB -OutLogPath $logPath -ErrLogPath $errLogPath
        Write-Host "GPU 校验通过: $gpuInfo"
        $startupReady = $true
    } finally {
        if (-not $startupReady) {
            Show-RecentServerLogs -OutLogPath $logPath -ErrLogPath $errLogPath
            Stop-Server
        }
    }

    Write-Host "已切换到 9b，思考模式: $ThinkMode"
    Write-Host "地址: http://$HostAddr`:$PortNum"
    Write-Host "视觉限制: image tokens $ImageMinTokens-$ImageMaxTokens, mmproj offload=$MmprojOffload, ctx=$CtxSize"
    Show-Status
}

switch ($Command) {
    'status' { Show-Status; break }
    'stop' { Stop-Server; Write-Host '服务已停止'; break }
    '9b' { Start-Server; break }
    default {
        Write-Host '用法:'
        Write-Host '  .\\switch_qwen35_webui.ps1 status'
        Write-Host '  .\\switch_qwen35_webui.ps1 stop'
        Write-Host '  .\\switch_qwen35_webui.ps1 9b [think-on|think-off]'
        exit 1
    }
}
