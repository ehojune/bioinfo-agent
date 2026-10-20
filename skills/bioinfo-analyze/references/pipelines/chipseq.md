# chipseq

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** No registered stub waiver. Preview and the full-command stub must pass; missing upstream stubs can execute real work.
- **Evidence lookup:** [procurement record](evidence/chipseq.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** ChIP-seq with input/IgG controls → peaks (narrow or broad), consensus peak set and count
matrix, bigWigs, and ChIP QC (cross-correlation, FRiP, fingerprint plots).

**Not for:** CUT&RUN or CUT&Tag if you want spike-in normalisation or SEACR — use cutandrun (`references/pipelines/cutandrun.md`).
Not for ChIP without any control unless you accept substantially worse peak calls. Not for
differential binding as a finished product (same limitation as atacseq).

**Minimum input:** `--input samplesheet.csv` — columns in `references/samplesheets.md`. Control rows
are samples too and need their own rows; that is what makes a 6-ChIP + 2-input design cost eight.

**Parameters that matter here:** `--narrow_peak` vs broad (default is broad in some revisions —
check; TFs want narrow, H3K27me3/H3K36me3 want broad), `--macs_gsize 2700000000` (plain decimal —
see the atacseq `references/pipelines/atacseq.md` note on why `2.7e9` fails schema validation), `--blacklist`, `--read_length`,
`--aligner bwa|bowtie2`, `--min_reps_consensus`.

**Reference-store paths:** same set as atacseq (`references/pipelines/atacseq.md`) — **including** the blacklist, which the
store records at `genomes/GRCh38/bed/blacklist.bed` ([reference history](evidence/reference-store-history.md)). Not the same store asset as
cutandrun's blacklist below; see the note on `references/pipelines/cutandrun.md`'s row for why those two must not be conflated.

**Do not use the compact `--genome <key>` form on this store — confirmed 2026-08-06 (chipseq
2.1.0, run `20260806-chipseq-vsmc-h3k27me3-smoke`).** Unlike scrnaseq, `fasta`/`gtf`/
`bowtie2_index`/`gene_bed` DO resolve correctly via `--genome GRCh38 --igenomes_ignore`. The
failure is different: chipseq's `main.nf` calls `getGenomeAttribute()` for `bwa`, `bowtie2`,
`chromap` AND `star` unconditionally, regardless of which one `--aligner` actually selects. This
store's `genomes.config` declares `GRCh38.bwa` and `GRCh38.star` for completeness even though
neither index is built for this FASTA, and nf-schema's `exists: true` validation checks every one
of those four params that ends up non-empty — not just the one the chosen aligner needs — so the
run aborts at parameter validation (`--bwa_index`/`--star_index` "does not exist") before any
process starts, no matter which `--aligner` is passed. `--blacklist` is a separate, permanent gap
either way: `genomes.config`'s GRCh38 block has no `blacklist` key, so the compact form never
populates it. Use explicit `--fasta`/`--gtf`/`--bowtie2_index`/`--blacklist`/`--gene_bed` instead
(`config/genomes.config` §3b has the full command and rationale). **cutandrun does NOT share this
trap — confirmed 2026-08-06 (cutandrun 3.2.2, run `20260806-cutandrun-hpsc-h3k27me3-smoke`) by
reading `main.nf` and `subworkflows/local/prepare_genome.nf` at the pinned revision directly.**
cutandrun's `main.nf` calls `getGenomeAttribute()` only for `fasta`, `bowtie2`, `gtf`,
`bed12`→`gene_bed`, and `blacklist` — it never touches `bwa`/`star`/`chromap`, so the
exists-regardless-of-aligner failure this section describes for chipseq cannot occur on cutandrun.
See `references/pipelines/cutandrun.md` for why cutandrun still uses explicit paths anyway (a different, permanent reason: its own
bundled blacklist is not the same file the ENCODE blacklist row here would resolve to).

**Key outputs:** same shape as atacseq — per-sample peaks, consensus BED + count matrix, bigWigs,
MultiQC with phantompeakqualtools metrics.

**QC verdict checklist:** NSC/RSC from cross-correlation, FRiP, fingerprint plot separation between
ChIP and input, peak count and its consistency across replicates, duplication rate. Bands:
`references/qc-interpretation.md` §3.5.
