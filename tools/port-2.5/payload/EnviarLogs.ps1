<#
  Night City Online - junta os logs do jogo e do mod num zip na area de trabalho, para mandar
  a quem hospeda o servidor quando algo da errado.
#>
$ErrorActionPreference = 'SilentlyContinue'
$home_ = Join-Path $env:APPDATA 'NightCityOnline'
$gameDir = if (Test-Path (Join-Path $home_ 'jogo.txt')) { (Get-Content (Join-Path $home_ 'jogo.txt') -TotalCount 1).Trim() } else { '' }
if (-not $gameDir) { Write-Host '  Nao sei onde o jogo esta. Rode o Instalar.bat de novo.' -ForegroundColor Red; exit 1 }

$stage = Join-Path $env:TEMP ('nco-logs-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $stage | Out-Null

function Copy-Newest([string]$dir, [string]$filter, [int]$count, [string]$into) {
    if (-not (Test-Path $dir)) { return }
    New-Item -ItemType Directory -Force (Join-Path $stage $into) | Out-Null
    Get-ChildItem $dir -Filter $filter -File | Sort-Object LastWriteTime -Descending | Select-Object -First $count |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $stage $into) }
}

Copy-Newest (Join-Path $gameDir 'red4ext\plugins\zzzCyberpunkMP\logs') '*.log' 3 'mod'
Copy-Newest (Join-Path $gameDir 'red4ext\logs') '*.log' 3 'red4ext'
Copy-Newest (Join-Path $gameDir 'r6\logs') '*.log' 2 'redscript'
foreach ($lib in 'ArchiveXL', 'Codeware', 'TweakXL') { Copy-Newest (Join-Path $gameDir "red4ext\plugins\$lib") '*.log' 1 $lib }

# O que esta instalado, sem a chave pessoal.
$saves = Join-Path $env:USERPROFILE 'Saved Games\CD Projekt Red\Cyberpunk 2077'
@(
    "versao instalada: $(Get-Content (Join-Path $home_ 'versao.txt') -TotalCount 1)"
    "jogo: $gameDir"
    "versao do jogo: $((Get-Item (Join-Path $gameDir 'bin\x64\Cyberpunk2077.exe')).VersionInfo.ProductVersion)"
    "save modelo presente: $(Test-Path (Join-Path $saves 'MultiplayerStart\sav.dat'))"
    "corpo do modelo: $(Get-Content (Join-Path $saves 'MultiplayerStart\.bodytype') -TotalCount 1)"
    "saves: $((Get-ChildItem $saves -Directory | Select-Object -ExpandProperty Name) -join ', ')"
) | Set-Content (Join-Path $stage 'resumo.txt') -Encoding utf8

$zip = Join-Path ([Environment]::GetFolderPath('Desktop')) ("logs-nightcity-{0}.zip" -f (Get-Date -Format 'yyyyMMdd-HHmm'))
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
Remove-Item $stage -Recurse -Force

$sendLogs = Join-Path $home_ 'EnviarLogsServidor.ps1'
if (Test-Path $sendLogs) { & $sendLogs -GameDir $gameDir }

Write-Host ''
Write-Host "  Pronto: $zip" -ForegroundColor Green
Write-Host '  Mande esse arquivo para quem hospeda o servidor.'
Start-Process explorer.exe "/select,`"$zip`""
