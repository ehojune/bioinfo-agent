# Plan — 20260816-bacass-srr2589044-realsample

## Pipeline
nf-core/bacass -r 2.6.1 (see `runs/20260816-bacass-testprofile-procurement/plan.md` for the
full procurement writeup: age/star/archive check, mag/sarek contrast, schema-drift check,
scope rationale, container/resource checks). This is the second stage of the mandatory
scale-up sequence (`new-pipeline.md` §2.8): CI test profile already passed clean
(`-preview`, `-stub-run` waived on `UNICYCLER` — 9th documented departure, upstream module
authoring bug — and the full non-stub `-profile test,docker` gate completed cleanly,
completed=17 failed=0, wall clock ~13m). This run is the required "one real sample, timed
and measured" step before any extrapolation.

## Sample count
1 sample.

## Real sample
`SRR2589044` (ENA/SRA), *Escherichia coli* B str. REL606, Illumina HiSeq 2500, paired-end WGS.
Sizes disclosed and downloaded (measured, matches the ENA filereport exactly):
`SRR2589044_1.fastq.gz` 129,138,426 B, `SRR2589044_2.fastq.gz` 134,214,678 B (263,353,104 B /
~251 MiB total). 1,107,090 read pairs, 332,127,000 bp, ≈72x coverage of the ~4.6 Mb genome.
Well under the ~10 GB silent-download ceiling — fetched via plain `curl` from the ENA FTP URLs,
no approval needed. Staged on ext4 at `/work/staging/bacass-realsample/` (not `/mnt/d` — the
pipeline reads these sequentially but placing them on ext4 avoids any drvfs latency on the
input stage step regardless).

## Scope (same as the procurement plan)
`--assembly_type short --assembler unicycler --annotation_tool prokka --skip_kraken2
--skip_kmerfinder`, no `--reference_fasta`/`--reference_gff` (QUAST reference-free). GenomeSize
supplied as `4.6m` (published *E. coli* genome size, used by Unicycler as a size hint only —
not a reference sequence, does not change the "de novo, no reference needed" scope).

## Reference genomes
None. De novo assembly needs no reference; QUAST runs reference-free.

## Disk
`/work` had 172 GB free as of the test-profile run moments earlier; this real-sample input is
~251 MiB and the test-profile run's own peak work-dir was 1.3 GB for two ~1M-read fixture
samples combined — a single 1.1M-read-pair real sample at comparable depth is expected to stay
in the same order of magnitude, well under 5 GB. 1.5x margin trivially satisfied.

## Estimate
Test-profile run (two ~1M-read fixture samples, resourceLimits clamped to 4 cpu/15 GB by
`conf/test.config` itself) took ~13 minutes wall clock end to end including container pulls.
This real sample is a single sample at ~1.1M read pairs (comparable order of magnitude to each
CI fixture sample) but run under this box's full pool (16 cpu/18 GB, not the CI profile's own
tighter 4/15 clamp) — expect single-digit to low tens of minutes, nowhere near the 24 h
threshold. No escalation needed.

## Bounded choices
- SRR2589044 chosen for small size (~251 MiB) and adequate coverage (~72x) for a first
  validation, not for any biological property of the isolate.
- GenomeSize `4.6m` taken from the published *E. coli* genome size (a size-hint parameter to
  Unicycler, not a reference sequence).
- Same scope/skip choices as the procurement plan (see above).

## Next steps
`-preview` and `-stub-run` on this exact samplesheet/params (already validated on the CI
fixture's identical flag set; re-checking on this sheet before launch per SKILL.md step 4),
then launch via tmux, monitor, QC verdict from QUAST/BUSCO/Prokka/MultiQC — no biological
interpretation.
