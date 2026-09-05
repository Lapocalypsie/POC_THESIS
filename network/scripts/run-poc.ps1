# =====================================================================
# run-poc.ps1 - reconstruction complete du PoC a froid, puis capture des
# preuves du paragraphe 5.4.1.
#
# A lancer depuis PowerShell, Docker Desktop demarre :
#     cd <racine-du-depot>\network\scripts
#     powershell -ExecutionPolicy Bypass -File .\run-poc.ps1
#
# Duree indicative a froid : 30 a 60 minutes (build des uberjars, demarrage
# des 9 JVM de chaincode). Le script est reprenable : chaque etape saute ce
# qui existe deja. En cas d'echec, relancer la meme commande.
#
# Toute la sortie est enregistree dans 05_PoC/evidence/00_build.log
# =====================================================================
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$net  = Split-Path $here -Parent
$root = Split-Path $net  -Parent
$ev   = Join-Path $root 'evidence'
New-Item -ItemType Directory -Force $ev | Out-Null

Start-Transcript -Path (Join-Path $ev '00_build.log') -Append | Out-Null
$t0 = Get-Date

function Step([string]$label, [string]$script) {
    Write-Host ""
    Write-Host "############################################################"
    Write-Host "#  $label"
    Write-Host "#  " (Get-Date -Format 'HH:mm:ss') " - $script"
    Write-Host "############################################################"
    & (Join-Path $here $script)
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        throw "$script s'est termine avec le code $LASTEXITCODE"
    }
}

try {
    Write-Host "Verification de Docker..."
    docker info --format '{{.ServerVersion}}' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker ne repond pas - demarre Docker Desktop et relance." }

    Step '1/6  Reseau : identites, genesis block, conteneurs, canal' 'network-up.ps1'
    Step '2/6  BondChaincode (jambe titres)'                          'deploy-bond.ps1'
    Step '3/6  wCBDCChaincode (jambe cash)'                           'deploy-wcbdc.ps1'
    Step '4/6  DvPChaincode (coordinateur, swap atomique)'            'deploy-dvp.ps1'
    Step '5/6  Serveurs CCaaS par organisation (9 serveurs)'          'setup-perorg-ccaas.ps1'
    Step '6/6  Capture des preuves du 5.4.1'                          'capture-evidence.ps1'

    $d = (Get-Date) - $t0
    Write-Host ""
    Write-Host "==================================================="
    Write-Host " PoC RECONSTRUIT ET PROUVE."
    Write-Host " Duree totale : $([math]::Round($d.TotalMinutes,1)) minutes"
    Write-Host " Preuves      : $ev"
    Write-Host "==================================================="
    Write-Host ""
    Write-Host "Etape suivante : previens Claude, il recupere le dossier evidence/"
    Write-Host "et fabrique les Figures 5.1-5.2 et le Tableau 5.5."
}
catch {
    Write-Host ""
    Write-Host "!!! ECHEC : $_" -ForegroundColor Red
    Write-Host "Le journal complet est dans $ev\00_build.log"
    Write-Host "Envoie ce fichier a Claude, il diagnostique."
    Stop-Transcript | Out-Null
    exit 1
}
Stop-Transcript | Out-Null
