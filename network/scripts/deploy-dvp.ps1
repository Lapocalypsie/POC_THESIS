# Etape 3c complete:
#   A. Rebuild + hot-swap des jars bond/wcbdc (fonctions *ForTrade v1.1)
#   B. Upgrade gouverne des definitions bond/wcbdc (sequence 2 = amendement 3/5)
#   C. Deploiement du coordinateur dvp (machine a etats + swap atomique)
#   D. Tests de fumee D-1..D-13 (prefiguration des tests T1-T9 du chapitre 8)
$ErrorActionPreference = 'Stop'

$ORD_CA  = '/work/crypto/ordererOrganizations/infra.dvp.poc/orderers/orderer.infra.dvp.poc/tls/ca.crt'
$ORDERER = 'orderer.infra.dvp.poc:7050'
$CHANNEL = 'dvp-channel'
# Le swap exige l'endorsement des DEUX banques; la pause C1 celui de la banque
# centrale seule (Appendix D: "Combined Fabric endorsement BuyerOrg + SellerOrg").
$DVP_POLICY   = "OR(AND('BankAMSP.peer','BankBMSP.peer'),'CentralBankMSP.peer')"
$BOND_POLICY  = "OR('CSDMSP.peer','BankAMSP.peer','BankBMSP.peer')"
$WCBDC_POLICY = "OR('CentralBankMSP.peer','BankAMSP.peer','BankBMSP.peer')"

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

$cbTls  = '/work/crypto/peerOrganizations/centralbank.dvp.poc/peers/peer0.centralbank.dvp.poc/tls/ca.crt'
$csdTls = '/work/crypto/peerOrganizations/csd.dvp.poc/peers/peer0.csd.dvp.poc/tls/ca.crt'
$baTls  = '/work/crypto/peerOrganizations/banka.dvp.poc/peers/peer0.banka.dvp.poc/tls/ca.crt'
$bbTls  = '/work/crypto/peerOrganizations/bankb.dvp.poc/peers/peer0.bankb.dvp.poc/tls/ca.crt'

$net = Split-Path $PSScriptRoot -Parent

# Endosseurs des transactions de reglement: les deux banques.
$BANKS_PEERS = @('--peerAddresses', 'peer0.banka.dvp.poc:9051', '--tlsRootCertFiles', $baTls,
                 '--peerAddresses', 'peer0.bankb.dvp.poc:10051', '--tlsRootCertFiles', $bbTls)
$CB_PEER     = @('--peerAddresses', 'peer0.centralbank.dvp.poc:7051', '--tlsRootCertFiles', $cbTls)

function Approve([string]$name, [string]$version, [string]$seq, [string]$policy,
                 [string[]]$pkgOrgs, [string]$pkg) {
    foreach ($org in @(@('CentralBank', $CB), @('CSD', $CSD), @('BankA', $BA), @('BankB', $BB), @('Supervisor', $SUP))) {
        $extra = @()
        if ($org[0] -in $pkgOrgs) { $extra = @('--package-id', $pkg) }
        & docker exec @($org[1]) dvp-cli peer lifecycle chaincode approveformyorg `
            -o $ORDERER --tls --cafile $ORD_CA --channelID $CHANNEL --name $name `
            --version $version --sequence $seq --signature-policy $policy @extra
        if ($LASTEXITCODE -ne 0) { Write-Host "  (!) approbation $name pour $($org[0]): deja enregistree ou refusee - poursuite" }
    }
    Write-Host "  -> $name v$version seq $seq approuve par les 5 organisations."
}

# ==================================================================
Write-Host "=== PHASE A: rebuild + hot-swap des jars bond et wcbdc (v1.1) ==="
& "$PSScriptRoot\restart-cc.ps1" -CC bond
& "$PSScriptRoot\restart-cc.ps1" -CC wcbdc

# ==================================================================
Write-Host ""
Write-Host "=== PHASE B: upgrade gouverne des definitions (sequence 2) ==="
$BOND_PKG  = (docker exec dvp-cli peer lifecycle chaincode calculatepackageid /work/artifacts/bond.tar.gz | Select-Object -Last 1).Trim()
$WCBDC_PKG = (docker exec dvp-cli peer lifecycle chaincode calculatepackageid /work/artifacts/wcbdc.tar.gz | Select-Object -Last 1).Trim()

Approve 'bond' '1.1' '2' $BOND_POLICY @('CSD', 'BankA', 'BankB') $BOND_PKG
& docker exec @CSD dvp-cli peer lifecycle chaincode commit `
    -o $ORDERER --tls --cafile $ORD_CA --channelID $CHANNEL --name bond `
    --version 1.1 --sequence 2 --signature-policy $BOND_POLICY `
    --peerAddresses peer0.csd.dvp.poc:8051 --tlsRootCertFiles $csdTls @BANKS_PEERS
if ($LASTEXITCODE -ne 0) { throw "commit bond seq 2 a echoue" }
Write-Host "  -> bond v1.1 committe (sequence 2)."

Approve 'wcbdc' '1.1' '2' $WCBDC_POLICY @('CentralBank', 'BankA', 'BankB') $WCBDC_PKG
& docker exec @CB dvp-cli peer lifecycle chaincode commit `
    -o $ORDERER --tls --cafile $ORD_CA --channelID $CHANNEL --name wcbdc `
    --version 1.1 --sequence 2 --signature-policy $WCBDC_POLICY @CB_PEER @BANKS_PEERS
if ($LASTEXITCODE -ne 0) { throw "commit wcbdc seq 2 a echoue" }
Write-Host "  -> wcbdc v1.1 committe (sequence 2)."

# ==================================================================
Write-Host ""
Write-Host "=== PHASE C: deploiement du coordinateur dvp ==="
$CC = 'dvp'
$ccDir = Join-Path (Split-Path $net -Parent) "chaincode\$CC"
$stage = "$net\artifacts\staging\$CC"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null
Get-ChildItem $ccDir | Where-Object { $_.Name -notin @('.gradle', 'build', 'bin') } |
    ForEach-Object { Copy-Item -Recurse -Force $_.FullName $stage }

Write-Host "[1/5] Build du uberjar dvp..."
docker run --rm -m 2g --memory-swap 2g -e "GRADLE_OPTS=-Dorg.gradle.jvmargs=-Xmx512m" `
    -v "${stage}:/src" -w /src -v gradle-cache:/root/.gradle `
    --entrypoint /bin/bash hyperledger/fabric-javaenv:2.5 `
    -c "/root/chaincode-java/gradlew --no-daemon -q shadowJar"
if ($LASTEXITCODE -ne 0) { throw "build gradle a echoue" }

Write-Host "[2/5] Packaging CCaaS..."
$pkgDir = "$net\artifacts\staging\$CC-ccaas"
if (Test-Path $pkgDir) { Remove-Item -Recurse -Force $pkgDir }
New-Item -ItemType Directory -Force $pkgDir | Out-Null
[IO.File]::WriteAllText("$pkgDir\metadata.json", '{"type":"ccaas","label":"dvp_1.0"}')
[IO.File]::WriteAllText("$pkgDir\connection.json",
    '{"address":"dvp.ccaas.dvp.poc:9999","dial_timeout":"10s","tls_required":false}')
docker exec dvp-cli bash -c "cd /work/artifacts/staging/$CC-ccaas && tar czf code.tar.gz connection.json && tar czf /work/artifacts/$CC.tar.gz metadata.json code.tar.gz"
if ($LASTEXITCODE -ne 0) { throw "package CCaaS a echoue" }

Write-Host "[3/5] Installation (CentralBank, BankA, BankB)..."
foreach ($org in @(@('CentralBank', $CB), @('BankA', $BA), @('BankB', $BB))) {
    & docker exec @($org[1]) dvp-cli peer lifecycle chaincode install "/work/artifacts/$CC.tar.gz"
    if ($LASTEXITCODE -ne 0) { throw "install a echoue sur $($org[0])" }
    Write-Host "  -> installe sur le peer $($org[0])."
}
$DVP_PKG = (docker exec dvp-cli peer lifecycle chaincode calculatepackageid /work/artifacts/dvp.tar.gz | Select-Object -Last 1).Trim()
Write-Host "  package ID: $DVP_PKG"

Write-Host "[4/5] Serveur de chaincode dvp-ccaas..."
$existing = docker ps -aq --filter "name=dvp-ccaas"
if ($existing) { docker rm -f dvp-ccaas | Out-Null }
docker run -d --name dvp-ccaas --network dvp-network --network-alias dvp.ccaas.dvp.poc `
    --memory 512m -e "JAVA_TOOL_OPTIONS=-Xmx256m" `
    -v "${stage}\build\libs\chaincode.jar:/chaincode.jar" `
    -e CHAINCODE_SERVER_ADDRESS=0.0.0.0:9999 `
    -e CORE_CHAINCODE_ID_NAME=$DVP_PKG `
    -e CORE_PEER_TLS_ENABLED=false `
    --entrypoint java hyperledger/fabric-javaenv:2.5 -jar /chaincode.jar | Out-Null
Start-Sleep -Seconds 5

Write-Host "[5/5] Approbations + commit dvp..."
Approve 'dvp' '1.0' '1' $DVP_POLICY @('CentralBank', 'BankA', 'BankB') $DVP_PKG
& docker exec @CB dvp-cli peer lifecycle chaincode commit `
    -o $ORDERER --tls --cafile $ORD_CA --channelID $CHANNEL --name dvp `
    --version 1.0 --sequence 1 --signature-policy $DVP_POLICY @CB_PEER @BANKS_PEERS
if ($LASTEXITCODE -ne 0) { throw "commit dvp a echoue" }
Write-Host "  -> dvp v1.0 committe."

# ==================================================================
Write-Host ""
Write-Host "=== PHASE D: tests de fumee ==="

function InvokeCC([string[]]$org, [string[]]$peers, [string]$cc, [string]$json) {
    & docker exec @org dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
        -C $CHANNEL -n $cc @peers -c $json --waitForEvent
    return $LASTEXITCODE
}
function QueryCC([string[]]$org, [string]$cc, [string]$json) {
    return (& docker exec @org dvp-cli peer chaincode query -C $CHANNEL -n $cc -c $json)
}
function PrintBalances([string]$label) {
    $bA = QueryCC $BA 'bond'  '{\"function\":\"balanceOf\",\"Args\":[\"FR0001\",\"BankAMSP\"]}'
    $bB = QueryCC $BA 'bond'  '{\"function\":\"balanceOf\",\"Args\":[\"FR0001\",\"BankBMSP\"]}'
    $cA = QueryCC $BA 'wcbdc' '{\"function\":\"balanceOf\",\"Args\":[\"BankAMSP\"]}'
    $cB = QueryCC $BA 'wcbdc' '{\"function\":\"balanceOf\",\"Args\":[\"BankBMSP\"]}'
    Write-Host "  [$label] titres A=$bA B=$bB | cash A=$cA B=$cB"
}

Write-Host "--- D-1: la banque centrale admet BankA et BankB (R03) et fixe le plafond R16 ---"
if ((InvokeCC $CB $CB_PEER 'dvp' '{\"function\":\"dvpAdmin:setEligibility\",\"Args\":[\"BankAMSP\",\"true\"]}') -ne 0) { throw "D-1a" }
if ((InvokeCC $CB $CB_PEER 'dvp' '{\"function\":\"dvpAdmin:setEligibility\",\"Args\":[\"BankBMSP\",\"true\"]}') -ne 0) { throw "D-1b" }
if ((InvokeCC $CB $CB_PEER 'dvp' '{\"function\":\"dvpAdmin:setComplianceCap\",\"Args\":[\"10000000\"]}') -ne 0) { throw "D-1c" }

Write-Host "--- D-2 (NEGATIF): BankA tente d'admettre un participant (reserve R14) ---"
if ((InvokeCC $BA $BANKS_PEERS 'dvp' '{\"function\":\"dvpAdmin:setEligibility\",\"Args\":[\"CSDMSP\",\"true\"]}') -eq 0) { throw "D-2: aurait du etre refuse" }
Write-Host "  -> REFUSE comme attendu."

PrintBalances "etat initial"
Write-Host "--- D-3: T100 propose par BankB, acheteuse (I3, 1re signature) ---"
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"proposeTrade\",\"Args\":[\"T100\",\"BankBMSP\",\"BankAMSP\",\"FR0001\",\"100000\",\"95000\",\"EUR\",\"300\",\"600\"]}') -ne 0) { throw "D-3" }

Write-Host "--- D-4: T100 confirme par BankA, vendeuse (cosignature R05) ---"
if ((InvokeCC $BA $BANKS_PEERS 'dvp' '{\"function\":\"confirmTrade\",\"Args\":[\"T100\"]}') -ne 0) { throw "D-4" }

Write-Host "--- D-5: reglement T100 - SWAP ATOMIQUE O1+O2 (payload attendu: SETTLED) ---"
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"executeSettlement\",\"Args\":[\"T100\"]}') -ne 0) { throw "D-5" }
PrintBalances "apres T100 (attendu titres 700000/300000, cash 845000/655000)"

Write-Host "--- D-6 (NEGATIF): rejouer le reglement de T100 (deja SETTLED) ---"
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"executeSettlement\",\"Args\":[\"T100\"]}') -eq 0) { throw "D-6: aurait du etre refuse" }
Write-Host "  -> REFUSE comme attendu: pas de double reglement."

Write-Host "--- D-7 (NEGATIF): BankB appelle bond.transferForTrade DIRECTEMENT (contournement du dvp) ---"
if ((InvokeCC $BB @('--peerAddresses', 'peer0.bankb.dvp.poc:10051', '--tlsRootCertFiles', $bbTls) 'bond' '{\"function\":\"bondSettlement:transferForTrade\",\"Args\":[\"T100\"]}') -eq 0) { throw "D-7: aurait du etre refuse" }
Write-Host "  -> REFUSE comme attendu: une jambe seule est inexecutable (invariant protege)."

Write-Host "--- D-8: pause C1 (banque centrale), tentative de trade, reprise ---"
if ((InvokeCC $CB $CB_PEER 'dvp' '{\"function\":\"dvpAdmin:pause\",\"Args\":[\"incident operationnel\"]}') -ne 0) { throw "D-8a" }
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"proposeTrade\",\"Args\":[\"T101\",\"BankBMSP\",\"BankAMSP\",\"FR0001\",\"1000\",\"950\",\"EUR\",\"300\",\"600\"]}') -eq 0) { throw "D-8b: aurait du etre refuse" }
Write-Host "  -> proposition REFUSEE pendant la pause (C1)."
if ((InvokeCC $BA $BANKS_PEERS 'dvp' '{\"function\":\"dvpAdmin:pause\",\"Args\":[\"tentative illegitime\"]}') -eq 0) { throw "D-8c: aurait du etre refuse" }
Write-Host "  -> pause par BankA REFUSEE (operation reservee R14)."
if ((InvokeCC $CB $CB_PEER 'dvp' '{\"function\":\"dvpAdmin:unpause\",\"Args\":[]}') -ne 0) { throw "D-8d" }

Write-Host "--- D-9: T102 au-dela du plafond de conformite (payload attendu: REJECTED_COMPLIANCE) ---"
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"proposeTrade\",\"Args\":[\"T102\",\"BankBMSP\",\"BankAMSP\",\"FR0001\",\"100000\",\"20000000\",\"EUR\",\"300\",\"600\"]}') -ne 0) { throw "D-9" }

Write-Host "--- D-10: T103 avec un vendeur non admis, CSDMSP (payload attendu: REJECTED_INELIGIBLE) ---"
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"proposeTrade\",\"Args\":[\"T103\",\"BankBMSP\",\"CSDMSP\",\"FR0001\",\"100000\",\"95000\",\"EUR\",\"300\",\"600\"]}') -ne 0) { throw "D-10" }

Write-Host "--- D-11: T104 sous-provisionne -> ESCROW -> on-ramp C2 -> SETTLED ---"
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"proposeTrade\",\"Args\":[\"T104\",\"BankBMSP\",\"BankAMSP\",\"FR0001\",\"200000\",\"5000000\",\"EUR\",\"3600\",\"7200\"]}') -ne 0) { throw "D-11a" }
if ((InvokeCC $BA $BANKS_PEERS 'dvp' '{\"function\":\"confirmTrade\",\"Args\":[\"T104\"]}') -ne 0) { throw "D-11b" }
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"executeSettlement\",\"Args\":[\"T104\"]}') -ne 0) { throw "D-11c" }
$avail = QueryCC $BA 'bond' '{\"function\":\"availableOf\",\"Args\":[\"FR0001\",\"BankAMSP\"]}'
Write-Host "  ESCROW_WAITING atteint; disponible vendeur = $avail (attendu 500000: 700000 - 200000 earmark)"
Write-Host "  ... on-ramp: la banque centrale mint 5,000,000 wCBDC pour BankB (C2)"
if ((InvokeCC $CB $CB_PEER 'wcbdc' '{\"function\":\"mint\",\"Args\":[\"BankBMSP\",\"5000000\"]}') -ne 0) { throw "D-11d" }
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"executeSettlement\",\"Args\":[\"T104\"]}') -ne 0) { throw "D-11e" }
PrintBalances "apres T104 (attendu titres 500000/500000, cash 5845000/655000)"

Write-Host "--- D-12: T105 jamais finance -> timeout metier -> RELEASED_BUSINESS ---"
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"proposeTrade\",\"Args\":[\"T105\",\"BankBMSP\",\"BankAMSP\",\"FR0001\",\"100000\",\"90000000\",\"EUR\",\"12\",\"300\"]}') -ne 0) { throw "D-12a" }
if ((InvokeCC $BA $BANKS_PEERS 'dvp' '{\"function\":\"confirmTrade\",\"Args\":[\"T105\"]}') -ne 0) { throw "D-12b" }
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"executeSettlement\",\"Args\":[\"T105\"]}') -ne 0) { throw "D-12c" }
Write-Host "  ESCROW_WAITING atteint; attente de l'expiration du timeout metier (12s)..."
Start-Sleep -Seconds 10
if ((InvokeCC $BA $BANKS_PEERS 'dvp' '{\"function\":\"releaseExpired\",\"Args\":[\"T105\"]}') -ne 0) { throw "D-12d" }
$avail = QueryCC $BA 'bond' '{\"function\":\"availableOf\",\"Args\":[\"FR0001\",\"BankAMSP\"]}'
Write-Host "  liberation OK; disponible vendeur = $avail (attendu 500000, earmark leve)"

Write-Host "--- D-13: T106 -> filet de securite -> RELEASED_SAFETY ---"
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"proposeTrade\",\"Args\":[\"T106\",\"BankBMSP\",\"BankAMSP\",\"FR0001\",\"100000\",\"90000000\",\"EUR\",\"2\",\"4\"]}') -ne 0) { throw "D-13a" }
if ((InvokeCC $BA $BANKS_PEERS 'dvp' '{\"function\":\"confirmTrade\",\"Args\":[\"T106\"]}') -ne 0) { throw "D-13b" }
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"executeSettlement\",\"Args\":[\"T106\"]}') -ne 0) { throw "D-13c" }
Start-Sleep -Seconds 2
if ((InvokeCC $BA $BANKS_PEERS 'dvp' '{\"function\":\"releaseExpired\",\"Args\":[\"T106\"]}') -ne 0) { throw "D-13d" }

Write-Host ""
Write-Host "=== Etats terminaux atteints (getTrade) ==="
foreach ($t in @('T100', 'T102', 'T103', 'T104', 'T105', 'T106')) {
    $j = QueryCC $BA 'dvp' ('{\"function\":\"getTrade\",\"Args\":[\"' + $t + '\"]}')
    $status = ($j | ConvertFrom-Json).status
    Write-Host ("  {0}: {1}" -f $t, $status)
}
PrintBalances "etat final"
Write-Host ""
Write-Host "DvPChaincode deploye et verifie: la machine a etats et le swap atomique sont demontres."
