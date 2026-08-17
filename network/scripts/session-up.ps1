# Demarrage de session du PoC: remonte le reseau compose puis (re)cree les
# 9 serveurs de chaincode par organisation. Idempotent - a lancer apres chaque
# demarrage de Docker Desktop. Le ledger vit dans les volumes nommes.
$ErrorActionPreference = 'Stop'
$net = Split-Path $PSScriptRoot -Parent

Set-Location $net
docker compose up -d
Start-Sleep -Seconds 5

$CCS = @(
    @{ cc = 'bond';  orgs = @('csd', 'banka', 'bankb') },
    @{ cc = 'wcbdc'; orgs = @('centralbank', 'banka', 'bankb') },
    @{ cc = 'dvp';   orgs = @('centralbank', 'banka', 'bankb') }
)

foreach ($entry in $CCS) {
    $cc = $entry.cc
    foreach ($org in $entry.orgs) {
        $name = "$cc-$org-ccaas"
        $existing = docker ps -aq --filter "name=$name"
        if ($existing) {
            $running = docker ps -q --filter "name=$name"
            if (-not $running) { docker start $name | Out-Null; Write-Host "demarre: $name" }
            continue
        }
        $PKG = (docker exec dvp-cli peer lifecycle chaincode calculatepackageid "/work/artifacts/$cc-$org.tar.gz" | Select-Object -Last 1).Trim()
        docker run -d --name $name --network dvp-network `
            --network-alias "$cc.$org.ccaas.dvp.poc" `
            --restart unless-stopped `
            --memory 768m -e "JAVA_TOOL_OPTIONS=-Xmx192m" `
            -v "${net}\artifacts\staging\$cc\build\libs\chaincode.jar:/chaincode.jar" `
            -e CHAINCODE_SERVER_ADDRESS=0.0.0.0:9999 `
            -e CORE_CHAINCODE_ID_NAME=$PKG `
            -e CORE_PEER_TLS_ENABLED=false `
            --entrypoint java hyperledger/fabric-javaenv:2.5 -jar /chaincode.jar | Out-Null
        Write-Host "cree: $name ($PKG)"
    }
}

Start-Sleep -Seconds 10
$count = (docker ps --format "{{.Names}}" | Measure-Object).Count
Write-Host ""
Write-Host "Conteneurs actifs: $count (attendu 16). Reseau pret."