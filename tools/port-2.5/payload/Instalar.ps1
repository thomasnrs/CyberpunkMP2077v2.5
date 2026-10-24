<#
  Night City Online (porte 2.5) - instalador.

  Copia os arquivos de jogo/ para a pasta do Cyberpunk 2077, instala o save modelo e
  mostra as opcoes de inicializacao da Steam. Tudo o que for copiado fica listado em
  red4ext\nco-instalados.txt, que o Desinstalar.ps1 usa para remover exatamente isso.
#>
param(
    [string]$GameDir,
    [ValidateSet('feminino', 'masculino')][string]$Corpo,
    [string]$ServidorIp
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$expectedProduct = '2.5'

function Find-GameDir {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    $libraries = @()
    if ($steam) {
        $libraries += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            Select-String -Path $vdf -Pattern '"path"\s+"(.+?)"' | ForEach-Object {
                $libraries += $_.Matches[0].Groups[1].Value -replace '\\\\', '\'
            }
        }
    }
    foreach ($lib in $libraries | Select-Object -Unique) {
        $candidate = Join-Path $lib 'steamapps\common\Cyberpunk 2077'
        if (Test-Path (Join-Path $candidate 'bin\x64\Cyberpunk2077.exe')) { return $candidate }
    }
    return $null
}

Write-Host ''
Write-Host '  Night City Online - porte para o Cyberpunk 2077 2.5' -ForegroundColor Cyan
Write-Host ''

if (-not $GameDir) { $GameDir = Find-GameDir }
if (-not $GameDir) { $GameDir = Read-Host '  Nao achei o jogo na Steam. Cole o caminho da pasta "Cyberpunk 2077"' }
$exe = Join-Path $GameDir 'bin\x64\Cyberpunk2077.exe'
if (-not (Test-Path $exe)) { throw "Cyberpunk2077.exe nao encontrado em $GameDir" }

$product = (Get-Item $exe).VersionInfo.ProductVersion
Write-Host "  Jogo:   $GameDir"
Write-Host "  Versao: $product"
if ($product -ne $expectedProduct) {
    Write-Host "  Este pacote foi feito para a versao $expectedProduct. Com outra versao o jogo provavelmente nao abre." -ForegroundColor Yellow
    if ((Read-Host '  Continuar mesmo assim? (s/n)') -ne 's') { exit 1 }
}

if (Get-Process Cyberpunk2077 -ErrorAction SilentlyContinue) { throw 'Feche o Cyberpunk antes de instalar.' }

# Arquivos do jogo. Nenhum arquivo original da CD Projekt e sobrescrito; se algum ja
# existir (outra versao de RED4ext, Codeware...), ele vai para a pasta de backup primeiro.
$source = Join-Path $here 'jogo'
$backup = Join-Path $GameDir ("nco-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$installed = New-Object System.Collections.Generic.List[string]

Get-ChildItem $source -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($source.Length + 1)
    $target = Join-Path $GameDir $relative
    if (Test-Path $target) {
        $saved = Join-Path $backup $relative
        New-Item -ItemType Directory -Force (Split-Path $saved) | Out-Null
        Copy-Item $target $saved -Force
    }
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    Copy-Item $_.FullName $target -Force
    $installed.Add($relative)
}

$manifest = Join-Path $GameDir 'red4ext\nco-instalados.txt'
$installed | Set-Content $manifest -Encoding utf8
Write-Host "  $($installed.Count) arquivos instalados." -ForegroundColor Green
if (Test-Path $backup) { Write-Host "  Arquivos que ja existiam foram guardados em: $backup" }

# Save modelo: o mundo onde o personagem aparece. O corpo nao muda depois dentro do jogo.
$saves = Join-Path $env:USERPROFILE 'Saved Games\CD Projekt Red\Cyberpunk 2077'
$templateDir = Join-Path $saves 'MultiplayerStart'
if (-not $Corpo) {
    Write-Host ''
    Write-Host '  Tipo de corpo do personagem (nao da para trocar depois dentro do jogo):'
    Write-Host '    1) feminino'
    Write-Host '    2) masculino'
    $Corpo = if ((Read-Host '  Escolha 1 ou 2') -eq '2') { 'masculino' } else { 'feminino' }
}
if (Test-Path $templateDir) { Remove-Item $templateDir -Recurse -Force }
Copy-Item (Join-Path $here "saves\MultiplayerStart-$Corpo") $templateDir -Recurse
$(if ($Corpo -eq 'masculino') { 'male' } else { 'female' }) | Set-Content (Join-Path $templateDir '.bodytype') -NoNewline -Encoding ascii
Write-Host "  Save modelo ($Corpo) instalado. Seus outros saves nao foram tocados." -ForegroundColor Green

# Opcoes de inicializacao. servidor.txt vem preenchido por quem gerou o pacote.
$defaultIp = '127.0.0.1'
$serverFile = Join-Path $here 'servidor.txt'
if (Test-Path $serverFile) { $defaultIp = (Get-Content $serverFile -TotalCount 1).Trim() }
if (-not $ServidorIp) { $ServidorIp = Read-Host "  IP do servidor (Enter = $defaultIp)" }
if (-not $ServidorIp) { $ServidorIp = $defaultIp }

# Conta no servidor sem Discord: o apelido aparece para os outros, a chave e a sua senha.
# Mesma chave = mesmo personagem salvo, entao ela fica guardada neste PC e e reaproveitada.
$keyDir = Join-Path $env:APPDATA 'NightCityOnline'
$keyFile = Join-Path $keyDir 'chave.txt'
if (Test-Path $keyFile) {
    $key = (Get-Content $keyFile -TotalCount 1).Trim()
} else {
    $chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $key = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    New-Item -ItemType Directory -Force $keyDir | Out-Null
    $key | Set-Content $keyFile -Encoding ascii
}
$nick = (Read-Host '  Seu apelido no jogo (sem espacos)') -replace '\s', '_'
if (-not $nick) { $nick = $env:USERNAME -replace '\s', '_' }

$options = "--online --ip=$ServidorIp --port=11778 -skipStartScreen --discord-name=$nick --discord-token=$key"

Write-Host ''
Write-Host '  Ultimo passo, na Steam:' -ForegroundColor Cyan
Write-Host '    Cyberpunk 2077 > botao direito > Propriedades > Geral > Opcoes de inicializacao'
Write-Host '    e cole isto (ja foi copiado para a area de transferencia):'
Write-Host ''
Write-Host "    $options" -ForegroundColor White
Write-Host ''
Set-Clipboard -Value $options -ErrorAction SilentlyContinue
Write-Host "  A parte --discord-token=... e a sua senha no servidor (guardada em $keyFile)."
Write-Host '  Nao passe ela para ninguem: quem tiver a chave entra como voce.'
Write-Host '  Para jogar single player normal, apague essas opcoes.'
Write-Host '  Para remover tudo, rode Desinstalar.bat.'
Write-Host ''
