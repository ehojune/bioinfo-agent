# Reference index

**Lookup only.** Start with the [README](../../README.md) for ordinary use.
Operators and reviewers can follow the sources below; AI execution rules have a separate entry.

| Topic | Source and boundary |
|---|---|
| Reviewer entry and evidence | [Five-minute check](../reviewer-guide.md), [Tables 1–3](evidence-tables.md): scope, failures, resources and verification limits |
| Architecture and controls | [Architecture](../agent-architecture.md), [state predicates](control-spec.md): responsibilities and enforcement limits |
| Inventory and pins | [pipelines.tsv](../../config/pipelines.tsv): 19 nf-core rows and one in-repository pipeline |
| Installation, host resources and TLS | [Setup](../agent-setup.md), [other hosts](../other-hosts.md) |
| Diagnostics, plugin cache and maintenance history | [Operations reference](maintenance.md) |
| Stub lifetime, patching and run metadata | [Helper contract](run-contract.md), [operational lessons](operational-lessons.md) |
| Public run records | [Examples](../examples/README.md), including the [GIAB whole-genome record](../examples/20260926-pacbio-hifi-wgs-giab-wholegenome/handoff.md) |
| PacBio, CLR and tumor–normal limits | [Pipeline README](../../pipelines/pacbio-hifi-wgs/README.md) |
| Agent rules loaded for a task | [Execution contract](../../skills/bioinfo-analyze/SKILL.md), [pipeline selection](../../skills/bioinfo-analyze/references/pipeline-selection.md), [runbook](../../skills/bioinfo-analyze/references/runbook.md) |
| Research and filing preparation | [Related work](related-work.md), [venue options](journal-options.md), [submission/filing checklist](submission-filing.md) |

Execution completion, QC and truth-set accuracy establish different evidence.
Historical runs retain their original revision and input scope.
