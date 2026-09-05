# Execute la suite T1-T9 du chapitre 5 (05_PoC/tests) dans un conteneur relie
# au reseau du PoC. Le rapport JUnit (XML + HTML) est l'artefact de preuve
# de la Figure 5.2 et de l'Annexe A du memoire.
# Prerequis: reseau up, chaincodes deployes, smoke tests passes.
$ErrorActionPreference = 'Stop'

$net    = Split-Path $PSScriptRoot -Parent
$root   = Split-Path $net -Parent
$tests  = Join-Path $root 'tests'
$crypto = Join-Path $net 'crypto'

Write-Host "Execution de la suite T1-T9 (JUnit 5 + Fabric Gateway)..."
docker run --rm --network dvp-network -m 2g --memory-swap 2g `
    -e "GRADLE_OPTS=-Dorg.gradle.jvmargs=-Xmx512m" `
    -v "${tests}:/tests" -v "${crypto}:/crypto" -v gradle-cache:/root/.gradle -w /tests `
    --entrypoint /bin/bash hyperledger/fabric-javaenv:2.5 `
    -c "/root/chaincode-java/gradlew --no-daemon test"
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "DES TESTS ONT ECHOUE. Rapport: 05_PoC/tests/build/reports/tests/test/index.html"
    exit 1
}
Write-Host ""
Write-Host "Suite T1-T9 VERTE."
Write-Host "  Rapport HTML : 05_PoC/tests/build/reports/tests/test/index.html"
Write-Host "  Rapport XML  : 05_PoC/tests/build/test-results/test/ (pour l'Annexe A)"