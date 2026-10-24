<#
  Night City Online (porte 2.5) - desinstalador.

  Remove exatamente os arquivos listados em red4ext\nco-instalados.txt e devolve o que o
  instalador tinha guardado na pasta de backup mais recente. Os saves nao sao tocados,
  exceto o save modelo MultiplayerStart.
#>
param([string]$GameDir)

$ErrorActionPreference = 'Stop'

if (-not $GameDir) {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    $libraries = @($steam)
    $vdf = if ($steam) { Join-Path $steam 'steamapps\libraryfolders.vdf' }
    if ($vdf -and (Test-Path $vdf)) {
        Select-String -Path $vdf -Pattern '"path"\s+"(.+?)"' | ForEach-Object { $libraries += $_.Matches[0].Groups[1].Value -replace '\\\\', '\' }
    }
    $GameDir = $libraries | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'steamapps\common\Cyberpunk 2077' } |
        Where-Object { Test-Path (Join-Path $_ 'red4ext\nco-instalados.txt') } | Select-Object -First 1
}
if (-not $GameDir) { throw 'Nao achei uma instalacao do Night City Online (red4ext\nco-instalados.txt).' }
if (Get-Process Cyberpunk2077 -ErrorAction SilentlyContinue) { throw 'Feche o Cyberpunk antes de desinstalar.' }

$manifest = Join-Path $GameDir 'red4ext\nco-instalados.txt'
$files = Get-Content $manifest
foreach ($relative in $files) {
    $target = Join-Path $GameDir $relative
    if (Test-Path $target) { Remove-Item $target -Force }
}
Remove-Item $manifest -Force

# Pastas que o instalador criou e que ficaram vazias - so as que continham arquivos da
# lista, nunca outras pastas vazias do jogo.
$dirs = foreach ($relative in $files) {
    $dir = Split-Path $relative
    while ($dir) { $dir; $dir = Split-Path $dir }
}
$dirs | Sort-Object -Unique | Sort-Object Length -Descending | ForEach-Object {
    $path = Join-Path $GameDir $_
    if ((Test-Path $path) -and -not (Get-ChildItem $path -Force)) { Remove-Item $path -Force }
}

$backup = Get-ChildItem $GameDir -Directory -Filter 'nco-backup-*' | Sort-Object Name -Descending | Select-Object -First 1
if ($backup) {
    Copy-Item (Join-Path $backup.FullName '*') $GameDir -Recurse -Force
    Write-Host "  Arquivos anteriores restaurados de $($backup.Name)."
}

$template = Join-Path $env:USERPROFILE 'Saved Games\CD Projekt Red\Cyberpunk 2077\MultiplayerStart'
if (Test-Path $template) { Remove-Item $template -Recurse -Force }

Write-Host "  Night City Online removido ($($files.Count) arquivos)." -ForegroundColor Green
Write-Host '  Lembre de apagar as opcoes de inicializacao na Steam.'
