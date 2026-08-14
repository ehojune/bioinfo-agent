# Time and disk estimates

Every number here is calibrated for **this box**: 24 logical cores, 63.5 GB host RAM, Docker engine
inside WSL2 Ubuntu-24.04, work directory on the distro's native ext4 (the 1 TB VHDX at
`D:\wsl\ubuntu-24.04\ext4.vhdx`, 955 GB free). They are not portable to a cluster and not portable
to a laptop. They are ranges because the variance is real; presenting a single number would be a
lie with extra decimal places.

**Recalibrate from your own traces after the first real run of each pipeline** — see §8. This file is
a starting prior, not a measurement.

---

## 0. Two things that will bite before any pipeline starts

### 0.1 WSL2 gives the distro half the host RAM by default

Default WSL2 memory allocation is ~50% of host RAM, so **~31.7 GB**, not 63.5 GB. A human STAR index
build peaks near 32–38 GB and a STAR alignment against that index holds ~30 GB resident. Both will
OOM at the default. Check and fix before estimating anything:

```bash
free -g                     # inside WSL — this is your real ceiling, not the host's
```

Copy `config/wslconfig.example` to `%UserProfile%\.wslconfig`, then `wsl --shutdown`. That file is
the tested copy target and the only `.wslconfig` source in this repo: 52 GB and 22 cores to the VM,
the rest left to Windows. Every memory figure below assumes it has been applied; at 31.7 GB the STAR
path is simply not runnable and you must say so rather than start it.

### 0.2 The VHDX grows and does not shrink

Deleting files inside WSL frees space to ext4 but not to Windows. A run that peaks at 600 GB leaves
the VHDX 600 GB large on D: forever until it is compacted:

```powershell
wsl --shutdown
Optimize-VHD -Path D:\wsl\ubuntu-24.04\ext4.vhdx -Mode Full   # Hyper-V module; else use diskpart
```
<!-- UNVERIFIED: Optimize-VHD requires the Hyper-V PowerShell module; on Windows 11 Pro without it, use `diskpart` → `select vdisk file=...` → `compact vdisk`. Confirm which is available before promising it. -->

The 1 TB VHDX max size is a hard ceiling on peak work-dir usage regardless of D: having 2.2 TB free.

---

## 1. Per-pipeline cost, per sample

Reference input size is stated per row. Scale roughly linearly with read count for alignment and
quantification; QC steps scale sublinearly; scatter-gather variant calling scales with genome
territory, not read count.

**Wall clock** below is *serialised machine time* — what one sample costs when it has the box
essentially to itself. It is the number you multiply by N and then divide by the concurrency
factor from §3. It is not what you observe per sample when Nextflow is running several at once.

| Pipeline | Reference input | Wall clock / sample | Work-dir peak / sample | Published results / sample | Dominant variance driver |
|---|---|---|---|---|---|
| **rnaseq** (STAR + salmon) | 30 M PE150 pairs | 0.7 – 1.6 h | 25 – 50 GB | 3 – 8 GB | STAR is memory-serialised (§3). Qualimap + RSeQC + dupRadar can be 40% of the total — `--skip_qualimap` etc. halves it. UMI dedup adds 30–60% |
| **rnaseq** (`--pseudo_aligner salmon --skip_alignment`) | 30 M PE150 pairs | 0.15 – 0.35 h | 8 – 15 GB | 1 – 3 GB | ~5× faster and ~4× smaller, at the cost of no BAM, no coverage tracks, no genomic QC |
| **sarek**, germline WGS | 30× PE150 (~50–70 GB gz FASTQ) | **20 – 36 h** | 300 – 600 GB | 25 – 60 GB | Caller set; `--split_fastq`; whether BQSR runs; annotation. See §5 |
| **sarek**, germline WES | 100× on a 35–60 Mb target (~12–18 GB gz) | 3 – 7 h | 60 – 130 GB | 8 – 20 GB | Target size, caller set, annotation |
| **sarek**, somatic T/N WGS | 2 × 30× (or 60×/30×) | 40 – 80 h **per pair** | 600 GB – 1.2 TB | 50 – 120 GB | Mutect2 scatter width dominates. This is at the edge of what the VHDX holds — see §6 |
| **methylseq** (bwameth + MethylDackel), WGBS | 30× PE150 | 8 – 16 h | 300 – 600 GB | 30 – 80 GB | Prefer this over bismark for WGS-scale bisulfite |
| **methylseq** (bismark), WGBS | 30× PE150 | 24 – 45 h | 350 – 650 GB | 30 – 80 GB | Bismark runs four alignment instances (2 strands × 2 conversions). Roughly 3× bwameth |
| **methylseq** (bismark), RRBS | 30 M PE reads | 2 – 5 h | 30 – 60 GB | 4 – 10 GB | Dedup must be **off** for RRBS; leaving it on is a correctness bug, not a time saving |
| **atacseq** | 50 M PE150 pairs | 1.5 – 3.5 h | 40 – 90 GB | 6 – 15 GB | Mitochondrial fraction inflates alignment time for reads you then throw away. `--narrow_peak` vs broad changes the peak stage only |
| **chipseq** | 30 M reads + matched input | 1 – 2.5 h (per ChIP; the input is another sample) | 25 – 55 GB | 4 – 10 GB | Controls are samples too — a 6-ChIP + 2-input design is 8 samples of cost, not 6 |
| **cutandrun** | 5 – 10 M PE reads | 0.3 – 0.9 h | 10 – 25 GB | 2 – 6 GB | Cheapest thing in the stock set. Spike-in alignment adds a few minutes |
| **scrnaseq** (`--aligner star`/STARsolo) | 400 M reads, one 10x lane | 1.5 – 3 h | 70 – 160 GB | 6 – 20 GB | Same 30 GB STAR index residency as rnaseq — memory-serialised |
| **scrnaseq** (`--aligner alevin` / simpleaf) | 400 M reads | 0.6 – 1.5 h | 40 – 90 GB | 4 – 12 GB | Much lighter on RAM; runs 2–3 wide |
| **differentialabundance** | whole experiment, ≤100 samples | 0.2 – 0.7 h **total, not per sample** | <10 GB | <2 GB | Number of contrasts and whether GSEA runs |
| **fetchngs** | download-bound | see §1.1 | ≈ 1.05 × downloaded bytes | = downloaded bytes | Network only |
| **ampliseq** (16S/ITS, CI-fixture-scale) | 4 samples × 2,500 PE reads (`-profile test`) | 0.7 – 1 h **total, not per sample** — peak process 960 MB (`QIIME2_DIVERSITY_*`), peak_rss stayed under 1 GB for every task | 560 MB **total** | 78 MB **total** | Measured 2026-08-10 (`runs/20260810-ampliseq-testprofile-procurement/`) — CI fixture; ANCOMBC/adonis/decontam/grouped-barplot branches run because the fixture has ≥2 samples + metadata, which inflates its per-task-count cost relative to a single real sample below |
| **ampliseq** (16S, one real sample, no metadata) | 1 sample × 20,794 PE reads, V4 amplicon (515F/806R), Illumina MiSeq 2×300, DRR033717 (ENA/DDBJ, real clinical BAL microbiome, not a mock community) | **10m 34s** wall clock | **231 MB** | **31 MB** | Measured 2026-08-11 (`runs/20260811-ampliseq-drr033717-realsample/`). **Peak single-process RAM 5.6 GB** (`QIIME2_TAXONOMY:QIIME2_CLASSIFY`, the GTDB naive-Bayes classifier — plausibly close to fixed-cost, driven by classifier size not read count) — 5–6× the CI fixture's peak, the number that row could not show. `QIIME2_TRAIN` 1.6 GB, `QIIME2_EXPORT_RELTAX`/`QIIME2_EXPORT_ABSOLUTE` 1.1–1.2 GB next. Faster and smaller than the CI-fixture row *in total* despite ~2× the read volume, because this run has no ANCOMBC/adonis/decontam/grouped-barplot branches (single sample, no `--metadata`) and pays cutadapt/DADA2 per-sample overhead once instead of ×4. Taxonomy DBs reused from a prior run's cache (`/refs/ampliseq/tax-db`), so this number excludes DB-fetch cost — see §2's ampliseq taxonomy DB row for that, separately. Primer pair confirmed correct post-hoc by a 56.1% cutadapt pass rate, not near-zero. **Still not a cohort estimate**: extrapolating to N samples needs the ANCOMBC/adonis/decontam/barplot branches' cost added back in once `--metadata` is supplied and N≥2, which this row does not cover — measure that on the first real multi-sample run before quoting a cohort number |

| **mag** (shotgun metagenome, CI-fixture-scale) | 3 tiny CI fixtures (`test_minigut`, `test_minigut` run2, `test_minigut_sample2`, `-profile test`), MEGAHIT+SPAdes × MetaBAT2/MaxBin2/SemiBin2, BUSCO/CAT/GTDB-Tk-mockup on | **27m 46s** wall clock | **2.2 GB** | **195 MB** | Measured 2026-08-12 (`runs/20260812-mag-testprofile-procurement/`). `completed=179 failed=1` — the 1 failure (`MAXBIN2` exit 255) is tolerated by the pipeline's own `conf/base.config` (`errorStrategy 'ignore'` on exit 1/255 for that process), not a real defect |
| **mag** (shotgun metagenome, one real sample — FLOOR, not typical) | 1 sample × 436,115 PE read pairs (~110 Mbp), DRR027580 (ENA, real "fossil metagenome" run, chosen for small download size not study relevance), MEGAHIT only × MetaBAT2/MaxBin2/SemiBin2, SPAdes/CONCOCT/COMEBin/MetaBinner/ALE/GTDB-Tk all skipped | **~3m 16s** wall clock | **122 MB** | **19 MB** | Measured 2026-08-12 (`runs/20260812-mag-drr027580-realsample/`). **Read this as a floor, not a typical-case number**: the sample assembled to only 74 contigs, all < 1500 bp, so no binner found anything to bin (`MetaBAT2` completed but produced zero bins; `MaxBin2`/`SemiBin2` both failed on "nothing to bin", tolerated — the `SemiBin2` tolerance is a host-level `config/local.config` addition this run made, since mag's own `base.config` only tolerates that failure shape for `MaxBin2`). Peak single-process RAM stayed under 1.6 GB (`FASTQC_RAW` highest at 1.5 GB) — far under the pool ceiling, because there was almost no sequence to process. **A real metagenome with actual community diversity would drive MEGAHIT/SPAdes assembly, Bowtie2 binning-prep mapping, and the binners themselves far harder than this row shows** — extrapolate cautiously, and prefer a second real-sample measurement against a higher-diversity input before quoting a production estimate from this row alone |

| **taxprofiler** (shotgun metagenome taxonomic profiling, CI-fixture-scale) | 4 tiny CI fixtures, `-profile test` (all 14 profilers on: Kraken2, Bracken, KrakenUniq, Centrifuge, DIAMOND, Kaiju, MALT, MetaPhlAn, ganon, sylph, KMCP, Melon, metacache, plus full short+long read QC/hostremoval/runmerging/Krona) | **24m 34s** wall clock | **4.0 GB** | **551 MB** | Measured 2026-08-12 (`runs/20260812-taxprofiler-testprofile-procurement/`). `completed=179 failed=0` — every one of the 14 profilers, and `-stub-run` separately (`completed=176 failed=0`), passed clean; unlike ampliseq/mag no waiver was needed for either gate. Test profile deliberately runs the full 14-tool roster on toy databases — a real run enabling only 1–2 tools (see next row) is proportionally far cheaper per tool, but a real run enabling most/all 14 tools against production-scale databases would be far more expensive than this row, dominated by database-load time (MALT/MetaPhlAn/DIAMOND load multi-GB indexes per task) rather than read count |
| **taxprofiler** (shotgun metagenome taxonomic profiling, one real sample, single tool) | 1 sample × 436,115 PE read pairs (~110 Mbp), DRR027580 (same ENA "fossil metagenome" sample used for mag's real-sample row — reused, not re-downloaded), Kraken2 only against a real 8 GB-capped standard DB (`db/kraken2/k2_standard_08gb`, archaea+bacteria+viral+plasmid+human+UniVec_Core) | **~47s** wall clock (04:56:41 launch to `Pipeline completed successfully`) | **9.7 MB** | **9.4 MB** | Measured 2026-08-12 (`runs/20260812-taxprofiler-drr027580-realsample/`). `completed=3 failed=0` (FASTQC, KRAKEN2_KRAKEN2, MULTIQC — only 3 tasks for 1 sample/1 tool/no QC/no hostremoval). **Peak single-process RAM 7.8 GB** (`KRAKEN2_KRAKEN2`, dominated by loading the 8 GB `hash.k2d` into memory, essentially fixed-cost regardless of read count — not driven by this sample's small size), `FASTQC` 1.5 GB, `MULTIQC` 900 MB. **99.07% of reads unclassified** against this DB — real classification did happen (bacterial hits down to genus/species level, e.g. *Saccharopolyspora* spp.). The same reads also assembled to only 74 short contigs in the mag real-sample run, which is consistent with a shallow/low-diversity input but does NOT establish that as the cause — an unclassified rate this high is equally consistent with this specific 8 GB-capped database simply lacking coverage for whatever this sample contains; only one database and one sample tested, so the cause is unresolved, not investigated further, no biological claim made. **This is a floor, not a typical-case number**: one tool, one small sample, DB-load cost dominates over read-count cost at this scale — a multi-tool run, a larger DB, or a deeper/higher-diversity sample would all cost substantially more; the DB-load-dominated shape in particular means wall clock will NOT scale down further with an even smaller sample, but WILL scale up with more tools (each pays its own DB-load cost) or a bigger DB (Kraken2 in particular: RAM scales with the k-mer index) |

| **raredisease** (WGS, one real sample, bam-input, lightest-scope) | 1 sample × ~40x WGS, SRR26793256, pre-aligned BAM reused from `nf-core/sarek`'s own MarkDuplicates CRAM (no realignment) — DeepVariant SNV + Manta/Tiddit/CNVnator SV + MT subworkflow + SMNCopyNumberCaller only, annotation/scoring subworkflows skipped (see `pipeline-selection.md` §4.13) | **elapsed across 5 resumed attempts spanning a host reboot: ~9h35m first-launch-to-completion (12:49→22:25 same day), not a clean single-shot number** — dominant per-process realtime measured directly from trace files: `PICARD_COLLECTMULTIPLEMETRICS` 55m30s, `TIDDIT_SV` 29m23s, `CNVNATOR_PARTITION` 28m48s, `DEEPVARIANT` 26m13s (all four run concurrently on this host's 18-core pool, not serially) — a clean single-shot run on this host is closer to the sum of the critical path than the elapsed-across-resumes figure, plausibly 1.5–2.5h, consistent with the plan's 2–6h pre-run estimate | 56 GB (across all resumed attempts; not re-measured for a clean single run) | **6.1 GB** (measured, `du -sh results/`; genome SNV VCF alone is 103 MB — the total is dominated by `qc_bam/` alone at 6.0 GB, per-chromosome TIDDIT coverage `.wig`/`.bw` tracks plus Picard/mosdepth QC outputs, not the small VCF/BED calling outputs) | Measured 2026-08-12 (`runs/20260812-raredisease-srr26793256/`). `succeededCount=50 failedCount=0` (34 more cached across resumes). **Not a clean single-shot measurement** — a host reboot mid-run forced 3 `-resume` relaunches; report a fresh single-shot number before quoting this row as a planning estimate for a new sample. The whole-genome `bwa-mem2` index build (unconsumed by this bam-input run, see §4.13's bounded-choice note) was OOM-killed twice before the run was switched to `--aligner bwa`, adding wasted wall-clock not reflected in the process-realtime figures above |

| **nanoseq** (ONT long-read, one real sample, DNA protocol, lightest scope) | 1 sample, SRR25466853, *E. coli* WGS ONT MinION, 4,000 reads / ~4.86 Mbp (~1.06x nominal coverage of the 4.64 Mb genome), already-basecalled FASTQ given directly (`--skip_demultiplexing true`), minimap2 alignment only — no variant calling, no RNA-specific subworkflows (`--protocol DNA`) | **2m31s** wall clock (20:59:23 launch to `Execution complete`, `completed=17 failed=0`) | **53 MB** | **23 MB** | Measured 2026-08-13 (`runs/20260813-nanoseq-srr25466853/`). **Peak single-process RAM 1.2 GB** (`QCFASTQ_NANOPLOT_FASTQC:NANOPLOT`), `MULTIQC` 135 MB, `FASTQC` 325 MB next — far under the pool ceiling at this genome/read-count scale. `-stub-run` on both the CI `test` profile and this run's own real command hit the identical documented `SAMTOOLS_IDXSTATS`/`SAMTOOLS_FLAGSTAT` no-stub-block gap (waived, 6th documented departure — see `pipeline-selection.md` §4.14); `-preview` clean (`completed=0 failed=0`). **This is a floor, not a typical-case number**: a bacterial genome at ~1x nominal coverage with no variant calling is close to the smallest real thing this pipeline can be asked to do — a human-scale genome, higher coverage, `--call_variants` (medaka/DeepVariant), or a cDNA/directRNA run with quantification would all cost substantially more; none of those are measured yet |

| **rnasplice** (alternative splicing, CI-fixture-scale) | 4 samples (GBR/YRI, 2 conditions × 2 reps), nf-core's own chrX toy genome, `-profile test,docker` — `--skip_alignment true`, SUPPA2 (per-isoform + per-local-event) only, `--rmats/--dexseq_exon/--edger_exon/--dexseq_dtu/--sashimi_plot` all `false`, `--clusterevents_local_event/--clusterevents_isoform` both `false` | **4m34s** wall clock (21:22:44→21:27:12, `completed=34 failed=0`) | **1.3 GB** | **44 MB** | Measured 2026-08-14 (`docs/examples/20260814-rnasplice-scer-gln3-ibutanol/`, evaluation phase). This is the flag set that first got a clean pass — an earlier attempt with `--clusterevents_local_event/--clusterevents_isoform` left at their real default (`true`) failed 4/46 tasks on this same toy dataset (`completed=42 failed=4`) at `CLUSTEREVENTS_IOI`/`_IOE`: 0 significant events survive on the toy data, `suppa.py clusterEvents` prints "Impossible to calculate silhouette score" and never writes the expected `*.clustvec`, so Nextflow reports a missing-output error — see `pipeline-selection.md` §4.15 and `config/pipelines.tsv`. `-stub-run` hits one waived departure (7th documented, same class as ampliseq/mag/nanoseq): `GUNZIP_FASTA`'s stub `touch`es an empty placeholder fasta, and the downstream `GTF_GENE_FILTER`/`RSEM_PREPAREREFERENCE` have no `stub:` block, so they run for real against it and legitimately fail ("The reference contains no transcripts!") — not a real defect, the identical real (non-stub) command above passes clean |
| **rnasplice** (alternative splicing, one real sample, SUPPA2 per-isoform only) | 8 samples (4 conditions × 2 reps), *S. cerevisiae* R64-1-1, real paired-end FASTQ reused from `runs/20260807-rnaseq-scer-gln3-ibutanol/` (1.5 GB, no new download), `--skip_alignment true`, `--suppa_per_local_event false` (see below), 1 contrast | **~2 min of genuine compute** (measured from the `-resume` relaunch after the finding below: 22:36:08→22:38-ish, `completed=2 failed=0 cached=38`) — **but ~58 min wall clock end to end this run** (21:38:47 launch → completion), because of a real pipeline bug hit mid-run, not because the workload itself is slow | **1.7 GB** | **66 MB** | Measured 2026-08-14 (`runs/20260814-rnasplice-scer-gln3-ibutanol/`, `docs/examples/20260814-rnasplice-scer-gln3-ibutanol/`). **Real (non-stub, non-CI-fixture) finding, found on this run**: with `suppa_per_local_event` at its real default (`true`), `SUPPA_SALMON:GENERATE_EVENTS_IOE` ran for 53 real minutes at 99% CPU and never returned — `modules/local/suppa_generateevents.nf`'s per-event-type `.ioe` concatenation (`awk 'FNR==1 && NR!=1 { while (/^seqname/) getline; } 1 {print}' *.ioe`) spins forever once any one of the six event-type files SUPPA writes is header-only (zero events of that type — S. cerevisiae's local/exon-level alternative-splicing rate against this annotation is essentially nil), because `getline` at EOF returns 0 without changing `$0`. Reproduced the identical hang in 5 seconds flat on two synthetic header-only `.ioe` files, outside the pipeline entirely (`timeout 5 awk '...' *.ioe`, exit 124) — a real, deterministic bug, not an artifact of this run's data or the container. Killed the hung container, added `suppa_per_local_event: false` (skips `GENERATE_EVENTS_IOE` structurally — confirmed by reading `subworkflows/local/suppa.nf`'s `if (suppa_per_local_event)` gate), relaunched with `-resume`: `completed=2 failed=0 cached=38`, all prior work (trimming, FastQC, Salmon quant/index, per-isoform SUPPA including `DIFFSPLICE_IOI`) reused untouched. Salmon mapping rate 92.5–95.8% across all 8 samples. `WT_ibuoh` vs `WT_ctrl` per-isoform `dPSI`/p-value table: 6,685 data rows, 4,808 with nominal p<0.05 (uncorrected, not a claim about how many are real). **This narrows the pipeline's realistic default scope for low-alternative-splicing organisms/annotations**: `suppa_per_local_event: false` (isoform-level only) should be the default starting point for any genome with a sparse local-event rate, not just yeast — the CI-fixture row above used human chrX toy data and did NOT hit this, so the trigger condition is data-dependent, not universal |

| **isoseq** (PacBio Iso-Seq genome annotation, one real sample, `entrypoint: isoseq` + `aligner: minimap2`, chunk sized to input) | 1 sample, `alz.1perc.subreads.10000.bam` (nf-core/isoseq's own CI subreads subset — real, non-synthetic 1% subsample of PacBio's public "Alzheimer's Brain Iso-Seq" release, human chr13/18/19-restricted, 531 ZMWs, 48 MB bam + 92 KB pbi), `--chunk 5` (matching `conf/test.config`'s own value for this bam — the pipeline's `--chunk 40` default crashed on this input, see the finding below), `--fasta` = Ensembl chr19-only slice (57 MB), no `--gtf` (minimap2 doesn't need one) | **9m49s** wall clock on the successful `--chunk 5` relaunch (00:28:32→00:38:21, `completed=38 failed=0`) — **but the FIRST launch, at the pipeline's own `--chunk 40` default, ran 19m42s before crashing** (00:08:06→00:27:48, `completed=12 failed=1`, see the real-bug finding below) — total elapsed across both attempts ~30m | **26 MB** (both attempts combined; the abandoned `--chunk 40` attempt's own task dirs, not deleted per the work-dir retention rule, are the majority of this) | **3.4 MB** (after removing stale published outputs from the abandoned `--chunk 40` attempt — same `--outdir` across both `-resume` attempts, `chunk1`-`chunk5` outputs came from the successful attempt, `chunk6`-`chunk40` were stale leftovers from the crashed one and were removed) | Measured 2026-08-14/15 (`runs/20260814-isoseq-alz-chr19/`). **Peak single-process RAM 842.5 MB** (`MINIMAP2_ALIGN`), far under the pool ceiling at this genome/read-count scale — `peakMemory 18 GB`/`peakCpus 12` reported by Nextflow's own workflow stats reflects the scheduler's concurrent-task ceiling, not any one process's actual usage. **Real (non-stub) bug, load-bearing for `--chunk`**: the pipeline's own default (`--chunk 40`) against this input's 531 ZMWs (~106-107 per would-be chunk) produced 29/40 empty per-chunk `GSTAMA_COLLAPSE` bed outputs, crashing `GSTAMA_MERGE` (`tama_merge.py`, `IndexError: list index out of range` reading an empty bed) — `--chunk` must be sized to the input's actual ZMW count for a small dataset, not left at default; see `pipeline-selection.md` §4.16 and `config/pipelines.tsv`. **Separately, a real (non-stub) bug affecting every configuration at this pin**: no MultiQC report is ever produced (`workflows/isoseq.nf`'s own `MULTIQC(...)` call passes a non-`.collect()`'d empty channel to two of the module's plain path inputs, so the process runs zero times) — QC numbers below are read from the pipeline's own per-process report files instead. Measured QC: 531 ZMWs input, 326 passed CCS filters (61.4%), 275 passed LIMA's primer-detection thresholds to become FLNC reads (84.4% of CCS-passed), 100% of FLNC reads carried a polyA tail, 13 gene models / 13 transcript models in the final chr19-restricted merged BED. **This is a floor, not a typical-case number**: a 531-ZMW input restricted to 3 human chromosomes with `aligner: minimap2` (no GTF, no uLTRA indexing) is close to the smallest real thing this pipeline can be asked to do — a full SMRT-cell input (tens of thousands of ZMWs), `aligner: ultra`, or a whole-genome `--fasta` would all cost substantially more; none of those are measured yet |

Row provenance: the rows were written against the pins in `config/pipelines.tsv`.
<!-- UNVERIFIED: per-pipeline default tool selection changes between minor revisions. Confirm the actual module list for your pinned `-r` with `nextflow run nf-core/<pipeline> -r <rev> --help` and by reading the pipeline's `conf/modules.config` before quoting a time. -->

### 1.1 fetchngs / download time

Pure bandwidth. Measure once, then divide:

```bash
# rough sustained throughput to ENA, run for ~30 s and cancel
curl -o /dev/null -w '%{speed_download}\n' <a-known-fastq-url>
```

| Sustained throughput | 100 GB takes | One 30× WGS sample (~60 GB) |
|---|---|---|
| 10 MB/s | 2.8 h | 1.7 h |
| 25 MB/s | 1.1 h | 0.7 h |
| 50 MB/s | 0.6 h | 0.35 h |
| 100 MB/s | 0.3 h | 0.2 h |

Add ~10% for MD5 verification and gz re-packing. Downloads land in the work dir first, so they count
twice against disk until the run publishes.

---

## 2. One-off costs

These are paid once and then reused via the reference store. **State them separately in every run
plan** — folding an index build into a per-sample number is how a 4-hour estimate becomes a 6-hour
run and destroys trust in the next estimate.

| One-off | Wall clock | Peak RAM | Disk produced | Notes |
|---|---|---|---|---|
| `gatk CreateSequenceDictionary` (`.dict`) | 1 – 3 min | <4 GB | ~1 MB | Missing for both builds right now. Trivial; just do it |
| **STAR index**, GRCh38 + GENCODE v50, `--sjdbOverhang 149` | 45 – 90 min at 18 threads | **32 – 38 GB** | 32 – 38 GB | Run it alone. Nothing else on the box. Requires the `.wslconfig` fix from §0.1 |
| **salmon index**, decoy-aware (gentrome = transcripts + genome decoys) | 20 – 50 min | 16 – 28 GB | 15 – 22 GB | Non-decoy is ~8 min / 3 GB but is the wrong index for human DE work |
| **bismark index** (bowtie2, two converted genomes) | 1.5 – 3 h | 8 – 16 GB | 10 – 14 GB | Cheap on RAM, expensive on time. `--parallel` helps modestly |
| **bowtie2 index** | 2 – 3 h | 4 – 8 GB | ~4 GB | Only if a pipeline needs it directly |
| **bwa index** | 60 – 90 min | ~6 GB | ~5.5 GB | **Already present** for `GRCh38gatk` — do not rebuild it |
| **bwa-mem2 index** | 40 – 70 min | **~80 GB** <!-- UNVERIFIED: bwa-mem2 index construction is documented as requiring roughly 28 × genome size in RAM; confirm against the bwa-mem2 README before attempting --> | ~26 GB | **Does not fit in 63.5 GB.** If a pipeline defaults to bwa-mem2, either force `--aligner bwa-mem`, or obtain a prebuilt index. Say this out loud rather than starting a build that will OOM at hour one |
| **Container image pulls** — rnaseq / atacseq / chipseq / cutandrun | 15 – 45 min | — | 8 – 20 GB each set | Docker images land in `/var/lib/docker` on the VHDX. Sets overlap heavily; the second pipeline pulls far less |
| **Container image pulls** — sarek | 25 – 70 min | — | 15 – 30 GB | GATK image alone is several GB |
| **GATK resource bundle** (dbsnp + index, Mills, known_indels, gnomAD af-only + index) | 20 – 70 min | — | 8 – 12 GB | Missing. Sarek's BQSR and germline-resource steps need it |
| **VEP cache**, human GRCh38 indexed | 40 – 120 min download + 20 – 40 min unpack | — | 25 – 30 GB unpacked | Missing. `--vep_cache` points at `$BIOINFO_REFS/cache/vep/` |
| **snpEff GRCh38 database** | 5 – 15 min | — | 1 – 2 GB | Cheaper alternative to VEP if annotation depth is not critical |
| **`-profile test` smoke run** (any pipeline) | 10 – 30 min | modest | 2 – 10 GB | Pays for itself the first time it catches a broken container or reference path |
| **ampliseq taxonomy DB** (GTDB bac120/ar53 SSU subset + Greengenes 85 OTUs via `PREPTAX`) | a few min at CI-fixture scale, measured 2026-08-10 | — | **21 MB** | Cached at `--ref_taxonomy_storage /refs/ampliseq/tax-db`, reused by every later ampliseq run — pay this once, not per run |
| **`-stub-run` / `-preview`** | 1 – 5 min | trivial | <1 GB | Non-negotiable per the guardrails. Costs nothing |

Total cold-start for a first RNA-seq run with nothing built (STAR + salmon indexes, container pulls,
stub + `-profile test`): **1.6 – 3.7 h** and **57 – 90 GB** of reference/index/container disk — the
sum of the rows above, and the same subtotal §6 step 2 uses.

Total cold-start for a first sarek germline run: **2.0 – 5.7 h** and **50 – 82 GB** (images + GATK
bundle + VEP cache download *and* unpack + stub/test; BWA index already exists, `.dict` is minutes).

---

## 3. Concurrency: N samples do not run N-wide

nf-core assigns resource labels per process. Typical requests, before capping:

| Label | CPUs | Memory |
|---|---|---|
| `process_single` | 1 | 6 GB |
| `process_low` | 2 | 12 GB |
| `process_medium` | 6 | 36 GB |
| `process_high` | 12 | 72 GB |
| `process_high_memory` | — | 200 GB |

<!-- UNVERIFIED: these are the conventional nf-core base.config values; confirm for your revision with `find "$NXF_ASSETS" -path '*nf-core/<pipeline>*' -name base.config | head -1` -->

`process_high`'s 72 GB and `process_high_memory`'s 200 GB exceed this box. `config/local.config`
section 2 caps them and is the only place the caps are set — always pass
`-c "$BIOINFO_HOME/config/local.config"`; never hand-tune per run.

That pool is **18 cpus / 40 GB**, inside a 22-core / 52 GB WSL2 VM on a 24-core / 63.5 GB host. It
is smaller than the VM on purpose: the Docker daemon, the Nextflow JVM head process, and Windows
all need to breathe.

### 3.1 Effective slots

```
slots(stage) = floor( min( CPU_budget / cpus_per_task , MEM_budget / mem_per_task ) )
```

At 18 CPU / 40 GB:

| Stage | Request | CPU-limited slots | MEM-limited slots | **Effective** |
|---|---|---|---|---|
| STAR align (human) | 12 cpu / ~38 GB resident | 1 | 1 | **1 — strictly serial** |
| salmon quant | 6 cpu / 12 GB | 3 | 3 | 3 |
| bwa-mem + sort | 12 cpu / 16 GB | 1 | 2 | 1 |
| MarkDuplicates | 6 cpu / 30 GB | 3 | 1 | 1 |
| GATK HaplotypeCaller (per interval) | 1 cpu / 8 GB | 18 | 5 | 5 |
| fastqc / trimming | 2–6 cpu / 6–12 GB | 3–9 | 3–6 | 3–6 |
| MACS2 / peak calling | 1–2 cpu / 8 GB | 9–18 | 5 | 5 |
| qualimap / RSeQC | 1–4 cpu / 6–16 GB | 4–18 | 2–6 | 2–6 |

**The headline fact: for human RNA-seq this machine serialises on memory at STAR, not on cores.**
One STAR at a time. Eight samples means eight STAR runs back to back. No amount of core count changes
that, and it is the single most common source of an underestimate.

### 3.2 The arithmetic to say out loud

```
T_total  =  T_oneoff  +  Σ_stages ( N × t_stage / slots_stage )  ×  1.2
```

The 1.2 is scheduling overhead: container start (1–3 s × thousands of tasks in a scattered sarek
run), `publishDir` copies, staging, and the gaps where the DAG has nothing runnable. For
scatter-heavy pipelines (sarek) use 1.3.

Simplified form when a single stage dominates:

```
T_total ≈ T_oneoff + (N × T_serial_per_sample) / C_eff × 1.2
```

with `C_eff` ≈ 1.25 for human rnaseq with STAR, 2.3 for salmon-only rnaseq, 1.15 for sarek WGS,
1.8–2.2 for atacseq/chipseq/cutandrun, 1.4 for methylseq, 1.3 for scrnaseq with STARsolo — derived
from the §3.1 slots.

Show the substitution in the run plan. A user who can see the arithmetic can argue with an
assumption; a user handed "about 12 hours" can only argue with you.

---

## 4. Disk arithmetic

```
Required_free  =  1.5 × ( work_peak + published_results + inputs_if_copied )
work_peak      ≈  M × total_input_size          # M from the table below
```

**Work-dir usage is cumulative across the whole run, not per-sample-at-a-time.** Nextflow retains
every task directory until the run ends, and the guardrails forbid cleaning it (cleaning destroys
`-resume`). So an 8-sample run peaks at roughly 8× the per-sample work figure, not 1×.

| Pipeline | work : input multiplier `M` | work : final-results ratio |
|---|---|---|
| rnaseq (STAR+salmon) | 5 – 8× | 5 – 8× |
| rnaseq (salmon only) | 2 – 3× | 4 – 6× |
| sarek WGS (CRAM output) | 5 – 9× | 8 – 12× |
| sarek WES | 5 – 8× | 6 – 9× |
| methylseq WGBS | 5 – 9× | 7 – 10× |
| atacseq | 5 – 8× | 5 – 8× |
| chipseq | 5 – 8× | 5 – 7× |
| cutandrun | 3 – 5× | 4 – 6× |
| scrnaseq | 5 – 8× | 8 – 12× |

Checks, in order:

```bash
df -h "$NXF_WORK"                       # ext4, NOT /mnt/d — check the right filesystem
du -sh /var/lib/docker                  # images live on the same VHDX
df -h "$BIOINFO_REFS"
```

Then the guardrail: **if free space on the work filesystem is below 1.5 × the estimate, refuse to
start.** Say the two numbers. Offer, in order of preference:

1. Split into batches (two runs of 4 rather than one of 8) — costs a little wall clock, preserves
   `-resume` within each batch.
2. Move the previous run's *published results* off to `/mnt/d` or `/mnt/e` and out of the VHDX.
3. Compact the VHDX (§0.2) if a previous run's work dir was already deleted by the user.
4. Reduce scope — fewer samples, subsample reads, cheaper aligner.

Never `-with-cleanup`, never `nextflow clean`, never `rm -rf work/`. Those are the forbidden moves.

Two extra terms people forget:

- **Inputs staged from `/mnt/d`.** Nextflow symlinks local inputs where it can, but any process that
  needs a real file, and any `stageInMode copy`, materialises the FASTQ into ext4. Assume inputs are
  copied unless you have verified otherwise, and add their size.
- **`publishDir` copy mode.** nf-core publishes by copy, so large outputs (BAM/CRAM, bigWig, CpG
  reports) exist twice — once in `work/`, once in `results/` — until the run ends.

---

## 5. Red lines, stated plainly

These are things to say **before** anyone starts, not after hour twelve.

**30× WGS through sarek is on the order of a day or more per sample on this hardware.** A ten-sample
germline WGS cohort is therefore roughly **8–15 days of continuous compute** — a multi-week job in
practice once you account for the machine being a workstation somebody also uses. It also needs
**3–6 TB of work-dir space cumulatively**, which does not fit in the 1 TB VHDX. That second fact is
the harder blocker: it is not "slow", it is "impossible as a single run".

The technician must say that sentence out loud, then offer the alternatives:

| Alternative | What it buys | What it costs |
|---|---|---|
| Batch it: 2 samples per run, 5 runs, publish and clear between | Fits the VHDX; each batch resumable | Same total time; manual babysitting between batches |
| WES instead of WGS | ~6× faster, ~5× smaller | Loses non-coding, CNV/SV resolution, and most repeat-expansion territory |
| Fewer callers (`--tools haplotypecaller` only, drop strelka/freebayes/deepvariant/manta/tiddit) | 30–50% off the calling stage | Loses SV and the cross-caller consensus |
| Skip BQSR (`--skip_tools baserecalibrator`) | 2–4 h/sample | Defensible on modern chemistry, but it is a methods choice — the user decides, not the technician |
| `--step` restart from `markduplicates` / `variant_calling` on existing BAM/CRAM | Skips the most expensive stage entirely | Only if aligned data already exists |
| Downsample to 15× for a pilot | Halves everything | Sensitivity drops materially for het calls; explicitly a pilot, not a result |
| **Send it to a cluster** | Actually solves it | Data transfer, access, and a different set of configs |

Say the last one when it is true. "This does not fit on this machine" is a correct and valuable
answer, and pretending otherwise wastes days.

Other red lines:

- **Somatic T/N WGS**: one pair is 40–80 h and 0.6–1.2 TB of work dir. A single pair is already at
  the VHDX ceiling. Anything beyond a pilot pair needs a cluster.
- **WGBS with bismark at 30×**: 24–45 h/sample. Recommend bwameth unless there is a specific reason
  for bismark's output format.
- **bwa-mem2 index**: cannot be built here (§2).
- **Any single run estimated over 24 h**: requires explicit user approval before it starts. Present
  the estimate, the alternatives, and wait. This is a guardrail, not a courtesy.
- **A run whose estimate exceeds 72 h**: also warn that a Windows update reboot, a `wsl --shutdown`,
  or sleep will interrupt it. Nextflow survives via `-resume`, but only if the work dir survives.

---

## 6. Worked example

> **Request:** 8 RNA-seq samples, 40 M PE reads each, human, no STAR or salmon index built yet.

**Step 1 — scale the per-sample figure.** The table's reference is 30 M PE150. 40 M is 1.33×.
Alignment and quant scale roughly linearly; QC less so. Per-sample serialised: 0.7–1.6 h × 1.33
→ **0.95 – 2.1 h**, call it 1.4 h typical.

**Step 2 — one-off costs.**

| Item | Time | Disk |
|---|---|---|
| STAR index (GRCh38 + GENCODE v50) | 0.75 – 1.5 h | 32 – 38 GB |
| salmon decoy-aware index | 0.35 – 0.85 h | 15 – 22 GB |
| Container pulls (rnaseq set) | 0.25 – 0.75 h | 8 – 20 GB |
| `.dict` (not needed for rnaseq) | — | — |
| `-stub-run` + `-profile test` | 0.2 – 0.6 h | 2 – 10 GB |
| **One-off subtotal** | **1.6 – 3.7 h** | **57 – 90 GB** |

**Step 3 — per-sample subtotal with concurrency.** STAR is memory-serialised (§3.1), everything else
runs 3-wide, so `C_eff ≈ 1.25`:

```
(8 × 1.4 h) / 1.25 × 1.2  =  11.2 / 1.25 × 1.2  ≈  10.8 h
```

Range using the endpoints: `(8 × 0.95)/1.25 × 1.2 = 7.3 h` to `(8 × 2.1)/1.25 × 1.2 = 16.1 h`.

**Step 4 — total.** 1.6 + 7.3 = **8.9 h** best case; 3.7 + 16.1 = **19.8 h** worst case. Say
**9–20 h, most likely 12–15 h.** Under the 24 h approval gate, but not by a comfortable margin.

**Step 5 — disk.**

| Term | Size |
|---|---|
| Input FASTQ, 8 × ~10 GB gz | 80 GB (assume copied into ext4) |
| Indexes + containers | 57 – 90 GB |
| Work dir, cumulative: 8 × (33 – 67 GB) at 1.33× scaling | 265 – 535 GB |
| Published results, 8 × (4 – 11 GB) | 32 – 88 GB |
| **Subtotal** | **434 – 793 GB** |
| **× 1.5 guardrail** | **650 GB – 1.19 TB** |

Against 955 GB free in the VHDX (1 TB hard max): the low and mid cases fit, the high case does not.
That must be said, not buried.

**Step 6 — the sentence to the user.**

> Eight RNA-seq samples at 40 M PE reads, STAR+salmon, GRCh38 + GENCODE v50. I have no STAR or salmon
> index yet, so there's a one-off build of about 1.6–3.7 h (STAR index alone is ~1 h and holds
> 32–38 GB of RAM — nothing else can run during it). After that, roughly 7.3–16 h for the eight
> samples: STAR is memory-bound so it runs one sample at a time here, which is what dominates.
> **Total 9–20 h, most likely 12–15.** Under the 24 h approval line, so I'll proceed unless you say
> otherwise — but it will occupy the machine overnight.
>
> Disk is the tighter constraint. Work dir peaks cumulatively at 265–535 GB (Nextflow keeps every
> intermediate so `-resume` stays available; I won't clean it), plus 80 GB inputs, 57–90 GB
> indexes/images, 32–88 GB results. With the 1.5× safety factor that's 650 GB to 1.19 TB against
> 955 GB free in the WSL VHDX. The midpoint fits; the pessimistic case does not. Two options: run all
> eight and I monitor free space and stop at 85%, or split into two batches of four, which costs about
> an extra hour of overhead and removes the risk entirely. I'd take the batches.
>
> First step either way is a `-stub-run` to validate the samplesheet and the DAG — five minutes, and
> I won't skip it.

Note what that does: separates one-off from per-sample, names the serialisation, shows the
multiplication, gives a range with a most-likely, applies the guardrail explicitly, states the
bounded choice (batching) rather than making it silently, and ends by handing the decision back.

---

## 7. Quick sanity ratios

For a fast plausibility check before doing the full arithmetic:

- Alignment throughput here is roughly **0.5–1.5 Gbp of read data per hour** for BWA/STAR at full
  width. 30× human WGS is 93 Gbp → alignment alone is ~10–20 h. That single ratio predicts the sarek
  red line without any table.
- Any estimate under **20 minutes per sample** for a human whole-genome-scale assay is wrong.
- Any estimate where **work-dir peak < 3× input size** is wrong.
- If a proposed run's total is under an hour and involves alignment, you have almost certainly
  forgotten the index build or the container pull.
- If `N × per_sample` came out suspiciously linear with N above 4, you forgot the concurrency ceiling
  is not N.

---

## 8. Replace these numbers with measurements

Every run emits its own calibration data. Use it.

```bash
nextflow run ... -with-report report.html -with-trace trace.txt -with-timeline timeline.html
```

```bash
# after the run: real cost per process.
# Columns BY NAME, never by position: the trace field set is configurable and nf-core
# changes it between releases (same rule as runbook.md section 6). And do not sort
# before the header is consumed -- `sort | awk 'NR>1'` moves the header into the body,
# so awk drops a real task row and prints the header as data.
awk -F'\t' '
  NR==1 { for (i=1;i<=NF;i++) h[$i]=i; next }
  { print $h["name"], $h["duration"], $h["realtime"], $h["%cpu"], $h["peak_rss"] }
' trace.txt | sort -k1,1 | head -40
# what the field set actually is on this Nextflow:
head -1 trace.txt
```

```bash
nextflow log <run_name> -f process,realtime,peak_rss,%cpu,read_bytes,write_bytes,workdir
```

`peak_rss` is what tells you whether a `resourceLimits` memory value is too generous (wasting
concurrency) or too tight (risking OOM). `%cpu` well under `100 × cpus` means the process is I/O
bound and giving it more cores is pointless — a common trap when the work dir accidentally landed on
`/mnt/d`.

After the first real run of each pipeline on this box, **append pipeline, revision, input size, wall
clock, work-dir peak and run id to `$BIOINFO_RUNLOG/measured.tsv`**. Do not edit §1 — this file
ships inside the plugin and is overwritten on reinstall, so measurements cannot accumulate here. A
measured number with provenance beats every estimate in this file.
