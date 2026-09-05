# =====================================================================
# capture-probes.ps1 - capture les soldes avant/apres des deux sondes
# adverses T8 et T9, CONTRE UN TRADE DEJA REGLE, sans rejouer S1.
#
# A utiliser quand le reseau est encore debout avec le trade du dernier
# run : ca produit les pieces manquantes de l'Annexe A sans changer un
# seul chiffre du Tableau 5.5, des Figures 5.1-5.2 ni du 5.4.
#
#     powershell -ExecutionPolicy Bypass -File .\capture-probes.ps1 `
#         -Trade S1-20260903-220244
#
# Si le reseau a ete detruit depuis, ce script echouera a lire le trade :
# passe alors par run-poc.ps1, qui reconstruit tout et capture S1 + T8 + T9
# en une passe coherente.
#
# Sorties, dans 05_PoC/evidence/ :
#   03_balances_T8.txt / .csv   execution a une jambe : refus, soldes figes
#   03_balances_T9.txt / .csv   rejeu : refus, reglement precedent intact
# =====================================================================
param(
    [Parameter(Mandatory=$true)][string]$Trade,
    [string]$Isin = 'FR0001'
)
# Les commandes natives (docker) ecrivent sur stderr meme quand tout va bien.
# Avec 'Stop', PowerShell transforme cette sortie en erreur terminale. On garde
# donc 'Continue' et on verifie $LASTEXITCODE explicitement a chaque appel.
$ErrorActionPreference = 'Continue'

$net  = $PSScriptRoot
$root = Split-Path (Split-Path $net -Parent) -Parent
$ev   = Join-Path $root 'evidence'
New-Item -ItemType Directory -Force $ev | Out-Null

$ORD_CA  = '/work/crypto/ordererOrganizations/infra.dvp.poc/orderers/orderer.infra.dvp.poc/tls/ca.crt'
$ORDERER = 'orderer.infra.dvp.poc:7050'
$CHANNEL = 'dvp-channel'

function OrgEnv([string]$name, [string]$msp, [int]$port) {
    $d = "$name.dvp.poc"
    @('-e', "CORE_PEER_LOCALMSPID=$msp",
      '-e', ("CORE_PEER_ADDRESS=peer0.{0}:{1}" -f $d, $port),
      '-e', "CORE_PEER_MSPCONFIGPATH=/work/crypto/peerOrganizations/$d/users/Admin@$d/msp",
      '-e', "CORE_PEER_TLS_ROOTCERT_FILE=/work/crypto/peerOrganizations/$d/peers/peer0.$d/tls/ca.crt")
}
$BA = OrgEnv 'banka' 'BankAMSP' 9051
$BB = OrgEnv 'bankb' 'BankBMSP' 10051
$baTls = '/work/crypto/peerOrganizations/banka.dvp.poc/peers/peer0.banka.dvp.poc/tls/ca.crt'
$bbTls = '/work/crypto/peerOrganizations/bankb.dvp.poc/peers/peer0.bankb.dvp.poc/tls/ca.crt'
$PEERS = @('--peerAddresses', 'peer0.banka.dvp.poc:9051',  '--tlsRootCertFiles', $baTls,
           '--peerAddresses', 'peer0.bankb.dvp.poc:10051', '--tlsRootCertFiles', $bbTls)

function InvokeCC([string[]]$org, [string]$cc, [string]$json) {
    $out = & docker exec @org dvp-cli peer chaincode invoke -o $ORDERER --tls --cafile $ORD_CA `
        -C $CHANNEL -n $cc @PEERS -c $json --waitForEvent 2>&1
    return @{ code = $LASTEXITCODE; out = ($out | Out-String) }
}
function QueryCC([string]$cc, [string]$json) {
    $out = & docker exec @BA dvp-cli peer chaincode query -C $CHANNEL -n $cc -c $json 2>&1
    return ($out | Out-String).Trim()
}
function Balances() {
    [ordered]@{
        bondSeller = [long](QueryCC 'bond'  ('{\"function\":\"balanceOf\",\"Args\":[\"' + $Isin + '\",\"BankAMSP\"]}'))
        bondBuyer  = [long](QueryCC 'bond'  ('{\"function\":\"balanceOf\",\"Args\":[\"' + $Isin + '\",\"BankBMSP\"]}'))
        cashSeller = [long](QueryCC 'wcbdc' '{\"function\":\"balanceOf\",\"Args\":[\"BankAMSP\"]}')
        cashBuyer  = [long](QueryCC 'wcbdc' '{\"function\":\"balanceOf\",\"Args\":[\"BankBMSP\"]}')
        availSeller= [long](QueryCC 'bond'  ('{\"function\":\"availableOf\",\"Args\":[\"' + $Isin + '\",\"BankAMSP\"]}'))
    }
}

# Attente active : apres un simple redemarrage, les 9 serveurs de chaincode Java
# mettent souvent plus d'une minute a ecouter sur le 9999. Tant qu'ils ne repondent
# pas, le peer renvoie "connection refused" - ce n'est pas une perte de donnees.
function WaitChaincodes([int]$TimeoutSec = 240) {
    $probes = @(
        @{ cc = 'bond';  json = ('{\"function\":\"balanceOf\",\"Args\":[\"' + $Isin + '\",\"BankAMSP\"]}') },
        @{ cc = 'wcbdc'; json = '{\"function\":\"balanceOf\",\"Args\":[\"BankAMSP\"]}' },
        @{ cc = 'dvp';   json = ('{\"function\":\"getTrade\",\"Args\":[\"' + $Trade + '\"]}') }
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $tour = 0
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $tour++
        $pending = @()
        foreach ($p in $probes) {
            $null = & docker exec @BA dvp-cli peer chaincode query -C $CHANNEL -n $p.cc -c $p.json 2>&1
            if ($LASTEXITCODE -ne 0) { $pending += $p.cc }
        }
        if ($pending.Count -eq 0) {
            Write-Host ("  chaincodes prets apres {0:N0}s" -f $sw.Elapsed.TotalSeconds)
            return
        }
        Write-Host ("  tour {0} : en attente de [{1}] ({2:N0}s)" -f $tour, ($pending -join ', '), $sw.Elapsed.TotalSeconds)
        Start-Sleep -Seconds 10
    }
    throw ("Les chaincodes [{0}] ne repondent toujours pas apres {1}s. " -f ($pending -join ', '), $TimeoutSec) +
          "Verifie 'docker ps' (16 conteneurs attendus) et 'docker logs dvp-banka-ccaas'."
}

Write-Host "Trade cible : $Trade"
Write-Host "[0/2] Attente du demarrage des serveurs de chaincode..."
WaitChaincodes
$state0 = QueryCC 'dvp' ('{\"function\":\"getTrade\",\"Args\":[\"' + $Trade + '\"]}')
if ($LASTEXITCODE -ne 0) {
    throw "Lecture du trade $Trade impossible. Reponse :`r`n$state0"
}
if ($state0 -notmatch 'SETTLED') {
    throw "Le trade $Trade n'est pas SETTLED (ou n'existe pas). Reponse du ledger :`r`n$state0"
}
Write-Host "  etat : SETTLED - OK"

function ProbeNoMove([string]$code, [string]$titre, [string]$attendu, [string]$cc, [string]$json) {
    $b = Balances
    $r = InvokeCC $BB $cc $json
    $a = Balances

    $rows = @(
        [pscustomobject]@{ Account='Seller - securities account'; Asset="Tokenised bond ($Isin, units)"; Before=$b.bondSeller; After=$a.bondSeller }
        [pscustomobject]@{ Account='Buyer - securities account';  Asset="Tokenised bond ($Isin, units)"; Before=$b.bondBuyer;  After=$a.bondBuyer }
        [pscustomobject]@{ Account='Seller - cash account';       Asset='wCBDC (EUR)';                   Before=$b.cashSeller; After=$a.cashSeller }
        [pscustomobject]@{ Account='Buyer - cash account';        Asset='wCBDC (EUR)';                   Before=$b.cashBuyer;  After=$a.cashBuyer }
        [pscustomobject]@{ Account='Escrow held by DvPChaincode'; Asset="Earmarked bond ($Isin, units)"; Before=($b.bondSeller-$b.availSeller); After=($a.bondSeller-$a.availSeller) }
    ) | ForEach-Object { $_ | Add-Member -NotePropertyName Delta -NotePropertyValue ($_.After - $_.Before) -PassThru }

    $refuse   = ($r.code -ne 0)
    $immobile = -not ($rows | Where-Object { $_.Delta -ne 0 })
    $ok       = $refuse -and $immobile
    $state    = QueryCC 'dvp' ('{\"function\":\"getTrade\",\"Args\":[\"' + $Trade + '\"]}')

    $l = @()
    $l += "# Sonde $code - $titre"
    $l += "# Trade cible : $Trade (deja SETTLED)"
    $l += "# Attendu : $attendu"
    $l += "# Capture le " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') + " par capture-probes.ps1"
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

Write-Host "[1/2] T8 - execution a une jambe (ProposalGuard)..."
ProbeNoMove 'T8' 'execution a une jambe (ProposalGuard)' `
    'refus mentionnant le coordinateur dvp ; aucun solde ne bouge' `
    'bond' `
    ('{\"function\":\"bondSettlement:transferForTrade\",\"Args\":[\"' + $Trade + '\",\"BankAMSP\",\"BankBMSP\",\"' + $Isin + '\",\"1000\"]}')

Write-Host "[2/2] T9 - rejeu d'un trade deja regle..."
ProbeNoMove 'T9' 'rejeu d un trade deja regle' `
    'refus ; le trade reste SETTLED ; aucun solde ne bouge' `
    'dvp' `
    ('{\"function\":\"executeSettlement\",\"Args\":[\"' + $Trade + '\"]}')

Write-Host ""
Write-Host "==================================================="
Write-Host " T8 et T9 captures. Rien d'autre n'a bouge :"
Write-Host " le Tableau 5.5, les Figures 5.1-5.2 et le 5.4"
Write-Host " restent valables tels quels."
Write-Host " Fichiers : $ev\03_balances_T8.* et 03_balances_T9.*"
Write-Host "==================================================="
