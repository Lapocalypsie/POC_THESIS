# Open items on the companion material

Points that are known, deliberate, or still to close. Kept in the repository rather than in a
private note, because a reader who finds one of these unaided will assume it was hidden.

---

## 1. To close before final submission

### 1.1 Confirm the IOSCO FR/17/25 page numbers
The locators for source **[21]** in sheet 4 of the realisation matrix were obtained in a pass that
returned inconsistent pagination for this report (chapter 4 appeared to sit on lower page numbers
than chapter 3). Every `[21]` locator must be re-checked against the PDF before submission. The
substance of what is cited is not in doubt; the page numbers are.

### 1.2 Source [25] — closed, 4 September 2026
An earlier state of the coding workbook mapped thesis reference **[25]** to Loyens, C. (2025),
*Project Agorá: Selecting a Technology*, a Capco industry whitepaper rated Low proximity, while the
thesis bibliography and Table 4.1 cite the BIS report: *Project Agorá: a shared programmable
platform for wholesale cross-border payments*, BIS othp110, 27 May 2026, Institutional, Medium
proximity. Two different documents under one number. The citation was sound; the workbook entry was
what was wrong.

It has been repaired the recommended way. The BIS report is now coded in place of the whitepaper,
from the report itself and with page-level locators, keeping the Institutional / Medium rating
already recorded in Table 4.1. Nine codes changed and the proximity moved from L to M, which aligns
the workbook with the thesis. The substitution is recorded in the coding matrix (sheet 3, note on
the source row) and in the re-coding log (sheet 8); the two whitepaper rows kept in that log are
labelled as residue of a source no longer in the corpus, for the audit trail only. The bibliography
entry now reads BIS (2026) with the IIF named as convening partner rather than co-author.

No requirement and no result changed: [25] carries no core requirement on its own.

### 1.3 Son & Jang [9] locators — closed, 5 September 2026
ScienceDirect blocked automated access, so [9] was located by abstract and by section name rather
than by internal section number, in both the coding workbook and sheet 4 of the realisation matrix.

The full text was obtained on 5 September 2026 and both files now carry section- and page-level
locators taken from the article itself: Sec. 2.2, pp. 3-4 (HTLC construction credited to Poon and
Dryja, four-step protocol, failure by late signature and the structural asymmetry); Sec. 2.3, p. 5
(Herlihy's atomic-swap protocol and its omission of economic incentives); Secs. 3.1-3.4, pp. 5-10
(model primitive, timelock preference, seller's signing preference, premium model); Sec. 4.1,
pp. 12-14 (KRX bond calibration). These are the locators reported in Table 5.6 of the manuscript.

Reading the full text also changed four codes in the workbook, all recorded in the re-coding log:
[9] × P4 and [9] × T10 from E to I, [9] × P13 from N to I, and R09 removed from the requirements the
source can support, since the paper carries no liquidity analysis of its own.

### 1.4 Project Jura, page 14
The Jura report states that final settlement occurred in the RTGS systems (TARGET2 and SIC) and the
DAR, rather than on the SDX platform itself. Jura is cited in the manuscript as corroboration for
the integrated on-ledger variant B2. Read that passage before relying on it.

If it turns out to weaken the claim, the fallback is available and costs little: cite Jura for the
geometry of control — dual-notary signing, subnetworks, each central bank retaining authority over
its own currency (pp. 13, 25–26) — and let Helvetia II and III carry the corroboration of
atomicity on their own.

---

## 2. Known limits, deliberately left as they are

### 2.1 No pilot designates a ledger as the authoritative securities record
Cells R01 × B2 and R06 × B2 assert that the ledger is the authoritative record. Project Helvetia II
does not support this: its legal assessment (§4, pp. 28–29) covers wholesale CBDC governance, not
the securities record. The support for these two cells is IOSCO's forward-looking statement that
CSDs "could evolve to be a governor of DLT-based settlement systems" — a regulatory projection,
not a deployment.

Both cells are marked accordingly in the matrix. This is a real asymmetry in the evidence and it is
reported rather than smoothed over.

### 2.2 One coder
Stated in §3.4.4, Table 3.7, §5.6 and §6.5 of the thesis. The mitigations reduce the subjectivity;
they do not remove it. An expert evaluation of the requirement set and of the six-layer
decomposition is named in §6.7 as the main validation step still outstanding.

### 2.3 The six-layer decomposition has no external validation
It is validated by its function rather than by a panel: the decomposition is complete and disjoint
over R01–R16, every requirement has exactly one primary layer, and the grouping was fixed before
any variant was specified — so no architecture could shape the framework meant to test it. That is
an argument, not an independent assessment, and it is offered as such.

### 2.4 The diagrams are dense
The manuscript reproduces the architecture diagrams at page width, where the densest of them are
hard to read. The editable source in this folder is the readable version: any zoom, any export
scale. This is a limitation of the printed figure, not of the artefact.

---

## 3. Notes on the evidence pack

**Closed, 4 September 2026.** Annex A of the thesis lists before-and-after balances for **S1, T8
and T9**. All three are now in `evidence/`. T8 and T9 were captured by `capture-probes.ps1` against
the trade settled on 3 September, without re-running the scenario, so Table 5.5, Figures 5.1 and
5.2 and the run reported in §5.4 are unchanged. Both probes returned PASS: the call refused, and
all four balances unchanged.

The paragraph below records how that was arrived at.

Annex A of the thesis lists before-and-after balances for **S1, T8 and T9**.

`capture-evidence.ps1` now produces all three: step 5 of 6 runs the two adversarial probes against
the trade settled in step 4, records the balances on either side of each attempt, and writes
`03_balances_T8.*` and `03_balances_T9.*`. Each probe asserts two things and fails the run if
either does not hold: the call was refused, and no balance moved.

The files appear the next time the capture is run. Because a run settles a fresh trade with a new
identifier, and balances carry over from the previous run, the S1 figures will differ from those
currently in Table 5.5 — so the capture should be run from a cold network (`run-poc.ps1`, which
rebuilds and captures in one pass) and Table 5.5, Figure 5.1, Figure 5.2 and the run date in §5.4
updated together from that single coherent run.
