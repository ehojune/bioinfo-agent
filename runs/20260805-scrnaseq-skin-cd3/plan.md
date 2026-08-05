# Plan — 20260805-scrnaseq-skin-cd3

## Purpose
First real execution of nf-core/scrnaseq on this host, using the single-lane 10x Chromium
3' v3 dataset already downloaded and validated on 2026-08-04
(`/work/rawdata/20260804-scrnaseq-skin-cd3-prep/SOURCE.md`). This is a smoke test of the
pipeline mechanics on this box, not an experiment — one sample, no replicate/condition
comparison possible.

**Pipeline**: nf-core/scrnaseq -r 2.7.1 (pinned, `config/pipelines.tsv`)
**Data**: SRR21657609 (ENA/SRA), single 10x lane, R1=28bp (16bp CB + 12bp UMI, 10x v3),
  R2=91bp cDNA, 3,242,030 read pairs, ~150 MB gz total. Already on ext4
  (`/work/rawdata/20260804-scrnaseq-skin-cd3-prep/`), already MD5/read-count/pairing verified
  in SOURCE.md — not re-verified here, reused as-is per that record.
**Samplesheet**: `runs/20260805-scrnaseq-skin-cd3/samplesheet.csv` — one row, columns
  `sample,fastq_1,fastq_2` matching `assets/schema_input.json` at this pinned revision
  (re-derived this run, not assumed: required columns are exactly `sample`, `fastq_1`,
  `fastq_2`; `expected_cells`/`seq_center`/`sample_type`/`feature_type` are optional and
  omitted).
**Reference**: GRCh38 (UCSC hg38 chr-prefixed + GENCODE v50). **Compact `--genome GRCh38` form
  does NOT work for scrnaseq 2.7.1** — discovered via `-stub-run` (see "Discovered this run"
  below) and confirmed via `-preview`. Using the explicit `--fasta`/`--gtf` form instead,
  pointed at the same build-named alias paths (`genomes/GRCh38/{fasta,gtf}/GRCh38.*`) that the
  compact form would have resolved to anyway. `--igenomes_ignore` on the command line (not in a
  `-c` file), per `genomes.config`'s documented reason.

## Discovered this run — compact `--genome` form broken for scrnaseq 2.7.1
`-stub-run` with `--genome GRCh38 --igenomes_ignore` failed immediately (before any process
ran) with `Must provide a genome fasta file ('--fasta') and a gtf file ('--gtf') if no index is
given!` and the params summary showed `star_index=[]`, `genome_fasta=[]`, `gtf=[]` — i.e.
`getGenomeAttribute('fasta')`/`getGenomeAttribute('gtf')` (workflows/scrnaseq.nf:35-36)
returned nothing even though `config/genomes.config`'s `params.genomes.GRCh38.fasta`/`.gtf` are
set and this exact mechanism works for `nf-core/rnaseq -r 3.18.0` on this host (verified in the
step-1 re-run today). Switching to explicit `--fasta /refs/genomes/GRCh38/fasta/GRCh38.fa
--gtf /refs/genomes/GRCh38/gtf/GRCh38.gtf.gz` resolved correctly — confirmed both by a
`-stub-run` that got past parameter validation into real process execution (FASTQC, GUNZIP_GTF)
and by a full `-preview` (validates the entire DAG without executing anything) completing
cleanly. Root cause not fully isolated (candidates: scrnaseq 2.7.1 pins the older
`nf-validation@1.1.4` plugin rather than `nf-schema`, which rnaseq 3.18 uses — a
plugin-generation difference in how the `params.genomes` nested config block is exposed to
workflow code is the leading suspect, not confirmed). Not a bug in this run's samplesheet or
data — the identical alias paths work once passed explicitly. Recommendation for the manifest/
config: explicit `--fasta`/`--gtf` for scrnaseq until this is root-caused against a newer
scrnaseq revision or nf-validation version.

The `-stub-run` also hit a second, unrelated failure after the fasta/gtf fix: `GTF_GENE_FILTER`
(a `modules/local` process with no `stub:` block) ran for real against `GUNZIP_GTF`'s stubbed
(intentionally empty, `touch GRCh38.gtf`) placeholder output, and the pipeline's own
`filter_gtf_for_genes_in_genome.py` throws `UnboundLocalError` on a zero-line GTF input rather
than exiting cleanly. This is a known `-stub-run` limitation (partial stub-block coverage
across a pipeline's modules, not something this repo controls) confirmed by inspecting
`modules/local/gtf_gene_filter.nf` — no `stub:` block. `-preview` (full DAG resolution, no
process execution) was used instead to validate past this point; it completed with
`completed=0 failed=0 cached=0` and no errors, and the earlier partial stub-run already
demonstrated FASTQC and GUNZIP_GTF launching correctly with the real fastq/gtf paths, so the
param wiring is independently confirmed, not just DAG-shape.

## Bounded choices
- **Aligner: `--aligner star` (STARsolo), not the pipeline's own default (`alevin`).** Checked
  via `nextflow run nf-core/scrnaseq -r 2.7.1 --help`: `--aligner` defaults to `alevin`, not
  `star` — SOURCE.md's note that "star가 기본" is incorrect, corrected here. STAR is chosen
  deliberately anyway because: (a) the task's own framing anticipates a STAR index build as
  the dominant cost, (b) it matches the aligner family already validated for this host in the
  rnaseq runs, and (c) it produces the fuller STARsolo per-cell QC used in `qc-interpretation.md`.
  Undo: rerun with `--aligner alevin` (lighter — salmon-family, no STAR index, per
  `estimates.md` §1) if the STAR cost turns out not worth it.
- **`--protocol 10XV3`** stated explicitly (not `auto`) — SOURCE.md's own recommendation, and
  confirmed directly from R1 length (28bp = 16+12, the v3 signature; v2 would be 26bp/10bp UMI).
- **`--star_feature Gene`** (pipeline default) — standard gene-level counts, not
  `GeneFull`/pre-mRNA or `Velocyto`. No reason from the request to change it.
- **`--save_reference`** so the STAR index this run builds is reusable (mirrors the rnaseq
  convention already in this repo) — lands under this run's own results dir, not
  auto-promoted into `$BIOINFO_REFS` (manifest still says `[!] build`; promoting it is a
  follow-up action for the user, same convention as the rnaseq run).
- **Single sample, no batching.** Only one channel exists; nothing to batch.

## What is missing / must be built this run
- **STAR index for GRCh38** — not present (`/refs/genomes/GRCh38/index/star` is empty,
  `refs.manifest.tsv` line 39 marks it `build`). Confirmed via `find` immediately before
  writing this plan. Per `estimates.md` §2: 45–90 min at 18 threads, peak RAM 32–38 GB — inside
  the 40 GB Nextflow pool but close to its ceiling; nothing else should run concurrently.
  `free -g` inside WSL shows 47 GB available right now (the `.wslconfig` 52 GB fix is applied),
  so this fits.
- Container images for scrnaseq's STAR/fastqc/multiqc/dropletutils(emptydrops) module set —
  not yet pulled on this host for this pipeline (first scrnaseq run). Estimated 15–45 min per
  `estimates.md` §2 (comparable to the rnaseq/atacseq set; some layers likely shared).
- `genome.dict` is not needed by scrnaseq (GATK-only artifact) — not a gap for this run.

## Estimate
Per `estimates.md` §1/§2/§3, worked out for this specific dataset (3.24M read pairs is ~1% of
the table's 400M-read reference lane, so per-sample alignment/quant is far below the table's
1.5–3 h figure — the STAR index build, not alignment, dominates here):

| Item | Time | Peak disk/RAM |
|---|---|---|
| STAR index, GRCh38 + GENCODE v50 | 45 – 90 min | 32 – 38 GB RAM, 32-38 GB disk |
| Container pulls (scrnaseq set, first run) | 15 – 45 min | 8 – 15 GB |
| `-stub-run` validation | 2 – 5 min | <1 GB |
| STARsolo alignment + quant, 1 sample, 3.24M pairs | 3 – 10 min | 1 – 3 GB |
| FastQC, emptydrops, MultiQC | 3 – 8 min | <1 GB |
| **Total, single stage (no concurrency benefit — one sample)** | **~70 – 160 min (1.2 – 2.7 h)** | |

Well under the 24 h approval line. STAR index build is the only stage that saturates the RAM
pool; everything else is small given the dataset size.

**Disk**: work-dir peak ≈ STAR index (~38 GB, saved into results too under `--save_reference`
→ counted twice until the run ends) + containers (~15 GB) + per-sample work (~5 GB) ≈ 60-80 GB
subtotal. With the 1.5× guardrail: **~90-120 GB**. Against 815 GB free on `/` (ext4, confirmed
via `df -h` just now): comfortably clear.

## Command shape
```
nextflow run nf-core/scrnaseq -r 2.7.1 -profile docker \
  -c config/local.config -c config/genomes.config \
  --igenomes_ignore --genome GRCh38 \
  --aligner star --protocol 10XV3 \
  --input samplesheet.csv --save_reference \
  --outdir <work>/results -work-dir <work>/work -resume
```

## QC thresholds to apply at step 6
Per `qc-interpretation.md` conventions for scrnaseq/STARsolo (stated here so the verdict isn't
invented after the fact): fraction of reads with valid barcode, fraction confidently mapped to
genome/transcriptome, and cells called by STARsolo/emptydrops vs the expected-cells default —
reported against pipeline defaults since no `expected_cells` was set in the samplesheet
(single smoke-test sample, no prior estimate of true cell count for this run).

Proceeding straight to preflight + stub-run + execution — this reuses an already-selected,
already-validated dataset (SOURCE.md) and a pipeline/reference combination consistent with the
repo's existing conventions; the only new element is scrnaseq itself, which the stub-run will
catch if anything about its schema or param names has drifted from the note above.
