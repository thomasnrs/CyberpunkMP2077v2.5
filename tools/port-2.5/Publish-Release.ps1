<#
  Publishes a player release: pushes the port and SDK branches, builds the package with a
  release tag, and creates the GitHub release with the zip attached. Players' "Jogar Night
  City Online" shortcut picks it up on its next start.

  Needs a GitHub login that git already holds (one interactive `git push` stores it in the
  Windows credential manager); the API token is read from there, never written anywhere.

  Usage:  .\tools\port-2.5\Publish-Release.ps1 -ServerIp 100.x.y.z [-Notes "what changed"]
#>
param(
    [Parameter(Mandatory)][string]$ServerIp,
    [string]$Notes = '',
    [string]$Repo = 'thomasnrs/CyberpunkMP2077v2.5'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$remote = "https://github.com/$Repo.git"

# 1. Code first, so a release never points at commits that are not on GitHub.
git -C (Join-Path $root 'vendor\RED4ext.SDK') push --no-tags $remote nosso-2.5:red4ext-sdk-2.5
if ($LASTEXITCODE -ne 0) { throw 'push do SDK falhou' }
git -C $root push --no-tags $remote nosso-2.5:main
if ($LASTEXITCODE -ne 0) { throw 'push do porte falhou' }

# 2. The package, stamped with the tag the updater compares against.
$commit = git -C $root rev-parse --short HEAD
$tag = "v2.5-{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmm'), $commit
& (Join-Path $PSScriptRoot 'Package-Client.ps1') -ServerIp $ServerIp -Tag $tag
$zip = Get-ChildItem (Join-Path (Split-Path $root) 'nco-dist') -Filter "NightCityOnline-2.5-*-$commit*.zip" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $zip) { throw 'pacote nao encontrado' }

# 3. The token git already stores for github.com.
$credential = "protocol=https`nhost=github.com`n`n" | git credential fill
$token = ($credential | Where-Object { $_ -like 'password=*' }) -replace '^password=', ''
if (-not $token) { throw 'nenhum login do GitHub guardado - faca um git push manual uma vez' }
$headers = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'nco-publish' }

$body = @{
    tag_name         = $tag
    target_commitish = 'main'
    name             = "Night City Online 2.5 - $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
    body             = "$Notes`n`ncommit $commit"
} | ConvertTo-Json
$release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases" -Method Post -Headers $headers -Body $body -ContentType 'application/json'

$upload = $release.upload_url -replace '\{.*\}$', ''
Invoke-RestMethod "$upload`?name=$($zip.Name)" -Method Post -Headers $headers -InFile $zip.FullName -ContentType 'application/zip' | Out-Null

Write-Host ''
Write-Host "  release $tag publicada: $($release.html_url)" -ForegroundColor Green
