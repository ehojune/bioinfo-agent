# Pipeline selection

Read this routing page at Step 2, then **only the selected pipeline card**.
`config/pipelines.tsv` is the source of truth for the stocked set and revision.
Confirm molecule/assay, requested deliverable, data location, and existing intermediates first.
If the question or assay is unclear, ask before choosing.

| Data / requested endpoint | Pipeline card | Scope boundary |
|---|---|---|
| Bulk RNA / counts | [rnaseq](pipelines/rnaseq.md) | Expression contrasts → differentialabundance; 3'-tag needs separate counting decision. |
| Counts / group contrasts | [differentialabundance](pipelines/differentialabundance.md) | Count input, replication and approved contrasts required; never TPM. |
| Public SRA/ENA/GEO reads | [fetchngs](pipelines/fetchngs.md) | Retrieval and samplesheet; stub modules may download real data. |
| Short-read WGS/WES variants | [sarek](pipelines/sarek.md) | Germline/somatic and BAM re-entry are distinct approved routes. |
| WGBS/RRBS/EM-seq | [methylseq](pipelines/methylseq.md) | RRBS requires its own mode; aligner choice affects estimates. |
| ATAC-seq peaks | [atacseq](pipelines/atacseq.md) | Differential analysis is a separate approved run. |
| ChIP-seq peaks | [chipseq](pipelines/chipseq.md) | Control and mark type required; not CUT&RUN. |
| CUT&RUN/CUT&Tag peaks | [cutandrun](pipelines/cutandrun.md) | Spike-in/CPM choice changes both normalization and QC. |
| Single-cell/nucleus RNA | [scrnaseq](pipelines/scrnaseq.md) | Nuclei need intron counting; downstream cell interpretation is separate. |
| 16S/ITS amplicons | [ampliseq](pipelines/ampliseq.md) | ASVs and diversity, not shotgun metagenomes. |
| Metagenome assembly/binning | [mag](pipelines/mag.md) | Taxonomy-only request → taxprofiler. |
| Metagenome taxonomy only | [taxprofiler](pipelines/taxprofiler.md) | No assembly/binning; database and profiler are explicit. |
| Rare-disease variant workflow | [raredisease](pipelines/raredisease.md) | Read exact stocked branch and prerequisites; no clinical interpretation. |
| ONT RNA/DNA long reads | [nanoseq](pipelines/nanoseq.md) | Read exact stocked assay branch; not a universal PacBio route. |
| RNA splicing/isoform usage | [rnasplice](pipelines/rnasplice.md) | PSI/splicing endpoint differs from gene expression. |
| PacBio Iso-Seq annotation | [isoseq](pipelines/isoseq.md) | Raw subreads and FLNC entry points differ; minimap2 stocked, ultra waiver conditional. |
| Bacterial assembly | [bacass](pipelines/bacass.md) | Read type and stocked assembly branch determine scope. |
| Viral Illumina amplicons | [viralrecon](pipelines/viralrecon.md) | Stocked mapping branch; consensus execution can pass while QC fails. |
| 10x Xenium spatial QC | [spatialaxe](pipelines/spatialaxe.md) | Coordinate-mode stocked; image segmentation is outside the validated scope. |
| PacBio HiFi WGS | [pacbio-hifi-wgs](pipelines/pacbio-hifi-wgs.md) | In-repo DSL2; germline and aligned tumour/normal somatic entry points differ. |

## Before writing a command

- Read [host-runtime.md](host-runtime.md); inspect current files and resource limits.
- Read the chosen card and its **exact stub gate**, when linked. No waiver may be inferred from another pipeline.
- Re-derive the pinned revision's live samplesheet schema and parameter names before first use
  on this host. Cached examples are hypotheses. Step 3 approval precedes commands that
  download or execute anything; read a cached schema during intake.
- Use `-r <revision>` for nf-core. The in-repo pipeline uses an absolute
  `$BIOINFO_HOME/pipelines/pacbio-hifi-wgs` target and the repository commit, not `-r`.
- Declare every aligner, filter, subset, skipped QC step and re-entry point in the plan.
  Workflow completion and scientific QC are separate verdicts.

## Load only when needed

| Need | Read |
|---|---|
| Several runs / output-to-input mapping | [workflow-chains.md](workflow-chains.md) |
| STR or tandem repeats | [repeat-expansion.md](repeat-expansion.md) |
| Ambiguous assay / unsupported endpoint | [selection-boundaries.md](selection-boundaries.md) |
| New pipeline procurement | [new-pipeline.md](new-pipeline.md) |
| Reference availability now | [reference-store.md](reference-store.md), manifest dry-run |
| Historical procurement findings | Selected card's `evidence/` link; never preload all records |

## Legacy section map

Older run records cite `pipeline-selection.md` §4.n. The mapping below preserves those citations;
the numbered content now lives in the linked card. §§5–10 moved to the topic links above
(§9: [reference-store history](pipelines/evidence/reference-store-history.md)).

- §4.1 → [rnaseq](pipelines/rnaseq.md)
- §4.2 → [differentialabundance](pipelines/differentialabundance.md)
- §4.3 → [fetchngs](pipelines/fetchngs.md)
- §4.4 → [sarek](pipelines/sarek.md)
- §4.5 → [methylseq](pipelines/methylseq.md)
- §4.6 → [atacseq](pipelines/atacseq.md)
- §4.7 → [chipseq](pipelines/chipseq.md)
- §4.8 → [cutandrun](pipelines/cutandrun.md)
- §4.9 → [scrnaseq](pipelines/scrnaseq.md)
- §4.10 → [ampliseq](pipelines/ampliseq.md)
- §4.11 → [mag](pipelines/mag.md)
- §4.12 → [taxprofiler](pipelines/taxprofiler.md)
- §4.13 → [raredisease](pipelines/raredisease.md)
- §4.14 → [nanoseq](pipelines/nanoseq.md)
- §4.15 → [rnasplice](pipelines/rnasplice.md)
- §4.16 → [isoseq](pipelines/isoseq.md)
- §4.17 → [bacass](pipelines/bacass.md)
- §4.18 → [viralrecon](pipelines/viralrecon.md)
- §4.19 → [spatialaxe](pipelines/spatialaxe.md)
- §4.20 → [pacbio-hifi-wgs](pipelines/pacbio-hifi-wgs.md)
