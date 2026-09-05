# Reprise du deploiement bond apres le crash memoire: le build, le packaging,
# les installs et le serveur CCaaS sont deja en place - on rejoue uniquement
# approbations -> commit -> tests de fumee.
$ErrorActionPreference = 'Stop'

$CC      = 'bond'
$VERSION = '1.0'
$SEQ     = '1'
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

$PKG = (& docker exec @CSD dvp-cli peer lifecycle chaincode calculatepackageid "/work/artifacts/$CC.tar.gz" | Select-Object -Last 1).Trim()
Write-Host "package ID: $PKG"

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
$balA   = & docker exec @BA dvp-cli peer chaincode query -C $CHANNEL -n $CC -c '{\"function\":\"balanceOf\",\"Args\":[\"FR0001\",\"BankAMSP\"]}'
$availA = & docker exec @BA dvp-cli peer chaincode query -C $CHANNEL -n $CC -c '{\"function\":\"availableOf\",\"Args\":[\"FR0001\",\"BankAMSP\"]}'
$balB   = & docker exec @BB dvp-cli peer chaincode query -C $CHANNEL -n $CC -c '{\"function\":\"balanceOf\",\"Args\":[\"FR0001\",\"BankBMSP\"]}'
$iss    = & docker exec @CSD dvp-cli peer chaincode query -C $CHANNEL -n $CC -c '{\"function\":\"getIssuance\",\"Args\":[\"FR0001\"]}'
Write-Host "  BankA: $balA (disponible: $availA) | BankB: $balB (attendu: 800000/800000 | 200000)"
Write-Host "  Emission: $iss"

Write-Host ""
Write-Host "BondChaincode deploye et verifie."
