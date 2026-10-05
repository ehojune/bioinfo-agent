# Reference index

Lookup-only evidence and detailed procedures. Start with the [main README](../../README.md).

| Topic | Source and boundary |
|---|---|
| Inventory and pins | [pipelines.tsv](../../config/pipelines.tsv): 19 nf-core rows plus one in-repository pipeline, checked 2026-10-06 |
| Prepared workflow scopes | [Pipeline selection](../../skills/bioinfo-analyze/references/pipeline-selection.md), [samplesheets](../../skills/bioinfo-analyze/references/samplesheets.md) and [estimates](../../skills/bioinfo-analyze/references/estimates.md) |
| Install, host resources and TLS | [Setup procedure](../agent-setup.md), [other hosts](../other-hosts.md) |
| Plugin cache and version gate | [Gate rationale](../../scripts/check-plugin-version.sh), [PR #26](https://github.com/ehojune/bioinfo-agent/pull/26) |
| tmux and read-only triage | [Runbook](../../skills/bioinfo-analyze/references/runbook.md); inspect status independently of task attempts |
| PacBio germline, CLR and somatic | [Pipeline README](../../pipelines/pacbio-hifi-wgs/README.md); CLR small variants are exploratory |
| Whole-genome GIAB benchmark | [Record](../examples/20260926-pacbio-hifi-wgs-giab-wholegenome/handoff.md): germline at `48ec463`, somatic at `f2de95e`; not a same-data rerun of current 0.2.0 |
| Other real runs and upstream caveats | [Examples](../examples/README.md), [runbook](../../skills/bioinfo-analyze/references/runbook.md) |

A completed workflow establishes execution. QC and truth-set comparison establish different evidence.
The GIAB record limits small-variant accuracy to HG001–HG007, SV to HG002, and somatic to the tested HG008 pairs.
