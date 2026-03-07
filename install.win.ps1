param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = (Resolve-Path $ScriptDir).Path
$EnvConfig = Join-Path $RootDir 'env_config.ps1'
if (Test-Path $EnvConfig) {
    . $EnvConfig
    Import-EnvFile -Path (Join-Path $RootDir '.env')
}
$VenvDir = Join-Path $RootDir '.venv-qwen35'
$VenvPython = Join-Path $VenvDir 'Scripts\python.exe'
$LlamaDir = Join-Path $RootDir '.tmp\llama_win_cuda'
$ModelRelativeDir = '.tmp\models\crossrepo\lmstudio-community__Qwen3.5-9B-GGUF'
$DefaultGgufRelativePath = Join-Path $ModelRelativeDir 'Qwen3.5-9B-Q4_K_M.gguf'
$DefaultMmprojRelativePath = Join-Path $ModelRelativeDir 'mmproj-Qwen3.5-9B-BF16.gguf'
$GgufPath = Resolve-ManagedPath -BaseDir $RootDir -Value $env:MODEL_PATH -DefaultRelativePath $DefaultGgufRelativePath
$MmprojPath = Resolve-ManagedPath -BaseDir $RootDir -Value $env:MMPROJ_PATH -DefaultRelativePath $DefaultMmprojRelativePath

$DefaultGgufUrl = 'https://huggingface.co/lmstudio-community/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf'
$DefaultMmprojUrl = 'https://huggingface.co/lmstudio-community/Qwen3.5-9B-GGUF/resolve/main/mmproj-Qwen3.5-9B-BF16.gguf'
$LlamaReleaseApiUrl = 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest'
$LlamaReleasePageUrl = 'https://github.com/ggml-org/llama.cpp/releases/latest'
$LlamaReleaseDownloadPrefix = 'https://github.com/ggml-org/llama.cpp/releases/latest/download/'
$PreferredCudaBinAssetRegexes = @(
    '^llama-.*-bin-win-cuda-12\.4-x64\.zip$',
    '^llama-.*-bin-win-cuda-13\.1-x64\.zip$',
    '^llama-.*-bin-win-cuda-.*-x64\.zip$'
)
$PreferredCudaRuntimeAssetRegexes = @(
    '^cudart-llama-bin-win-cuda-12\.4-x64\.zip$',
    '^cudart-llama-bin-win-cuda-13\.1-x64\.zip$',
    '^cudart-llama-bin-win-cuda-.*-x64\.zip$'
)

function Write-Step {
    param([string]$Message)
    Write-Host "[install] $Message"
}

function New-PythonCandidate {
    param(
        [string]$Label,
        [string]$Command,
        [string[]]$Args = @()
    )
    return [PSCustomObject]@{
        Label = $Label
        Command = $Command
        Args = $Args
    }
}

function Format-MiB {
    param([long]$Bytes)
    if ($Bytes -lt 0) {
        return '0.0'
    }
    return ('{0:N1}' -f ($Bytes / 1MB))
}

function Write-DownloadProgress {
    param(
        [string]$Label,
        [long]$DownloadedBytes,
        [long]$TotalBytes,
        [int]$Tick
    )
    $frames = @('|', '/', '-', '\')
    $frame = $frames[$Tick % $frames.Count]
    if ($TotalBytes -gt 0) {
        $percent = [math]::Min(100, [int](($DownloadedBytes * 100) / $TotalBytes))
        $done = Format-MiB -Bytes $DownloadedBytes
        $total = Format-MiB -Bytes $TotalBytes
        Write-Host -NoNewline "`r[install] $Label $percent% ($done/$total MiB)"
        return
    }
    $doneOnly = Format-MiB -Bytes $DownloadedBytes
    Write-Host -NoNewline "`r[install] $Label $frame 已下载 $doneOnly MiB"
}

function Get-PythonCandidates {
    $candidates = @()
    if ($env:PYTHON_BIN) {
        $candidates += New-PythonCandidate -Label "PYTHON_BIN=$($env:PYTHON_BIN)" -Command $env:PYTHON_BIN
    }
    $candidates += New-PythonCandidate -Label 'py -3' -Command 'py' -Args @('-3')
    $candidates += New-PythonCandidate -Label 'python' -Command 'python'
    $candidates += New-PythonCandidate -Label 'python3' -Command 'python3'
    return $candidates
}

function Test-PythonCandidate {
    param([object]$PythonSpec)
    $probeCode = 'import sys, venv; raise SystemExit(0 if sys.version_info >= (3, 10) else 3)'
    try {
        & $PythonSpec.Command @($PythonSpec.Args + @('-c', $probeCode)) *> $null
    } catch {
        Write-Step "跳过 Python 候选 $($PythonSpec.Label): $($_.Exception.Message)"
        return $false
    }
    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    if ($LASTEXITCODE -eq 3) {
        Write-Step "跳过 Python 候选 $($PythonSpec.Label): Python 版本低于 3.10"
        return $false
    }
    Write-Step "跳过 Python 候选 $($PythonSpec.Label): 解释器不可用或缺少 venv 模块，exit code: $LASTEXITCODE"
    return $false
}

function Resolve-PythonSpec {
    foreach ($candidate in Get-PythonCandidates) {
        if (Test-PythonCandidate -PythonSpec $candidate) {
            Write-Step "使用 Python: $($candidate.Label)"
            return $candidate
        }
    }
    throw '未找到可用 Python，请安装 Python 3.10+ 并确保 venv 模块可用。'
}

function Invoke-CommandChecked {
    param(
        [string]$Command,
        [string[]]$CommandArgs,
        [string]$Action,
        [string]$DisplayName = $Command
    )
    try {
        & $Command @CommandArgs
    } catch {
        throw "$Action 失败。命令: $DisplayName。错误: $($_.Exception.Message)"
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$Action 失败。命令: $DisplayName。exit code: $LASTEXITCODE"
    }
}

function Invoke-Python {
    param(
        [object]$PythonSpec,
        [string[]]$PythonArgs,
        [string]$Action
    )
    Invoke-CommandChecked -Command $PythonSpec.Command -CommandArgs ($PythonSpec.Args + $PythonArgs) -Action $Action -DisplayName $PythonSpec.Label
}

function Test-VenvPython {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return $false
    }
    try {
        & $Path '-c' 'import sys' *> $null
    } catch {
        return $false
    }
    return $LASTEXITCODE -eq 0
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Download-File {
    param(
        [string]$Url,
        [string]$OutFile
    )
    Write-Step "下载: $Url"
    $targetDir = Split-Path -Parent $OutFile
    if (-not [string]::IsNullOrWhiteSpace($targetDir)) {
        Ensure-Dir $targetDir
    }
    $tempFile = '{0}.part.{1}.{2}' -f $OutFile, $PID, ([guid]::NewGuid().ToString('N'))

    $response = $null
    $inStream = $null
    $outStream = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.AllowAutoRedirect = $true
        $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        $response = $request.GetResponse()
        $totalBytes = [long]$response.ContentLength
        $inStream = $response.GetResponseStream()
        $outStream = [System.IO.File]::Open($tempFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

        $buffer = New-Object byte[] (1MB)
        $downloadedBytes = [long]0
        $tick = 0
        $lastTick = [System.Diagnostics.Stopwatch]::StartNew()
        while (($read = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outStream.Write($buffer, 0, $read)
            $downloadedBytes += $read
            if ($lastTick.ElapsedMilliseconds -ge 250) {
                Write-DownloadProgress -Label '下载中' -DownloadedBytes $downloadedBytes -TotalBytes $totalBytes -Tick $tick
                $tick++
                $lastTick.Restart()
            }
        }
        Write-DownloadProgress -Label '下载中' -DownloadedBytes $downloadedBytes -TotalBytes $totalBytes -Tick $tick
        Write-Host ''
    } catch {
        if (Test-Path $tempFile) {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
        throw
    } finally {
        if ($outStream) { $outStream.Dispose() }
        if ($inStream) { $inStream.Dispose() }
        if ($response) { $response.Dispose() }
    }

    if (Test-Path $OutFile) {
        Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue
    }
    Move-Item -Path $tempFile -Destination $OutFile -Force
}

function Verify-Sha256 {
    param(
        [string]$Path,
        [string]$Expected
    )
    if ([string]::IsNullOrWhiteSpace($Expected)) {
        return
    }
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $exp = $Expected.ToLowerInvariant()
    if ($actual -ne $exp) {
        throw "SHA256 校验失败: $Path"
    }
}

function Get-LlamaReleaseAssetsFromApi {
    try {
        $release = Invoke-RestMethod -Uri $LlamaReleaseApiUrl -Method Get
        return @($release.assets | ForEach-Object {
            [PSCustomObject]@{
                Name = [string]$_.name
                Url = [string]$_.browser_download_url
            }
        })
    } catch {
        Write-Step "GitHub API 不可用，改用页面解析。原因: $($_.Exception.Message)"
        return @()
    }
}

function Get-LlamaReleaseAssetsFromHtml {
    try {
        $response = Invoke-WebRequest -Uri $LlamaReleasePageUrl -UseBasicParsing
    } catch {
        throw "获取 llama.cpp release 页面失败: $($_.Exception.Message)"
    }
    $content = [string]$response.Content
    $regex = '(?:cudart-)?llama-[^"''<> ]*bin-win-cuda-[0-9.]+-x64\.zip'
    $matches = [regex]::Matches($content, $regex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $seen = @{}
    $assets = @()
    foreach ($match in $matches) {
        $name = [string]$match.Value
        $key = $name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        $assets += [PSCustomObject]@{
            Name = $name
            Url = "$LlamaReleaseDownloadPrefix$name"
        }
    }
    return $assets
}

function Select-LlamaAsset {
    param(
        [object[]]$Assets,
        [string[]]$Regexes
    )
    foreach ($regex in $Regexes) {
        $candidate = $Assets | Where-Object { $_.Name -match $regex } | Select-Object -First 1
        if ($candidate) {
            return $candidate
        }
    }
    return $null
}

function Resolve-LlamaCudaAssets {
    if ($env:LLAMA_WIN_CUDA_URL) {
        $binName = Split-Path -Path $env:LLAMA_WIN_CUDA_URL -Leaf
        $runtimeUrl = if ($env:LLAMA_WIN_CUDART_URL) { [string]$env:LLAMA_WIN_CUDART_URL } else { '' }
        $runtimeName = if ([string]::IsNullOrWhiteSpace($runtimeUrl)) { '' } else { (Split-Path -Path $runtimeUrl -Leaf) }
        Write-Step "使用自定义 llama.cpp 主包: $binName"
        if (-not [string]::IsNullOrWhiteSpace($runtimeName)) {
            Write-Step "使用自定义 CUDA 运行时包: $runtimeName"
        }
        return @{
            BinUrl = [string]$env:LLAMA_WIN_CUDA_URL
            RuntimeUrl = $runtimeUrl
        }
    }

    $assets = Get-LlamaReleaseAssetsFromApi
    if ($assets.Count -eq 0) {
        $assets = Get-LlamaReleaseAssetsFromHtml
    }
    if ($assets.Count -eq 0) {
        throw '自动解析 llama.cpp CUDA 资源失败，未读取到任何 win-cuda 包。'
    }

    $bin = Select-LlamaAsset -Assets $assets -Regexes $PreferredCudaBinAssetRegexes
    if (-not $bin) {
        $preview = (@($assets | Select-Object -ExpandProperty Name | Select-Object -First 12)) -join ', '
        throw "自动解析失败：未找到完整 CUDA 主包。可用资源: $preview"
    }
    $runtime = Select-LlamaAsset -Assets $assets -Regexes $PreferredCudaRuntimeAssetRegexes
    Write-Step "使用 llama.cpp 主包: $($bin.Name)"
    if ($runtime) {
        Write-Step "可选 CUDA 运行时包: $($runtime.Name)"
    }
    return @{
        BinUrl = [string]$bin.Url
        RuntimeUrl = if ($runtime) { [string]$runtime.Url } else { '' }
    }
}

function Get-LlamaRuntimeStatus {
    param([string]$BaseDir)
    $missing = @()
    $llamaExe = Test-Path (Join-Path $BaseDir 'llama-server.exe')
    if (-not $llamaExe) {
        $missing += 'llama-server.exe'
    }
    $cudaBackendDll = @(Get-ChildItem -Path $BaseDir -Filter 'ggml-cuda*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($cudaBackendDll.Count -eq 0) {
        $missing += 'ggml-cuda*.dll'
    }
    $cudartDll = @(Get-ChildItem -Path $BaseDir -Filter 'cudart64_*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($cudartDll.Count -eq 0) {
        $missing += 'cudart64_*.dll'
    }
    $cublasDll = @(Get-ChildItem -Path $BaseDir -Filter 'cublas64_*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($cublasDll.Count -eq 0) {
        $missing += 'cublas64_*.dll'
    }
    return @{
        Ready = ($missing.Count -eq 0)
        Missing = $missing
    }
}

function Clear-LlamaRuntimeDirectory {
    if (-not (Test-Path $LlamaDir)) {
        Ensure-Dir $LlamaDir
        return
    }
    try {
        Get-ChildItem -Path $LlamaDir -Force -ErrorAction Stop | Remove-Item -Recurse -Force -ErrorAction Stop
    } catch {
        throw "清理 CUDA 运行时目录失败，请先停止服务后重试。目录: $LlamaDir。错误: $($_.Exception.Message)"
    }
}

function Ensure-PythonEnv {
    $python = Resolve-PythonSpec
    $venvExists = Test-Path $VenvDir
    $venvReady = Test-VenvPython -Path $VenvPython
    if ($venvExists -and -not $venvReady) {
        Write-Step "检测到不完整或非 Windows 虚拟环境，重建: $VenvDir"
        Remove-Item -Path $VenvDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $VenvDir) {
            Write-Step '目录无法直接删除，尝试 venv --clear 重建'
            Invoke-Python -PythonSpec $python -PythonArgs @('-m', 'venv', '--clear', $VenvDir) -Action '清空并重建虚拟环境'
        }
    }
    if (-not (Test-Path $VenvDir)) {
        Write-Step "创建虚拟环境: $VenvDir"
        Invoke-Python -PythonSpec $python -PythonArgs @('-m', 'venv', $VenvDir) -Action '创建虚拟环境'
    }
    if (-not (Test-VenvPython -Path $VenvPython)) {
        throw "虚拟环境未就绪: $VenvPython。请检查上面的 Python 或权限报错。"
    }
    Write-Step '安装 Python 依赖'
    Invoke-CommandChecked -Command $VenvPython -CommandArgs @('-m', 'pip', 'install', '--upgrade', 'pip', 'wheel') -Action '升级 pip 和 wheel'
    Invoke-CommandChecked -Command $VenvPython -CommandArgs @('-m', 'pip', 'install', '-r', (Join-Path $RootDir 'requirements.txt')) -Action '安装 requirements.txt 依赖'
}

function Ensure-LlamaRuntime {
    Ensure-Dir $LlamaDir
    $status = Get-LlamaRuntimeStatus -BaseDir $LlamaDir
    if ($status.Ready) {
        Write-Step '检测到完整 CUDA 运行时，跳过下载'
        return
    }
    Write-Step '检测到不完整 CUDA 运行时，清理后重装'
    Clear-LlamaRuntimeDirectory

    $assets = Resolve-LlamaCudaAssets
    $binZipPath = Join-Path $LlamaDir 'llama-win-cuda-bin.zip'
    Download-File -Url $assets.BinUrl -OutFile $binZipPath
    Write-Step '解压 llama.cpp CUDA 主包'
    Expand-Archive -Path $binZipPath -DestinationPath $LlamaDir -Force

    $foundServer = Get-ChildItem -Path $LlamaDir -Filter 'llama-server.exe' -Recurse -File | Select-Object -First 1
    if (-not $foundServer) {
        throw 'llama-server.exe 下载或解压失败，未在主包中找到可执行文件。'
    }
    $srcDir = Split-Path -Parent $foundServer.FullName
    $srcDirResolved = (Resolve-Path $srcDir).Path
    $llamaDirResolved = (Resolve-Path $LlamaDir).Path
    if ($srcDirResolved -ne $llamaDirResolved) {
        Copy-Item -Path (Join-Path $srcDir '*') -Destination $LlamaDir -Recurse -Force
    }

    $status = Get-LlamaRuntimeStatus -BaseDir $LlamaDir
    $needRuntime = ($status.Missing | Where-Object { $_ -match '^cudart64_|^cublas64_' }).Count -gt 0
    if ($needRuntime -and -not [string]::IsNullOrWhiteSpace([string]$assets.RuntimeUrl)) {
        $runtimeZipPath = Join-Path $LlamaDir 'llama-win-cuda-runtime.zip'
        Download-File -Url $assets.RuntimeUrl -OutFile $runtimeZipPath
        Write-Step '解压 CUDA 运行时补充包'
        Expand-Archive -Path $runtimeZipPath -DestinationPath $LlamaDir -Force
    }

    $status = Get-LlamaRuntimeStatus -BaseDir $LlamaDir
    if (-not $status.Ready) {
        $missingText = ($status.Missing -join ', ')
        throw "CUDA 运行时不完整，缺失: $missingText"
    }
}

function Ensure-ModelFiles {
    Ensure-Dir (Split-Path -Parent $GgufPath)
    Ensure-Dir (Split-Path -Parent $MmprojPath)

    $ggufUrl = if ($env:MODEL_GGUF_URL) { $env:MODEL_GGUF_URL } else { $DefaultGgufUrl }
    $mmprojUrl = if ($env:MODEL_MMPROJ_URL) { $env:MODEL_MMPROJ_URL } else { $DefaultMmprojUrl }
    Write-Step "主模型路径: $GgufPath"
    Write-Step "视觉模型路径: $MmprojPath"

    if (-not (Test-Path $GgufPath)) {
        Download-File -Url $ggufUrl -OutFile $GgufPath
    } else {
        Write-Step '检测到现有 9B 主模型，跳过下载'
    }

    if (-not (Test-Path $MmprojPath)) {
        Download-File -Url $mmprojUrl -OutFile $MmprojPath
    } else {
        Write-Step '检测到现有 mmproj，跳过下载'
    }

    Verify-Sha256 -Path $GgufPath -Expected $env:MODEL_GGUF_SHA256
    Verify-Sha256 -Path $MmprojPath -Expected $env:MODEL_MMPROJ_SHA256
}

function Main {
    Ensure-PythonEnv
    Ensure-LlamaRuntime
    Ensure-ModelFiles
    Write-Step '安装完成'
    Write-Step '启动命令: .\\start_8080_toolhub_stack.cmd start'
    Write-Step '停止命令: .\\start_8080_toolhub_stack.cmd stop'
}

Main
