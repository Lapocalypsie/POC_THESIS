# Migration vers un serveur CCaaS PAR ORGANISATION endosseuse.
# Un serveur partage entre peers casse les invocations imbriquees: les deux
# endorsements portent le meme txid et le shim confond les sessions (timeout).
# Chaque org installe donc un paquet pointant vers SON serveur, et approuve
# SON package id a la sequence deja committee - la definition ne change pas.
$ErrorActionPreference = 'Stop'

$ORD_CA  = '/work/crypto/ordererOrganizations/infra.dvp.poc/orderers/orderer.infra.dvp.poc/tls/ca.crt'
$ORDERER = 'orderer.infra.dvp.poc:7050'
$CHANNEL = 'dvp-channel'
$net     = Split-Path $PSScriptRoot -Parent

function OrgEnv([string]$name, [string]$msp, [int]$port) {
    $d = "$name.dvp.poc"
    @(
        '-e', "CORE_PEER_LOCALMSPID=$msp",
        '-e', ("CORE_PEER_ADDRESS=peer0.{0}:{1}" -f $d, $port),
        '-e', "CORE_PEER_MSPCONFIGPATH=/work/crypto/peerOrganizations/$d/users/Admin@$d/msp",
        '-e', "CORE_PEER_TLS_ROOTCERT_FILE=/work/crypto/peerOrganizations/$d/peers/peer0.$d/tls/ca.crt"
    )
}
$ENVS = @{
    centralbank = OrgEnv 'centralbank' 'CentralBankMSP' 7051
    csd         = OrgEnv 'csd'         'CSDMSP'         8051
    banka       = OrgEnv 'banka'       'BankAMSP'       9051
    bankb       = OrgEnv 'bankb'       'BankBMSP'       10051
}

# Endosseurs par chaincode + parametres de leur definition committee.
$CCS = @(
    @{ cc = 'bond';  orgs = @('csd', 'banka', 'bankb');         ver = '1.1'; seq = '2';
       policy = "OR('CSDMSP.peer','BankAMSP.peer','BankBMSP.peer')" },
    @{ cc = 'wcbdc'; orgs = @('centralbank', 'banka', 'bankb'); ver = '1.1'; seq = '2';
       policy = "OR('CentralBankMSP.peer','BankAMSP.peer','BankBMSP.peer')" },
    @{ cc = 'dvp';   orgs = @('centralbank', 'banka', 'bankb'); ver = '1.0'; seq = '1';
       policy = "OR(AND('BankAMSP.peer','BankBMSP.peer'),'CentralBankMSP.peer')" }
)

foreach ($entry in $CCS) {
    $cc = $entry.cc
    Write-Host "=== $cc : migration vers un serveur par organisation ==="

    # L'ancien serveur unique disparait
    $old = docker ps -aq --filter "name=$cc-ccaas"
    if ($old) { docker rm -f $old | Out-Null; Write-Host "  ancien serveur unique supprime" }

    $jar = "$net\artifacts\staging\$cc\build\libs\chaincode.jar"
    if (-not (Test-Path $jar)) { throw "jar introuvable pour $cc - lancer restart-cc.ps1 -CC $cc d'abord" }

    foreach ($org in $entry.orgs) {
        # 1. Paquet propre a l'org: l'adresse pointe vers SON serveur
        $pkgDir = "$net\artifacts\staging\$cc-ccaas-$org"
        if (Test-Path $pkgDir) { Remove-Item -Recurse -Force $pkgDir }
        New-Item -ItemType Directory -Force $pkgDir | Out-Null
        [IO.File]::WriteAllText("$pkgDir\metadata.json",
            ('{"type":"ccaas","label":"' + $cc + '_' + $org + '_1"}'))
        [IO.File]::WriteAllText("$pkgDir\connection.json",
            ('{"address":"' + $cc + '.' + $org + '.ccaas.dvp.poc:9999","dial_timeout":"10s","tls_required":false}'))
        docker exec dvp-cli bash -c "cd /work/artifacts/staging/$cc-ccaas-$org && tar czf code.tar.gz connection.json && tar czf /work/artifacts/$cc-$org.tar.gz metadata.json code.tar.gz"
        if ($LASTEXITCODE -ne 0) { throw "package $cc/$org a echoue" }

        # 2. Install sur le peer de l'org + approbation de SON package id
        $e = $ENVS[$org]
        & docker exec @e dvp-cli peer lifecycle chaincode install "/work/artifacts/$cc-$org.tar.gz"
        if ($LASTEXITCODE -ne 0) { throw "install $cc sur $org a echoue" }
        $PKG = (docker exec dvp-cli peer lifecycle chaincode calculatepackageid "/work/artifacts/$cc-$org.tar.gz" | Select-Object -Last 1).Trim()
        & docker exec @e dvp-cli peer lifecycle chaincode approveformyorg `
            -o $ORDERER --tls --cafile $ORD_CA --channelID $CHANNEL --name $cc `
            --version $entry.ver --sequence $entry.seq --signature-policy $entry.policy `
            --package-id $PKG
        if ($LASTEXITCODE -ne 0) { throw "approbation $cc/$org a echoue" }

        # 3. Le serveur de l'org
        $cname = "$cc-$org-ccaas"
        $stale = docker ps -aq --filter "name=$cname"
        if ($stale) { docker rm -f $stale | Out-Null }
        docker run -d --name $cname --network dvp-network `
            --network-alias "$cc.$org.ccaas.dvp.poc" `
            --memory 384m -e "JAVA_TOOL_OPTIONS=-Xmx192m" `
            -v "${net}\artifacts\staging\$cc\build\libs\chaincode.jar:/chaincode.jar" `
            -e CHAINCODE_SERVER_ADDRESS=0.0.0.0:9999 `
            -e CORE_CHAINCODE_ID_NAME=$PKG `
            -e CORE_PEER_TLS_ENABLED=false `
            --entrypoint java hyperledger/fabric-javaenv:2.5 -jar /chaincode.jar | Out-Null
        Write-Host "  -> $org : paquet installe, approuve (seq $($entry.seq)), serveur $cname lance"
    }
}

Start-Sleep -Seconds 8
Write-Host ""
docker ps --format "{{.Names}}" --filter "name=-ccaas" | Sort-Object
Write-Host ""
Write-Host "Topologie par organisation en place. Lancer smoke-dvp.ps1."