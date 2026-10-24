<#
  Night City Online - manda os logs mais recentes para o servidor (POST /api/v1/logs/), onde
  quem hospeda le em logs\clients\<apelido>\. Chamado pelo atalho a cada inicio e pelo
  "Enviar logs". Silencioso: sem servidor ou sem rede, nao faz nada.
#>
param([string]$GameDir)

$ErrorActionPreference = 'SilentlyContinue'
$home_ = Join-Path $env:APPDATA 'NightCityOnline'
if (-not $GameDir -and (Test-Path (Join-Path $home_ 'jogo.txt'))) { $GameDir = (Get-Content (Join-Path $home_ 'jogo.txt') -TotalCount 1).Trim() }
$serverFile = Join-Path $home_ 'servidor.txt'
if (-not $GameDir -or -not (Test-Path $serverFile)) { return }
$server = (Get-Content $serverFile -TotalCount 1).Trim()
if (-not $server) { return }

$modLogs = Get-ChildItem (Join-Path $GameDir 'red4ext\plugins\zzzCyberpunkMP\logs') -Filter '*.log' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 2
$player = $env:COMPUTERNAME
foreach ($log in $modLogs) {
    $line = Select-String -Path $log.FullName -Pattern 'Display name: (\S+)' | Select-Object -First 1
    if ($line) { $player = $line.Matches[0].Groups[1].Value; break }
}

$files = @($modLogs)
$files += Get-ChildItem (Join-Path $GameDir 'red4ext\logs') -Filter 'red4ext-*.log' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$files += Get-Item (Join-Path $GameDir 'r6\logs\redscript_rCURRENT.log')

$sent = 0
foreach ($file in $files | Where-Object { $_ }) {
    if ($file.Length -gt 4MB) { continue }
    $name = [Uri]::EscapeDataString($file.Name)
    $uri = "http://${server}:11778/api/v1/logs/?player=$([Uri]::EscapeDataString($player))&file=$name"
    try {
        Invoke-RestMethod -Method Post -Uri $uri -Body ([IO.File]::ReadAllText($file.FullName)) -ContentType 'text/plain; charset=utf-8' -TimeoutSec 10 | Out-Null
        $sent++
    } catch { break }
}
if ($sent) { Write-Host "  $sent log(s) enviados para o servidor." -ForegroundColor DarkGray }
