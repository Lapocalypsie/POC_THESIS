# Deploie le BondChaincode (jambe titres): package CCaaS -> install -> approbations -> commit.
# Tests de fumee: cycle I1/I2 (emission endossee CSD), transferts, earmark (escrow R09/R10).
$ErrorActionPreference = 'Stop'

$CC      = 'bond'
$VERSION = '1.0'
$SEQ     = '1'
$LABEL   = "${CC}_${VERSION}"
# L'autorite sur les titres est le CSD (I2); les banques endossent leurs transferts.
# Ni la banque centrale ni le superviseur n'apparaissent: pas d'autorite sur les titres.
$POLICY  = "OR('CSDMSP.peer','BankAMSP.peer','BankBMSP.peer')"

$ORD_CA  = '/work/crypto/ordererOrganizations/infra.dvp.poc/orderers/orderer.infra.dvp.poc/tls/ca.crt'
$ORDERER = 'orderer.infra.dvp.poc:7050'
$CHANNEL = 'dvp-channel'

function OrgEnv([string]$name, [string]$msp, [int]$port) {
    $d = "$name.dvp.poc"
    @(
        '-e', "CORE_PEER_LOCALMSPID=$msp",
        '-e', ("CORE_PEER_ADDRESS=peer0.{0}:{1}" -f $d, $port),
        '-e', "CORE_PEER_MSPCONFIGPATH=/work/crypto/peerOrganizations/$d/users/Admin@$d/msp",
        '-e', "CORE_PEER_TLS_ROOTCERT_FILE=/work/crypto/peerOrganizations/$d/peers/peer0.$d/tls/ca.crt"
    )
}
$CB   = OrgEnv 'centralbank' 'CentralBankMSP' 7051
$CSD  = OrgEnv 'csd'         'CSDMSP'         8051
$BA   = OrgEnv 'banka'       'BankAMSP'       9051
$BB   = OrgEnv 'bankb'       'BankBMSP'       10051
$SUP  = OrgEnv 'supervisor'  'SupervisorMSP'  11051

$csdTls = '/work/crypto/peerOrganizations/csd.dvp.poc/peers/peer0.csd.dvp.poc/tls/ca.crt'
$baTls  = '/work/crypto/peerOrganizations/banka.dvp.poc/peers/peer0.banka.dvp.poc/tls/ca.crt'
$bbTls  = '/work/crypto/peerOrganizations/bankb.dvp.poc/peers/peer0.bankb.dvp.poc/tls/ca.crt'

# Copie staging (exclut les artefacts IDE) puis build du uberjar dans javaenv.
$net   = Split-Path $PSScriptRoot -Parent
$ccDir = Join-Path (Split-Path $net -Parent) "chaincode\$CC"
$stage = "$net\artifacts\staging\$CC"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null
Get-ChildItem $ccDir | Where-Object { $_.Name -notin @('.gradle', 'build', 'bin') } |
    ForEach-Object { Copy-Item -Recurse -Force $_.FullName $stage }

Write-Host "[1/6] Build du uberjar (gradle dans le conteneur javaenv)..."
docker run --rm -v "${stage}:/src" -w /src -v gradle-cache:/root/.gradle `
    --entrypoint /bin/bash hyperledger/fabric-javaenv:2.5 `
    -c "/root/chaincode-java/gradlew --no-daemon -q shadowJar"
if ($LASTEXITCODE -ne 0) { throw "build gradle a echoue" }

Write-Host "     Packaging CCaaS du chaincode $CC..."
$pkgDir = "$net\artifacts\staging\$CC-ccaas"
if (Test-Path $pkgDir) { Remove-Item -Recurse -Force $pkgDir }
New-Item -ItemType Directory -Force $pkgDir | Out-Null
[IO.File]::WriteAllText("$pkgDir\metadata.json",
    ('{"type":"ccaas","label":"' + $LABEL + '"}'))
[IO.File]::WriteAllText("$pkgDir\connection.json",
    ('{"address":"' + $CC + '.ccaas.dvp.poc:9999","dial_timeout":"10s","tls_required":false}'))
docker exec dvp-cli bash -c "cd /work/artifacts/staging/$CC-ccaas && tar czf code.tar.gz connection.json && tar czf /work/artifacts/$CC.tar.gz metadata.json code.tar.gz"
if ($LASTEXITCODE -ne 0) { throw "package CCaaS a echoue" }

Write-Host "[2/6] Installation sur les peers endosseurs (CSD, BankA, BankB)..."
foreach ($org in @(@('CSD', $CSD), @('BankA', $BA), @('BankB', $BB))) {
    Write-Host "  -> installation sur le peer $($org[0])..."
    & docker exec @($org[1]) dvp-cli peer lifecycle chaincode install "/work/artifacts/$CC.tar.gz"
    if ($LASTEXITCODE -ne 0) { throw "install a echoue sur $($org[0])" }
}

Write-Host "[3/6] Calcul du package ID..."
$PKG = (& docker exec @CSD dvp-cli peer lifecycle chaincode calculatepackageid "/work/artifacts/$CC.tar.gz" | Select-Object -Last 1).Trim()
if (-not $PKG) { throw "package ID introuvable pour $LABEL" }
Write-Host "  package ID: $PKG"

Write-Host "[3bis] Demarrage du serveur de chaincode (CCaaS)..."
$existing = docker ps -aq --filter "name=$CC-ccaas"
if ($existing) { docker rm -f "$CC-ccaas" | Out-Null }
docker run -d --name "$CC-ccaas" --network dvp-network --network-alias "$CC.ccaas.dvp.poc" `
    -v "${stage}\build\libs\chaincode.jar:/chaincode.jar" `
    -e CHAINCODE_SERVER_ADDRESS=0.0.0.0:9999 `
    -e CORE_CHAINCODE_ID_NAME=$PKG `
    -e CORE_PEER_TLS_ENABLED=false `
    --entrypoint java hyperledger/fabric-javaenv:2.5 -jar /chaincode.jar
if ($LASTEXITCODE -ne 0) { throw "demarrage du serveur CCaaS a echoue" }
Start-Sleep -Seconds 5

Write-Host "[4/6] Approbation par chaque organisation (3/5 requis)..."
foreach ($org in @(@('CentralBank', $CB), @('CSD', $CSD), @('BankA', $BA), @('BankB', $BB), @('Supervisor', $SUP))) {
    $extra = @()
    if ($org[0] -in @('CSD', 'BankA', 'BankB')) { $extra = @('--package-id', $PKG) }
    & docker exec @($org[1]) dvp-cli peer lifecycle chaincode approveformyorg `
        -o $ORDERER --tls --cafile $ORD_CA --channelID $CHANNEL --name $CC `
        --version $VERSION --sequence $SEQ --signature-policy $POLICY @extra
    if ($LASTEXITCODE -ne 0) { throw "approbation a echoue pour $($org[0])" }
    Write-Host "  -> $($org[0]) a approuve la definition du chaincode."
}

Write-Host "[5/6] Commit de la definition sur le channel..."
& docker exec @CSD dvp-cli peer lifecycle chaincode commit `
    -o $ORDERER --tls --cafile $ORD_CA --channelID $CHANNEL --name $CC `
    --version $VERSION --sequence $SEQ --signature-policy $POLICY `
    --peerAddresses peer0.csd.dvp.poc:8051   --tlsRootCertFiles $csdTls `
    --peerAddresses peer0.banka.dvp.poc:9051 --tlsRootCertFiles $baTls `
    --peerAddresses peer0.bankb.dvp.poc:10051 --tlsRootCertFiles $bbTls
if ($LASTEXITCODE -ne 0) { throw "commit a echoue" }

Write-Host ""
Write-Host "[6/6] Tests de fumee"
Write-Host "--- B-a: BankA enregistre l'emission FR0001, 1,000,000 EUR (I1) ---"
& docker exec @BA dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
    -C $CHANNEL -n $CC --peerAddresses peer0.banka.dvp.poc:9051 --tlsRootCertFiles $baTls `
    -c '{\"function\":\"registerIssuance\",\"Args\":[\"FR0001\",\"1000000\",\"EUR\",\"2030-12-31\"]}' --waitForEvent
if ($LASTEXITCODE -ne 0) { throw "registerIssuance a echoue" }

Write-Host "--- B-b (NEGATIF): BankA (emetteur) tente de mint sa propre emission ---"
& docker exec @BA dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
    -C $CHANNEL -n $CC --peerAddresses peer0.banka.dvp.poc:9051 --tlsRootCertFiles $baTls `
    -c '{\"function\":\"mint\",\"Args\":[\"FR0001\"]}' --waitForEvent
if ($LASTEXITCODE -eq 0) { throw "ECHEC DU TEST: le mint par l'emetteur aurait du etre refuse !" }
Write-Host "  -> REFUSE comme attendu: seul le CSD cree les tokens (I2, R06)."

Write-Host "--- B-c: le CSD mint les tokens vers l'emetteur (I2) ---"
& docker exec @CSD dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
    -C $CHANNEL -n $CC --peerAddresses peer0.csd.dvp.poc:8051 --tlsRootCertFiles $csdTls `
    -c '{\"function\":\"mint\",\"Args\":[\"FR0001\"]}' --waitForEvent
if ($LASTEXITCODE -ne 0) { throw "mint CSD a echoue" }

Write-Host "--- B-d: BankA transfere 200,000 titres a BankB ---"
& docker exec @BA dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
    -C $CHANNEL -n $CC --peerAddresses peer0.banka.dvp.poc:9051 --tlsRootCertFiles $baTls `
    -c '{\"function\":\"transfer\",\"Args\":[\"FR0001\",\"BankAMSP\",\"BankBMSP\",\"200000\"]}' --waitForEvent
if ($LASTEXITCODE -ne 0) { throw "transfer a echoue" }

Write-Host "--- B-e: BankA earmark 300,000 titres pour le trade T-TEST (escrow) ---"
& docker exec @BA dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
    -C $CHANNEL -n $CC --peerAddresses peer0.banka.dvp.poc:9051 --tlsRootCertFiles $baTls `
    -c '{\"function\":\"earmark\",\"Args\":[\"FR0001\",\"T-TEST\",\"300000\"]}' --waitForEvent
if ($LASTEXITCODE -ne 0) { throw "earmark a echoue" }

Write-Host "--- B-f (NEGATIF): BankA tente de transferer 600,000 (> disponible apres earmark) ---"
& docker exec @BA dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
    -C $CHANNEL -n $CC --peerAddresses peer0.banka.dvp.poc:9051 --tlsRootCertFiles $baTls `
    -c '{\"function\":\"transfer\",\"Args\":[\"FR0001\",\"BankAMSP\",\"BankBMSP\",\"600000\"]}' --waitForEvent
if ($LASTEXITCODE -eq 0) { throw "ECHEC DU TEST: le transfert au-dela du disponible aurait du etre refuse !" }
Write-Host "  -> REFUSE comme attendu: l'earmark protege les titres reserves (pas de double-vente)."

Write-Host "--- B-g: BankA libere l'earmark de T-TEST ---"
& docker exec @BA dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
    -C $CHANNEL -n $CC --peerAddresses peer0.banka.dvp.poc:9051 --tlsRootCertFiles $baTls `
    -c '{\"function\":\"releaseEarmark\",\"Args\":[\"FR0001\",\"T-TEST\"]}' --waitForEvent
if ($LASTEXITCODE -ne 0) { throw "releaseEarmark a echoue" }

Write-Host "--- B-h: etat final ---"
$balA  = & docker exec @BA dvp-cli peer chaincode query -C $CHANNEL -n $CC -c '{\"function\":\"balanceOf\",\"Args\":[\"FR0001\",\"BankAMSP\"]}'
$availA = & docker exec @BA dvp-cli peer chaincode query -C $CHANNEL -n $CC -c '{\"function\":\"availableOf\",\"Args\":[\"FR0001\",\"BankAMSP\"]}'
$balB  = & docker exec @BB dvp-cli peer chaincode query -C $CHANNEL -n $CC -c '{\"function\":\"balanceOf\",\"Args\":[\"FR0001\",\"BankBMSP\"]}'
$iss   = & docker exec @CSD dvp-cli peer chaincode query -C $CHANNEL -n $CC -c '{\"function\":\"getIssuance\",\"Args\":[\"FR0001\"]}'
Write-Host "  BankA: $balA (disponible: $availA) | BankB: $balB (attendu: 800000/800000 | 200000)"
Write-Host "  Emission: $iss"

Write-Host ""
Write-Host "BondChaincode deploye et verifie."
