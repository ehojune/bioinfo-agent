# Run plan — 20260816-methylseq-revalidate

## What / why

Re-verify `nf-core/methylseq -r 3.0.0` (pin: `config/pipelines.tsv`) still runs cleanly against
this repo's *current* shared infrastructure, after 8 further pipeline procurements
(ampliseq, mag, taxprofiler, raredisease, nanoseq, rnasplice, isoseq, bacass) each touched
`scripts/check-samplesheet.sh`, `config/refs.manifest.tsv`, and the skill's `runbook.md`/`SKILL.md`.
This is a confirmation, not new stocking — no design decisions are re-litigated, no upgrade off
3.0.0 is being considered (newer revisions 4.0.0/4.1.0/4.2.0 exist upstream per `nextflow info
nf-core/methylseq`, out of scope here).

Precedent: `runs/20260805-methylseq-sle-rrbs-smoke/` (mirrored at
`docs/examples/20260805-methylseq-sle-rrbs-smoke/`) — first and only prior methylseq run on this
host. `--aligner bismark --rrbs`, GRCh38, 2 real RRBS samples (PRJNA484966, HC660_SM/SLE497_SM),
PASS WITH CAVEATS. Bismark index was built that run but **never promoted** to `$BIOINFO_REFS`
(still `[!] build` in `refs.manifest.tsv` today, confirmed this session) — it landed in that run's
own `results/bismark/reference_genome/` (18 GB) and that run's `/work/nxf/.../work/` (17 GB) is
still intact on disk (confirmed `du -sh`, 36 GB combined, both untouched since 2026-08-06).
`bwameth` index: still an undeclared-build gap too, unchanged, not needed here (bismark, not
bwameth, is the pipeline default and what RRBS uses).

## Scope decision (bounded choice, stated explicitly)

Per the task's own proportionality guidance: do **not** launch a fresh WGS-scale WGBS run (8-45 h
per `estimates.md`) just to confirm the pin still works. Three checks, escalating, per
`new-pipeline.md` §2.4:

1. `nextflow config` / `--help` against the live 3.0.0 clone — confirms schema/param names have not
   silently drifted and that shared config (`local.config`, `genomes.config`) still merges cleanly.
2. `-stub-run` on `-profile test,docker` — exercises process wiring against the pipeline's own tiny
   CI fixture (not our real data), cheap and fast.
3. **Full non-stub `-profile test,doc300ker` run — the gate, not skipped.** Uses the pipeline's
   built-in CI test data (small, synthetic, downloaded by the pipeline itself, not from this repo's
   own ~10 GB budget). Confirms the pipeline actually executes end-to-end under Docker on this host
   right now, independent of our own reference store.
4. **Real-sample re-check**: reuse the existing RRBS FASTQs at
   `/work/rawdata/20260805-methylseq-sle-rrbs-prep/` (still on disk, MD5/read-count verified in the
   original run's SOURCE.md, no re-download) and re-launch the *original* `cmd.sh`/samplesheet
   **with `-resume` against the original run's own work dir**
   (`/work/nxf/20260805-methylseq-sle-rrbs-smoke/work/`, intact). This is the lightest option that
   is still genuine "real sample" evidence: it does not silently trust old numbers (the QC verdict
   below is freshly computed from this session's own MultiQC/bismark_summary output, not copied),
   but with a matching cache it should short-circuit the ~1h9m bismark-index build and most of the
   per-sample alignment, so it mainly re-exercises exactly the part that could have broken —
   config merging, container resolution, samplesheet validation, and the post-alignment
   methylation-extraction/dedup-skip/reporting chain — against the current repo state. A `-resume`
   miss (full re-run) is possible if any of the 8 intervening procurements' shared-file edits
   touched something that invalidates Nextflow's cache keys (e.g. `local.config`); if that happens
   it is itself a finding, not a silent cost — reported in the handoff either way.
   This is the same run shape/scale as the precedent (identical revision, aligner, samples,
   reference, entry point), so a full from-scratch estimate is not needed; on a cache hit this is
   minutes, not hours.

## Repo/infrastructure re-checks (read-only, done during intake, not re-stated)

- `scripts/check-samplesheet.sh --pipeline methylseq`: branch unchanged —
  `methylseq|scrnaseq) REQ='sample fastq_1' ;;` — still matches methylseq 3.0.0's
  `schema_input.json` (`sample`+`fastq_1` required, `fastq_2`/`genome` optional). None of the 8
  later pipelines' additions to this file's `case` block altered the methylseq branch itself
  (confirmed by reading the full case statement — each later pipeline added its own new arm).
- `config/refs.manifest.tsv`: `genomes/GRCh38/index/bismark/` and `.../bwameth/` rows unchanged,
  both still `build` (not built/promoted). No later procurement touched these rows.
- `config/genomes.config` GRCh38 block: the `bismark`/`bismark_hisat2`/`bwameth`/`fasta_index` key
  fix from PR #13 (2026-08-05) is still present, with its own documented caveat that the compact
  `--genome GRCh38 --igenomes_ignore` form does not reliably discover a promoted bismark index
  (root cause not isolated at the time). This run continues using the explicit `--fasta`/
  `--save_reference` form from the precedent, so that caveat does not block this re-check; it is
  restated as a known gap, not re-investigated (out of scope for a revalidation).

## Estimate

| item | time | disk |
|---|---|---|
| `nextflow config`/`--help` | <2 min | 0 |
| `-stub-run`, `-profile test,docker` | <5 min | <1 GB |
| full `-profile test,docker` run (CI fixture, tiny) | 10-20 min | 2-4 GB (container pulls mostly cached already) |
| real-sample resume (cache hit expected) | 10-30 min | <2 GB new (mostly reads from existing 36 GB work/results, already on disk) |
| real-sample resume (cache MISS, worst case: full re-run) | up to ~1h45m (matches precedent's measured wall clock) | up to ~37 GB (already have the headroom; not double-counted since old work dir is reused, not duplicated) |

**Total: well under 1 h expected, worst-case (full cache miss on real-sample step) ~2 h. Both far
under the 24 h approval line.** Free disk 156 GB on the single ext4 filesystem (`/`, `/work`,
`/refs` all `/dev/sdd`) — 1.5x guardrail against the worst case (~37 GB) is ~56 GB, comfortably
covered.

## What happens after

- Steps 1-3 (§2.4 checks) run first, against the CI test profile only — no real data touched yet.
- Step 4 (real-sample resume) launched via `tmux` per `runbook.md` §5, even though it is expected
  to be short — mandatory regardless of expected duration.
- Fresh QC verdict computed from this session's own output (bismark summary + MultiQC), compared
  against the precedent's numbers for consistency, not copied.
- If everything is clean: curate `plan.md`/`handoff.md`/`cmd.sh` (no `results/`) into
  `docs/examples/20260816-methylseq-revalidate/`, commit on a branch, optional lightweight PR
  (sarek-revalidate PR #30 precedent) — not obligatory if nothing needed fixing.
- If anything is actually broken by the intervening 8 procurements' shared edits: fix it, document
  it here as an addendum, and that fix gets its own PR with the normal Codex review loop.
