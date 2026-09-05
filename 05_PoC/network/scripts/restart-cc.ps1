# Rebuild + remplacement a chaud d'un chaincode CCaaS, sans toucher au cycle de
# vie (le package installe ne contient que l'adresse du service, pas le jar).
# Usage: .\restart-cc.ps1 -CC wcbdc   (ou bond, dvp...)
param([Parameter(Mandatory = $true)][string]$CC)
$ErrorActionPreference = 'Stop'

$net   = Split-Path $PSScriptRoot -Parent
$ccDir = Join-Path (Split-Path $net -Parent) "chaincode\$CC"
$stage = "$net\artifacts\staging\$CC"

Write-Host "[1/3] Copie staging + build du uberjar $CC..."
$old = docker ps -aq --filter "name=$CC-ccaas"
if ($old) { docker rm -f "$CC-ccaas" | Out-Null }
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null
Get-ChildItem $ccDir | Where-Object { $_.Name -notin @('.gradle', 'build', 'bin') } |
    ForEach-Object { Copy-Item -Recurse -Force $_.FullName $stage }
docker run --rm -m 2g --memory-swap 2g -e "GRADLE_OPTS=-Dorg.gradle.jvmargs=-Xmx512m" `
    -v "${stage}:/src" -w /src -v gradle-cache:/root/.gradle `
    --entrypoint /bin/bash hyperledger/fabric-javaenv:2.5 `
    -c "/root/chaincode-java/gradlew --no-daemon -q shadowJar"
if ($LASTEXITCODE -ne 0) { throw "build gradle a echoue" }

Write-Host "[2/3] Redemarrage du serveur $CC-ccaas..."
$PKG = (docker exec dvp-cli peer lifecycle chaincode calculatepackageid "/work/artifacts/$CC.tar.gz" | Select-Object -Last 1).Trim()
docker run -d --name "$CC-ccaas" --network dvp-network --network-alias "$CC.ccaas.dvp.poc" `
    --memory 512m -e "JAVA_TOOL_OPTIONS=-Xmx256m" `
    -v "${stage}\build\libs\chaincode.jar:/chaincode.jar" `
    -e CHAINCODE_SERVER_ADDRESS=0.0.0.0:9999 `
    -e CORE_CHAINCODE_ID_NAME=$PKG `
    -e CORE_PEER_TLS_ENABLED=false `
    --entrypoint java hyperledger/fabric-javaenv:2.5 -jar /chaincode.jar | Out-Null
if ($LASTEXITCODE -ne 0) { throw "demarrage du serveur CCaaS a echoue" }
Start-Sleep -Seconds 6

Write-Host "[3/3] Serveur $CC-ccaas relance (package $PKG)."