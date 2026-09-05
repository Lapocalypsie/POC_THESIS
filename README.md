# A Reference Framework for DvP Settlement Architectures in Central Bank Money

*On the underdetermination of architecture by normative requirements*

Master's thesis — Jimmy Rasolosoa, M2 MIAGE IKSEM, University Paris 1 Panthéon-Sorbonne, 2025–2026.
Supervisor: Eddy Kiomba.

This repository holds the manuscript and everything needed to check what it claims: the derivation
behind the requirement set, the realisation matrix, the interface contracts, the proof-of-concept
source code, and the execution evidence from the run reported in Chapter 5.

---

## The question

The Principles for Financial Market Infrastructures say what a delivery-versus-payment (DvP)
settlement arrangement must achieve, not how to build it. Pilots that all cite the PFMI have built
visibly different systems. **Do those requirements determine a single settlement architecture, or
can several structurally distinct architectures satisfy them?**

The thesis derives sixteen traceable requirements from a normative, institutional and academic
corpus, groups them into six functional layers, identifies five design parameters the requirements
leave open, and specifies three candidate architecture families. One of the three is built and run
as a proof of concept; the other two are matched against arrangements central banks have documented.

The answer is that the requirements leave more than one architecture standing.

---

## What is where

| Path | What it is |
|---|---|
| [`RASOLOSOA_Jimmy_Thesis.docx`](RASOLOSOA_Jimmy_Thesis.docx) | The manuscript |
| [`05_PoC/`](05_PoC/) | The proof of concept — **start at [`05_PoC/README.md`](05_PoC/README.md)** |
| [`05_PoC/evidence/`](05_PoC/evidence/) | Execution evidence for the run of 3 September 2026: environment, running network, committed chaincodes, ledger balances before and after each scenario, test log, JUnit reports |
| [`05_PoC/thesis-materials/`](05_PoC/thesis-materials/) | The derivation behind the manuscript: PFMI coding workbook, requirement sheets R01–R16, the 48-cell realisation matrix, the interface contracts, and the editable source of Figures 4.1 to 4.5 |
| [`05_PoC/chaincode/`](05_PoC/chaincode/) | The three Hyperledger Fabric chaincodes: `bond`, `wcbdc`, `dvp` |
| [`05_PoC/network/`](05_PoC/network/) | Network configuration and the deployment, session and evidence-capture scripts |
| [`05_PoC/tests/`](05_PoC/tests/) | The ten-test suite, run end-to-end against the real network through the Fabric Gateway |
| [`wCBDC_DvP_reference_architecture.drawio`](wCBDC_DvP_reference_architecture.drawio) | Editable source of the architecture diagrams |

`05_PoC/thesis-materials/NOTES_open_items.md` records what remains open on that material, and what is
deliberately left as it is. It is worth reading before the realisation matrix.

---

## The proof of concept in short

Architecture variant **B2** — both legs of a DvP settlement committed in a single platform
transaction — on a permissioned **Hyperledger Fabric 2.5** network: five peer organisations
(central bank, CSD, two banks, a read-only supervisor), one ordering service, three chaincodes
committed on one channel, sixteen containers in all.

**What it demonstrates.** The DvP invariant: at every terminal state, bond tokens transfer if and
only if wCBDC tokens transfer. Ten tests — five scenarios and five adversarial or control probes —
completed with no failures on 3 September 2026.

**What it does not claim.** Production throughput, production-grade cyber-resilience, live RTGS
integration, legal finality, or operational readiness.

From a cold clone, one command builds the network, deploys the three chaincodes and produces every
execution artefact:

```powershell
cd 05_PoC\network\scripts
powershell -ExecutionPolicy Bypass -File .\run-poc.ps1
```

With the network already up, the test suite alone:

```powershell
cd 05_PoC\network\scripts
powershell -ExecutionPolicy Bypass -File .\run-tests.ps1
```

Prerequisites, network topology, chaincode endorsement policies, the settlement state machine, the
scenario-by-scenario test table and the evidence file index are all in
[`05_PoC/README.md`](05_PoC/README.md).

---

## Limits of this artefact

The run covers one bounded configuration on a local test network. It shows that the design can be
built and made to run under the assumptions implemented — not how it would behave in production, at
volume, or under stress. No third party has re-executed it; this repository makes that possible but
does not substitute for it. The requirement set was derived by a single coder, with the mitigations
and residual limits stated in §3.4.4 and §5.6 of the manuscript.

## Licence

MIT for the code and the companion materials — see [`05_PoC/LICENSE`](05_PoC/LICENSE). The
manuscript itself is the author's academic work and is not covered by that licence.
