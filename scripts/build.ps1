# Сборка Cash на Windows: тесты, Windows-приложение и APK для Android.
# Результат — в папке dist\.
#
#   .\build.bat                 всё
#   .\build.bat -SkipAndroid    только Windows
#   .\build.bat -SkipWindows    только APK

param(
    [switch]$SkipAndroid,
    [switch]$SkipWindows,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter не найден. Установите Flutter SDK и добавьте flutter\bin в PATH (см. README.md).'
}

& (Join-Path $PSScriptRoot 'prepare.ps1')

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# Запуск команды с записью вывода в лог (stderr тоже, без остановки на предупреждениях).
function Invoke-Logged([string]$LogName, [scriptblock]$Command) {
    $log = Join-Path $dist $LogName
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { "$($_.TargetObject)" } else { "$_" } } | Tee-Object -FilePath $log
    } finally {
        $ErrorActionPreference = $old
    }
}

if (-not $SkipTests) {
    Write-Host '==> flutter test'
    Invoke-Logged 'log-test.txt' { flutter test --reporter expanded }
    if ($LASTEXITCODE -ne 0) { throw 'Тесты не прошли (подробности: dist\log-test.txt)' }
}

if (-not $SkipWindows) {
    Write-Host '==> flutter build windows'
    # Flutter под Windows иногда не обновляет ресурсы (в т.ч. урезанный шрифт
    # иконок) — новые иконки не видны. Удаляем старые копии, чтобы собрались заново.
    foreach ($stale in 'build\flutter_assets', 'build\windows\x64\runner\Release\data\flutter_assets') {
        $p = Join-Path $root $stale
        if (Test-Path $p) { Remove-Item -Recurse -Force $p }
    }
    # Полный шрифт иконок (+1,5 МБ): иконки не пропадут, даже если кэш снова устареет.
    Invoke-Logged 'log-windows.txt' { flutter build windows --release --no-tree-shake-icons }
    if ($LASTEXITCODE -ne 0) { throw 'Сборка Windows не удалась (подробности: dist\log-windows.txt)' }
    $out = Join-Path $dist 'Cash-windows'
    if (Test-Path $out) { Remove-Item -Recurse -Force $out }
    Copy-Item -Recurse -Path (Join-Path $root 'build\windows\x64\runner\Release') -Destination $out
    # Библиотеки Visual C++, чтобы программа запускалась на любом Windows 10
    foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
        $p = Join-Path $env:WINDIR "System32\$dll"
        if (Test-Path $p) { Copy-Item $p $out -Force }
    }
    Write-Host "    Windows: $out\cash.exe"
}

if (-not $SkipAndroid) {
    Write-Host '==> flutter build apk'
    Invoke-Logged 'log-android.txt' { flutter build apk --release }
    if ($LASTEXITCODE -ne 0) { throw 'Сборка APK не удалась (подробности: dist\log-android.txt)' }
    Copy-Item (Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk') (Join-Path $dist 'Cash.apk') -Force
    Write-Host "    Android: $dist\Cash.apk"
}

Write-Host ''
Write-Host "Готово. Результат в $dist"
