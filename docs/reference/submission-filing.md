# Submission and filing preparation

Checked 2026-10-21. **2026-11-20 is an internal preparation/decision target**,
conditional on evidence and ownership review, not a filing deadline or a promise
of submission, acceptance or patentability. No application is filed by this work.

## Journal

Venue is undecided; see [publication routes](journal-options.md) for baselines
and evidence gates, and [Bio Research](bio-research.md) for feature provenance.

The official [Bioinformatics Advances author guidelines](https://academic.oup.com/bioinformaticsadvances/pages/author-guidelines)
allow Application Notes of up to 4 pages and **3 figures or tables combined**.
Usefulness, quality, ease of use and tutorials matter. A plugin listing alone
does not establish these or predict acceptance.

The guidelines permit AI-assisted code/documentation but reject papers drafted
from prompts; researchers must author the manuscript and disclose AI use.
Repository tables are source material for verification. Preprints are permitted;
confirm the selected venue's policies again before submission.

Required private decisions: authors/affiliations/CRediT, corresponding author,
funding/conflicts, accessions, release/commit, archival DOI if deposited and
availability statement. `CITATION.cff` cites software only; invent no DOI/date.

Authorship follows actual contributions and responsibility, not access to an APC
agreement. A preprint does not change employer or inventorship obligations.

## Korean filing

[Patent Act Article 29](https://law.go.kr/LSW/lsLinkCommonInfo.do?chrClsCd=010202&lsJoLnkSeq=1029986041)
sets novelty and inventive-step requirements against relevant prior disclosures.
[Article 30](https://www.law.go.kr/lsLinkCommonInfo.do?lsJoLnkSeq=1029338489)
provides a conditional 12-month disclosure exception. Counsel must determine
applicability, evidence/formalities, jurisdictions and actual dates; do not
calculate a deadline from a Git author timestamp or this target date.

The IP office's [AI examination guidance](https://www.moip.go.kr/ko/kpoContentView.do?aprchId=CNT0000364&menuCd=SCD0201244&ntatcSeq=5&pgmSeq=5)
distinguishes concrete technical means/effects from merely using known AI.
Its [2026 applicant guidance](https://www.moip.go.kr/ko/kpoBultnDetail.do?aprchId=BUT0000029&menuCd=SCD0200618&ntatcSeq=20927&sysCd=SCD02)
also requires substantive human inventive contribution and verified evidence.
These are review criteria, not a patentability finding for this project.
Bundling AI, containers, pinning, resume and guardrails does not by itself
establish novelty or inventive step.

| Preparation item | Current source / missing evidence |
|---|---|
| Technical problem / embodiments | [Control mechanisms](control-spec.md), actual code, failure transitions and limits; distinguish implementation from claimed benefit |
| Technical effects | [Recorded evidence](evidence-tables.md) plus the matched comparison in [publication routes](journal-options.md); no counterfactual estimate presented as a measured result |
| Prior-art candidates | Bio Research, direct nf-core, other workflow systems and patents; map each relevant feature to a dated public snapshot before counsel assesses claims |
| Disclosure chronology | [Source provenance](bio-research.md); plugin launch date does not date every current feature. The first public accessibility of this project's relevant features remains **UNVERIFIED** |
| Private evidence packet | Preserve URLs, public timestamps, commits/releases, screenshots and hashes; map feature → dated disclosure → possible claim element, including this project's own disclosures |
| Rights / filing decision | Confirm human inventors, employer agreements and ownership with counsel. Agent footers are not inventorship evidence; scientific comparison is not legal novelty analysis |

Deleting a commit does not undo a public disclosure. Keep new filing-only
details private until rights and publication sequence are resolved; revise the
2026-11-20 plan if those gates remain unmet.
