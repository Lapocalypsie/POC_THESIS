# Reprise apres redemarrage de Docker Desktop: attend le moteur, remonte le
# reseau, redemarre le serveur CCaaS avec le jar refactore, verifie l'etat.
$ErrorActionPreference = 'Continue'
$net   = Split-Path $PSScriptRoot -Parent
$stage = "$net\artifacts\staging\wcbdc"

$ready = $false
foreach ($i in 1..30) {
    $v = docker info --format "{{.ServerVersion}}" 2>$null
    if ($LASTEXITCODE -eq 0 -and $v) { $ready = $true; Write-Output "engine pret ($v)"; break }
    Start-Sleep -Seconds 10
}
if (-not $ready) { Write-Output "ECHEC: moteur docker indisponible"; exit 1 }

Set-Location $net
docker compose up -d 2>&1 | Select-Object -Last 3
Start-Sleep -Seconds 8

docker run --rm -v "${stage}:/src" -w /src -v gradle-cache:/root/.gradle `
    --entrypoint /bin/bash hyperledger/fabric-javaenv:2.5 `
    -c "/root/chaincode-java/gradlew --no-daemon -q shadowJar"
if ($LASTEXITCODE -ne 0) { Write-Output "ECHEC build"; exit 1 }

$c = docker ps -aq --filter "name=wcbdc-ccaas"
if ($c) { docker rm -f $c | Out-Null }
$PKG = (docker exec dvp-cli peer lifecycle chaincode calculatepackageid /work/artifacts/wcbdc.tar.gz | Select-Object -Last 1).Trim()
docker run -d --name wcbdc-ccaas --network dvp-network --network-alias wcbdc.ccaas.dvp.poc `
    -v "${stage}\build\libs\chaincode.jar:/chaincode.jar" `
    -e CHAINCODE_SERVER_ADDRESS=0.0.0.0:9999 -e CORE_CHAINCODE_ID_NAME=$PKG -e CORE_PEER_TLS_ENABLED=false `
    --entrypoint java hyperledger/fabric-javaenv:2.5 -jar /chaincode.jar | Out-Null
Start-Sleep -Seconds 8

$BA = @(
    '-e','CORE_PEER_LOCALMSPID=BankAMSP',
    '-e','CORE_PEER_ADDRESS=peer0.banka.dvp.poc:9051',
    '-e','CORE_PEER_MSPCONFIGPATH=/work/crypto/peerOrganizations/banka.dvp.poc/users/Admin@banka.dvp.poc/msp',
    '-e','CORE_PEER_TLS_ROOTCERT_FILE=/work/crypto/peerOrganizations/banka.dvp.poc/peers/peer0.banka.dvp.poc/tls/ca.crt'
)
$balA = & docker exec @BA dvp-cli peer chaincode query -C dvp-channel -n wcbdc -c '{\"function\":\"balanceOf\",\"Args\":[\"BankAMSP\"]}'
$balB = & docker exec @BA dvp-cli peer chaincode query -C dvp-channel -n wcbdc -c '{\"function\":\"balanceOf\",\"Args\":[\"BankBMSP\"]}'
$sup  = & docker exec @BA dvp-cli peer chaincode query -C dvp-channel -n wcbdc -c '{\"function\":\"totalSupply\",\"Args\":[]}'
Write-Output "RESULTAT -> BankA: $balA | BankB: $balB | supply: $sup (attendu 750000/750000/1500000)"