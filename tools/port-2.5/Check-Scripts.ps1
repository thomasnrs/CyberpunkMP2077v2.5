<#
  Compiles the mod's redscript offline, exactly as the game would at start-up, so a syntax or
  type error is caught here instead of taking every script in the mod down in someone's game.

  The game's scc.exe (redscript) takes ONE scripts folder and the cache FILE to write:
      scc -compile <scripts dir> <final.redscripts>
  A second folder passed positionally is read as the cache file - which is how a stray
  "redscript.redscripts.ts" once appeared next to the mod's scripts. So everything the game
  compiles (its plugins' scripts plus ours) is copied into one temporary tree first, and the
  vanilla bundle is copied beside it so the real cache is never touched.

  Usage:  .\tools\port-2.5\Check-Scripts.ps1 [-Game <Cyberpunk 2077 folder>]
  On failure scc also shows an error dialog - click OK; the errors are printed here too.
#>
param(
    [string]$Game = 'C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077'
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ("cpmp-scc-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$scripts = Join-Path $work 'scripts'
$cache = Join-Path $work 'cache'
New-Item -ItemType Directory $scripts, $cache | Out-Null

foreach ($plugin in 'ArchiveXL', 'Codeware', 'TweakXL') {
    $dir = Join-Path $Game "red4ext\plugins\$plugin\Scripts"
    if (Test-Path $dir) { Copy-Item $dir (Join-Path $scripts "_$plugin") -Recurse }
}
Copy-Item (Join-Path $repo 'code\assets\redscript') (Join-Path $scripts '_cpmp') -Recurse
Copy-Item (Join-Path $Game 'r6\cache\final.redscripts') (Join-Path $cache 'final.redscripts')

$output = & (Join-Path $Game 'engine\tools\scc.exe') -compile $scripts (Join-Path $cache 'final.redscripts') 2>&1
$output | Where-Object { $_ -notmatch '\.reds$' } | ForEach-Object { "$_" }

if ($output -match 'Compilation complete') {
    Write-Host 'scripts OK' -ForegroundColor Green
    exit 0
}
Write-Host 'scripts FAILED - see the errors above' -ForegroundColor Red
exit 1
