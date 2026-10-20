# Reference index

**Lookup only.** Start with the [README](../../README.md) for ordinary use.
Operators and reviewers can follow the sources below; AI execution rules have a separate entry.

| Topic | Source and boundary |
|---|---|
| Architecture and controls | [Architecture](../agent-architecture.md): responsibilities, inputs and state transitions |
| Inventory and pins | [pipelines.tsv](../../config/pipelines.tsv): 19 nf-core rows and one in-repository pipeline |
| Installation, host resources and TLS | [Setup](../agent-setup.md), [other hosts](../other-hosts.md) |
| Diagnostics, plugin cache and maintenance history | [Operations reference](maintenance.md) |
| Public run records | [Examples](../examples/README.md), including the [GIAB whole-genome record](../examples/20260926-pacbio-hifi-wgs-giab-wholegenome/handoff.md) |
| PacBio, CLR and tumor–normal limits | [Pipeline README](../../pipelines/pacbio-hifi-wgs/README.md) |
| Agent rules loaded for a task | [Execution contract](../../skills/bioinfo-analyze/SKILL.md), [pipeline selection](../../skills/bioinfo-analyze/references/pipeline-selection.md), [runbook](../../skills/bioinfo-analyze/references/runbook.md) |

Execution completion, QC and truth-set accuracy establish different evidence.
Historical runs retain their original revision and input scope.
