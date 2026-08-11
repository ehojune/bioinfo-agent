# Run 20260812-taxprofiler-drr027580-realsample — nf-core/taxprofiler -r 2.0.1 — COMPLETE

**Inputs**       1 sample, shotgun metagenome shortread paired-end, samplesheet:
`/mnt/d/bioinfo-agent/runs/20260812-taxprofiler-drr027580-realsample/samplesheet.csv`;
databases: `/mnt/d/bioinfo-agent/runs/20260812-taxprofiler-drr027580-realsample/databases.csv`
**Reference**    Kraken2 "Standard, capped at 8 GB" DB via `$BIOINFO_REFS/db/kraken2/k2_standard_08gb`
(fetched this procurement, not built)
**Command**      `/mnt/d/bioinfo-agent/runs/20260812-taxprofiler-drr027580-realsample/cmd.sh`
**Wall clock**   ~47s (04:56:41 tmux launch to `Pipeline completed successfully`)
**Peak disk**    work dir 9.7 MB, published results 9.4 MB
**Cores/RAM used**  pool ceiling (18 cores / 40 GB) available; actual peak single-process RAM
7.8 GB (`KRAKEN2_KRAKEN2`, DB-load dominated)
**Results**      `/mnt/d/bioinfo-agent/runs/20260812-taxprofiler-drr027580-realsample/results/`
(9.3 MB, rsynced from `/work/nxf/20260812-taxprofiler-drr027580-realsample/results/`,
diff-verified clean)
**MultiQC**      `.../results/multiqc/multiqc_report.html`
**Work dir**     `/work/nxf/20260812-taxprofiler-drr027580-realsample/work` — RETAINED, do not
delete, `-resume` depends on it

## QC verdict

PASS (mechanical pipeline validation) — `completed=3 failed=0 cached=0`. All three tasks for
this 1-sample/1-tool/no-QC/no-hostremoval configuration (`FASTQC`, `KRAKEN2_KRAKEN2`,
`MULTIQC`) completed exit 0.

| sample | reads (pairs) | tool | % unclassified | verdict |
|---|---|---|---|---|
| DRR027580 | 436,115 | kraken2 (k2standard08gb) | 99.07% | PASS (mechanical) — real classification occurred (bacterial hits down to species level, e.g. *Saccharopolyspora* spp.), no biological read on whether 99.07% unclassified is itself good or bad for this sample type |

Thresholds applied: none formal — first real-sample run for this pipeline on this host (source:
my default, stated in `pipeline-selection.md` §4.12 as establishing a floor, not a QC band).
Samples flagged: none excluded. **The high unclassified fraction is not itself flagged as a
defect** — the identical reads assembled to only 74 short contigs in this same sample's mag
real-sample run (`runs/20260812-mag-drr027580-realsample/`), consistent with genuinely
shallow/degraded input rather than a Kraken2 or database problem. No biological interpretation
of what the sample actually is offered here.

## Bounded choices I made

- **Sample reuse**: DRR027580 reused from the mag procurement's own real-sample validation
  (same ENA "fossil metagenome" run, chosen there for small download size, not relevance) to
  avoid downloading the same bytes twice. Not a claim of study relevance for taxprofiler either.
  Undo: re-download any other ENA WGS+METAGENOMIC+ILLUMINA+PAIRED run and point the samplesheet
  at it instead.
- **Single-tool procurement (Kraken2 only)**: taxprofiler supports 14 profilers; this
  procurement stocks and exercises only Kraken2, deliberately, per the task's "lightest
  combination first" instruction. Undo/extend: add a `--databases` row + `--run_<tool> true`
  for any other profiler, and a `config/refs.manifest.tsv fetch` row for its database.
- **`db/kraken2/k2_standard_08gb` (5.96 GB download) over a larger Kraken2 build**: chosen to
  stay under the ~10 GB no-ask download threshold. Coarser taxonomic resolution than a full
  `k2_core_nt`-scale build (~150 GB, not fetched). Undo: fetch a bigger `k2_*` tarball from
  `https://benlangmead.github.io/aws-indexes/k2` and add a new manifest row / databases.csv row
  — needs explicit approval given the size.
- **No host removal, no read QC/complexity filtering enabled** for this validation run, to
  isolate Kraken2's own behaviour. Undo: set `--perform_shortread_qc true` and, if the sample
  turns out to be host-associated, `--perform_shortread_hostremoval true --hostremoval_reference
  <path>`.

## Known gaps

- No formal QC band for percent-classified — this is the first real-sample run for this
  pipeline on this host (see `pipeline-selection.md` §4.12).
- Only Kraken2 exercised against real data; the other 13 profilers are only proven against the
  CI test-profile fixture databases (`runs/20260812-taxprofiler-testprofile-procurement/`), not
  against a real sample.
- No host-associated sample tested — host-removal branch (`--perform_shortread_hostremoval`)
  is schema-wired and stub-tested via the CI fixture but not exercised against real data here.

## Next step for you

Review `results/kraken2/k2standard08gb/DRR027580_DRR027580_k2standard08gb.kraken2.kraken2.report.txt`
and `results/multiqc/multiqc_report.html` if you want to see the raw classification. If a
production run is wanted, decide which additional profiler(s)/database(s) to stock (each is a
new manifest row and, for anything over ~10 GB, needs your approval first) and whether host
removal should be turned on for the sample type in question.

No biological interpretation is included, by design.
