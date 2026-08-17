# Arrete le reseau. -Reset supprime aussi identites et genesis block (repart de zero).
param([switch]$Reset)
$ErrorActionPreference = 'Stop'
$net = Split-Path $PSScriptRoot -Parent
Set-Location $net

docker compose down --volumes --remove-orphans

# Serveurs de chaincode CCaaS (lances via docker run, hors compose)
$ccaas = docker ps -aq --filter "name=-ccaas"
if ($ccaas) { docker rm -f $ccaas }

# Conteneurs et images de chaincode lances par les peers (hors compose)
$ccContainers = docker ps -aq --filter "name=dev-peer0"
if ($ccContainers) { docker rm -f $ccContainers }
$ccImages = docker images -q --filter "reference=dev-peer0*"
if ($ccImages) { docker rmi -f $ccImages }

if ($Reset) {
    if (Test-Path "$net\crypto")    { Remove-Item -Recurse -Force "$net\crypto" }
    if (Test-Path "$net\artifacts") { Remove-Item -Recurse -Force "$net\artifacts" }
    Write-Host "Reseau arrete et reinitialise (identites et genesis supprimes)."
} else {
    Write-Host "Reseau arrete. Les identites et le genesis sont conserves."
}
