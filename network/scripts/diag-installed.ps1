# Diagnostic: chaincodes installes sur chaque peer + approbations dvp.
$ErrorActionPreference = 'Continue'
function OrgEnv([string]$name, [string]$msp, [int]$port) {
    $d = "$name.dvp.poc"
    @(
        '-e', "CORE_PEER_LOCALMSPID=$msp",
        '-e', ("CORE_PEER_ADDRESS=peer0.{0}:{1}" -f $d, $port),
        '-e', "CORE_PEER_MSPCONFIGPATH=/work/crypto/peerOrganizations/$d/users/Admin@$d/msp",
        '-e', "CORE_PEER_TLS_ROOTCERT_FILE=/work/crypto/peerOrganizations/$d/peers/peer0.$d/tls/ca.crt"
    )
}
foreach ($o in @(@('centralbank','CentralBankMSP',7051), @('banka','BankAMSP',9051), @('bankb','BankBMSP',10051))) {
    $e = OrgEnv $o[0] $o[1] $o[2]
    Write-Host "=== $($o[0]) : chaincodes installes ==="
    & docker exec @e dvp-cli peer lifecycle chaincode queryinstalled
}
Write-Host "=== approbations dvp (checkcommitreadiness vue CB) ==="
$CB = OrgEnv 'centralbank' 'CentralBankMSP' 7051
& docker exec @CB dvp-cli peer lifecycle chaincode checkcommitreadiness --channelID dvp-channel --name dvp --version 1.0 --sequence 1 --signature-policy "OR(AND('BankAMSP.peer','BankBMSP.peer'),'CentralBankMSP.peer')" --output json