# =====================================================================
# capture-evidence.ps1
# Produit les pieces justificatives du paragraphe 5.4.1 du memoire.
# Prerequis : reseau up, 3 chaincodes committes, 9 serveurs CCaaS actifs.
#             (network-up.ps1 -> deploy-bond -> deploy-wcbdc -> deploy-dvp
#              -> setup-perorg-ccaas)
#
# Sorties, dans 05_PoC/evidence/ :
#   00_environment.txt   versions Docker / Fabric / date de run
#   01_docker_ps.txt     conteneurs actifs            -> Figure 5.1 (haut)
#   02_querycommitted.txt definitions engagees        -> Figure 5.1 (bas)
#   03_balances_S1.txt   soldes avant/apres S1        -> Tableau 5.5
#   03_balances_S1.csv   les memes, en CSV
#   03_balances_T8.txt   sonde T8 execution a une jambe, soldes inchanges
#   03_balances_T8.csv   les memes, en CSV
#   03_balances_T9.txt   sonde T9 rejeu, soldes inchanges
#   03_balances_T9.csv   les memes, en CSV
#   04_testsuite.log     log complet de la suite T1-T9 -> Figure 5.2
#   05_junit/            rapports JUnit XML            -> Annexe A
# =====================================================================
$ErrorActionPreference = 'Continue'

$net  = Split-Path $PSScriptRoot -Parent
$root = Split-Path $net -Parent
$ev   = Join-Path $root 'evidence'
New-Item -ItemType Directory -Force $ev | Out-Null

$ORD_CA  = '/work/crypto/ordererOrganizations/infra.dvp.poc/orderers/orderer.infra.dvp.poc/tls/ca.crt'
$ORDERER = 'orderer.infra.dvp.poc:7050'
$CHANNEL = 'dvp-channel'
$ISIN    = 'FR0001'
$RUN     = Get-Date -Format 'yyyyMMdd-HHmmss'
$TRADE   = "S1-$RUN"
$BOND_QTY = 100000
$CASH_QTY = 95000

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
$BANKS_PEERS = @('--peerAddresses', 'peer0.banka.dvp.poc:9051',  '--tlsRootCertFiles', $baTls,
                 '--peerAddresses', 'peer0.bankb.dvp.poc:10051', '--tlsRootCertFiles', $bbTls)
$CB_PEER     = @('--peerAddresses', 'peer0.centralbank.dvp.poc:7051', '--tlsRootCertFiles', $cbTls)

# Invocation : la sortie combinee (stdout + stderr) contient le txid et le
# statut de validation - c'est la trace d'audit, on la conserve telle quelle.
function InvokeCC([string[]]$org, [string[]]$peers, [string]$cc, [string]$json) {
    $out = & docker exec @org dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
        -C $CHANNEL -n $cc @peers -c $json --waitForEvent 2>&1
    return @{ code = $LASTEXITCODE; out = ($out | Out-String) }
}
function QueryCC([string[]]$org, [string]$cc, [string]$json) {
    $out = & docker exec @org dvp-cli peer chaincode query -C $CHANNEL -n $cc -c $json 2>&1
    return ($out | Out-String).Trim()
}
function Balances() {
    [ordered]@{
        bondSeller = [long](QueryCC $BA 'bond'  ('{\"function\":\"balanceOf\",\"Args\":[\"' + $ISIN + '\",\"BankAMSP\"]}'))
        bondBuyer  = [long](QueryCC $BA 'bond'  ('{\"function\":\"balanceOf\",\"Args\":[\"' + $ISIN + '\",\"BankBMSP\"]}'))
        cashSeller = [long](QueryCC $BA 'wcbdc' '{\"function\":\"balanceOf\",\"Args\":[\"BankAMSP\"]}')
        cashBuyer  = [long](QueryCC $BA 'wcbdc' '{\"function\":\"balanceOf\",\"Args\":[\"BankBMSP\"]}')
        availSeller= [long](QueryCC $BA 'bond'  ('{\"function\":\"availableOf\",\"Args\":[\"' + $ISIN + '\",\"BankAMSP\"]}'))
    }
}

# ---------------------------------------------------------------------
Write-Host "[1/6] Environnement..."
$envLines = @()
$envLines += "Run identifier      : $RUN"
$envLines += "Date (local)        : " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
$envLines += "Date (UTC)          : " + ((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) + " UTC"
$envLines += "Host                : $env:COMPUTERNAME / " + [System.Environment]::OSVersion.VersionString
$envLines += "PowerShell          : " + $PSVersionTable.PSVersion
$envLines += ""
$envLines += "--- docker version ---"
$envLines += (cmd /c "docker version 2>&1" | Out-String)
$envLines += "--- images Fabric utilisees ---"
$envLines += (cmd /c "docker images --filter reference=hyperledger/* --format ""{{.Repository}}:{{.Tag}}  {{.ID}}  {{.CreatedSince}}"" 2>&1" | Out-String)
$envLines += "--- peer version (conteneur cli) ---"
$envLines += (cmd /c "docker exec dvp-cli peer version 2>&1" | Out-String)
$envLines -join "`r`n" | Set-Content -Path (Join-Path $ev '00_environment.txt') -Encoding UTF8

# ---------------------------------------------------------------------
Write-Host "[2/6] Etat du reseau (Figure 5.1, haut)..."
$psOut = @()
$psOut += "# Reseau Fabric du PoC - conteneurs actifs"
$psOut += "# Genere le " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " par capture-evidence.ps1"
$psOut += ""
$psOut += (cmd /c "docker ps --format ""table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"" 2>&1" | Out-String)
$psOut += ""
$psOut += "# Total conteneurs actifs : " + (@(cmd /c "docker ps -q 2>&1").Count)
$psOut -join "`r`n" | Set-Content -Path (Join-Path $ev '01_docker_ps.txt') -Encoding UTF8

Write-Host "[3/6] Definitions de chaincode engagees (Figure 5.1, bas)..."
$qc = @()
$qc += "# Definitions de chaincode engagees sur le canal $CHANNEL"
$qc += "# Vue depuis le peer de la banque centrale (CentralBankMSP)"
$qc += ""
$qc += (& docker exec @CB dvp-cli peer lifecycle chaincode querycommitted -C $CHANNEL 2>&1 | Out-String)
$qc += ""
$qc += "# Canaux vus par ce peer"
$qc += (& docker exec @CB dvp-cli peer channel list 2>&1 | Out-String)
$qc -join "`r`n" | Set-Content -Path (Join-Path $ev '02_querycommitted.txt') -Encoding UTF8

# ---------------------------------------------------------------------
Write-Host "[4/6] Scenario S1 - soldes avant/apres (Tableau 5.5)..."
# Etat prealable : participants admis, plafond en vigueur, reglement actif.
InvokeCC $CB $CB_PEER 'dvp' '{\"function\":\"dvpAdmin:setEligibility\",\"Args\":[\"BankAMSP\",\"true\"]}' | Out-Null
InvokeCC $CB $CB_PEER 'dvp' '{\"function\":\"dvpAdmin:setEligibility\",\"Args\":[\"BankBMSP\",\"true\"]}' | Out-Null
InvokeCC $CB $CB_PEER 'dvp' '{\"function\":\"dvpAdmin:setComplianceCap\",\"Args\":[\"10000000\"]}' | Out-Null
InvokeCC $CB $CB_PEER 'dvp' '{\"function\":\"dvpAdmin:unpause\",\"Args\":[]}' | Out-Null

$before = Balances
$log = @()
$log += "# Scenario S1 (happy path) - trade $TRADE"
$log += "# ISIN $ISIN | titres $BOND_QTY | cash $CASH_QTY EUR"
$log += "# Vendeur BankAMSP -> Acheteur BankBMSP"
$log += ""
$log += "== SOLDES AVANT S1 =="
$before.GetEnumerator() | ForEach-Object { $log += ("  {0,-12} = {1}" -f $_.Key, $_.Value) }
$log += ""

$propose = '{\"function\":\"proposeTrade\",\"Args\":[\"' + $TRADE + '\",\"BankBMSP\",\"BankAMSP\",\"' + $ISIN + '\",\"' + $BOND_QTY + '\",\"' + $CASH_QTY + '\",\"EUR\",\"300\",\"600\"]}'
$r = InvokeCC $BB $BANKS_PEERS 'dvp' $propose
$log += "== I3 proposeTrade (BankB, acheteuse) =="; $log += $r.out
if ($r.code -ne 0) { throw "proposeTrade a echoue" }

$r = InvokeCC $BA $BANKS_PEERS 'dvp' ('{\"function\":\"confirmTrade\",\"Args\":[\"' + $TRADE + '\"]}')
$log += "== confirmTrade (BankA, vendeuse - cosignature R05) =="; $log += $r.out
if ($r.code -ne 0) { throw "confirmTrade a echoue" }

$r = InvokeCC $BB $BANKS_PEERS 'dvp' ('{\"function\":\"executeSettlement\",\"Args\":[\"' + $TRADE + '\"]}')
$log += "== executeSettlement - SWAP ATOMIQUE O1+O2 =="; $log += $r.out
if ($r.code -ne 0) { throw "executeSettlement a echoue" }

$state = QueryCC $BA 'dvp' ('{\"function\":\"getTrade\",\"Args\":[\"' + $TRADE + '\"]}')
$log += "== Etat du trade apres reglement =="; $log += $state; $log += ""

$after = Balances
$log += "== SOLDES APRES S1 =="
$after.GetEnumerator() | ForEach-Object { $log += ("  {0,-12} = {1}" -f $_.Key, $_.Value) }
$log += ""

$rows = @(
    [pscustomobject]@{ Account='Seller - securities account'; Asset="Tokenised bond ($ISIN, units)"; Before=$before.bondSeller; After=$after.bondSeller }
    [pscustomobject]@{ Account='Buyer - securities account';  Asset="Tokenised bond ($ISIN, units)"; Before=$before.bondBuyer;  After=$after.bondBuyer }
    [pscustomobject]@{ Account='Seller - cash account';       Asset='wCBDC (EUR)';                   Before=$before.cashSeller; After=$after.cashSeller }
    [pscustomobject]@{ Account='Buyer - cash account';        Asset='wCBDC (EUR)';                   Before=$before.cashBuyer;  After=$after.cashBuyer }
    [pscustomobject]@{ Account='Escrow held by DvPChaincode'; Asset="Earmarked bond ($ISIN, units)"; Before=($before.bondSeller-$before.availSeller); After=($after.bondSeller-$after.availSeller) }
) | ForEach-Object { $_ | Add-Member -NotePropertyName Delta -NotePropertyValue ($_.After - $_.Before) -PassThru }

$log += "== TABLEAU 5.5 - Ledger balances before and after scenario S1 =="
$log += ($rows | Format-Table -AutoSize | Out-String)

# Verification de l'invariant DvP, ecrite dans la preuve elle-meme.
$ok = ($rows[0].Delta -eq -$BOND_QTY) -and ($rows[1].Delta -eq $BOND_QTY) `
  -and ($rows[2].Delta -eq  $CASH_QTY) -and ($rows[3].Delta -eq -$CASH_QTY) `
  -and ($rows[4].After -eq 0)
$log += "== INVARIANT DvP =="
$log += "  delta titres vendeur   = " + $rows[0].Delta + "  (attendu " + (-$BOND_QTY) + ")"
$log += "  delta titres acheteur  = " + $rows[1].Delta + "  (attendu " + $BOND_QTY + ")"
$log += "  delta cash vendeur     = " + $rows[2].Delta + "  (attendu " + $CASH_QTY + ")"
$log += "  delta cash acheteur    = " + $rows[3].Delta + "  (attendu " + (-$CASH_QTY) + ")"
$log += "  escrow apres reglement = " + $rows[4].After + "  (attendu 0)"
$log += "  VERDICT : " + $(if ($ok) { 'PASS - les deux jambes ont bouge des montants instruits' } else { 'FAIL' })
$log -join "`r`n" | Set-Content -Path (Join-Path $ev '03_balances_S1.txt') -Encoding UTF8
$rows | Export-Csv -Path (Join-Path $ev '03_balances_S1.csv') -NoTypeInformation -Encoding UTF8
if (-not $ok) { throw "INVARIANT DvP VIOLE - voir evidence/03_balances_S1.txt" }
Write-Host "  invariant DvP : PASS"

# ---------------------------------------------------------------------
# Sondes adverses T8 et T9 : les deux chemins qui creeraient un etat mixte.
# Elles pesent plus que le happy path, parce qu'elles montrent que
# l'execution a une jambe et le rejeu sont INDISPONIBLES, pas seulement
# non testes. L'Annexe A demande les soldes avant/apres pour S1, T8 et T9.
Write-Host "[5/6] Sondes adverses T8 et T9 - soldes avant/apres..."

function ProbeNoMove([string]$code, [string]$titre, [string]$attendu,
                     [string[]]$org, [string[]]$peers, [string]$cc, [string]$json) {
    $b = Balances
    $r = InvokeCC $org $peers $cc $json
    $a = Balances

    $rows = @(
        [pscustomobject]@{ Account='Seller - securities account'; Asset="Tokenised bond ($ISIN, units)"; Before=$b.bondSeller; After=$a.bondSeller }
        [pscustomobject]@{ Account='Buyer - securities account';  Asset="Tokenised bond ($ISIN, units)"; Before=$b.bondBuyer;  After=$a.bondBuyer }
        [pscustomobject]@{ Account='Seller - cash account';       Asset='wCBDC (EUR)';                   Before=$b.cashSeller; After=$a.cashSeller }
        [pscustomobject]@{ Account='Buyer - cash account';        Asset='wCBDC (EUR)';                   Before=$b.cashBuyer;  After=$a.cashBuyer }
        [pscustomobject]@{ Account='Escrow held by DvPChaincode'; Asset="Earmarked bond ($ISIN, units)"; Before=($b.bondSeller-$b.availSeller); After=($a.bondSeller-$a.availSeller) }
    ) | ForEach-Object { $_ | Add-Member -NotePropertyName Delta -NotePropertyValue ($_.After - $_.Before) -PassThru }

    $refuse   = ($r.code -ne 0)
    $immobile = -not ($rows | Where-Object { $_.Delta -ne 0 })
    $ok       = $refuse -and $immobile
    $state    = QueryCC $BA 'dvp' ('{\"function\":\"getTrade\",\"Args\":[\"' + $TRADE + '\"]}')

    $l = @()
    $l += "# Sonde $code - $titre"
    $l += "# Trade cible : $TRADE (deja SETTLED par S1)"
    $l += "# Attendu : $attendu"
    $l += ""
    $l += "== SOLDES AVANT $code =="
    $b.GetEnumerator() | ForEach-Object { $l += ("  {0,-12} = {1}" -f $_.Key, $_.Value) }
    $l += ""
    $l += "== APPEL - doit etre REFUSE =="
    $l += $r.out
    $l += ("  code de retour = {0}   (attendu : different de 0)" -f $r.code)
    $l += ""
    $l += "== SOLDES APRES $code =="
    $a.GetEnumerator() | ForEach-Object { $l += ("  {0,-12} = {1}" -f $_.Key, $_.Value) }
    $l += ""
    $l += "== ETAT DU TRADE APRES LA SONDE =="
    $l += $state
    $l += ""
    $l += "== SOLDES AVANT / APRES $code =="
    $l += ($rows | Format-Table -AutoSize | Out-String)
    $l += "== VERIFICATION =="
    $l += ("  appel refuse            : {0}" -f $refuse)
    $l += ("  aucun solde n'a bouge   : {0}" -f $immobile)
    $l += "  VERDICT : " + $(if ($ok) { 'PASS - refus, et les quatre soldes sont inchanges' } else { 'FAIL' })

    $l -join "`r`n" | Set-Content -Path (Join-Path $ev "03_balances_$code.txt") -Encoding UTF8
    $rows | Export-Csv -Path (Join-Path $ev "03_balances_$code.csv") -NoTypeInformation -Encoding UTF8
    if (-not $ok) { throw "$code : comportement inattendu - voir evidence/03_balances_$code.txt" }
    Write-Host ("  {0} : PASS" -f $code)
}

# T8 - execution a une jambe : appel direct de la jambe titres sans passer par
# le coordinateur. ProposalGuard doit refuser (R05, R14).
ProbeNoMove 'T8' 'execution a une jambe (ProposalGuard)' `
    'refus mentionnant le coordinateur dvp ; aucun solde ne bouge' `
    $BB $BANKS_PEERS 'bond' `
    ('{\"function\":\"bondSettlement:transferForTrade\",\"Args\":[\"' + $TRADE + '\",\"BankAMSP\",\"BankBMSP\",\"' + $ISIN + '\",\"1000\"]}')

# T9 - rejeu : reglement d'un trade deja SETTLED. Doit etre refuse et laisser
# le reglement precedent intact.
ProbeNoMove 'T9' 'rejeu d un trade deja regle' `
    'refus ; le trade reste SETTLED ; aucun solde ne bouge' `
    $BB $BANKS_PEERS 'dvp' `
    ('{\"function\":\"executeSettlement\",\"Args\":[\"' + $TRADE + '\"]}')

# ---------------------------------------------------------------------
Write-Host "[6/6] Suite T1-T9 (Figure 5.2)..."
$tests  = Join-Path $root 'tests'
$crypto = Join-Path $net  'crypto'
$sw = [Diagnostics.Stopwatch]::StartNew()
$testLog = cmd /c "docker run --rm --network dvp-network -m 2g --memory-swap 2g -e ""GRADLE_OPTS=-Dorg.gradle.jvmargs=-Xmx512m"" -v ""${tests}:/tests"" -v ""${crypto}:/crypto"" -v gradle-cache:/root/.gradle -w /tests --entrypoint /bin/bash hyperledger/fabric-javaenv:2.5 -c ""/root/chaincode-java/gradlew --no-daemon test --info"" 2>&1"
$code = $LASTEXITCODE
$sw.Stop()

$header = @(
    "# Suite T1-T9 - execution bout-en-bout via Fabric Gateway",
    "# Date            : " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
    "# Duree totale    : " + [math]::Round($sw.Elapsed.TotalSeconds, 1) + " s",
    "# Code de sortie  : $code (" + $(if ($code -eq 0) { 'SUCCES' } else { 'ECHEC' }) + ")",
    ""
)
(($header + $testLog) -join "`r`n") | Set-Content -Path (Join-Path $ev '04_testsuite.log') -Encoding UTF8

$junitSrc = Join-Path $tests 'build\test-results\test'
if (Test-Path $junitSrc) {
    $junitDst = Join-Path $ev '05_junit'
    New-Item -ItemType Directory -Force $junitDst | Out-Null
    Copy-Item "$junitSrc\*.xml" $junitDst -Force
}

Write-Host ""
Write-Host "==================================================="
Write-Host " Preuves ecrites dans : $ev"
Get-ChildItem $ev | ForEach-Object { Write-Host ("   {0,-24} {1,8} o" -f $_.Name, $_.Length) }
Write-Host " Duree de la suite : " ([math]::Round($sw.Elapsed.TotalSeconds, 1)) "s"
Write-Host "==================================================="
if ($code -ne 0) { throw "DES TESTS ONT ECHOUE - voir evidence/04_testsuite.log" }
Write-Host "Suite T1-T9 VERTE. Toutes les pieces du 5.4.1 sont produites."
