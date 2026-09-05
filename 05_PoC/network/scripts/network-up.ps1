# Demarre le reseau du PoC: identites -> genesis block -> conteneurs -> channel.
$ErrorActionPreference = 'Stop'
$net = Split-Path $PSScriptRoot -Parent
Set-Location $net

# 1. Identites (certificats X.509 de chaque organisation)
if (-not (Test-Path "$net\crypto")) {
    Write-Host "[1/5] Generation des identites (cryptogen)..."
    docker run --rm -v "${net}:/work" -w /work hyperledger/fabric-tools:2.5 `
        cryptogen generate --config=crypto-config.yaml --output=crypto
    if ($LASTEXITCODE -ne 0) { throw "cryptogen a echoue" }
} else {
    Write-Host "[1/5] Identites deja presentes (crypto/), etape sautee."
}

# 2. Genesis block du channel (le rulebook L1 compile)
New-Item -ItemType Directory -Force "$net\artifacts" | Out-Null
if (-not (Test-Path "$net\artifacts\dvp-channel.block")) {
    Write-Host "[2/5] Generation du genesis block (configtxgen)..."
    docker run --rm -v "${net}:/work" -w /work hyperledger/fabric-tools:2.5 `
        configtxgen -configPath /work -profile DvPChannel -channelID dvp-channel -outputBlock artifacts/dvp-channel.block
    if ($LASTEXITCODE -ne 0) { throw "configtxgen a echoue" }
} else {
    Write-Host "[2/5] Genesis block deja present, etape sautee."
}

# 3. Conteneurs (orderer + 5 peers + cli)
Write-Host "[3/5] Demarrage des conteneurs..."
docker compose up -d
if ($LASTEXITCODE -ne 0) { throw "docker compose up a echoue" }
Start-Sleep -Seconds 5

# 4. L'orderer rejoint le channel (API de participation, osnadmin)
Write-Host "[4/5] L'orderer rejoint dvp-channel..."
$ordTls = "crypto/ordererOrganizations/infra.dvp.poc/orderers/orderer.infra.dvp.poc/tls"
docker exec dvp-cli osnadmin channel join --channelID dvp-channel `
    --config-block artifacts/dvp-channel.block -o orderer.infra.dvp.poc:7053 `
    --ca-file "$ordTls/ca.crt" --client-cert "$ordTls/server.crt" --client-key "$ordTls/server.key"
if ($LASTEXITCODE -ne 0) { throw "osnadmin channel join a echoue" }

# 5. Chaque peer rejoint le channel (signe par l'admin de son organisation)
Write-Host "[5/5] Les 5 peers rejoignent dvp-channel..."
$orgs = @(
    @{ name = 'centralbank'; msp = 'CentralBankMSP'; port = 7051 },
    @{ name = 'csd';         msp = 'CSDMSP';         port = 8051 },
    @{ name = 'banka';       msp = 'BankAMSP';       port = 9051 },
    @{ name = 'bankb';       msp = 'BankBMSP';       port = 10051 },
    @{ name = 'supervisor';  msp = 'SupervisorMSP';  port = 11051 }
)
foreach ($o in $orgs) {
    $d = "$($o.name).dvp.poc"
    $addr = "peer0.{0}:{1}" -f $d, $o.port
    docker exec `
        -e CORE_PEER_LOCALMSPID=$($o.msp) `
        -e CORE_PEER_ADDRESS=$addr `
        -e CORE_PEER_MSPCONFIGPATH=/work/crypto/peerOrganizations/$d/users/Admin@$d/msp `
        -e CORE_PEER_TLS_ROOTCERT_FILE=/work/crypto/peerOrganizations/$d/peers/peer0.$d/tls/ca.crt `
        dvp-cli peer channel join -b artifacts/dvp-channel.block
    if ($LASTEXITCODE -ne 0) { throw "peer channel join a echoue pour $($o.name)" }
    Write-Host "  -> $($o.msp) a rejoint le channel."
}

Write-Host ""
Write-Host "Reseau operationnel. Verification (channels vus par le peer de la banque centrale):"
$d = "centralbank.dvp.poc"
docker exec `
    -e CORE_PEER_LOCALMSPID=CentralBankMSP `
    -e CORE_PEER_ADDRESS=peer0.${d}:7051 `
    -e CORE_PEER_MSPCONFIGPATH=/work/crypto/peerOrganizations/$d/users/Admin@$d/msp `
    -e CORE_PEER_TLS_ROOTCERT_FILE=/work/crypto/peerOrganizations/$d/peers/peer0.$d/tls/ca.crt `
    dvp-cli peer channel list
