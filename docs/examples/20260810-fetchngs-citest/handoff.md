# Run 20260810-fetchngs-citest — nf-core/fetchngs -r 1.12.0 — COMPLETE

**Inputs**       10 accessions (SRR/ERR/DRR run ids, one GSM, one GSE) — nf-core's own official
CI smoke-test fixture for this pin, reused verbatim rather than invented (see plan.md). Expanded
to 14 underlying sequencing runs / 11 SRA experiments at resolve time (re-counted directly from
`results/fastq/` and `results/samplesheet/samplesheet.csv` for this correction — the number
first reported here was wrong, see the git history on this file). Samplesheet (accession list,
headerless): `/mnt/d/bioinfo-agent/runs/20260810-fetchngs-citest/samplesheet.csv`
**Reference**    none — fetchngs touches no genome (confirmed against `--help`, no `--genome`/
`--fasta` param exists)
**Command**      `/mnt/d/bioinfo-agent/runs/20260810-fetchngs-citest/cmd.sh`
**Wall clock**   ~11 min total (11:17–11:28), but almost all of it happened during what was meant
to be the *stub* run — see Known gaps, first bullet. The final real `cmd.sh` launch itself took
26 s because everything came back `CACHED` from that stub run.
**Peak disk**    939 MB downloaded FASTQ + metadata/samplesheet/reports (~1 GB total) on ext4
**Cores/RAM used** default pool (18 cpu / 40 GB ceiling); this pipeline is network-bound, not
compute-bound — actual usage per task ~1 cpu / <30 MB RSS (see trace)
**Results**      `/work/nxf/20260810-fetchngs-citest/results/` (fastq/, metadata/, samplesheet/,
custom/, pipeline_info/) — left on ext4, not rsynced into the NTFS run record (large binary
FASTQ; run record stays text-only per the environment contract)
**MultiQC**      none — fetchngs does not emit one (confirmed, matches
`references/qc-interpretation.md`); verified by checksum + row count instead, see below
**Work dir**     `/work/nxf/20260810-fetchngs-citest/work/` (+ `stub-work/`) — RETAINED, do not
delete, `-resume` depends on it

## QC verdict

**PASS.** All 10 input accessions resolved; 0 failed processes across both the (accidentally
real) stub run and the real launch (53 stub-run tasks, 15 real-run tasks + 38 cached, 0 failed
anywhere). Verified by checksum + row count per `qc-interpretation.md`'s fetchngs row, not by
opening file contents:

| Check | Expected | Measured | Verdict |
|---|---|---|---|
| Input accessions | 10 | 10 (`metadata/*.runinfo_ftp.tsv` = 10 files, one per input line) | PASS |
| FASTQ files | one per run × PE/SE | 22 files (6 SE + 8 PE pairs = 14 runs) | PASS |
| ENA-supplied md5 (FTP-sourced files only) | all OK | 17/17 `md5sum -c` OK, 0 FAILED | PASS |
| Downstream samplesheet rows | one per underlying run (not per experiment — see GSM row below) | 14 rows / 11 distinct experiment (SRX/ERX/DRX) ids; `id_mappings.csv` agrees, 14 rows | PASS |
| GSM4907283 → runs | — | resolved to experiment SRX9504942, 4 underlying paired-end runs (SRR13055517–520), all 4 kept as separate samplesheet rows, not collapsed | PASS — matches samplesheets.md's warning that GEO-derived samples are "occasionally non-unique across runs of the same biosample" |
| GSE214215 → runs | — | resolved to 2 experiments (SRX17709227, SRX17709228), single-end, 447 MB and 530 MB respectively | PASS |
| SRR14593545 / SRR14709033 (no ENA FTP path, sratools fallback) | fallback works | downloaded via `SRATOOLS_PREFETCH`+`FASTERQDUMP`, 0 exit, but files are 150–473 bytes — essentially empty reads | Flagging, not failing: consistent with these being subsampled-to-near-nothing CI fixtures (nf-core picks minimal accessions on purpose for GH Actions runtime/disk budgets), not a pipeline defect. Not independently confirmed against the original SRA record — say so rather than guess. |

Thresholds applied: pipeline-defined success (exit 0, all outputs present) + independent
checksum verification. Source: `qc-interpretation.md`'s fetchngs row ("verify by checksum + row
count") — no other band exists for this pipeline.

Samples flagged: SRR14593545, SRR14709033 — near-empty FASTQ (see table). Not excluded; that is
your call, and it likely reflects the CI fixture's intentional design, not a download failure.

## Bounded choices I made

- Reused nf-core's own CI accession list (`test.config` → `sra_ids_test.csv` at this pin) rather
  than picking accessions myself, so the first local run of this pipeline exercises the same
  accession-family mix nf-core's own CI already validates. Undo: rerun with any other accession
  list — the pipeline and this run's plumbing are unaffected either way.
- `--nf_core_pipeline rnaseq --nf_core_rnaseq_strandedness auto` — added purely to exercise the
  downstream-samplesheet-generation code path (the most GEO-metadata-fragile part of fetchngs).
  No rnaseq run was launched. Undo: drop the flag; it changes nothing about the FASTQ downloads.
- `--download_method ftp` (pipeline default) — untested here whether `sratools`/`aspera` behave
  differently; ftp is what ran, and the two accessions ENA had no FTP path for fell back to
  `sratools` automatically, which is the pipeline's own documented behavior, not a choice I made.

## Known gaps

- **`-stub-run` is not cheap for fetchngs and the runbook does not say so.** `modules/local/
  sra_fastq_ftp/main.nf` and the `nf-core/sratools/prefetch` and `/fasterqdump` modules define no
  `stub:` block, so under Nextflow's documented fallback, `-stub-run` executed their real
  `script:` — i.e. the "stub" run for this smoke test genuinely downloaded all 939 MB (11:20:16–
  11:27:34, ~7m18s) before the "real" launch ran at all (and then trivially reused it via
  `-resume`/cache, 26 s). For a large accession list, following runbook.md section 4's mandatory
  stub-run step as written would silently perform the full download under the belief that it's a
  free wiring check — filed as a PR against `references/runbook.md` / `references/pipeline-
  selection.md` (see below), not fixed by working around it quietly. That reuse-on-real-launch
  behavior was itself an accident of leaving `-work-dir` pointed at the stub's tree rather than
  the isolated, deleted-after `$STUBROOT` `runbook.md` §4 otherwise mandates — following the
  documented default would have downloaded the same 939 MB a second time. See the PR discussion
  (Codex round 4) for the corrected guidance now in `pipeline-selection.md` §4.3.
- This handoff originally reported 15 underlying sequencing runs / 13 SRA experiments; re-counted
  directly from `results/fastq/` and `results/samplesheet/samplesheet.csv` during PR review and
  corrected to the true 14 runs / 11 experiments (see the numbers above and in the QC table).
  Noting the correction here rather than silently editing history.
- `bin/preflight.sh`'s `== samplesheet ==` section and `scripts/check-samplesheet.sh`'s file-
  hygiene section both treat samplesheet line 1 as a header even for `fetchngs`'s headerless
  accession list — reported "9 data rows" / "header: SRR9984183" against an actual 10-accession
  file. Off-by-one only, not a launch blocker (fetchngs's own required-column check is already
  correctly skipped), but misleading. Filed in the same PR.
- `references/samplesheets.md`'s UNVERIFIED note on header tolerance is now resolved: confirmed
  via `subworkflows/local/utils_nfcore_fetchngs_pipeline/main.nf`'s `isSraId()` that a header row
  is not tolerated (it would raise "Mixture of ids provided via --input" and abort before any
  download, since a literal `id`/`sample` line does not match the accession regex). Not
  re-confirmed by actually triggering that failure live — the source proof was considered
  sufficient to avoid a needless failing run.
- `references/pipeline-selection.md`'s UNVERIFIED note on GSE/GSM handling is now resolved: both
  accession types work correctly at 1.12.0 and expand to the right per-run granularity (see QC
  table above).
- SRR14593545 / SRR14709033 near-empty FASTQ not independently traced back to the original SRA
  record to confirm it's intentional subsampling rather than an ENA-side gap — flagged, not
  chased further; out of scope for "does fetchngs itself run correctly."

## Next step for you

Review `/work/nxf/20260810-fetchngs-citest/results/samplesheet/samplesheet.csv` and
`id_mappings.csv` if you want to see the auto-generated rnaseq-chaining output firsthand.
Otherwise nothing further needed — this run's only purpose was establishing the first fetchngs
precedent on this host; the doc/script gaps found are being fixed via PR (see final report).

No biological interpretation is included, by design.
