# cutandrun

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** No registered stub waiver. Preview and the full-command stub must pass; missing upstream stubs can execute real work.
- **Evidence lookup:** [procurement record](evidence/cutandrun.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** CUT&RUN and CUT&Tag → peaks called with SEACR and/or MACS2, spike-in normalised coverage
tracks, consensus peaks, an IGV session, and a reporting deck of QC plots.

**Not for:** conventional ChIP-seq (use chipseq — the normalisation model differs). Not for ATAC.
Not for experiments with no IgG control if you intend to use SEACR's control mode.

**Minimum input:** `--input samplesheet.csv` — columns in `references/samplesheets.md`. This family
uses `group`/`replicate`, **not** `sample`; copying an atacseq samplesheet across is the usual error.

**Pinned compatibility patch: cutandrun 3.2.2.**
The old `emit: html optional true` syntax in `modules/local/for_patch/trimgalore/main.nf`
fails on the recorded Nextflow 26.04.6 with `Cannot invoke method optional() on null object`.
The repository helper checks the exact revision and two declarations before changing them:

```bash
python3 "$BIOINFO_HOME/scripts/apply-pipeline-patch.py" "$NXF_ASSETS/nf-core/cutandrun"
# After approval of the planned cache patch:
python3 "$BIOINFO_HOME/scripts/apply-pipeline-patch.py" "$NXF_ASSETS/nf-core/cutandrun" --apply
```

Keep its manifest/report with the run record and rerun preview. A new pin, unknown content
or unrelated dirty cache is a stop, not permission for a blind edit. This is a compile fix,
not a stub waiver. The original finding is retained in [procurement evidence](evidence/cutandrun.md).

**`-stub-run` is not a cheap gate for this pipeline — budget it, do not skip it.**
`FASTQC_TRIMGALORE:TRIMGALORE` has no `stub:` block, so `-stub-run` silently falls back to running
the *real* `trim_galore` on the *real*, full-size input fastqs (confirmed by watching
multi-hundred-MB real trimmed outputs and trimming reports appear in the stub work dir) — the same
class of issue the chipseq run hit with `GENOME_BLACKLIST_REGIONS`, and the same shape as fetchngs
in `references/pipelines/fetchngs.md`. Both `-preview` and `-stub-run` are still mandatory (SKILL.md step 4, `runbook.md` §4);
this pipeline has no waiver. What changes is the estimate: put the real trimming cost of the
samplesheet's fastqs into the plan as part of the gate, and expect the stub to take run-scale time
rather than minutes. `runbook.md` §4 has the 30-second check for which modules lack a `stub:` block.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--bowtie2` | store bowtie2 index path | **NOT** `--bowtie2_index` — that is chipseq's param name for the equivalent index. cutandrun's own is `--bowtie2`. Confirmed via `--help` and source, 2026-08-06 (run `20260806-cutandrun-hpsc-h3k27me3-smoke`); easy to get wrong copying a chipseq cmd.sh forward |
| `--peakcaller` | `seacr` or `seacr,macs2` | order matters: the first listed is used for the consensus/reporting. Pipeline default is `seacr` alone |
| `--normalisation_mode` | `Spikein` if a spike-in was used, else `CPM` | pipeline default is `Spikein`; declaring it with no real spike-in reads produces garbage scale factors — silently wrong, not an error. **`CPM` switches the entire spike-in arm off: no spike-in alignment, no spike-in index build, and none of the `qc-interpretation.md` §3.5 spike-in QC band.** See the boxed correction below — an earlier version of this row claimed the opposite, and a completed run disproved it |
| `--spikein_genome` | E. coli K12 by default | if the experiment used a different carrier, override. Ignored once `--spikein_fasta` is passed explicitly |
| `--spikein_fasta` / `--spikein_bowtie2` | store paths | **Both are inert unless `--normalisation_mode Spikein`.** Under `Spikein`, `--spikein_bowtie2` may be omitted and the pipeline builds the index itself from `--spikein_fasta` via `BOWTIE2_BUILD_SPIKEIN` (trivial, ~4.6 Mb). Under `CPM` neither is read: passing a valid `--spikein_fasta` produces no spike-in output and no error |
| `--macs2_narrow_peak` | pipeline default `true` (narrow) | set `false` for broad marks (H3K27me3/H3K9me3/H3K36me3), same reasoning as chipseq's broad-mode choice |
| `--use_control` / `--igg_scale_factor` | with IgG | controls how the IgG track is subtracted |
| `--dedup_target_reads` | usually **off** for CUT&RUN | high-efficiency CUT&RUN produces genuine duplicate fragments; deduplicating them throws away signal. This is a real judgement call — state which way you went |
| `--consensus_peak_mode` | `group` | `all` collapses across the whole experiment |

**Reference-store paths:**

```
$BIOINFO_REFS/genomes/GRCh38/fasta/GRCh38.fa           alias, present
$BIOINFO_REFS/genomes/GRCh38/gtf/GRCh38.gtf.gz         alias, present
$BIOINFO_REFS/genomes/GRCh38/index/bowtie2/            present — built by atacseq, reused by chipseq and cutandrun
$BIOINFO_REFS/genomes/GRCh38/bed/cutandrun_blacklist.bed   present — added 2026-08-06, see below
$BIOINFO_REFS/genomes/ECOLI_K12/fasta/genome.fa        present — added 2026-08-06 (NCBI RefSeq GCF_000005845.2)
$BIOINFO_REFS/genomes/ECOLI_K12/index/bowtie2/         manifest row present (build mode) — built per-run ONLY under --normalisation_mode Spikein; a CPM run never builds it (see below)
```

**`--normalisation_mode CPM` switches the whole spike-in arm off. Measured, and it corrects a
claim this file previously made.** Until 2026-08-10 the `--normalisation_mode` row above said
spike-in alignment and its QC metrics "run unconditionally regardless of this setting", citing a
source read. Run `20260810-cutandrun-hpsc-h3k27me3` (cutandrun 3.2.2, `--normalisation_mode CPM`,
a valid `--spikein_fasta` passed, `--save_reference true`) completed 146 tasks and **not one of
them was a spike-in task** — no `BOWTIE2_BUILD_SPIKEIN`, no `BOWTIE2_SPIKEIN_ALIGN`, no
`EXTRACT_BT2_SPIKEIN_META` (`grep -ci spikein` over the trace: 0). MultiQC emitted a
`Bowtie2 (target)` general-stats column and no spike-in column at all,
`02_alignment/bowtie2/` published only `target/log/*.bowtie2.log`, and
`$BIOINFO_REFS/genomes/ECOLI_K12/index/bowtie2/` did not exist after the run.

The old claim was half a reading. The `ALIGN_BOWTIE2` **call site**
(`workflows/cutandrun.nf:260-262`) really is guarded only by `params.run_alignment` and
`params.aligner == "bowtie2"` — that much was right. But the spike-in processes inside it are
starved by a **data dependency** gated further upstream:

```
prepare_genome.nf:46    if (params.normalisation_mode == "Spikein") { ch_spikein_fasta = ... }
                        -> under CPM, ch_spikein_fasta stays Channel.empty()
prepare_genome.nf:152   if (normalisation_mode == "Spikein" && params.spikein_bowtie2) { ...untar/use... }
                        else { BOWTIE2_BUILD_SPIKEIN(ch_spikein_fasta) }   <- empty in, no task out
                        -> ch_bt2_spikein_index stays empty
align_bowtie2.nf:36     BOWTIE2_SPIKEIN_ALIGN(reads, ch_spikein_index.collect{...}, ...)
                        -> never receives a complete input tuple, so it never runs
```

Note the `else` on line 152: passing `--spikein_bowtie2` explicitly does **not** rescue this
under `CPM` — the condition requires `Spikein` too, so control still falls to the build branch
and that branch is fed the empty channel.

Two consequences to carry into any plan:

- **A `CPM` run cannot report the §3.5 spike-in fraction band.** There are no spike-in reads to
  count. Do not promise that metric in a plan that selects `CPM`, and do not record its absence
  as a failure — it is a direct consequence of the normalisation choice.
- **A `CPM` run never builds the E. coli index**, so `--save_reference` has nothing to persist and
  the `ECOLI_K12/index/bowtie2` manifest row stays unmaterialised no matter how many `CPM` runs go
  through.

The judgement itself is unchanged and still stands: `Spikein` with no real spike-in carrier
produces scale factors from stray reads, which is silently wrong. The correction is only that
choosing `CPM` to avoid that **also** costs the spike-in QC readout, rather than keeping it as a
free diagnostic. If the spike-in fraction is wanted precisely *in order to decide* whether a
spike-in was used, that has to be measured some other way — `CPM` will not measure it for you.

**Do not point `--blacklist` at `genomes/GRCh38/bed/blacklist.bed` (the atacseq/chipseq ENCODE
list) for this pipeline.** nf-core/cutandrun 3.2.2's own `conf/igenomes.config` maps GRCh38 to its
bundled `assets/blacklists/GRCh38-blacklist.bed` — a different, CUT&RUN-specific region set (1049
regions vs 636 in the ENCODE ChIP-seq list; confirmed by diff 2026-08-05). As of 2026-08-06 this
file is copied into the store at `genomes/GRCh38/bed/cutandrun_blacklist.bed` (fetch-mode manifest
row pinned to the 3.2.2 tag URL + sha256 in `refs.manifest.tsv`, so a fresh machine materialises
it without a pipeline clone) rather than left pointing at the pipeline's `NXF_ASSETS` clone
directory, which changes hash on every `nextflow pull`. Do not reuse the atacseq/chipseq row, and
do not point atacseq/chipseq at this one either.

The E. coli K12 spike-in genome (`genomes/ECOLI_K12/fasta/genome.fa`) was fetched and manifest-
tracked as of 2026-08-06 rather than left to the pipeline's own per-run download — the store is
offline-reproducible for this pipeline now. The spike-in bowtie2 index is still built per-run
(cheap — seconds, for a 4.6 Mb genome) unless a future run promotes a built copy to the store path
above, the same way the human GRCh38 bowtie2 index was promoted after atacseq first built it.

**Key outputs:** SEACR/MACS2 peak BEDs per group, consensus peaks, normalised bigWigs, the
`igv_session.xml`, the reporting HTML, MultiQC.

**QC verdict checklist:** spike-in read fraction and the resulting scale factors (wildly divergent
factors across samples means the spike-in was not added consistently), FRiP, peak counts per group,
IgG background level, duplication. Bands: `references/qc-interpretation.md` §3.5.
