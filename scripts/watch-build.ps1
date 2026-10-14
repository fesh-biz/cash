# Автосборка: следит за папкой проекта и после каждого нового коммита
# запускает scripts\build.ps1 (тесты, Windows, APK).
#
# Состояние последней сборки — в dist\build-status.json (его читает Claude,
# чтобы узнать, прошли ли тесты), полный вывод — в dist\log-build.txt.
#
#   watch-build.bat              следить и собирать
#   watch-build.bat -Interval 10 проверять раз в 10 секунд (по умолчанию 5)

param([int]$Interval = 5)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$statusFile = Join-Path $dist 'build-status.json'
$logFile = Join-Path $dist 'log-build.txt'
$utf8 = New-Object System.Text.UTF8Encoding($false)

# Текущий коммит: через git, а если его нет в PATH — прямо из .git.
function Get-Head {
    try {
        $h = (& git -C $root rev-parse HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $h) { return $h.Trim() }
    } catch {}
    $headFile = Join-Path $root '.git\HEAD'
    if (-not (Test-Path $headFile)) { return $null }
    $head = (Get-Content $headFile -Raw).Trim()
    if ($head -notmatch '^ref: (.+)$') { return $head }
    $ref = $Matches[1]
    $refFile = Join-Path $root ('.git\' + $ref.Replace('/', '\'))
    if (Test-Path $refFile) { return (Get-Content $refFile -Raw).Trim() }
    $packed = Join-Path $root '.git\packed-refs'
    if (Test-Path $packed) {
        foreach ($line in Get-Content $packed) {
            if ($line -match "^([0-9a-f]{40}) $([regex]::Escape($ref))$") { return $Matches[1] }
        }
    }
    return $null
}

function Write-Status([hashtable]$s) {
    $json = $s | ConvertTo-Json
    [System.IO.File]::WriteAllText($statusFile, $json, $utf8)
}

function Read-LastBuilt {
    if (-not (Test-Path $statusFile)) { return $null }
    try {
        $s = [System.IO.File]::ReadAllText($statusFile, $utf8) | ConvertFrom-Json
        if ($s.state -eq 'running') { return $null }   # прошлая сборка прервана
        return $s.commit
    } catch { return $null }
}

$lastBuilt = Read-LastBuilt
Write-Host "Автосборка Cash: слежу за $root (раз в $Interval с). Закрыть — Ctrl+C."

while ($true) {
    $head = Get-Head
    if ($head -and $head -ne $lastBuilt) {
        $short = $head.Substring(0, 7)
        $started = Get-Date
        Write-Host ''
        Write-Host "[$($started.ToString('HH:mm:ss'))] Новый коммит $short — собираю..."
        Write-Status @{ state = 'running'; commit = $head; started = $started.ToString('o') }

        # Сборка в отдельном процессе: её ошибка не останавливает наблюдение.
        $build = Join-Path $PSScriptRoot 'build.ps1'
        $lines = New-Object System.Collections.Generic.List[string]
        # Предупреждения в stderr не должны прерывать наблюдение.
        $ErrorActionPreference = 'Continue'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $build 2>&1 | ForEach-Object {
            $line = "$_"
            $lines.Add($line)
            Write-Host $line
        }
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        [System.IO.File]::WriteAllLines($logFile, $lines, $utf8)

        $finished = Get-Date
        $ok = ($code -eq 0)
        $tail = ($lines | Select-Object -Last 25) -join "`n"
        Write-Status @{
            state    = $(if ($ok) { 'ok' } else { 'failed' })
            commit   = $head
            started  = $started.ToString('o')
            finished = $finished.ToString('o')
            seconds  = [int]($finished - $started).TotalSeconds
            exitCode = $code
            tail     = $tail
        }
        $lastBuilt = $head
        $mark = $(if ($ok) { 'готово' } else { 'ОШИБКА (подробности: dist\log-build.txt)' })
        Write-Host "[$($finished.ToString('HH:mm:ss'))] Коммит ${short}: $mark"
        if (-not $ok) { [console]::Beep(440, 400) }
    }
    Start-Sleep -Seconds $Interval
}
