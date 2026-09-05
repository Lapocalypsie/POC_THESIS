# Acheve la migration per-org: approbation dvp/bankb + son serveur.
$ErrorActionPreference = 'Stop'
$ORD_CA  = '/work/crypto/ordererOrganizations/infra.dvp.poc/orderers/orderer.infra.dvp.poc/tls/ca.crt'
$ORDERER = 'orderer.infra.dvp.poc:7050'
$net     = Split-Path $PSScriptRoot -Parent
$d = 'bankb.dvp.poc'
$BB = @(
    '-e', 'CORE_PEER_LOCALMSPID=BankBMSP',
    '-e', 'CORE_PEER_ADDRESS=peer0.bankb.dvp.poc:10051',
    '-e', "CORE_PEER_MSPCONFIGPATH=/work/crypto/peerOrganizations/$d/users/Admin@$d/msp",
    '-e', "CORE_PEER_TLS_ROOTCERT_FILE=/work/crypto/peerOrganizations/$d/peers/peer0.$d/tls/ca.crt"
)

$PKG = (docker exec dvp-cli peer lifecycle chaincode calculatepackageid /work/artifacts/dvp-bankb.tar.gz | Select-Object -Last 1).Trim()
Write-Host "package ID dvp/bankb: $PKG"

& docker exec @BB dvp-cli peer lifecycle chaincode approveformyorg `
    -o $ORDERER --tls --cafile $ORD_CA --channelID dvp-channel --name dvp `
    --version 1.0 --sequence 1 `
    --signature-policy "OR(AND('BankAMSP.peer','BankBMSP.peer'),'CentralBankMSP.peer')" `
    --package-id $PKG
if ($LASTEXITCODE -ne 0) { throw "approbation dvp/bankb a echoue" }
Write-Host "-> approbation dvp/bankb OK"

$stale = docker ps -aq --filter "name=dvp-bankb-ccaas"
if ($stale) { docker rm -f $stale | Out-Null }
docker run -d --name dvp-bankb-ccaas --network dvp-network `
    --network-alias dvp.bankb.ccaas.dvp.poc `
    --memory 384m -e "JAVA_TOOL_OPTIONS=-Xmx192m" `
    -v "${net}\artifacts\staging\dvp\build\libs\chaincode.jar:/chaincode.jar" `
    -e CHAINCODE_SERVER_ADDRESS=0.0.0.0:9999 `
    -e CORE_CHAINCODE_ID_NAME=$PKG `
    -e CORE_PEER_TLS_ENABLED=false `
    --entrypoint java hyperledger/fabric-javaenv:2.5 -jar /chaincode.jar | Out-Null
Start-Sleep -Seconds 8
Write-Host "-> serveur dvp-bankb-ccaas lance"
docker ps --format "{{.Names}}" --filter "name=-ccaas" | Sort-Object