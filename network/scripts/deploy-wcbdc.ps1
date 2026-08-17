# Deploie le wCBDCChaincode selon le cycle de vie Fabric:
# package -> install (peers endosseurs) -> approbation par org -> commit.
# Puis tests de fumee, dont la preuve R14 (mint refuse hors banque centrale).
$ErrorActionPreference = 'Stop'

$CC      = 'wcbdc'
$VERSION = '1.0'
$SEQ     = '1'
$LABEL   = "${CC}_${VERSION}"
# Endorsement policy du contrat: un peer institutionnel suffit a endosser.
# Le POUVOIR (qui peut mint/burn) est controle dans le code par l'identite du
# soumetteur - le superviseur, lui, n'apparait nulle part: lecture seule.
$POLICY  = "OR('CentralBankMSP.peer','BankAMSP.peer','BankBMSP.peer')"

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

$cbTls = '/work/crypto/peerOrganizations/centralbank.dvp.poc/peers/peer0.centralbank.dvp.poc/tls/ca.crt'
$baTls = '/work/crypto/peerOrganizations/banka.dvp.poc/peers/peer0.banka.dvp.poc/tls/ca.crt'
$bbTls = '/work/crypto/peerOrganizations/bankb.dvp.poc/peers/peer0.bankb.dvp.poc/tls/ca.crt'

# Le packaging embarque tout le dossier source; les artefacts IDE (.gradle
# verrouille par un demon, build/) le font echouer. On package donc depuis une
# copie propre en staging, qui les exclut.
$net   = Split-Path $PSScriptRoot -Parent
$ccDir = Join-Path (Split-Path $net -Parent) "chaincode\$CC"
$stage = "$net\artifacts\staging\$CC"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null
robocopy $ccDir $stage /E /XD .gradle build bin /NFL /NDL /NJH /NJS | Out-Null

# Le build.sh de l'image javaenv 2.5 est bugue apres un build gradle reussi
# (cd ''). On construit donc le uberjar nous-memes avec la meme image, et on
# package le jar precompile - chemin nativement supporte, sans build cote peer.
Write-Host "[1/6] Build du uberjar (gradle dans le conteneur javaenv)..."
docker run --rm -v "${stage}:/src" -w /src -v gradle-cache:/root/.gradle `
    --entrypoint /bin/bash hyperledger/fabric-javaenv:2.5 `
    -c "/root/chaincode-java/gradlew --no-daemon shadowJar"
if ($LASTEXITCODE -ne 0) { throw "build gradle a echoue" }

# Mode Chaincode-as-a-Service (CCaaS): le chaincode tourne comme un service
# que les peers contactent - aucun build d'image Docker par le peer (le
# docker-in-docker du peer 2.5 est incompatible avec Docker Engine 29).
# Le paquet installe ne contient que l'adresse du service.
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

Write-Host "[2/6] Installation sur les peers endosseurs (compilation Java a la premiere fois, patience)..."
foreach ($org in @(@('CentralBank', $CB), @('BankA', $BA), @('BankB', $BB))) {
    Write-Host "  -> installation sur le peer $($org[0])..."
    & docker exec @($org[1]) dvp-cli peer lifecycle chaincode install "/work/artifacts/$CC.tar.gz"
    if ($LASTEXITCODE -ne 0) { throw "install a echoue sur $($org[0])" }
}

Write-Host "[3/6] Calcul du package ID..."
$PKG = (& docker exec @CB dvp-cli peer lifecycle chaincode calculatepackageid "/work/artifacts/$CC.tar.gz" | Select-Object -Last 1).Trim()
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

Write-Host "[4/6] Approbation par chaque organisation (LifecycleEndorsement: MAJORITY, 3/5 requis)..."
foreach ($org in @(@('CentralBank', $CB), @('CSD', $CSD), @('BankA', $BA), @('BankB', $BB), @('Supervisor', $SUP))) {
    $extra = @()
    if ($org[0] -in @('CentralBank', 'BankA', 'BankB')) { $extra = @('--package-id', $PKG) }
    & docker exec @($org[1]) dvp-cli peer lifecycle chaincode approveformyorg `
        -o $ORDERER --tls --cafile $ORD_CA --channelID $CHANNEL --name $CC `
        --version $VERSION --sequence $SEQ --signature-policy $POLICY @extra
    if ($LASTEXITCODE -ne 0) { throw "approbation a echoue pour $($org[0])" }
    Write-Host "  -> $($org[0]) a approuve la definition du chaincode."
}

Write-Host "[5/6] Commit de la definition sur le channel..."
& docker exec @CB dvp-cli peer lifecycle chaincode commit `
    -o $ORDERER --tls --cafile $ORD_CA --channelID $CHANNEL --name $CC `
    --version $VERSION --sequence $SEQ --signature-policy $POLICY `
    --peerAddresses peer0.centralbank.dvp.poc:7051 --tlsRootCertFiles $cbTls `
    --peerAddresses peer0.banka.dvp.poc:9051       --tlsRootCertFiles $baTls `
    --peerAddresses peer0.bankb.dvp.poc:10051      --tlsRootCertFiles $bbTls
if ($LASTEXITCODE -ne 0) { throw "commit a echoue" }

Write-Host ""
Write-Host "[6/6] Tests de fumee"
Write-Host "--- T-a: la banque centrale mint 1,000,000 pour BankA (C2, on-ramp) ---"
& docker exec @CB dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
    -C $CHANNEL -n $CC --peerAddresses peer0.centralbank.dvp.poc:7051 --tlsRootCertFiles $cbTls `
    -c '{\"function\":\"mint\",\"Args\":[\"BankAMSP\",\"1000000\"]}' --waitForEvent
if ($LASTEXITCODE -ne 0) { throw "mint BankA a echoue" }

Write-Host "--- T-b: la banque centrale mint 500,000 pour BankB ---"
& docker exec @CB dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
    -C $CHANNEL -n $CC --peerAddresses peer0.centralbank.dvp.poc:7051 --tlsRootCertFiles $cbTls `
    -c '{\"function\":\"mint\",\"Args\":[\"BankBMSP\",\"500000\"]}' --waitForEvent
if ($LASTEXITCODE -ne 0) { throw "mint BankB a echoue" }

Write-Host "--- T-c: BankA transfere 250,000 a BankB (O2 hors swap) ---"
& docker exec @BA dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
    -C $CHANNEL -n $CC --peerAddresses peer0.banka.dvp.poc:9051 --tlsRootCertFiles $baTls `
    -c '{\"function\":\"transfer\",\"Args\":[\"BankAMSP\",\"BankBMSP\",\"250000\"]}' --waitForEvent
if ($LASTEXITCODE -ne 0) { throw "transfer a echoue" }

Write-Host "--- T-d: soldes et offre totale ---"
$balA = & docker exec @BA dvp-cli peer chaincode query -C $CHANNEL -n $CC -c '{\"function\":\"balanceOf\",\"Args\":[\"BankAMSP\"]}'
$balB = & docker exec @BB dvp-cli peer chaincode query -C $CHANNEL -n $CC -c '{\"function\":\"balanceOf\",\"Args\":[\"BankBMSP\"]}'
$sup  = & docker exec @CB dvp-cli peer chaincode query -C $CHANNEL -n $CC -c '{\"function\":\"totalSupply\",\"Args\":[]}'
Write-Host "  BankA: $balA | BankB: $balB | offre totale: $sup (attendu: 750000 / 750000 / 1500000)"

Write-Host "--- T-e (NEGATIF, preuve R14): BankA tente de mint 9,999,999 pour elle-meme ---"
& docker exec @BA dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
    -C $CHANNEL -n $CC --peerAddresses peer0.banka.dvp.poc:9051 --tlsRootCertFiles $baTls `
    -c '{\"function\":\"mint\",\"Args\":[\"BankAMSP\",\"9999999\"]}' --waitForEvent
if ($LASTEXITCODE -eq 0) { throw "ECHEC DU TEST: le mint par BankA aurait du etre refuse !" }
Write-Host "  -> REFUSE comme attendu: seule la banque centrale peut emettre du wCBDC (R14)."

Write-Host "--- T-f (NEGATIF): BankB tente de debiter le compte de BankA ---"
& docker exec @BB dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
    -C $CHANNEL -n $CC --peerAddresses peer0.bankb.dvp.poc:10051 --tlsRootCertFiles $bbTls `
    -c '{\"function\":\"transfer\",\"Args\":[\"BankAMSP\",\"BankBMSP\",\"1000\"]}' --waitForEvent
if ($LASTEXITCODE -eq 0) { throw "ECHEC DU TEST: le debit du compte d'autrui aurait du etre refuse !" }
Write-Host "  -> REFUSE comme attendu: nul ne depense l'argent d'autrui."

Write-Host ""
Write-Host "wCBDCChaincode deploye et verifie. L'offre totale n'a pas bouge apres les refus:"
& docker exec @CB dvp-cli peer chaincode query -C $CHANNEL -n $CC -c '{\"function\":\"totalSupply\",\"Args\":[]}'
