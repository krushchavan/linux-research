# Live progress view for the plain-language conversion.
# Usage:  powershell -File scripts\explain-progress.ps1          (refreshes every 15s, Ctrl+C to stop)
#         powershell -File scripts\explain-progress.ps1 -Once
param([int]$Interval = 15, [switch]$Once)

$repo  = Split-Path -Parent $PSScriptRoot
$queue = Join-Path $repo 'explain-queue.md'
$log   = Join-Path $repo 'explain-progress.log'
$lock  = Join-Path $repo '.git\explain-run.lock'

do {
    $lines   = Get-Content $queue
    $done    = @($lines | Where-Object { $_ -like '- `[x`]*' }).Count
    $todo    = @($lines | Where-Object { $_ -like '- `[ `]*' }).Count
    $current = @($lines | Where-Object { $_ -like '- `[>`]*' }) -replace '^- \[>\] ', ''
    $total   = $done + $todo + $current.Count
    $pct     = if ($total) { [math]::Round(100 * $done / $total, 1) } else { 0 }

    $sync = git -C $repo status -sb 2>$null | Select-Object -First 1
    $ahead = if ($sync -match 'ahead (\d+)') { "$($Matches[1]) commit(s) not yet pushed" } else { 'in sync with GitHub (as of last fetch)' }
    $runState = if (Test-Path $lock) { "RUNNING (lock $(Get-Content $lock))" } else { 'idle' }

    Clear-Host
    Write-Host "Plain-language conversion - $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan
    Write-Host ("Progress : {0}/{1} notes ({2}%)" -f $done, $total, $pct)
    $bar = [int]($pct / 2); Write-Host ('[' + ('#' * $bar) + ('.' * (50 - $bar)) + ']')
    Write-Host "Run      : $runState"
    Write-Host "Current  : $(if ($current) { $current -join ', ' } else { '-' })"
    Write-Host "Git      : $ahead"
    Write-Host ""
    Write-Host "Recent conversions:" -ForegroundColor Cyan
    git -C $repo log --since='24 hours ago' --grep='^explain:' --format='  %ad  %s' --date=format:'%m-%d %H:%M' -n 10
    if (Test-Path $log) {
        Write-Host ""
        Write-Host "Run log (explain-progress.log):" -ForegroundColor Cyan
        Get-Content $log -Tail 8 | ForEach-Object { "  $_" }
    }
    if (-not $Once) { Start-Sleep -Seconds $Interval }
} while (-not $Once)
