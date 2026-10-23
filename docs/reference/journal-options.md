# Publication routes

Checked 2026-10-21. Venue remains undecided. This is a fit/workload assessment,
not an acceptance-probability estimate. The 2026-11-20 preparation/decision target
depends on evidence and rights review; it is not a peer-review promise.

| Route | Fit and remaining work | Cost boundary |
|---|---|---|
| **SoftwareX: Original Software Publication** | First candidate for reusable research software, architecture and demonstrated use. Prepare a release and reproducible examples. Current template/length limits need rechecking: the official guide was inaccessible in this audit. | Fully OA; **Hybrid-only** support does not cover it. Obtain a funding decision. |
| **Bioinformatics Advances: Application Note** | Specialist readership; demonstrate usefulness, quality and accessible examples. Current limit: 4 pages, 3 figures/tables combined. | Fully OA, OUP; an Elsevier/Wiley agreement does not establish coverage. |
| **Software: Practice and Experience: Research Article** | Conditional engineering route for original implementation/runtime/reuse work. Needs generalizable practical results and comparison; validation-only work is outside scope. | Confirm current publication options, institutional agreement, article type, corresponding-author eligibility and quota. |
| **JOSS** | Deferred pending documented research use and more than six months of active public development. Audit public history before choosing a date. | No submission/publication fees. |
| **bioRxiv research preprint** | Dissemination after screening; prepare research results or tool outputs, not a software announcement alone. Check the filing sequence first. | No submission fee; screening is not journal peer review. |

Sources: [SoftwareX guide](https://www.sciencedirect.com/journal/softwarex/publish/guide-for-authors)
(not fetched), [Elsevier Research Elements](https://www.elsevier.com/researcher/author/tools-and-resources/research-elements-journals),
[Bioinformatics Advances](https://academic.oup.com/bioinformaticsadvances/pages/author-guidelines),
[SPE scope](https://onlinelibrary.wiley.com/page/journal/1097024x/homepage/productinformation.html),
[JOSS](https://joss.readthedocs.io/en/latest/submitting.html),
[bioRxiv screening](https://connect.biorxiv.org/news/2022/06/13/screening_procedures)
and [introduction](https://www.biorxiv.org/about-biorxiv) (bioRxiv checked 2026-10-20).
Other candidates, including CMPB, need a separate current scope/cost check.
Submission does not reserve agreement funding; confirm eligibility and quota
when the accepted article reaches its publishing agreement.

## Evidence before venue selection

Bio Research already covers substantial AI-assisted nf-core work. Generic
AI+Nextflow, pinning and resume are not a differentiation claim. See the
[feature inventory, dated sources and comparison boundary](bio-research.md);
the matched comparative evaluation has **not been performed**.

| Comparison requirement | Reporting rule |
|---|---|
| Baselines | Bioinfo-agent, Bio Research and direct nf-core; use the same model/configuration for the two agents |
| Matched conditions | Same task/data, pipeline release, containers, host/resources, reference/index and cache state; separate cold and warm cache runs |
| Version compatibility | Start with shared ATAC-seq 2.1.2. rnaseq/sarek pins differ: validate and label any common-pin adaptation separately from as-shipped compatibility; expected pin refusal is not failure |
| Reliability | Predefine success, failure injection, retries, human intervention and budget; report all attempted tasks, recovery correctness, retained/reused work, time and resource use |
| Breadth | Report supported pipelines separately. An out-of-scope Bio Research task is N/A, not a reliability failure |
| Candidate contribution | Test the existing re-entry, read-only triage, retention and full-sheet stub safeguards; implementation alone does not prove benefit |

Prioritize 2–3 reproducible public cases and bounded recovery comparisons over
more pipelines. If matched results show no material benefit, narrow the work to
an extension or upstream contribution; do not manufacture a superiority claim.
[Related systems](related-work.md) provide context, not novelty or acceptance
evidence. A plugin listing is distribution, not peer review.

Authorship, rights, AI-use policy and publication order: [submission and filing](submission-filing.md).
