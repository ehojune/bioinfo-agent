# Run 20260813-nanoseq-srr25466853 — nf-core/nanoseq -r 3.1.0 — COMPLETE

**Inputs**       1 sample, ONT MinION DNA WGS, SRR25466853 — already-basecalled FASTQ given
directly as `input_file` (`--skip_demultiplexing true`, no raw fast5/`--input_path`).
Samplesheet: `/mnt/d/bioinfo-agent/runs/20260813-nanoseq-srr25466853/samplesheet.csv`
**Reference**    `$BIOINFO_REFS/genomes/ECOLI_K12/fasta/genome.fa` (RefSeq ASM584v2, reused from
cutandrun's spike-in reference, not fetched this run); minimap2 index/fai/chrom-sizes all built
in-run (seconds at 4.6 Mb)
**Command**      `/mnt/d/bioinfo-agent/runs/20260813-nanoseq-srr25466853/cmd.sh`
(`--protocol DNA --skip_demultiplexing true --skip_quantification true
--skip_differential_analysis true --skip_fusion_analysis true --skip_modification_analysis true`
— see `plan.md` for full rationale)
**Wall clock**   2m31s (20:59:23 launch → `Execution complete`, single clean shot, no resume
needed)
**Peak disk**    work dir 53 MB; published results 23 MB
**Cores/RAM used**  pool ceiling available (18 cores / 40 GB); peak single-process RAM 1.2 GB
(`QCFASTQ_NANOPLOT_FASTQC:NANOPLOT`) — far under the ceiling
**Results**      `/mnt/d/bioinfo-agent/runs/20260813-nanoseq-srr25466853/results/`
(rsynced from `/work/nxf/20260813-nanoseq-srr25466853/results/`)
**MultiQC**      `.../results/multiqc/minimap2/multiqc_report.html`
**Work dir**     `/work/nxf/20260813-nanoseq-srr25466853/work` — RETAINED, do not delete,
`-resume` depends on it

## QC verdict (measured only — no biological interpretation)

PASS (mechanical pipeline validation and QC signal) — `completed=17 failed=0`, all processes
exit 0.

| sample | metric | value | verdict |
|---|---|---|---|
| SRR25466853 | primary reads mapped (samtools flagstat) | 3,584 / 4,000 (89.60%) | measured |
| SRR25466853 | total mapped incl. secondary/supplementary | 3,987 / 4,403 (90.55%) | measured |
| SRR25466853 | reads on expected contig (samtools idxstats, `NC_000913.3`) | 3,987 mapped / 0 unmapped-elsewhere | consistent — single-contig bacterial genome, all mapped reads on the one contig present |
| SRR25466853 | NanoPlot mean / median read length | 1,214.2 bp / 840.0 bp | measured |
| SRR25466853 | NanoPlot read length N50 | 1,746 bp | measured |
| SRR25466853 | NanoPlot mean read quality | 11.0 | measured |
| SRR25466853 | reads above Q5 / Q7 / Q10 / Q12 | 100.0% / 100.0% / 76.0% / 22.4% | measured |
| SRR25466853 | total bases (NanoPlot) | 4,856,605 | ~1.06x nominal coverage of the 4.64 Mb genome |

Thresholds applied: none formal — first real-sample run for this pipeline on this host (source:
my default, stated in `pipeline-selection.md` §4.14). No sample flagged/excluded.

## Bounded choices I made

- **FASTQ-direct entry point, not raw fast5 + qcat demultiplexing**: avoids GPU-basecalling
  assumptions and qcat/`--input_path`/`--barcode_kit` complexity this host doesn't need for a
  single already-basecalled sample. Undo: supply `--input_path`/`--barcode_kit` and drop
  `--skip_demultiplexing` to exercise the demultiplexing path instead.
- **`--protocol DNA`, no variant calling**: `--call_variants` was left off entirely (medaka/
  DeepVariant/pepper_margin_deepvariant not exercised). Undo: add `--call_variants true` (default
  caller `medaka`) once a variant-calling validation run is wanted — untested territory on this
  host so far.
- ***E. coli*, not human, reference**: the smallest real ENA ONT WGS dataset is bacterial; using
  a human reference against a 4,000-read run would be a scale mismatch. Not a claim about
  organism relevance for any future nanoseq run — a human-scale run needs its own reference
  choice (`GRCh38`/`GRCh38gatk`, both already stocked) and its own real-sample validation.
- **RNA-only subworkflows explicitly skipped** (`--skip_quantification
  --skip_differential_analysis --skip_fusion_analysis --skip_modification_analysis`): harmless
  no-ops for `--protocol DNA` but set explicitly rather than relying on protocol-gating alone,
  matching the CI `test` profile's own practice.

## Known gaps

- No variant-calling validation at all (`--call_variants`, medaka/DeepVariant/
  pepper_margin_deepvariant) — this run validates alignment + QC only.
- No cDNA/directRNA protocol run — quantification (bambu/stringtie2), differential analysis,
  fusion detection (JAFFAL), and RNA-modification detection (xpore/m6anet) are all unexercised.
- No raw fast5/qcat demultiplexing path exercised (only the FASTQ-direct entry point).
- `-stub-run` fails identically on both the CI test profile and this run's own real command at
  `SAMTOOLS_IDXSTATS`/`SAMTOOLS_FLAGSTAT` — waived as a documented upstream module gap (no
  `stub:` block on those two modules), not a defect here; see `pipeline-selection.md` §4.14 and
  `config/pipelines.tsv`.
- No formal QC band for this pipeline on this host yet — first real-sample run, single bacterial
  sample at ~1x coverage. A human-scale, higher-coverage, or multi-sample run has not been
  measured and would likely behave very differently (see `estimates.md`'s floor-not-typical
  caveat).

## Next step for you

Review `results/multiqc/minimap2/multiqc_report.html` for the aggregated NanoPlot/FastQC/
samtools-stats view. If a production run is wanted, the next real decisions are: (1) whether to
validate `--call_variants` (medaka is the lightest caller to try first), and (2) whether to
validate the cDNA/directRNA quantification path, which needs a GTF and a real transcriptome
dataset — neither is set up yet.

No biological interpretation is included, by design.
