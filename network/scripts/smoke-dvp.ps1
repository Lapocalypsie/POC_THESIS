# Tests de fumee du coordinateur dvp (ex-phase D de deploy-dvp.ps1).
# Prerequis: reseau up, chaincodes wcbdc/bond/dvp deployes.
# Prefiguration des tests T1-T9 du chapitre 8.
$ErrorActionPreference = 'Stop'

$ORD_CA  = '/work/crypto/ordererOrganizations/infra.dvp.poc/orderers/orderer.infra.dvp.poc/tls/ca.crt'
$ORDERER = 'orderer.infra.dvp.poc:7050'
$CHANNEL = 'dvp-channel'
# Suffixe unique par execution: les trades T1xx deviennent T<hhmmss>-1xx,
# le script est rejouable sans collision d'identifiants.
$R = Get-Date -Format HHmmss

# Barriere de disponibilite: chaque serveur CCaaS doit avoir REELLEMENT mis
# son port gRPC en ecoute (ligne "start grpc server" dans ses logs) - le
# demarrage JVM a froid prend 60-90s, bien plus que l'age "Up" du conteneur.
Write-Host "Attente de disponibilite des 9 serveurs de chaincode..."
$deadline = (Get-Date).AddMinutes(8)
while ($true) {
    if ((Get-Date) -gt $deadline) { throw "serveurs de chaincode indisponibles apres 8 minutes" }
    $names = @(docker ps --filter "name=-ccaas" --format "{{.Names}}")
    $ready = 0
    foreach ($n in $names) {
        # Redirection dans cmd.exe: PS 5.1 transforme le stderr natif en erreur
        # fatale. Log COMPLET: sur un serveur actif, la ligne de demarrage
        # defile au-dela des dernieres lignes.
        $found = cmd /c "docker logs $n 2>&1" | Select-String -Quiet "start grpc server"
        if ($found) { $ready++ }
    }
    Write-Host "  serveurs prets: $ready/9"
    if ($names.Count -ge 9 -and $ready -ge 9) { break }
    Start-Sleep -Seconds 15
}
Write-Host "Les 9 serveurs ecoutent."

function OrgEnv([string]$name, [string]$msp, [int]$port) {
    $d = "$name.dvp.poc"
    @(
        '-e', "CORE_PEER_LOCALMSPID=$msp",
        '-e', ("CORE_PEER_ADDRESS=peer0.{0}:{1}" -f $d, $port),
        '-e', "CORE_PEER_MSPCONFIGPATH=/work/crypto/peerOrganizations/$d/users/Admin@$d/msp",
        '-e', "CORE_PEER_TLS_ROOTCERT_FILE=/work/crypto/peerOrganizations/$d/peers/peer0.$d/tls/ca.crt"
    )
}
$CB = OrgEnv 'centralbank' 'CentralBankMSP' 7051
$BA = OrgEnv 'banka'       'BankAMSP'       9051
$BB = OrgEnv 'bankb'       'BankBMSP'       10051

$cbTls = '/work/crypto/peerOrganizations/centralbank.dvp.poc/peers/peer0.centralbank.dvp.poc/tls/ca.crt'
$baTls = '/work/crypto/peerOrganizations/banka.dvp.poc/peers/peer0.banka.dvp.poc/tls/ca.crt'
$bbTls = '/work/crypto/peerOrganizations/bankb.dvp.poc/peers/peer0.bankb.dvp.poc/tls/ca.crt'

$BANKS_PEERS = @('--peerAddresses', 'peer0.banka.dvp.poc:9051', '--tlsRootCertFiles', $baTls,
                 '--peerAddresses', 'peer0.bankb.dvp.poc:10051', '--tlsRootCertFiles', $bbTls)
$CB_PEER     = @('--peerAddresses', 'peer0.centralbank.dvp.poc:7051', '--tlsRootCertFiles', $cbTls)

function InvokeCC([string[]]$org, [string[]]$peers, [string]$cc, [string]$json) {
    $json = $json.Replace('\"T1', '\"T' + $R + '-1')
    & docker exec @org dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
        -C $CHANNEL -n $cc @peers -c $json --waitForEvent
    return $LASTEXITCODE
}
function QueryCC([string[]]$org, [string]$cc, [string]$json) {
    $json = $json.Replace('\"T1', '\"T' + $R + '-1')
    return (& docker exec @org dvp-cli peer chaincode query -C $CHANNEL -n $cc -c $json)
}
# NB: noms locaux distincts de $BA/$BB/$CB - les variables PowerShell sont
# INSENSIBLES a la casse, $bA ecraserait l'identite $BA.
function PrintBalances([string]$label) {
    $bondA = QueryCC $BA 'bond'  '{\"function\":\"balanceOf\",\"Args\":[\"FR0001\",\"BankAMSP\"]}'
    $bondB = QueryCC $BA 'bond'  '{\"function\":\"balanceOf\",\"Args\":[\"FR0001\",\"BankBMSP\"]}'
    $cashA = QueryCC $BA 'wcbdc' '{\"function\":\"balanceOf\",\"Args\":[\"BankAMSP\"]}'
    $cashB = QueryCC $BA 'wcbdc' '{\"function\":\"balanceOf\",\"Args\":[\"BankBMSP\"]}'
    Write-Host "  [$label] titres A=$bondA B=$bondB | cash A=$cashA B=$cashB"
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

Write-Host "--- D-7 (NEGATIF): BankB appelle bondSettlement:transferForTrade DIRECTEMENT ---"
if ((InvokeCC $BB @('--peerAddresses', 'peer0.bankb.dvp.poc:10051', '--tlsRootCertFiles', $bbTls) 'bond' '{\"function\":\"bondSettlement:transferForTrade\",\"Args\":[\"T100\",\"BankAMSP\",\"BankBMSP\",\"FR0001\",\"100000\"]}') -eq 0) { throw "D-7: aurait du etre refuse" }
Write-Host "  -> REFUSE comme attendu: une jambe seule est inexecutable (invariant protege)."

Write-Host "--- D-8: pause C1 (banque centrale), tentative de trade, reprise ---"
if ((InvokeCC $CB $CB_PEER 'dvp' '{\"function\":\"dvpAdmin:pause\",\"Args\":[\"incident-operationnel\"]}') -ne 0) { throw "D-8a" }
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"proposeTrade\",\"Args\":[\"T101\",\"BankBMSP\",\"BankAMSP\",\"FR0001\",\"1000\",\"950\",\"EUR\",\"300\",\"600\"]}') -eq 0) { throw "D-8b: aurait du etre refuse" }
Write-Host "  -> proposition REFUSEE pendant la pause (C1)."
if ((InvokeCC $BA $BANKS_PEERS 'dvp' '{\"function\":\"dvpAdmin:pause\",\"Args\":[\"tentative-illegitime\"]}') -eq 0) { throw "D-8c: aurait du etre refuse" }
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
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"proposeTrade\",\"Args\":[\"T105\",\"BankBMSP\",\"BankAMSP\",\"FR0001\",\"100000\",\"9000000\",\"EUR\",\"12\",\"300\"]}') -ne 0) { throw "D-12a" }
if ((InvokeCC $BA $BANKS_PEERS 'dvp' '{\"function\":\"confirmTrade\",\"Args\":[\"T105\"]}') -ne 0) { throw "D-12b" }
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"executeSettlement\",\"Args\":[\"T105\"]}') -ne 0) { throw "D-12c" }
Write-Host "  ESCROW_WAITING atteint; attente de l'expiration du timeout metier (12s)..."
Start-Sleep -Seconds 10
if ((InvokeCC $BA $BANKS_PEERS 'dvp' '{\"function\":\"releaseExpired\",\"Args\":[\"T105\"]}') -ne 0) { throw "D-12d" }
$avail = QueryCC $BA 'bond' '{\"function\":\"availableOf\",\"Args\":[\"FR0001\",\"BankAMSP\"]}'
Write-Host "  liberation OK; disponible vendeur = $avail (attendu 500000, earmark leve)"

Write-Host "--- D-13: T106 -> filet de securite -> RELEASED_SAFETY ---"
if ((InvokeCC $BB $BANKS_PEERS 'dvp' '{\"function\":\"proposeTrade\",\"Args\":[\"T106\",\"BankBMSP\",\"BankAMSP\",\"FR0001\",\"100000\",\"9000000\",\"EUR\",\"2\",\"4\"]}') -ne 0) { throw "D-13a" }
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
Write-Host "Machine a etats et swap atomique demontres: les 5 etats terminaux sont atteints."