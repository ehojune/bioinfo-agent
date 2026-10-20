# methylseq

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** [Exact stub conditions](stubs/methylseq.md) — read before Step 4; match every predicate.
- **Evidence lookup:** [procurement record](evidence/methylseq.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** bisulfite and enzymatic-conversion sequencing → per-cytosine methylation calls. WGBS,
RRBS, EM-seq, PBAT, NOMe-seq.

**Not for:** array data (EPIC/450k — completely different pipeline, not nf-core). Not for
differential methylation testing; it produces per-cytosine calls, and DMR/DMC calling is downstream
work. Not for long-read 5mC (that comes off the basecaller, not from an aligner). Not for
hydroxymethylation deconvolution without oxBS/ACE-seq pairs, which the pipeline does not model.

**Minimum input:** `--input samplesheet.csv` — columns in `references/samplesheets.md`.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--aligner` | `bwameth` for human WGS-scale; `bismark` for small/RRBS | bismark on 30× human WGBS is punishing on a single node. bwameth + MethylDackel is materially faster |
| `--rrbs` | RRBS libraries | enables MspI-aware trimming and disables deduplication (which is invalid for RRBS) |
| `--em_seq` | NEBNext EM-seq | sets the end-clipping the protocol requires <!-- UNVERIFIED: exact clip values (believed 8 bp at both ends of both reads); confirm via --help --show_hidden --> |
| `--clip_r1/--clip_r2/--three_prime_clip_r1/--three_prime_clip_r2` | protocol-dependent | if the kit is not one of the presets, set these manually — M-bias plots will tell you what is needed |
| `--save_reference` | first run | the bismark index build is expensive and there is no index in the store yet |
| `--cytosine_report` | only if genome-wide per-cytosine output is needed | it is large |

**Reference-store paths:**

```
$BIOINFO_REFS/genomes/GRCh38/fasta/genome.fa
$BIOINFO_REFS/genomes/GRCh38/index/bismark/     build mode — absent, first run pays for it
$BIOINFO_REFS/genomes/GRCh38/index/bwameth/     build mode — absent, first --aligner bwameth run pays for it
```

bwameth needs its own index — manifest row present (`config/refs.manifest.tsv`, added 2026-08-05),
index itself not yet built by any run on this host. Not the gap it used to be; still a real cost
the first time `--aligner bwameth` is used.

**Key outputs:** per-sample `*.bismark.cov.gz` (or MethylDackel `*.bedGraph`), splitting reports,
deduplicated BAMs, M-bias plots, MultiQC.

**QC verdict checklist:** bisulfite conversion efficiency (from lambda/pUC19 spike-in if present,
otherwise from non-CpG methylation), duplication rate, M-bias plots flat across the read (if not,
clipping is wrong and the run should be redone), mean CpG coverage, and CpGs covered at depth.
Bands: `references/qc-interpretation.md` §3.3.

**`-stub-run` always fails at `BISMARK_SUMMARY`, harmlessly.** Confirmed on this host both
2026-08-05 (`20260805-methylseq-sle-rrbs-smoke`, real samplesheet — reproduced but not written
down at the time) and re-confirmed 2026-08-16 (`20260816-methylseq-revalidate`, both the real
samplesheet and the pipeline's own `-profile test` fixture): `modules/nf-core/bismark/summary/
main.nf`'s **stub** block calls `${bam.baseName()}` on `val(bam)`, which is always a list (all
samples' BAMs collected into one call) — `nextflow.util.ArrayBag` has no `baseName()` method, so
the stub errors with `No signature of method: ... ArrayBag.baseName()`. This is a bug in
nf-core/methylseq 3.0.0's own bundled module code, not this repo's config — the **real** script
block uses `${bam.join(' ')}` correctly and is unaffected; both a full non-stub `-profile
test,docker` run and a real-sample run complete `BISMARK_SUMMARY`/`MULTIQC` successfully on this
host. Treat a stub-run stopping here, with every upstream process (FASTQC through
BISMARK_REPORT) cached/succeeded, as this known issue, not a new regression — but still run the
full non-stub test-profile pass (`new-pipeline.md` §2.4c) before trusting a methylseq run on this
pin; do not extrapolate past this one process from the stub alone.
