[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipRelocationPrompts,
    [switch]$SkipRecycleBin,
    [switch]$UseComponentStoreCleanup,
    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:CleanupResults = New-Object System.Collections.Generic.List[object]
$script:RelocationResults = New-Object System.Collections.Generic.List[object]
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:CurrentUser = $env:USERNAME

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "{0:N0} B" -f $Bytes
}

function Get-DriveSnapshot {
    param([string]$DriveLetter = "C")
    $drive = [System.IO.DriveInfo]::new($DriveLetter)
    [pscustomobject]@{
        Drive = "$DriveLetter`:"
        Total = [double]$drive.TotalSize
        Free  = [double]$drive.AvailableFreeSpace
        Used  = [double]($drive.TotalSize - $drive.AvailableFreeSpace)
    }
}

function Get-DirectorySizeBytes {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0L
    }

    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Force -File -Recurse -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) {
            return 0L
        }
        return [int64]$sum
    }
    catch {
        return 0L
    }
}

function Test-PathOnDrive {
    param(
        [string]$Path,
        [string]$Drive = "C"
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return $expanded -match ("^{0}:" -f [Regex]::Escape($Drive))
}

function New-ResultObject {
    param(
        [string]$Category,
        [string]$Label,
        [string]$Path,
        [string]$Action,
        [string]$Status,
        [string]$Detail
    )

    [pscustomobject]@{
        Category = $Category
        Label    = $Label
        Path     = $Path
        Action   = $Action
        Status   = $Status
        Detail   = $Detail
    }
}

function Get-DisplayMethod {
    param([string]$Method)
    switch ($Method) {
        "known-folder" { return "系统目录迁移" }
        "junction" { return "迁移并保留连接点" }
        default { return $Method }
    }
}

function Get-DisplayStatus {
    param([string]$Status)
    switch ($Status) {
        "DryRun" { return "预演" }
        "ok" { return "完成" }
        "partial" { return "部分完成" }
        "missing" { return "不存在" }
        "skipped" { return "已跳过" }
        "blocked" { return "被占用" }
        "failed" { return "失败" }
        "unsupported" { return "不支持" }
        default { return $Status }
    }
}

function Remove-ChildItemsBestEffort {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        $script:CleanupResults.Add((New-ResultObject -Category "清理" -Label $Label -Path $Path -Action "跳过" -Status "不存在" -Detail "路径不存在"))
        return
    }

    $before = Get-DirectorySizeBytes -Path $Path
    if ($DryRun) {
        $script:CleanupResults.Add((New-ResultObject -Category "清理" -Label $Label -Path $Path -Action "预演" -Status "DryRun" -Detail ("预计可清理：{0}" -f (Format-Bytes $before))))
        return
    }

    $deleted = 0
    $failed = 0
    $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)

    foreach ($child in $children) {
        try {
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
            $deleted++
        }
        catch {
            $failed++
        }
    }

    $after = Get-DirectorySizeBytes -Path $Path
    $freed = [Math]::Max(0, ($before - $after))
    $detail = "释放 {0}；已删除 {1} 项；失败 {2} 项" -f (Format-Bytes $freed), $deleted, $failed
    $status = if ($failed -gt 0) { "部分完成" } else { "完成" }
    $script:CleanupResults.Add((New-ResultObject -Category "清理" -Label $Label -Path $Path -Action "删除子项" -Status $status -Detail $detail))
}

function Clear-RecycleBinSafe {
    if ($SkipRecycleBin) {
        $script:CleanupResults.Add((New-ResultObject -Category "清理" -Label "回收站" -Path "回收站" -Action "跳过" -Status "已跳过" -Detail "已按参数跳过"))
        return
    }

    if ($DryRun) {
        $script:CleanupResults.Add((New-ResultObject -Category "清理" -Label "回收站" -Path "回收站" -Action "预演" -Status "DryRun" -Detail "将会清空回收站"))
        return
    }

    try {
        Clear-RecycleBin -Force -ErrorAction Stop | Out-Null
        $script:CleanupResults.Add((New-ResultObject -Category "清理" -Label "回收站" -Path "回收站" -Action "清空" -Status "完成" -Detail "回收站已清空"))
    }
    catch {
        $script:CleanupResults.Add((New-ResultObject -Category "清理" -Label "回收站" -Path "回收站" -Action "清空" -Status "部分完成" -Detail $_.Exception.Message))
    }
}

function Get-DownloadsPath {
    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    $name = "{374DE290-123F-4565-9164-39C4925E467B}"
    $raw = (Get-ItemProperty -LiteralPath $regPath -Name $name -ErrorAction SilentlyContinue).$name
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return (Join-Path $env:USERPROFILE "Downloads")
    }
    return [Environment]::ExpandEnvironmentVariables($raw)
}

function Get-KnownFolderCandidates {
    $downloads = Get-DownloadsPath
    return @(
        [pscustomobject]@{ Name = "桌面"; SourcePath = [Environment]::GetFolderPath("Desktop"); RegistryName = "Desktop"; TargetPath = "D:\UserFolders\Desktop"; Method = "known-folder" }
        [pscustomobject]@{ Name = "下载"; SourcePath = $downloads; RegistryName = "{374DE290-123F-4565-9164-39C4925E467B}"; TargetPath = "D:\UserFolders\Downloads"; Method = "known-folder" }
        [pscustomobject]@{ Name = "文档"; SourcePath = [Environment]::GetFolderPath("MyDocuments"); RegistryName = "Personal"; TargetPath = "D:\UserFolders\Documents"; Method = "known-folder" }
        [pscustomobject]@{ Name = "图片"; SourcePath = [Environment]::GetFolderPath("MyPictures"); RegistryName = "My Pictures"; TargetPath = "D:\UserFolders\Pictures"; Method = "known-folder" }
        [pscustomobject]@{ Name = "视频"; SourcePath = [Environment]::GetFolderPath("MyVideos"); RegistryName = "My Video"; TargetPath = "D:\UserFolders\Videos"; Method = "known-folder" }
    )
}

function Get-AppDataMoveCandidates {
    $documents = [Environment]::GetFolderPath("MyDocuments")
    return @(
        [pscustomobject]@{ Name = "微信文件夹 WeChat Files"; SourcePath = Join-Path $documents "WeChat Files"; TargetPath = "D:\AppDataRelocated\WeChat Files"; Method = "junction"; ProcessNames = @("WeChat", "Weixin") }
        [pscustomobject]@{ Name = "微信文件夹 Weixin Files"; SourcePath = Join-Path $documents "Weixin Files"; TargetPath = "D:\AppDataRelocated\Weixin Files"; Method = "junction"; ProcessNames = @("WeChat", "Weixin") }
        [pscustomobject]@{ Name = "QQ 文件夹 Tencent Files"; SourcePath = Join-Path $documents "Tencent Files"; TargetPath = "D:\AppDataRelocated\Tencent Files"; Method = "junction"; ProcessNames = @("QQ") }
    )
}

function Get-RelocationPlan {
    $plan = New-Object System.Collections.Generic.List[object]
    $knownFolderThresholdBytes = 1GB
    $appDataThresholdBytes = 500MB

    foreach ($item in (Get-KnownFolderCandidates)) {
        if (-not (Test-Path -LiteralPath $item.SourcePath)) { continue }
        if (-not (Test-PathOnDrive -Path $item.SourcePath -Drive "C")) { continue }
        $size = Get-DirectorySizeBytes -Path $item.SourcePath
        if ($size -lt $knownFolderThresholdBytes) { continue }
        $plan.Add([pscustomobject]@{ Name = $item.Name; SourcePath = $item.SourcePath; TargetPath = $item.TargetPath; Method = $item.Method; RegistryName = $item.RegistryName; SizeBytes = $size; ProcessNames = @() })
    }

    foreach ($item in (Get-AppDataMoveCandidates)) {
        if (-not (Test-Path -LiteralPath $item.SourcePath)) { continue }
        if (-not (Test-PathOnDrive -Path $item.SourcePath -Drive "C")) { continue }
        $size = Get-DirectorySizeBytes -Path $item.SourcePath
        if ($size -lt $appDataThresholdBytes) { continue }
        $plan.Add([pscustomobject]@{ Name = $item.Name; SourcePath = $item.SourcePath; TargetPath = $item.TargetPath; Method = $item.Method; RegistryName = $null; SizeBytes = $size; ProcessNames = $item.ProcessNames })
    }

    return $plan
}

function Ensure-ParentDirectory {
    param([string]$Path)
    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Invoke-RobocopyMove {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target
    )

    Ensure-ParentDirectory -Path $Target
    if (-not (Test-Path -LiteralPath $Target)) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }

    $args = @($Source, $Target, "/MOVE", "/E", "/COPY:DAT", "/DCOPY:DAT", "/R:1", "/W:1", "/NFL", "/NDL", "/NJH", "/NJS", "/NP")
    $null = & robocopy.exe @args
    $code = $LASTEXITCODE
    if ($code -gt 7) {
        throw "robocopy 失败，退出码：$code"
    }
}

function Set-KnownFolderRegistry {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryName,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $userShell = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    $shell = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"

    Set-ItemProperty -LiteralPath $userShell -Name $RegistryName -Value $TargetPath
    try {
        Set-ItemProperty -LiteralPath $shell -Name $RegistryName -Value $TargetPath -ErrorAction Stop
    }
    catch {
        $script:Warnings.Add(("无法更新旧版路径注册表 {0}: {1}" -f $RegistryName, $_.Exception.Message))
    }
}

function Move-KnownFolderToD {
    param([Parameter(Mandatory = $true)][pscustomobject]$Item)

    if ($DryRun) {
        $script:RelocationResults.Add((New-ResultObject -Category "迁移" -Label $Item.Name -Path $Item.SourcePath -Action "预演" -Status "DryRun" -Detail ("将迁移到 {0}" -f $Item.TargetPath)))
        return
    }

    if (-not (Test-Path -LiteralPath $Item.SourcePath)) {
        $script:RelocationResults.Add((New-ResultObject -Category "迁移" -Label $Item.Name -Path $Item.SourcePath -Action "迁移" -Status "不存在" -Detail "源目录不存在"))
        return
    }

    Ensure-ParentDirectory -Path $Item.TargetPath
    if (-not (Test-Path -LiteralPath $Item.TargetPath)) {
        New-Item -ItemType Directory -Path $Item.TargetPath -Force | Out-Null
    }

    Invoke-RobocopyMove -Source $Item.SourcePath -Target $Item.TargetPath
    Set-KnownFolderRegistry -RegistryName $Item.RegistryName -TargetPath $Item.TargetPath
    $script:RelocationResults.Add((New-ResultObject -Category "迁移" -Label $Item.Name -Path $Item.SourcePath -Action "迁移已知目录" -Status "完成" -Detail ("已迁移到 {0}" -f $Item.TargetPath)))
}

function Ensure-ProcessesClosed {
    param(
        [string[]]$ProcessNames,
        [string]$Label
    )

    if (-not $ProcessNames -or $ProcessNames.Count -eq 0) { return $true }

    $running = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $ProcessNames -contains $_.ProcessName } |
        Select-Object -ExpandProperty ProcessName -Unique)

    if ($running.Count -eq 0) { return $true }

    $script:Warnings.Add(("{0} 仍在运行，暂时不能迁移 {1}。请关闭相关程序后再试。" -f ($running -join ", "), $Label))
    return $false
}

function Move-FolderWithJunctionToD {
    param([Parameter(Mandatory = $true)][pscustomobject]$Item)

    if ($DryRun) {
        $script:RelocationResults.Add((New-ResultObject -Category "迁移" -Label $Item.Name -Path $Item.SourcePath -Action "预演" -Status "DryRun" -Detail ("将迁移到 {0}，并保留连接点" -f $Item.TargetPath)))
        return
    }

    if (-not (Ensure-ProcessesClosed -ProcessNames $Item.ProcessNames -Label $Item.Name)) {
        $script:RelocationResults.Add((New-ResultObject -Category "迁移" -Label $Item.Name -Path $Item.SourcePath -Action "迁移并保留连接点" -Status "被占用" -Detail "相关程序仍在运行"))
        return
    }

    if (-not (Test-Path -LiteralPath $Item.SourcePath)) {
        $script:RelocationResults.Add((New-ResultObject -Category "迁移" -Label $Item.Name -Path $Item.SourcePath -Action "迁移并保留连接点" -Status "不存在" -Detail "源目录不存在"))
        return
    }

    Ensure-ParentDirectory -Path $Item.TargetPath
    if (Test-Path -LiteralPath $Item.TargetPath) {
        $script:RelocationResults.Add((New-ResultObject -Category "迁移" -Label $Item.Name -Path $Item.SourcePath -Action "迁移并保留连接点" -Status "已跳过" -Detail ("目标目录已存在：{0}" -f $Item.TargetPath)))
        return
    }

    Invoke-RobocopyMove -Source $Item.SourcePath -Target $Item.TargetPath

    if (Test-Path -LiteralPath $Item.SourcePath) {
        Remove-Item -LiteralPath $Item.SourcePath -Recurse -Force -ErrorAction SilentlyContinue
    }

    New-Item -ItemType Junction -Path $Item.SourcePath -Target $Item.TargetPath -Force | Out-Null
    $script:RelocationResults.Add((New-ResultObject -Category "迁移" -Label $Item.Name -Path $Item.SourcePath -Action "迁移并保留连接点" -Status "完成" -Detail ("已迁移到 {0}，并创建连接点" -f $Item.TargetPath)))
}

function Invoke-RelocationStep {
    $plan = @(Get-RelocationPlan | Sort-Object SizeBytes -Descending)
    if ($plan.Count -eq 0) {
        Write-Host ""
        Write-Host "没有发现需要迁移到 D 盘的大型受支持目录。" -ForegroundColor Green
        return
    }

    Write-Section "可选迁移计划：C 盘到 D 盘"
    $plan |
        Select-Object `
            @{Name = "名称"; Expression = { $_.Name } }, `
            @{Name = "方式"; Expression = { Get-DisplayMethod $_.Method } }, `
            @{Name = "源路径"; Expression = { $_.SourcePath } }, `
            @{Name = "目标路径"; Expression = { $_.TargetPath } }, `
            @{Name = "大小"; Expression = { Format-Bytes $_.SizeBytes } } |
        Format-Table -Wrap -AutoSize

    if ($SkipRelocationPrompts) {
        $script:Warnings.Add("已按参数跳过迁移确认，本轮未执行迁移到 D 盘。")
        return
    }

    $answer = Read-Host "是否现在将上面列出的目录统一迁移到 D 盘？[y/N]"
    if ($answer -notmatch '^(y|yes)$') {
        $script:Warnings.Add("用户取消了迁移到 D 盘的计划。")
        return
    }

    foreach ($item in $plan) {
        try {
            switch ($item.Method) {
                "known-folder" { Move-KnownFolderToD -Item $item }
                "junction" { Move-FolderWithJunctionToD -Item $item }
                default {
                    $script:RelocationResults.Add((New-ResultObject -Category "迁移" -Label $item.Name -Path $item.SourcePath -Action "跳过" -Status "不支持" -Detail ("未知迁移方式：{0}" -f $item.Method)))
                }
            }
        }
        catch {
            $script:RelocationResults.Add((New-ResultObject -Category "迁移" -Label $item.Name -Path $item.SourcePath -Action "迁移" -Status "失败" -Detail $_.Exception.Message))
        }
    }
}

function Invoke-ComponentStoreCleanup {
    if (-not $UseComponentStoreCleanup) { return }

    if ($DryRun) {
        $script:CleanupResults.Add((New-ResultObject -Category "清理" -Label "DISM 组件存储清理" -Path "C:\Windows\WinSxS" -Action "预演" -Status "DryRun" -Detail "将运行 DISM /StartComponentCleanup"))
        return
    }

    try {
        $proc = Start-Process -FilePath "dism.exe" -ArgumentList "/Online", "/Cleanup-Image", "/StartComponentCleanup" -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0) {
            $script:CleanupResults.Add((New-ResultObject -Category "清理" -Label "DISM 组件存储清理" -Path "C:\Windows\WinSxS" -Action "DISM" -Status "完成" -Detail "执行成功"))
        }
        else {
            $script:CleanupResults.Add((New-ResultObject -Category "清理" -Label "DISM 组件存储清理" -Path "C:\Windows\WinSxS" -Action "DISM" -Status "失败" -Detail ("DISM 退出码：{0}" -f $proc.ExitCode)))
        }
    }
    catch {
        $script:CleanupResults.Add((New-ResultObject -Category "清理" -Label "DISM 组件存储清理" -Path "C:\Windows\WinSxS" -Action "DISM" -Status "失败" -Detail $_.Exception.Message))
    }
}

function Get-CleanupTargets {
    $localAppData = $env:LOCALAPPDATA
    $roaming = $env:APPDATA
    $targets = @(
        [pscustomobject]@{ Label = "用户临时文件"; Path = $env:TEMP }
        [pscustomobject]@{ Label = "Windows 临时目录"; Path = "C:\Windows\Temp" }
        [pscustomobject]@{ Label = "Windows 更新下载缓存"; Path = "C:\Windows\SoftwareDistribution\Download" }
        [pscustomobject]@{ Label = "Delivery Optimization 缓存"; Path = "C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache" }
        [pscustomobject]@{ Label = "Chrome 缓存"; Path = Join-Path $localAppData "Google\Chrome\User Data\Default\Cache" }
        [pscustomobject]@{ Label = "Chrome Code Cache"; Path = Join-Path $localAppData "Google\Chrome\User Data\Default\Code Cache" }
        [pscustomobject]@{ Label = "Chrome GPU Cache"; Path = Join-Path $localAppData "Google\Chrome\User Data\Default\GPUCache" }
        [pscustomobject]@{ Label = "Chrome Service Worker CacheStorage"; Path = Join-Path $localAppData "Google\Chrome\User Data\Default\Service Worker\CacheStorage" }
        [pscustomobject]@{ Label = "Edge 缓存"; Path = Join-Path $localAppData "Microsoft\Edge\User Data\Default\Cache" }
        [pscustomobject]@{ Label = "Edge Code Cache"; Path = Join-Path $localAppData "Microsoft\Edge\User Data\Default\Code Cache" }
        [pscustomobject]@{ Label = "Edge GPU Cache"; Path = Join-Path $localAppData "Microsoft\Edge\User Data\Default\GPUCache" }
        [pscustomobject]@{ Label = "Edge Service Worker CacheStorage"; Path = Join-Path $localAppData "Microsoft\Edge\User Data\Default\Service Worker\CacheStorage" }
        [pscustomobject]@{ Label = "Brave 缓存"; Path = Join-Path $localAppData "BraveSoftware\Brave-Browser\User Data\Default\Cache" }
        [pscustomobject]@{ Label = "Firefox Cache2"; Path = Join-Path $localAppData "Mozilla\Firefox\Profiles" }
        [pscustomobject]@{ Label = "WPS 缓存"; Path = Join-Path $roaming "kingsoft\office6\cache" }
        [pscustomobject]@{ Label = "百度网盘缓存"; Path = Join-Path $roaming "baidunetdisk\Cache" }
    )

    $expandedTargets = New-Object System.Collections.Generic.List[object]
    foreach ($target in $targets) {
        if ($target.Label -eq "Firefox Cache2") {
            if (Test-Path -LiteralPath $target.Path) {
                Get-ChildItem -LiteralPath $target.Path -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    $cache2 = Join-Path $_.FullName "cache2"
                    if (Test-Path -LiteralPath $cache2) {
                        $expandedTargets.Add([pscustomobject]@{ Label = "Firefox Cache2 ($($_.Name))"; Path = $cache2 })
                    }
                }
            }
            continue
        }

        $expandedTargets.Add($target)
    }

    return $expandedTargets
}

function Show-Summary {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Before,
        [Parameter(Mandatory = $true)][pscustomobject]$After
    )

    $freed = [Math]::Max(0, ($After.Free - $Before.Free))
    Write-Section "清理结果汇总"
    [pscustomobject]@{
        "C 盘总容量"   = Format-Bytes $After.Total
        "清理前可用空间" = Format-Bytes $Before.Free
        "清理后可用空间" = Format-Bytes $After.Free
        "本轮释放空间"   = Format-Bytes $freed
    } | Format-List

    if ($script:CleanupResults.Count -gt 0) {
        Write-Host ""
        Write-Host "清理结果：" -ForegroundColor Yellow
        $script:CleanupResults |
            Select-Object `
                @{Name = "类别"; Expression = { $_.Category } }, `
                @{Name = "项目"; Expression = { $_.Label } }, `
                @{Name = "状态"; Expression = { Get-DisplayStatus $_.Status } }, `
                @{Name = "说明"; Expression = { $_.Detail } } |
            Format-Table -Wrap -AutoSize
    }

    if ($script:RelocationResults.Count -gt 0) {
        Write-Host ""
        Write-Host "迁移结果：" -ForegroundColor Yellow
        $script:RelocationResults |
            Select-Object `
                @{Name = "类别"; Expression = { $_.Category } }, `
                @{Name = "项目"; Expression = { $_.Label } }, `
                @{Name = "状态"; Expression = { Get-DisplayStatus $_.Status } }, `
                @{Name = "说明"; Expression = { $_.Detail } } |
            Format-Table -Wrap -AutoSize
    }

    if ($script:Warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "提示与未完成项：" -ForegroundColor Yellow
        $script:Warnings | ForEach-Object { Write-Host ("- " + $_) -ForegroundColor Yellow }
    }
}

Write-Section "C 盘安全清理"
Write-Host "C 盘安全清理与迁移工具包" -ForegroundColor Cyan
Write-Host ("演练模式：{0}" -f [bool]$DryRun) -ForegroundColor Gray
Write-Host ("当前用户：{0}" -f $script:CurrentUser) -ForegroundColor Gray
Write-Host ("管理员权限：{0}" -f ([bool]([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))) -ForegroundColor Gray

$beforeSnapshot = Get-DriveSnapshot -DriveLetter "C"

Write-Section "自动安全清理"
foreach ($target in (Get-CleanupTargets)) {
    try {
        Remove-ChildItemsBestEffort -Path $target.Path -Label $target.Label
    }
    catch {
        $script:CleanupResults.Add((New-ResultObject -Category "清理" -Label $target.Label -Path $target.Path -Action "删除子项" -Status "失败" -Detail $_.Exception.Message))
    }
}

Clear-RecycleBinSafe
Invoke-ComponentStoreCleanup
Invoke-RelocationStep

$afterSnapshot = Get-DriveSnapshot -DriveLetter "C"
Show-Summary -Before $beforeSnapshot -After $afterSnapshot

if (-not $NoPause) {
    Write-Host ""
    Read-Host "按回车退出"
}
