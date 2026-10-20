# rnasplice

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** [Exact stub conditions](stubs/rnasplice.md) — read before Step 4; match every predicate.
- **Evidence lookup:** [procurement record](evidence/rnasplice.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** alternative splicing analysis from RNA-seq — event-level and isoform-level percent-spliced-in
(PSI) quantification and differential splicing, via SUPPA2, rMATS, DEXSeq (differential exon usage
and differential transcript usage), and edgeR (differential exon usage). **First splicing-specific
pipeline stocked here.**

**Not for gene/transcript expression quantification** — that is `nf-core/rnaseq` (`references/pipelines/rnaseq.md`), already
stocked. **The two are not redundant and do not automatically chain.** `rnaseq` produces gene/
transcript counts and TPM (STAR+Salmon or pseudo-alignment) and, chained into
`differentialabundance` (`references/pipelines/differentialabundance.md`), a differential-*expression* result: which genes/transcripts go up
or down. `rnasplice` answers a different question entirely: for a given gene, does the *relative
mixture of its isoforms/exons* change between conditions — a PSI shift can happen with zero change
in a gene's total expression, and a large expression change can happen with zero PSI shift. A user
asking "which genes are differentially expressed" wants `rnaseq`→`differentialabundance`; a user
asking "which genes/exons are alternatively spliced" or "does this treatment change isoform usage"
wants `rnasplice`. **`rnasplice` runs its own alignment/quantification from FASTQ — it does not
consume `rnaseq`'s outputs.** `--source` accepts `fastq` (own STAR+Salmon or Salmon-only quant,
this procurement's scope), `genome_bam`, `transcriptome_bam`, or `salmon_results` (pre-computed
inputs from elsewhere), but there is no direct hand-off path from a completed `nf-core/rnaseq` run
— feeding `rnaseq`'s STAR BAMs in via `--source genome_bam` or its Salmon output via `--source
salmon_results` is possible in principle (matching input shape) but was **not verified this
procurement** and would need its own check before trusting it (transcript-fasta/index provenance
matters here — see the bounded-choice note in `runs/20260814-rnasplice-scer-gln3-ibutanol/plan.md`
about NOT reusing `rnaseq`'s Salmon index for exactly this reason).

**Schema-drift note #1 — `assets/schema_input.json` is unused, same class of finding as
nanoseq (`references/pipelines/nanoseq.md`).** At this pin (1.0.4) that file describes `sample`/`fastq_1`/`fastq_2`/
`strandedness`/`condition` but for the `fastq` source (the only source this procurement stocks)
is **never referenced by any `.nf` file** — grepped `workflows/`, `subworkflows/`, `modules/` for
`schema_input|validateParameters|nf-validation|nf-schema`, nothing wired to it. The samplesheet
actually enforced is the pipeline's own bundled `bin/check_samplesheet_fastq.py` (via the local
`SAMPLESHEET_CHECK` module). See `samplesheets.md` for the full column table, and note there that
one of that script's own stated rules (`check_condition_replicates()`, meant to require ≥2 rows
per `condition`) is confirmed dead code at this pin.

**Schema-drift note #2 — `--help`'s stated defaults do not match the pipeline's actual runtime
defaults.** `--help` (schema-derived) shows `aligner` defaulting to `star` and
`rmats`/`dexseq_exon`/`edger_exon`/`dexseq_dtu`/`sashimi_plot` all defaulting to `false`. The
pipeline's own `nextflow.config` — the file Nextflow actually loads, and which wins — sets
`aligner = 'star_salmon'` and **all five of those `true`**. Confirmed by reading `nextflow.config`
directly and by `-preview`'s "differs from pipeline defaults" summary. **The unscoped default run
is the full kitchen-sink toolset**, not the light one `--help` alone suggests — do not plan a run
from `--help` output alone for this pipeline.

**Minimum input (fastq source):** `sample`,`fastq_1`,`fastq_2` (header required even for
single-end; value may be empty),`strandedness` (`unstranded`/`forward`/`reverse` — **not** `auto`,
which this pipeline's own samplesheet checker rejects, unlike rnaseq),`condition` (a free-form
group label). Uniqueness key is the `(sample, fastq_1)` pair, not `sample` alone. A separate
`--contrasts` CSV (`contrast`,`treatment`,`control`) selects which condition pairs get a
differential-splicing comparison.

**Reference-store paths:** `--fasta`/`--gtf`, standard manifest paths (this procurement used
`genomes/R64-1-1/fasta/genome.fa` + `genomes/R64-1-1/gtf/genes.gtf.gz`, already stocked for
`rnaseq`). `--transcript_fasta`/`--star_index`/`--salmon_index` are all optional — the pipeline
builds them itself (`GTF_GENE_FILTER` → `RSEM_PREPAREREFERENCE` → `SALMON_INDEX`/
`STAR_GENOMEGENERATE`) if omitted. **Do not point `--salmon_index`/`--star_index` at another
pipeline's index of the same genome build** (e.g. `rnaseq`'s) without verifying the transcript-
fasta extraction and decoy handling match — rnasplice's own `RSEM_PREPAREREFERENCE`-based
extraction is a different code path than `rnaseq`'s, unverified for interchangeability; at small
genome scale (yeast, ~12 Mb) building rnasplice's own index costs well under a minute, so there is
no real reason to risk the substitution.

**Known gaps / stub-run behaviour.** `-stub-run` has one waived departure (7th documented, same
class as ampliseq/mag/nanoseq): `modules/nf-core/gunzip/main.nf`'s `stub:` block `touch`es an
empty placeholder for whichever of `--fasta`/`--gtf` is gzipped, and the downstream
`modules/local/gtf_gene_filter.nf` + `modules/nf-core/rsem/preparereference/main.nf` have **no**
`stub:` block at all, so they run for real against that empty stub input and legitimately fail
("The reference contains no transcripts!" or SUPPA's "No exons found", depending on which input
was gzipped) — confirmed by reading both modules and inspecting the stub work-dir's actual empty
files directly. The identical real (non-stub) command completes cleanly.

**Real, non-stub bug — found on the first real (non-CI-fixture) run, and load-bearing for scope.**
With `suppa_per_local_event` at its true default, `SUPPA_SALMON:GENERATE_EVENTS_IOE` **hangs
indefinitely** (measured: 53 real minutes at 99% CPU, never returning) whenever SUPPA finds zero
local splicing events of some type (SE/SS/MX/RI/AF/AL) in the genome/annotation — real on any
low-alternative-splicing organism, not a fluke. Root cause:
`modules/local/suppa_generateevents.nf`'s per-event-type `.ioe` concatenation —
`awk 'FNR==1 && NR!=1 { while (/^seqname/) getline; } 1 {print}' *.ioe` — spins forever once a
file's only line is the header being matched, because `getline` at EOF returns 0 without changing
`$0`, so the `while` condition never goes false. Reproduced standalone (outside the pipeline,
5-second `timeout`) on two synthetic header-only `.ioe` files. **Fix: `--suppa_per_local_event
false`** — structurally skips `GENERATE_EVENTS_IOE` (`subworkflows/local/suppa.nf`'s
`if (suppa_per_local_event)` gate, confirmed by reading it), leaving the per-isoform SUPPA branch
(`GENERATE_EVENTS_IOI`/`DIFFSPLICE_IOI`, transcript-level PSI/dPSI) unaffected. **This is now part
of the stocked default, not an optional flag** — see below.

**Key outputs (this procurement's scope):** `salmon/<sample>/quant.sf` (Salmon quantification),
`salmon/suppa/psi_per_isoform/suppa_isoform.psi` (per-sample transcript-level PSI),
`salmon/suppa/diffsplice/per_isoform/<contrast>_transcript_diffsplice.dpsi` (dPSI + p-value per
transcript/isoform between the two contrast conditions), `multiqc/`.

**QC verdict checklist (measured, no biological interpretation):** Salmon `percent_mapped` per
sample (this run: 92.5–95.8%, all 8 samples); TrimGalore pass rate / read counts vs
`--min_trimmed_reads` (default 10,000); FastQC per-sample flags; row count and nominal-p<0.05
fraction in the `*_diffsplice.dpsi` table (raw counts only — no multiple-testing-correction claim
unless the pipeline's own downstream `stageR` step is enabled, which this procurement's scope does
not exercise); MultiQC's aggregated view.

**Scope of this procurement — lightest combination that still exercises splicing detection, not
the kitchen-sink default.** `--skip_alignment true` (skips STAR entirely — SUPPA runs off plain
Salmon pseudo-alignment, not the STAR+Salmon combined path; structurally also gates off
`rmats`/`dexseq_exon`/`edger_exon`/`dexseq_dtu`/`sashimi_plot` since every one of those
subworkflows in `workflows/rnasplice.nf` is nested inside `if (!params.skip_alignment ...)`),
`--rmats/--dexseq_exon/--edger_exon/--dexseq_dtu/--sashimi_plot` all `false` explicitly
(redundant with the structural gate above, kept explicit so the config is self-documenting),
`--pseudo_aligner salmon` + `--suppa true` kept at default (SUPPA2 event/isoform generation,
PSI, differential splicing — the core this procurement exercises),
`--clusterevents_local_event/--clusterevents_isoform` both `false` (SUPPA's DBSCAN clustering of
significant events; disabled after a real reproducible CI-fixture failure when 0 events survive
significance — see `estimates.md`), and **`--suppa_per_local_event false`** (added mid-procurement
after the real hang above — per-isoform splicing detection only, not per-local-event). rMATS/
DEXSeq DEU/edgeR DEU/DEXSeq DTU/Miso sashimi are all out of scope: redundant or STAR-dependent
detection/visualization methods beyond SUPPA2's own core coverage, same "lightest combination
first" pattern as taxprofiler's kraken2-only and raredisease's `--skip_subworkflows` stocking.

**First real-sample run** (`runs/20260814-rnasplice-scer-gln3-ibutanol/`): 8 samples (4
conditions × 2 replicates), *S. cerevisiae* R64-1-1, real paired-end FASTQ reused from a prior
`rnaseq` procurement run (PRJEB33652, isobutanol response in WT/`gln3Δ`, no new download), 1
contrast (`WT_ibuoh` vs `WT_ctrl`). Salmon mapping rate 92.5–95.8% across all 8 samples.
Per-isoform `dPSI`/p-value table: 6,685 rows, 4,808 with nominal p<0.05 (uncorrected — no claim
about how many are real). See `estimates.md` for the full timing row, including the real
`GENERATE_EVENTS_IOE` hang found on this run.
