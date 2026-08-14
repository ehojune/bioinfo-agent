# Run 20260814-rnasplice-scer-gln3-ibutanol — nf-core/rnasplice -r 1.0.4 — COMPLETE WITH CAVEATS

**Inputs**       8 samples, bulk paired-end RNA-seq, *S. cerevisiae*, 4 conditions × 2 replicates
(`WT_ctrl`, `WT_ibuoh`, `gln3_ctrl`, `gln3_ibuoh`) — FASTQ reused from
`runs/20260807-rnaseq-scer-gln3-ibutanol/` (PRJEB33652, no new download).
Samplesheet: `/mnt/d/bioinfo-agent/runs/20260814-rnasplice-scer-gln3-ibutanol/samplesheet.csv`
**Reference**    `$BIOINFO_REFS/genomes/R64-1-1/{fasta/genome.fa,gtf/genes.gtf.gz}` (Ensembl
R64-1-1, reused from a prior `nf-core/rnaseq` run, not fetched this run); rnasplice's own
Salmon index built in-run (not reused from `rnaseq`'s index — see plan.md)
**Command**      `/mnt/d/bioinfo-agent/runs/20260814-rnasplice-scer-gln3-ibutanol/cmd.sh`
(`--skip_alignment true --rmats false --dexseq_exon false --edger_exon false --dexseq_dtu false
--sashimi_plot false --clusterevents_local_event false --clusterevents_isoform false
--suppa_per_local_event false` — see `plan.md` for full rationale)
**Wall clock**   ~58 min end to end (21:38:47 launch → 22:38 completion) — **but only ~2 min of
that is genuine compute**; the rest is a real pipeline bug hit mid-run (see below), not workload
size. A clean re-run with `suppa_per_local_event: false` set from the start would be a few
minutes total, in line with the CI-fixture row in `estimates.md`.
**Peak disk**    work dir 1.7 GB; published results 66 MB
**Cores/RAM used**  this host's actual pool is 16 cores / 18 GB (`config/host.env`); every task
ran far below that ceiling — 12 Mb genome, no STAR
**Results**      `/mnt/d/bioinfo-agent/runs/20260814-rnasplice-scer-gln3-ibutanol/results/`
(rsynced from `/work/nxf/20260814-rnasplice-scer-gln3-ibutanol/results/`)
**MultiQC**      `.../results/multiqc/multiqc_report.html`
**Work dir**     `/work/nxf/20260814-rnasplice-scer-gln3-ibutanol/work` — RETAINED, do not
delete, `-resume` depends on it

## QC verdict (measured only — no biological interpretation)

**COMPLETE WITH CAVEATS** — `completed=2 failed=0 cached=38` on the final (post-fix) `-resume`,
all processes exit 0. The caveat is scope, not failure: per-local-event (exon/intron-level)
splicing detection is disabled for this run after a real pipeline bug (below); per-isoform
(transcript-level) detection ran cleanly and completed.

| sample | metric | value | verdict |
|---|---|---|---|
| WT_ctrl_rep1 | Salmon `percent_mapped` | 94.41% | measured |
| WT_ctrl_rep2 | Salmon `percent_mapped` | 92.52% | measured |
| WT_ibuoh_rep1 | Salmon `percent_mapped` | 95.38% | measured |
| WT_ibuoh_rep2 | Salmon `percent_mapped` | 93.88% | measured |
| gln3_ctrl_rep1 | Salmon `percent_mapped` | 93.72% | measured |
| gln3_ctrl_rep2 | Salmon `percent_mapped` | 95.33% | measured |
| gln3_ibuoh_rep1 | Salmon `percent_mapped` | 95.80% | measured |
| gln3_ibuoh_rep2 | Salmon `percent_mapped` | 95.39% | measured |
| `WT_ibuoh` vs `WT_ctrl` | per-isoform `dPSI`/p-value table row count | 6,685 | measured (`salmon/suppa/diffsplice/per_isoform/WT_ibuoh-WT_ctrl_transcript_diffsplice.dpsi`) |
| `WT_ibuoh` vs `WT_ctrl` | rows with nominal p<0.05 | 4,808 / 6,685 (71.9%) | measured, **uncorrected** — no multiple-testing-correction step is in this run's scope, not a claim about how many are real |

Thresholds applied: mapping-rate band informal (>90% treated as healthy, source: my default,
no formal published band exists for this pipeline yet). No sample flagged/excluded.

## Bounded choices I made

- **SUPPA2 per-isoform only, not the pipeline's kitchen-sink default.** `--skip_alignment true`
  plus explicit `false` on `rmats`/`dexseq_exon`/`edger_exon`/`dexseq_dtu`/`sashimi_plot` —
  the pipeline's real (not `--help`-stated) default runs all of those. Undo: drop all six flags.
- **`--suppa_per_local_event false`, added mid-run after a real hang** (not planned in advance —
  see Known gaps). Undo: drop the flag, but expect the same 53-minute hang to recur on this
  genome/annotation until the upstream bug is fixed.
- **Strandedness fixed at `reverse` for all 8 samples**, taken from the prior `rnaseq` run's
  measured RSeQC/Salmon-agreement result on the identical FASTQ files, not re-inferred and not
  `auto` (rejected by this pipeline's samplesheet checker).
- **Single contrast**: `WT_ibuoh` vs `WT_ctrl` only. The other 5 pairwise contrasts among the 4
  conditions were not run.
- **rnasplice built its own Salmon index rather than reusing `rnaseq`'s R64-1-1 index** — a
  different, unverified transcript-fasta-extraction code path; see `plan.md`.
- **8 of 8 samples used.** Nothing excluded, nothing subsampled.

## Known gaps

- **A real, reproducible pipeline bug was found and routed around, not fixed upstream.**
  `SUPPA_SALMON:GENERATE_EVENTS_IOE` hangs indefinitely (measured 53 real minutes at 99% CPU) on
  any genome/annotation where SUPPA finds zero local splicing events of some type — confirmed as
  a genuine `awk` infinite-loop bug in `modules/local/suppa_generateevents.nf`, reproduced
  standalone outside the pipeline. Worked around with `--suppa_per_local_event false`, which
  means **this run ships no per-local-event (exon/intron-level SE/SS/MX/RI/AF/AL) splicing
  detection at all** — only per-isoform (transcript-level) PSI/dPSI. See `pipeline-selection.md`
  §4.15 and `config/pipelines.tsv` for the full writeup.
- No multiple-testing correction (`stageR`) applied to the 4,808-row nominal-significance count
  above — raw counts only.
- rMATS/DEXSeq DEU/DEXSeq DTU/edgeR DEU/Miso sashimi all out of scope this procurement —
  redundant or STAR-BAM-dependent methods beyond SUPPA2's coverage, not exercised at all.
- Only one contrast run (`WT_ibuoh` vs `WT_ctrl`); the `gln3Δ` genotype effect and the
  genotype×treatment interaction are not measured.
- n=2 replicates per condition — the pipeline's own floor, below the ≥3 the skill flags for a DE
  analysis I would stand behind.

## Next step for you

Review `results/multiqc/multiqc_report.html` for the aggregated FastQC/TrimGalore/Salmon view,
and `results/salmon/suppa/diffsplice/per_isoform/WT_ibuoh-WT_ctrl_transcript_diffsplice.dpsi`
for the per-isoform dPSI/p-value table. If per-local-event (exon-level) splicing detection is
wanted, that needs either an organism/annotation with a higher local-event rate than yeast, or an
upstream fix/workaround for the `GENERATE_EVENTS_IOE` hang beyond simply disabling it — neither
is done here. If additional contrasts (genotype effect, interaction) are wanted, add rows to
`contrasts.csv` and rerun with `-resume`.

No biological interpretation is included, by design.
