# DvP Settlement Proof of Concept — Variant B2 (Integrated On-Ledger Platform Commit)

Companion repository to the Master's thesis *A Reference Framework for DvP Settlement
Architectures in Central Bank Money: On the underdetermination of architecture by normative
requirements* (Jimmy Rasolosoa, M2 MIAGE IKSEM, University Paris 1 Panthéon-Sorbonne,
2025–2026).

This repository contains the proof of concept reported in **Chapter 5**. It implements
architecture variant **B2** — both legs of a delivery-versus-payment settlement committed in a
single platform transaction — on a permissioned Hyperledger Fabric network, and the ten-test
suite that exercises it.

**What it demonstrates.** The DvP invariant: at every terminal state, bond tokens transfer if
and only if wCBDC tokens transfer.

**What it does not claim.** Production throughput, production-grade cyber-resilience, live RTGS
integration, legal finality, or operational readiness. See §5.1 and §5.6 of the thesis.

---

## 1. Network topology

One channel, `dvp-channel`, on Hyperledger Fabric **2.5** (`goleveldb` state database).

| Organisation | MSP ID | Peer endpoint | Role |
|---|---|---|---|
| Central bank | `CentralBankMSP` | `peer0.centralbank.dvp.poc:7051` | Issues and redeems wCBDC; reserved operations (mint, burn, pause) |
| CSD | `CSDMSP` | `peer0.csd.dvp.poc:8051` | Authority over securities issuance |
| Bank A | `BankAMSP` | `peer0.banka.dvp.poc:9051` | Seller in the reference scenario |
| Bank B | `BankBMSP` | `peer0.bankb.dvp.poc:10051` | Buyer in the reference scenario |
| Supervisor | `SupervisorMSP` | `peer0.supervisor.dvp.poc:11051` | Read-only; queries state and subscribes to events, endorses nothing |

Ordering service: `orderer.infra.dvp.poc:7050` (admin API on `7053`), single Raft node.

Running the network brings up **16 containers**: 1 orderer, 5 peers, 1 CLI, and 9 chaincode
servers (three chaincodes × three endorsing organisations each, in *chaincode-as-a-service*
mode — one server per organisation, because a server shared between peers makes nested
invocations collide on the transaction id).

## 2. Chaincodes

| Chaincode | Contracts | Endorsement policy |
|---|---|---|
| `bond` | `BondContract` (issuance, transfer, balances), `bondSettlement` (`*ForTrade` settlement entry points), `ProposalGuard` | `OR('CSDMSP.peer','BankAMSP.peer','BankBMSP.peer')` |
| `wcbdc` | `WCBDCContract` (mint, burn, transfer, balances), `ProposalGuard` | `OR('CentralBankMSP.peer','BankAMSP.peer','BankBMSP.peer')` |
| `dvp` | `DvPContract` (lifecycle state machine, atomic swap), `dvpAdmin` / `CentralBankOperations` (eligibility, compliance cap, pause) | `OR(AND('BankAMSP.peer','BankBMSP.peer'),'CentralBankMSP.peer')` |

Two structural properties carry the invariant:

1. **Atomic swap.** `DvPContract.executeSettlement` invokes the securities transfer and the cash
   transfer through `invokeChaincodeWithStringArgs` within one platform transaction. Both
   invocations contribute to a single read/write set, so they validate and commit together or
   neither commits. No committed intermediate state can hold one settled leg.
2. **Caller guard.** `ProposalGuard.requireInvokedViaDvp`, present in both token chaincodes,
   parses the client's signed proposal and refuses any `*ForTrade` call whose transaction does
   not target `dvp`. A participant therefore cannot invoke one leg directly.

### Settlement state machine

```
                proposeTrade                confirmTrade            executeSettlement
  (instruction) ───────────►  PROPOSED  ─────────────────►  PENDING ─────────────────► SETTLED
        │                                                      │
        │ pause / eligibility / compliance                     │ underfunded
        ▼                                                      ▼
  REJECTED_INELIGIBLE                                    ESCROW_WAITING
  REJECTED_COMPLIANCE                                          │
                                          retry after on-ramp  ├────────────────────► SETTLED
                                          business timeout     ├────────────────────► RELEASED_BUSINESS
                                          safety timeout       └────────────────────► RELEASED_SAFETY
```

Value is reserved only in `ESCROW_WAITING`, as an earmark on the seller's securities. Terminal
states admit no further value-moving transition; replay is refused.

## 3. Prerequisites

- Docker Desktop (Linux containers), 8 GB RAM available to the engine
- Windows PowerShell 5.1 or later — the deployment scripts are PowerShell
- No local Java, Gradle or Fabric binary: every build runs inside `hyperledger/fabric-javaenv:2.5`
  and `hyperledger/fabric-tools:2.5`

## 4. Reproducing the run

From a cold clone, one command builds the network, deploys the three chaincodes and produces
every execution artefact reported in §5.4:

```powershell
cd network\scripts
powershell -ExecutionPolicy Bypass -File .\run-poc.ps1
```

Expect 30–60 minutes on first run: the uberjars are compiled inside the build container and the
nine chaincode JVMs take 60–90 seconds each to listen. The script is resumable — each stage skips
what already exists, so re-running the same command after a failure continues where it stopped.

Individual stages, in order, if you prefer to run them one at a time:

| # | Script | What it does |
|---|---|---|
| 1 | `network-up.ps1` | `cryptogen` identities, `configtxgen` genesis block, containers, channel joins |
| 2 | `deploy-bond.ps1` | Package, install, approve, commit `bond`; smoke tests |
| 3 | `deploy-wcbdc.ps1` | Same for `wcbdc`, including the reserved-mint check |
| 4 | `deploy-dvp.ps1` | Upgrade `bond`/`wcbdc` to sequence 2, deploy the `dvp` coordinator |
| 5 | `setup-perorg-ccaas.ps1` | Migrate to one chaincode server per endorsing organisation |
| 6 | `capture-evidence.ps1` | Produce `evidence/` (see below) |

After a Docker Desktop restart, `session-up.ps1` brings the network back without redeploying —
the ledger lives in named volumes. `network-down.ps1` tears everything down.

### The test suite alone

With the network up and the chaincodes committed:

```powershell
cd network\scripts
powershell -ExecutionPolicy Bypass -File .\run-tests.ps1
```

Ten tests run end-to-end against the real network through the Fabric Gateway — no mocks. Each
records the four balances before and after, and asserts both the terminal state reached and the
DvP invariant on those balances.

| Test | Scenario | Expected terminal state |
|---|---|---|
| T1 | Happy path, funded co-signed instruction | `SETTLED` |
| T2 | Escrow never funded, business window elapses | `RELEASED_BUSINESS` |
| T2bis | Escrow funded by central-bank on-ramp, retry | `SETTLED` |
| T3 | Escrow persists past the safety window | `RELEASED_SAFETY` |
| T4 | Cash amount breaches the compliance cap | `REJECTED_COMPLIANCE` |
| T5 | Counterparty not admitted | `REJECTED_INELIGIBLE` |
| T6 | Central-bank pause; participant activation attempt | Settlement blocked; participant refused |
| T7 | Participant attempts a wCBDC mint | Refused, total supply unchanged |
| T8 | Securities leg invoked without the coordinator | Refused, balances unchanged |
| T9 | Settled trade replayed | Refused, previous settlement unchanged |

Reports land in `tests/build/reports/tests/test/index.html` (human) and
`tests/build/test-results/test/*.xml` (JUnit XML).

## 5. Execution evidence

`capture-evidence.ps1` writes `evidence/`, which is the material reproduced in §5.4.1 of the
thesis:

| File | Supports |
|---|---|
| `00_environment.txt` | Docker and Fabric versions, run timestamp |
| `01_docker_ps.txt` | Running containers — Figure 5.1 (upper panel) |
| `02_querycommitted.txt` | Committed chaincode definitions on the channel — Figure 5.1 (lower panel) |
| `03_balances_S1.txt` / `.csv` | Ledger balances before and after scenario S1 — Table 5.5 |
| `03_balances_T8.txt` / `.csv` | Balances around the one-legged execution probe: refused, nothing moved |
| `03_balances_T9.txt` / `.csv` | Balances around the replay probe: refused, the earlier settlement intact |
| `04_testsuite.log` | Test-suite execution log — Figure 5.2 |
| `05_junit/` | JUnit XML reports |

Each of these three artefacts recomputes the invariant from the recorded balances and fails the
run if it does not hold — the settled scenario if the deltas do not offset exactly, the two probes
if the call was not refused or if any balance moved. The artefact states its own verdict rather
than relying on the narrative around it.

The two probes carry more weight than the happy path: they show that one-legged execution and
replay are *unavailable*, not merely untried. T8 records the securities contract's own refusal —
`transferForTrade is only invocable through the dvp coordinator; the signed proposal targets
'bond'`, payload `UNAUTHORIZED` — which is the caller guard reproduced in Figure 5.3 of the thesis,
observed at runtime. T9 records `INVALID_STATE` and the trade still reading `SETTLED`.

Their absolute balances differ from Table 5.5 because the probes are captured against the settled
trade at a later point in the ledger's life. That is not an inconsistency: what a probe establishes
is that every delta is zero, and the header of each file records the trade it targets and the
moment of capture.

## 6. Repository layout

```
chaincode/
  bond/    BondContract, BondSettlement, BondStore, ProposalGuard, Issuance, Errors
  wcbdc/   WCBDCContract, ProposalGuard
  dvp/     DvPContract, CentralBankOperations, DvPStore, Trade, Errors
network/
  configtx.yaml          channel profile and organisation definitions
  crypto-config.yaml     identity topology for cryptogen
  docker-compose.yaml    orderer, 5 peers, CLI
  scripts/               deployment, session, diagnostic and evidence scripts
tests/
  src/test/java/poc/tests/  DvPScenariosTest (T1–T9), Fabric (Gateway connection helper)
evidence/                 produced by capture-evidence.ps1 (not committed until generated)
thesis-materials/         coding workbook, requirement sheets, realisation matrix,
                          interface contracts and the editable architecture diagrams
```

`network/crypto/` and `network/artifacts/` are generated and deliberately untracked: identities
and the genesis block are recreated by step 1 on any machine.

## 7. Thesis companion materials

`thesis-materials/` holds the derivation behind the manuscript, listed in Annex A of the thesis:

| File | What it is |
|---|---|
| `01_PFMI_Coding_Workbook.xlsx` | Retention of the twenty-four PFMI principles, per-source coding matrix, source register, harmonisation and re-coding log |
| `02_Requirement_Sheets_R01-R16.docx` | One sheet per requirement, including what would have to be observed for an arrangement to fail it |
| `03_Realisation_Matrix_R01R16_x_B1B2B3.xlsx` | All forty-eight cells with mechanism, interface trace, evidence locator, assumption and residual risk; plus the strict-reading sensitivity and a locator register |
| `04_Interface_Contracts.docx` | Semantic contracts for every I, T, O, H, C and S flow of the three specifications |
| `05_wCBDC_DvP_reference_architecture.drawio` | Editable source of Figures 4.1 to 4.5 |

`thesis-materials/NOTES_open_items.md` records what is still open on that material, and what is
deliberately left as it is. Read it before the matrix.

## 8. Limits of this artefact

The run covers one bounded configuration on a local test network. It shows that the design can be
built and made to run under the assumptions implemented — not how it would behave in production,
at volume, or under stress. No third party has re-executed it; this repository makes that
possible but does not substitute for it.

## 9. Licence

MIT. See `LICENSE`.
