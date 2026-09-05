# Rebuild + hot-swap des trois chaincodes puis tests de fumee.
# Les serveurs CCaaS sont arretes pendant les builds pour minimiser la
# pression memoire (VM 6GB): un seul processus Java lourd a la fois.
$ErrorActionPreference = 'Stop'

Set-Location (Split-Path $PSScriptRoot -Parent)
docker compose up -d
Start-Sleep -Seconds 5

$running = docker ps -q --filter "name=-ccaas"
if ($running) { docker stop $running | Out-Null; Write-Host "Serveurs CCaaS arretes pendant les builds." }

& "$PSScriptRoot\restart-cc.ps1" -CC bond
& "$PSScriptRoot\restart-cc.ps1" -CC wcbdc
& "$PSScriptRoot\restart-cc.ps1" -CC dvp
Start-Sleep -Seconds 5

& "$PSScriptRoot\smoke-dvp.ps1"