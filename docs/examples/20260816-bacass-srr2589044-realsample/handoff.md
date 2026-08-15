# Run 20260816-bacass-srr2589044-realsample — nf-core/bacass -r 2.6.1 — COMPLETE

**Inputs**       1 sample, short-read paired-end Illumina WGS (SRR2589044, *E. coli* B str.
                 REL606, 1,107,090 read pairs, 332,127,000 bp, ~72x coverage of the 4.6 Mb
                 genome), samplesheet:
                 `/mnt/d/bioinfo-agent/runs/20260816-bacass-srr2589044-realsample/samplesheet.csv`
**Reference**    none (de novo assembly, no reference genome used; QUAST ran reference-free)
**Command**      `/mnt/d/bioinfo-agent/runs/20260816-bacass-srr2589044-realsample/cmd.sh`
**Wall clock**   8m21s (08:35:01 - 08:43:22)   **Peak disk**  work dir 514 MB, results 102 MB
**Cores/RAM used** clamped to this box's pool: 16 cpu / 18 GB (`config/host.env`)
**Results**      `/mnt/d/bioinfo-agent/runs/20260816-bacass-srr2589044-realsample/results` (101 MB)
                 **MultiQC**  `results/multiqc/multiqc_report.html`
**Work dir**     `/work/nxf/20260816-bacass-srr2589044-realsample/work` — RETAINED, do not
                 delete, `-resume` depends on it

## QC verdict
PASS — `completed=9 failed=0`. `-preview` and `-stub-run` both run on this exact samplesheet
first (`-stub-run` hits the same waived `UNICYCLER` stub bug as the CI fixture, confirming
consistency, not a new finding), then the full run launched via tmux and completed cleanly.

| sample | contigs (QUAST, >=500bp) | N50 | L50 | total length | GC% | BUSCO complete | Prokka CDS |
|---|---|---|---|---|---|---|---|
| SRR2589044-unicycler | 61 | 143,933 bp | 10 | 4,545,618 bp | 50.72% | 100.0% (S:100.0%,D:0.0%,F:0.0%,M:0.0%, n=124) | 4,232 |

Additional measured numbers: largest contig 328,315 bp; auN 169,384.7; N90 46,310 bp / L90 29;
0 N's per 100 kbp. Prokka: 111 contigs (Prokka's own unfiltered contig set, includes short
scaffolds QUAST's >=500bp filter drops), 4,553,928 bases, 5 rRNA, 77 tRNA, 1 tmRNA, 2
repeat_region. fastp: 1,890,006 / 2,214,180 reads passed filter (~85.4%).

Thresholds applied: none pipeline-default or user-stated for a first single-sample validation;
these are the measured numbers themselves, reported without a pass/fail cutoff beyond "the run
completed and produced a coherent assembly+annotation for every stage" (source: my own default
for a procurement validation run, not a QC threshold this repo has established for bacass).
Samples flagged: none.

## Bounded choices I made
- `--assembly_type short --assembler unicycler --annotation_tool prokka --skip_kraken2
  --skip_kmerfinder`, no `--reference_fasta`/`--reference_gff` — lightest real short-read
  assembly+annotation combination, matches the pipeline's own CI test-profile shape exactly.
  Undo: add `--reference_fasta`/`--reference_gff` for QUAST reference comparison, or switch
  `--assembly_type`/`--assembler`/`--annotation_tool` for a different combination.
- `GenomeSize: 4.6m` in the samplesheet — a size hint to Unicycler only, not a reference
  sequence; taken from the published approximate *E. coli* genome size.
- SRR2589044 chosen for small size (~251 MiB) and adequate coverage (~72x), not for any
  biological property of the isolate.

## Known gaps
- Kraken2/KmerFinder contamination screening skipped (no local database in `$BIOINFO_REFS`) —
  this assembly's species/contamination identity was never independently checked by the
  pipeline itself; the input's own ENA metadata states *E. coli* B str. REL606, not verified
  by this run.
- Bakta/DFAST/Liftoff annotation, long-read/hybrid assembly not exercised.
- Only 1 sample run — cohort-scale timing/disk not measured; see `estimates.md` for how this
  scales.

## Next step for you
Review `results/multiqc/multiqc_report.html` and `results/QUAST/report/report.txt` /
`results/Prokka/SRR2589044-unicycler/SRR2589044-unicycler.txt` for the full detail behind the
summary table above.

No biological interpretation is included, by design.
