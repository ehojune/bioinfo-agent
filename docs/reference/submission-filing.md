# Submission and filing preparation

Checked 2026-10-20; target 2026-11-20. This is a preparation checklist, not a
submitted manuscript, patent application or opinion on patentability.

## Journal

Venue is undecided. Compare [journal and preprint routes](journal-options.md)
before selecting a template; publication charges depend on the exact journal,
article type, corresponding author's eligibility and available agreement quota.

The official [Bioinformatics Advances author guidelines](https://academic.oup.com/bioinformaticsadvances/pages/author-guidelines)
allow Application Notes of up to 4 pages, abstract ≤200 words, ≤5 keywords,
≤15 references and **3 figures or tables combined**. Software usefulness, quality,
ease of use and tutorials matter. Suggested allocation: architecture figure,
scope/validation table, guardrail table; resource details in supplement.

The guidelines permit AI-assisted code/documentation but reject papers drafted
from prompts; researchers must write the manuscript and disclose AI use. Treat
these repository tables as auditable source material for author verification,
not a manuscript ready to submit. Preprints are permitted; bioRxiv has a transfer
route to the journal. Confirm policies again at submission.

Required private decisions: authors/affiliations/CRediT, corresponding author,
funding/conflicts, public-data accessions, software commit/release, archival DOI
if deposited, and availability statement. `CITATION.cff` cites software only;
no DOI or release date is invented.

Authorship follows actual contributions and responsibility, not access to an APC
agreement. A solo preprint is an alternative dissemination route; it does not
establish journal acceptance or change employer/inventorship obligations.

## Korean filing

[Patent Act Article 30](https://www.law.go.kr/lsLinkCommonInfo.do?lsJoLnkSeq=1029338489)
provides a conditional 12-month disclosure exception. The
[KIPO disclosure-exception guide](https://www.kipo.go.kr/club/file.do?attachmentId=10367)
describes disclosure evidence and filing formalities, including the ordinary
30-day evidence submission route. Applicability, current procedural exceptions
and dates require a Korean patent professional's review; do not infer a deadline
from a Git author timestamp.

[KIPO computer-related invention guidance](https://www.kipo.go.kr/club/file.do?attachmentId=12498)
addresses concrete software/hardware cooperation. Describing containers and OS
interfaces does not by itself establish novelty or inventive step.

| Preparation item | Current source / missing evidence |
|---|---|
| Technical problem and embodiments | [Four control mechanisms](control-spec.md), file/function links and failure transitions |
| Method/system mapping | Header inspection → compatibility/re-entry decision; command interception → retention decision; storage/triage; configured resource/QC boundaries |
| Measured technical effects | [Tables 2–3](evidence-tables.md); distinguish recorded effects from counterfactual estimates |
| Earliest public disclosure | Git history contains control work from July–October 2026; actual first public accessibility remains **UNVERIFIED** |
| Disclosure packet | Preserve original repository/PR URLs, public timestamps, release/download records, screenshots and hashes; maintain each disclosed feature's mapping privately |
| Ownership and inventorship | Human inventors, employer agreements and contributions need confirmation; agent authorship footer is not inventorship evidence |
| Prior art / claims | Search existing patents and workflow systems; have counsel review method and system claims against actual code and limits |

Public development is already underway. Removing a public commit cannot undo its
disclosure. Keep new filing-only detail private until the filing/publication
sequence has been reviewed. No application has been filed by this work.
