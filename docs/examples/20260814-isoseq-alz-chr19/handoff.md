# Run 20260814-isoseq-alz-chr19 — nf-core/isoseq -r 2.0.0 — COMPLETE WITH CAVEATS

**Inputs**       1 sample, PacBio Iso-Seq raw subreads, `alz` — nf-core/isoseq's own CI subreads
subset (real, non-synthetic 1% subsample of PacBio's public "Alzheimer's Brain Iso-Seq" release,
human chr13/18/19-restricted), `bam`+`pbi` (`entrypoint: isoseq`, default). Samplesheet:
`/mnt/d/bioinfo-agent/runs/20260814-isoseq-alz-chr19/samplesheet.csv`
**Reference**    `$BIOINFO_REFS/genomes/GRCh38_chr1318_19/fasta/genome.fa` (Ensembl GRCh38
release-104, chr19-only slice, fetched this run — new manifest rows, not the existing
chr-prefixed `genomes/GRCh38` build; see `plan.md`). `aligner: minimap2`, no `--gtf` needed;
index built in-run (seconds at this genome size)
**Command**      `/mnt/d/bioinfo-agent/runs/20260814-isoseq-alz-chr19/cmd.sh`
(`entrypoint: isoseq --chunk 5 --aligner minimap2 --capped false` — see `plan.md` for full
rationale, and "Bounded choices" below for the `--chunk` fix mid-procurement)
**Wall clock**   9m49s on the successful `--chunk 5` relaunch (00:28:32→00:38:21,
`completed=38 failed=0`) — **the first launch, at the pipeline's own `--chunk 40` default,
crashed after 19m42s** (00:08:06→00:27:48, `completed=12 failed=1`) — see "Known gaps" below
**Peak disk**    work dir 26 MB (both attempts combined; work-dir retention rule means the
abandoned `--chunk 40` attempt's task dirs are still on disk); published results 3.4 MB (stale
`chunk6`-`chunk40` outputs from the abandoned attempt were removed from the published `results/`
directory — same `--outdir` across both `-resume` attempts — the work dir itself was NOT touched)
**Cores/RAM used**  pool ceiling available (16 cores / 18 GB, this host's actual
`BIOINFO_MAX_CPUS`/`BIOINFO_MAX_MEMORY`); peak single-process RAM 842.5 MB (`MINIMAP2_ALIGN`) —
far under the ceiling
**Results**      `/mnt/d/bioinfo-agent/runs/20260814-isoseq-alz-chr19/results/`
(rsynced from `/work/nxf/20260814-isoseq-alz-chr19/results/`, 3.4 MB)
**MultiQC**      **Not produced — see "Known gaps."** No `*_report.html`/`*_data` anywhere in the
output tree; QC below is read from the pipeline's own per-process report files instead.
**Work dir**     `/work/nxf/20260814-isoseq-alz-chr19/work` — RETAINED, do not delete, `-resume`
depends on it

## QC verdict (measured only — no biological interpretation)

PASS WITH CAVEATS — `completed=38 failed=0` on the final (chunk-corrected) attempt, all processes
exit 0, and the pipeline produced a non-empty gene-model annotation. The caveats are structural
pipeline gaps found this run (no MultiQC report at this pin, in any configuration; the pipeline's
own `--chunk` default crashes on a small input), not anything wrong with this specific sample.

| sample | metric | value | verdict |
|---|---|---|---|
| alz | ZMWs input (PBCCS, summed across 5 chunks) | 531 | measured |
| alz | ZMWs passing CCS filters | 326 (61.4%) | measured |
| alz | ZMWs above all LIMA primer-detection thresholds | 275 / 326 (84.4%) | measured |
| alz | FLNC reads (post `ISOSEQ_REFINE`) | 275 | measured, matches LIMA pass count |
| alz | FLNC reads carrying a polyA tail (post `GSTAMA_POLYACLEANUP`) | 275 / 275 (100%) | measured |
| alz | final merged gene models (`09_GSTAMA_MERGE/alz_gene_report.txt`) | 13 | measured |
| alz | final merged transcript models (`09_GSTAMA_MERGE/alz_trans_report.txt`) | 13 | measured |
| alz | gene-model span | chr19:7,841,503-51,240,015 (Ensembl numbering, no `chr` prefix) | measured |

Thresholds applied: none formal — first real-sample run for this pipeline on this host (source:
my default, stated in `pipeline-selection.md` §4.16). No sample flagged/excluded.

## Bounded choices I made

- **`entrypoint: isoseq` (default, raw-subreads path), not `entrypoint: map`**: `map` needs an
  already fully-processed FLNC `.fa.gz` — the *output* of `entrypoint: isoseq`'s own
  CCS→LIMA→REFINE→POLYACLEANUP chain, not raw CCS/HiFi reads. No public deposit ships one
  directly; producing one externally would mean hand-running the pipeline's own tool chain,
  forbidden by this repo's hard rules. Undo: not applicable — this is the only honest entry point
  for public data, not a scope-narrowing choice.
- **`aligner: minimap2`, not `ultra` (the CI test profile's own choice)**: `ultra` needs a
  sorted+indexed GTF and is markedly heavier to set up for a first validation. Undo: supply
  `--aligner ultra --gtf <path>` — `-stub-run` on that combination hits a waived upstream gap
  (`ULTRA_INDEX`, no `stub:` block — see "Known gaps"), but the real (non-stub) command was not
  tested with `ultra` this procurement.
- **`--chunk 5`, not the pipeline's own default of 40** — added mid-procurement after the first
  launch (at the default) crashed `GSTAMA_MERGE` on 29 empty per-chunk bed files. Matches
  `conf/test.config`'s own value for this identical bam. Undo/generalize: size `--chunk` to the
  input's actual ZMW count for any small dataset; the default is tuned for a full SMRT cell, not
  a CI-scale subset.
- **`--capped false`** (schema-required boolean, no stated default): no dataset metadata
  indicated a capped library prep. A disclosed default, not a measurement. Undo: set `true` if
  the library prep is known to be capped.
- **Real-sample dataset is the pipeline's own CI subreads subset, not an independently-sourced
  SRA/ENA accession**: every independently-sourced candidate checked either lacked the required
  native `subreads.bam`+`.pbi` format (small yeast Iso-Seq runs on ENA are fastq-only) or
  exceeded this repo's ~10 GB silent-download ceiling by ~9× (the pipeline's own full pig
  fixture, `ERR8606831`, 91.3 GB submitted). Full search record in `plan.md`. This dataset is
  itself real, non-synthetic PacBio data, not a synthetic CI-only construct.
- **New reference rows (`genomes/GRCh38_chr1318_19/`), not the existing chr-prefixed
  `genomes/GRCh38` build**: the real-sample reads are restricted to Ensembl-numbered (no `chr`
  prefix) chr13/18/19 sequence; reusing the full UCSC-style hg38 build would silently break
  mapping on the naming mismatch and cost far more mapping time. Undo: not applicable to this
  dataset; a future isoseq run against a different organism/build needs its own reference choice.
- **Stale published outputs from the abandoned `--chunk 40` attempt were removed from
  `results/`** (not from the work dir) before rsyncing to the run record, so the published
  results reflect only the successful `--chunk 5` configuration. This is a cleanup of published
  output only — the work dir's own abandoned-attempt task directories were left untouched, per
  the "never delete/move a work directory" hard rule.

## Known gaps

- **No MultiQC report is ever produced by this pipeline at this pin (2.0.0), in any
  configuration** — a real (non-stub) authoring bug, not a config or flag-choice defect.
  `workflows/isoseq.nf`'s own `MULTIQC(...)` call passes a bare, non-`.collect()`'d
  `channel.empty()` for two of the module's plain `path` inputs (`replace_names`/
  `sample_names`), so the process runs zero times regardless of what every other input channel
  carries. Confirmed by reading `workflows/isoseq.nf` and `modules/nf-core/multiqc/main.nf`
  directly, and empirically on this run (`succeededCount=38`, no `MULTIQC` task anywhere in the
  trace, `multiqc/` in the output tree contains only version YAMLs published by a different
  process). There is no flag that routes around it. QC in this handoff is read from the
  pipeline's own per-process report files instead (`01_PBCCS/*.report.txt`,
  `02_LIMA/*.lima.summary`, `03_ISOSEQ_REFINE/*.filter_summary.report.json`,
  `09_GSTAMA_MERGE/*_gene_report.txt`/`*_trans_report.txt`).
- **`aligner: ultra` was not exercised on the real command this procurement** — only `-stub-run`
  on the CI test data was run with `ultra` (and it hit the waived `ULTRA_INDEX` gap; see
  `config/pipelines.tsv`/`pipeline-selection.md` §4.16/`runbook.md` §4). A real `ultra` run,
  with a real `--gtf`, is unvalidated.
- **`entrypoint: map` was not exercised at all this procurement** — no suitable public FLNC
  input was found or manufactured (see "Bounded choices" above).
- **No CADD/VEP/annotation-style enrichment of the output BED** — isoseq produces a raw
  gene-model annotation, nothing downstream of it (no functional annotation, no comparison
  across samples/conditions — this pipeline has no differential/contrast concept at all).
- **Only 1 sample, 531 ZMWs, 3 chromosomes** — see `estimates.md`'s explicit "floor, not a
  typical-case number" caveat; a full SMRT-cell input or a whole-genome `--fasta` would cost
  substantially more, unmeasured.

## Next step for you

Review the final merged BED (`results/09_GSTAMA_MERGE/alz.bed`, 13 gene models) and the
per-process QC files listed above directly, since no aggregated MultiQC report exists for this
pipeline at this pin. If a production-scale isoseq run is wanted, budget for `--chunk` sized to
the real input's ZMW count (not the pipeline default) and expect no MultiQC report regardless of
configuration.

No biological interpretation is included, by design.
