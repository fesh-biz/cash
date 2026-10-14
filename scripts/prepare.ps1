# Подготовка проекта к сборке.
# 1) Flutter генерирует стандартные платформенные папки android/ и windows/
#    (существующие файлы не трогает).
# 2) Поверх кладутся наши настройки из папки platform/
#    (разрешения сети для Android, multicast-lock и т.п.).
# 3) Загружаются зависимости.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host '==> flutter create (android, windows)'
flutter create --project-name cash --org com.cash --platforms android,windows .
if ($LASTEXITCODE -ne 0) { throw 'flutter create завершился с ошибкой' }

Write-Host '==> Применяю настройки из platform/'
$src = Join-Path $root 'platform'
Get-ChildItem -Path $src -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length).TrimStart('\', '/')
    $dst = Join-Path $root $rel
    $dir = Split-Path -Parent $dst
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -Path $_.FullName -Destination $dst -Force
    Write-Host "    $rel"
}

# Заголовок окна в Windows
$mainCpp = Join-Path $root 'windows/runner/main.cpp'
if (Test-Path $mainCpp) {
    $text = [System.IO.File]::ReadAllText($mainCpp)
    $patched = $text.Replace('L"cash"', 'L"Cash"')
    if ($patched -cne $text) { [System.IO.File]::WriteAllText($mainCpp, $patched) }
}

# Android NDK: если версии, которую просит Flutter, нет в SDK, а другая установлена —
# используем самую новую установленную (иначе Gradle пытается скачать её сам и может упасть).
$gradle = Join-Path $root 'android/app/build.gradle.kts'
$sdkCandidates = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)
if ($env:LOCALAPPDATA) { $sdkCandidates += (Join-Path $env:LOCALAPPDATA 'Android\sdk') }
$sdk = $sdkCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($sdk -and (Test-Path $gradle)) {
    $ndkDir = Join-Path $sdk 'ndk'
    $ndks = @()
    if (Test-Path $ndkDir) {
        $ndks = Get-ChildItem -Path $ndkDir -Directory |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' -and (Test-Path (Join-Path $_.FullName 'source.properties')) } |
            Sort-Object { [version]$_.Name } -Descending
    }
    if ($ndks.Count -gt 0) {
        $ver = $ndks[0].Name
        $text = [System.IO.File]::ReadAllText($gradle)
        $patched = [regex]::Replace($text, 'ndkVersion\s*=\s*[^\r\n]+', "ndkVersion = `"$ver`"")
        if ($patched -cne $text) {
            [System.IO.File]::WriteAllText($gradle, $patched)
            Write-Host "    Android NDK: $ver"
        }
    } else {
        Write-Host '    Android NDK не установлен — Gradle попробует скачать его сам'
    }
}

Write-Host '==> flutter pub get'
flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'flutter pub get завершился с ошибкой' }
