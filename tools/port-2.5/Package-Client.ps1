<#
  Builds the player package for the 2.5 port: a zip with the game-folder overlay, both
  template saves and the Portuguese installer, for players who do not build anything.

  Inputs (defaults assume the layout this port was made in, next to the repo):
    ..\red4ext            RED4ext built from wopss/RED4ext main (2.5 support)
    ..\deps-src\<lib>     Codeware / TweakXL / ArchiveXL built from their 2.5 PRs
    this repo             CyberpunkMP client + assets, staged with xmake install -o distrib
  Pinned downloads (cached in ..\.nco-cache): redscript, Input Loader, the ArchiveXL
  release (bundle/scripts are unchanged by its 2.5 PR) and the two template saves.

  Usage:  .\tools\port-2.5\Package-Client.ps1 [-Build] [-ServerIp <tailscale ip of the host>]
#>
param(
    [switch]$Build,
    [string]$ServerIp,
    [string]$Work = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$cache = Join-Path $Work '.nco-cache'
$outDir = Join-Path $Work 'nco-dist'
$stage = Join-Path $outDir 'stage'
$game = Join-Path $stage 'jogo'

$downloads = @{
    redscript   = 'https://github.com/jac3km4/redscript/releases/download/v0.5.32/redscript-v0.5.32-windows.zip'
    inputloader = 'https://github.com/jackhumbert/cyberpunk2077-input-loader/releases/download/v0.2.3/input_loader_v0.2.3.zip'
    archivexl   = 'https://github.com/psiberx/cp2077-archive-xl/releases/download/v1.27.5/ArchiveXL-1.27.5.zip'
    feminino    = 'https://github.com/ofmiceandcam98-eng/CyberpunkMP/releases/download/v0.3.124/character-template.zip'
    masculino   = 'https://github.com/ofmiceandcam98-eng/CyberpunkMP/releases/download/v0.3.124/character-template-male.zip'
}

function Get-Cached([string]$name) {
    New-Item -ItemType Directory -Force $cache | Out-Null
    $file = Join-Path $cache ([IO.Path]::GetFileName($downloads[$name]))
    if (-not (Test-Path $file)) {
        Write-Host "  baixando $name..."
        Invoke-WebRequest $downloads[$name] -OutFile $file
    }
    return $file
}

function Expand-Into([string]$zip, [string]$destination, [string]$skip) {
    $tmp = Join-Path $outDir ('x-' + [IO.Path]::GetFileNameWithoutExtension($zip))
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive $zip $tmp
    Get-ChildItem $tmp -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($tmp.Length + 1)
        if ($skip -and $relative -match $skip) { return }
        $target = Join-Path $destination $relative
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item $_.FullName $target -Force
    }
    Remove-Item $tmp -Recurse -Force
}

function Assert-File([string]$path) {
    if (-not (Test-Path $path -PathType Leaf)) { throw "faltando: $path" }
    return $path
}

if ($Build) {
    Push-Location $repo
    try {
        xmake build -y -j 4 Client
        if ($LASTEXITCODE -ne 0) { throw 'xmake build Client falhou' }
    } finally { Pop-Location }
}

# The mod folder as the game loads it, from the current build.
Push-Location $repo
try {
    foreach ($target in 'Client', 'Archives', 'Inputs', 'Tweaks', 'redscript') {
        xmake install -y -o distrib $target | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "xmake install $target falhou" }
    }
} finally { Pop-Location }

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $game | Out-Null

# RED4ext
$r4 = Join-Path $Work 'red4ext\build\bin'
New-Item -ItemType Directory -Force (Join-Path $game 'bin\x64'), (Join-Path $game 'red4ext\plugins') | Out-Null
Copy-Item (Assert-File (Join-Path $r4 'winmm.dll')) (Join-Path $game 'bin\x64\winmm.dll')
Copy-Item (Assert-File (Join-Path $r4 'RED4ext.dll')) (Join-Path $game 'red4ext\RED4ext.dll')

# redscript and Input Loader as released. Input Loader regenerates r6\cache at every start,
# so its shipped copies (2025 game data) are left out.
Expand-Into (Get-Cached 'redscript') $game
Expand-Into (Get-Cached 'inputloader') $game '^r6\\cache\\'

# Codeware and TweakXL: their own packaging (scripts from the 2.5 PRs) plus the built DLL,
# which that packaging leaves out.
foreach ($lib in 'Codeware', 'TweakXL') {
    $src = Join-Path $Work "deps-src\$lib"
    $zip = Get-ChildItem (Join-Path $src 'build\dist') -Filter '*.zip' | Where-Object Name -notmatch 'pdb' | Select-Object -First 1
    if (-not $zip) { throw "sem pacote em deps-src\$lib\build\dist - rode tools\dist\package-mod.ps1 la (pwsh)" }
    Expand-Into $zip.FullName $game
    $dll = Join-Path $game "red4ext\plugins\$lib\$lib.dll"
    if (Test-Path $dll -PathType Container) { Remove-Item $dll -Recurse -Force }
    Copy-Item (Assert-File (Join-Path $src "build\windows\x64\release\$lib.dll")) $dll
}

# ArchiveXL: the release package (its 2.5 PR changes only C++) with the built DLL.
Expand-Into (Get-Cached 'archivexl') $game
Copy-Item (Assert-File (Join-Path $Work 'deps-src\ArchiveXL\build\windows\x64\release\ArchiveXL.dll')) (Join-Path $game 'red4ext\plugins\ArchiveXL\ArchiveXL.dll') -Force

# The mod. zzz sorts it after the frameworks it depends on.
$mod = Join-Path $repo 'distrib\launcher\mod'
$modTarget = Join-Path $game 'red4ext\plugins\zzzCyberpunkMP'
Copy-Item $mod $modTarget -Recurse
Remove-Item (Join-Path $modTarget 'logs') -Recurse -Force -ErrorAction SilentlyContinue

# Template saves, one per body type.
foreach ($body in 'feminino', 'masculino') {
    Expand-Archive (Get-Cached $body) (Join-Path $stage "saves\MultiplayerStart-$body")
}

Copy-Item (Join-Path $PSScriptRoot 'payload\*') $stage
if ($ServerIp) { $ServerIp | Set-Content (Join-Path $stage 'servidor.txt') -Encoding ascii }

$commit = git -C $repo rev-parse --short HEAD
$dirty = if (git -C $repo status --porcelain -- code vendor) { '-modificado' } else { '' }
@(
    "Night City Online - porte 2.5"
    "gerado:       $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    "commit:       $commit$dirty"
    "jogo alvo:    Cyberpunk 2077 2.5 (3.0.88.46235)"
    "RED4ext:      $(git -C (Join-Path $Work 'red4ext') rev-parse --short HEAD)"
    "Codeware:     $(git -C (Join-Path $Work 'deps-src\Codeware') rev-parse --short HEAD)"
    "TweakXL:      $(git -C (Join-Path $Work 'deps-src\TweakXL') rev-parse --short HEAD)"
    "ArchiveXL:    $(git -C (Join-Path $Work 'deps-src\ArchiveXL') rev-parse --short HEAD)"
) | Set-Content (Join-Path $stage 'VERSAO.txt') -Encoding utf8

$zipPath = Join-Path $outDir ("NightCityOnline-2.5-{0}-{1}{2}.zip" -f (Get-Date -Format 'yyyyMMdd'), $commit, $dirty)
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath
Remove-Item $stage -Recurse -Force

Write-Host ''
Write-Host "  pacote: $zipPath ($([math]::Round((Get-Item $zipPath).Length / 1MB, 1)) MB)" -ForegroundColor Green
