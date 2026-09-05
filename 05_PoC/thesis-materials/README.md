# Thesis companion materials

Supporting material for *A Reference Framework for DvP Settlement Architectures in Central Bank
Money: On the underdetermination of architecture by normative requirements*
(Jimmy Rasolosoa, M2 MIAGE IKSEM, University Paris 1 Panthéon-Sorbonne, 2025–2026).

The manuscript reports condensed evidence so that the argument stays readable. These files carry
the derivation behind it. Annex A of the thesis lists them as required companion material; this
folder is that list, made openable.

---

## What is here

| # | File | What it contains | Referenced from |
|---|---|---|---|
| 01 | `01_PFMI_Coding_Workbook.xlsx` | Retention decisions for all twenty-four PFMI principles against the four criteria; per-source E/I/N coding matrix with evidence locations; source register with proximity ratings; inductive codebook; harmonisation pass; second-pass re-coding log | §3.4, §4.1, Tables 4.1 and 4.2 |
| 02 | `02_Requirement_Sheets_R01-R16.docx` | One sheet per requirement: full statement, PFMI anchor with page numbers, inductive theme, responsible component, the design parameter it leaves open, sources with locators, and what would have to be observed for an arrangement to fail it | §4.2, Table 4.3 |
| 03 | `03_Realisation_Matrix_R01R16_x_B1B2B3.xlsx` | All forty-eight cells. Each carries a named mechanism, an interface trace, evidence with a locator, the assumption it depends on and its residual risk. Separate sheets hold the strict-reading sensitivity, a register of every source locator, and a changelog | §4.6, Table 4.10; §5.5, hypothesis H1 |
| 04 | `04_Interface_Contracts.docx` | Semantic contracts for every flow of the three specifications — I, T, O, H, C and S — with actors, trigger, preconditions, effect, post-condition, failure handling and the requirements each discharges | §4.5 |
| 05 | `05_wCBDC_DvP_reference_architecture.drawio` | Editable source of the six architecture diagrams: generic architecture, six-layer framework, a reading aid, and one page per variant | Figures 4.1 to 4.5 |

The proof of concept itself, its ten-test suite and its execution evidence are in the parent
repository. See `../README.md` and `../evidence/`.

---

## How to read the realisation matrix

The matrix is the instrument of hypothesis H1: several structurally distinct architectures satisfy
every core requirement. It is not a summary of the manuscript — it is what the manuscript's Table
4.10 condenses.

**A cell counts as filled only when it names a concrete mechanism.** A descriptive similarity, or
the name of a project, does not fill a cell. Each cell separates four things that are easy to
conflate: what the mechanism is, what must be assumed for it to work, what remains exposed once it
is in place, and what evidence supports the claim.

**Only the eight Core rows bear on admissibility** — R01 to R07 and R14. The other eight are filled
because they describe the dimensions along which admissible architectures legitimately differ, and
those differences are the subject of Chapter 6, not of the H1 test.

**Three cells are contested.** R01 × B3, R05 × B3 and R14 × B3 are admissible under the primary
outcome-level reading of the requirement set and fail under a stricter one. Sheet 3 reconstructs
the matrix under that stricter reading. The conclusion does not depend on which reading is taken:
B1 and B2 alone are admissible and structurally non-equivalent, which is enough to reject the
determination hypothesis either way.

---

## What these files do not establish

**They are not an independent assessment.** One coder derived the requirement set and filled the
cells. The coding rules were fixed before the final pass, each requirement is linked to an evidence
location, a delayed second pass re-coded the corpus with divergences resolved against the source
text, and the supervisor reviewed a sample of decisions. No inter-coder reliability statistic is
claimed, and no expert panel has assessed the requirement set or the six-layer decomposition. This
is stated in §3.4.4 and §5.6 of the thesis and named in §6.7 as the validation step still
outstanding.

**They are not a compliance assessment of any named arrangement.** Where a pilot report is cited,
the claim is that its documented coordination design displays a mechanism — never that the
arrangement was found compliant by its overseer, and never that it was designed against this
thesis's requirement set.

**Locators are to the published documents, not to this repository.** Page numbers are the printed
page numbers of the source. Sheet 4 of the realisation matrix gives the URL for every source cited,
so any locator can be checked directly.

See `NOTES_open_items.md` for the points still open on this material.

## Licence

MIT, as for the rest of the repository. See `../LICENSE`.
