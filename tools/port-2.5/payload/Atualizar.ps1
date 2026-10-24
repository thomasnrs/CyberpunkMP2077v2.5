<#
  Night City Online (porte 2.5) - atualiza e abre o jogo.

  Confere a ultima release no GitHub; se for mais nova que a instalada, baixa e copia os
  arquivos de jogo/ por cima (o save, a chave e as opcoes da Steam nao sao tocados). Depois
  abre o Cyberpunk pela Steam. Roda a partir de %APPDATA%\NightCityOnline, onde o
  instalador o deixa, e se atualiza junto.
#>
param([switch]$SemJogo)

$ErrorActionPreference = 'Stop'
$repo = 'thomasnrs/CyberpunkMP2077v2.5'
$home_ = Join-Path $env:APPDATA 'NightCityOnline'
$installedFile = Join-Path $home_ 'versao.txt'
$gameFile = Join-Path $home_ 'jogo.txt'

function Start-Game {
    if (-not $SemJogo) { Start-Process 'steam://rungameid/1091500' }
}

Write-Host ''
Write-Host '  Night City Online - verificando atualizacao...' -ForegroundColor Cyan

try {
    $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'NightCityOnline-updater' } -TimeoutSec 20
} catch {
    Write-Host '  Sem internet ou GitHub fora do ar - abrindo o jogo com a versao atual.' -ForegroundColor Yellow
    Start-Game
    exit 0
}

$installed = if (Test-Path $installedFile) { (Get-Content $installedFile -TotalCount 1).Trim() } else { '' }
if ($release.tag_name -eq $installed) {
    Write-Host "  Ja esta na versao mais nova ($installed)." -ForegroundColor Green
    Start-Game
    exit 0
}

$asset = $release.assets | Where-Object { $_.name -like 'NightCityOnline-2.5-*.zip' } | Select-Object -First 1
if (-not $asset) {
    Write-Host '  A release nova nao tem o pacote - abrindo o jogo com a versao atual.' -ForegroundColor Yellow
    Start-Game
    exit 0
}

$gameDir = if (Test-Path $gameFile) { (Get-Content $gameFile -TotalCount 1).Trim() } else { '' }
if (-not $gameDir -or -not (Test-Path (Join-Path $gameDir 'bin\x64\Cyberpunk2077.exe'))) {
    throw 'Nao sei onde o jogo esta instalado. Rode o Instalar.bat do pacote mais uma vez.'
}

while (Get-Process Cyberpunk2077 -ErrorAction SilentlyContinue) {
    Write-Host '  Feche o Cyberpunk para atualizar e aperte Enter...' -ForegroundColor Yellow
    Read-Host | Out-Null
}

Write-Host "  Baixando $($release.tag_name)..."
$work = Join-Path $env:TEMP ('nco-update-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $work | Out-Null
try {
    $zip = Join-Path $work $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive $zip (Join-Path $work 'x')
    $source = Join-Path $work 'x\jogo'

    $manifest = Join-Path $gameDir 'red4ext\nco-instalados.txt'
    $listed = New-Object System.Collections.Generic.HashSet[string]
    if (Test-Path $manifest) { Get-Content $manifest | ForEach-Object { [void]$listed.Add($_) } }

    Get-ChildItem $source -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($source.Length + 1)
        $target = Join-Path $gameDir $relative
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item $_.FullName $target -Force
        [void]$listed.Add($relative)
    }
    $listed | Sort-Object | Set-Content $manifest -Encoding utf8

    # O save modelo do mesmo corpo que o jogador escolheu na instalacao. Os personagens ficam
    # no servidor, entao trocar o modelo nao perde nada.
    $template = Join-Path $env:USERPROFILE 'Saved Games\CD Projekt Red\Cyberpunk 2077\MultiplayerStart'
    $bodyFile = Join-Path $template '.bodytype'
    $body = if ((Test-Path $bodyFile) -and (Get-Content $bodyFile -TotalCount 1) -eq 'male') { 'masculino' } else { 'feminino' }
    $newTemplate = Join-Path $work "x\saves\MultiplayerStart-$body"
    if (Test-Path (Join-Path $newTemplate 'sav.dat')) {
        if (Test-Path $template) { Remove-Item $template -Recurse -Force }
        Copy-Item $newTemplate $template -Recurse
        $(if ($body -eq 'masculino') { 'male' } else { 'female' }) | Set-Content $bodyFile -NoNewline -Encoding ascii
    }

    # O proprio atualizador e os scripts que vem no pacote.
    foreach ($script in 'Atualizar.ps1', 'Desinstalar.ps1', 'Desinstalar.bat') {
        $new = Join-Path $work "x\$script"
        if (Test-Path $new) { Copy-Item $new (Join-Path $home_ $script) -Force }
    }

    $release.tag_name | Set-Content $installedFile -Encoding ascii
    Write-Host "  Atualizado para $($release.tag_name)." -ForegroundColor Green
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Start-Game
