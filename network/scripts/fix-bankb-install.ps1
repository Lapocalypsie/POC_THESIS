# Reinstalle le paquet dvp de BankB (perdu lors d'un crash de la VM avant flush disque).
$ErrorActionPreference = 'Stop'
$d = 'bankb.dvp.poc'
$BB = @(
    '-e', 'CORE_PEER_LOCALMSPID=BankBMSP',
    '-e', 'CORE_PEER_ADDRESS=peer0.bankb.dvp.poc:10051',
    '-e', "CORE_PEER_MSPCONFIGPATH=/work/crypto/peerOrganizations/$d/users/Admin@$d/msp",
    '-e', "CORE_PEER_TLS_ROOTCERT_FILE=/work/crypto/peerOrganizations/$d/peers/peer0.$d/tls/ca.crt"
)
& docker exec @BB dvp-cli peer lifecycle chaincode install /work/artifacts/dvp-bankb.tar.gz
if ($LASTEXITCODE -ne 0) { throw "install a echoue" }
Write-Host "-> dvp_bankb_1 reinstalle sur le peer BankB."