param(
    [string]$StateDir = (Join-Path $PSScriptRoot 'state'),
    [string]$ADILibrary = (Join-Path $PSScriptRoot '.cache\openbubbles-store\rust_lib_bluebubbles.dll'),
    [string]$Python = 'python',
    [ValidateRange(1024,65535)][int]$Port = 18741,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
$taskBin = Join-Path $PSScriptRoot 'bin'
$taskBinPrefix = $taskBin + [IO.Path]::DirectorySeparatorChar
$taskDashboard = Join-Path $taskBin 'dashboard.exe'
$taskWorker = Join-Path $taskBin 'trusted-device-gui.exe'
$StateDir = [IO.Path]::GetFullPath($StateDir)
$ADILibrary = [IO.Path]::GetFullPath($ADILibrary)
$taskProcess = $null
$taskHash = [Security.Cryptography.SHA256]::Create()
try { $taskKey = [BitConverter]::ToString($taskHash.ComputeHash([Text.Encoding]::UTF8.GetBytes($PSScriptRoot.ToLowerInvariant()))).Replace('-', '') }
finally { $taskHash.Dispose() }
$taskMutex = [Threading.Mutex]::new($false, ('Local\AppleServicesLauncher-' + $taskKey))
$taskLocked = $false

try {
    try { $taskLocked = $taskMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $taskLocked = $true }
    if (-not $taskLocked) { throw '本项目正在启动，请等待当前启动完成。' }
    Write-Host '[1/3] 检查并关闭本项目已有进程……'
    # 以完整路径划定本项目范围；/T 同时关闭原生桥接等子进程。
    $taskExisting = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($taskBinPrefix, [StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object @{ Expression = { $_.Name -ne 'dashboard.exe' } })
    foreach ($taskEntry in $taskExisting) {
        $taskRunning = Get-Process -Id $taskEntry.ProcessId -ErrorAction SilentlyContinue
        if (-not $taskRunning -or -not $taskRunning.Path -or
            -not $taskRunning.Path.StartsWith($taskBinPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        Write-Host ('关闭项目进程：{0}（PID {1}）' -f $taskEntry.Name, $taskEntry.ProcessId)
        & "$env:SystemRoot\System32\taskkill.exe" /PID $taskEntry.ProcessId /T /F | Out-Null
        if (-not $taskRunning.WaitForExit(10000)) { throw '旧进程未退出，已取消启动。' }
    }

    # 其他程序占用端口时直接报错，不按端口终止未知程序。
    $taskProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    try { $taskProbe.Start() }
    catch { throw "端口 $Port 已被其他程序占用；可使用 -Port 指定其他端口。" }
    finally { $taskProbe.Stop() }

    Write-Host '[2/3] 编译面板、后台和配套工具……'
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) { throw '未找到 Go，请先安装 Go 1.26 或更新版本。' }
    New-Item -ItemType Directory -Force -Path $taskBin | Out-Null
    Push-Location $PSScriptRoot
    try {
        # 本机启动不依赖 Git 版本戳，避免 Git 状态读取失败阻断编译。
        & go build -buildvcs=false -o $taskWorker ./cmd/trusted-device
        if ($LASTEXITCODE -ne 0) { throw '后台编译失败。' }
        & go build -buildvcs=false -o ($taskBin + '\') ./cmd/dashboard ./tools/familyinspect ./tools/accountsetupcheck ./tools/nacexchange
        if ($LASTEXITCODE -ne 0) { throw '面板或配套工具编译失败。' }
    } finally { Pop-Location }

    Write-Host '[3/3] 启动本机网页控制台……'
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $taskArgs = @('-dir', $StateDir, '-worker', $taskWorker, '-adi-dll', $ADILibrary,
        '-python', $Python, '-mac-push-setup', (Join-Path $PSScriptRoot 'tools\mac-push-check.py'), '-port', [string]$Port)
    # Start-Process 的 ArgumentList 会重新拼接，按 Windows 原生 argv 规则引用路径。
    $taskQuotedArgs = @($taskArgs | ForEach-Object { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' })
    $taskProcess = Start-Process -FilePath $taskDashboard -ArgumentList ($taskQuotedArgs -join ' ') `
        -WorkingDirectory $PSScriptRoot -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $StateDir 'dashboard.out.log') `
        -RedirectStandardError (Join-Path $StateDir 'dashboard.err.log')
    $null = $taskProcess.Handle
    $taskURL = "http://127.0.0.1:$Port"
    $taskReady = $false
    $taskDeadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $taskDeadline) {
        if ($taskProcess.HasExited) { throw '面板已退出，请检查状态目录中的 dashboard.err.log。' }
        try {
            $taskResponse = Invoke-WebRequest -Uri $taskURL -UseBasicParsing -TimeoutSec 1
            if ($taskResponse.Headers['X-AppleServices-UI'] -eq '1') { $taskReady = $true; break }
        } catch { }
        Start-Sleep -Milliseconds 200
    }
    if (-not $taskReady -or $taskProcess.HasExited) { throw '面板未能就绪，请检查状态目录中的 dashboard.err.log。' }
    Write-Host "启动成功：$taskURL"
    Write-Host '请保留此窗口；关闭此窗口或按 Ctrl+C，即退出面板及其账号后台。'
    if (-not $NoOpen) { Start-Process $taskURL }
    # 就绪后释放启动锁，允许再次双击启动并替换旧面板。
    $taskMutex.ReleaseMutex()
    $taskLocked = $false
    $taskProcess.WaitForExit()
    if ($taskProcess.ExitCode -ne 0) { throw '程序已退出；如非主动关闭，请检查 dashboard.err.log。' }
} catch {
    if ($taskProcess -and -not $taskProcess.HasExited) {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $taskProcess.Id /T /F | Out-Null
    }
    Write-Host ('启动失败：' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($taskLocked) { $taskMutex.ReleaseMutex() }
    $taskMutex.Dispose()
}
