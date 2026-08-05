#!/usr/bin/env bash
set -euo pipefail

RUNID=20260804-rnaseq-scer-verify
PIPE=nf-core/rnaseq
REV=3.18.0        # from config/pipelines.tsv
RUNDIR=/mnt/d/bioinfo-agent/runs/$RUNID
NXFDIR=/work/nxf/$RUNID

# NXF_SYNTAX_PARSER=v1 — required on this host's installed Nextflow (26.04.6).
# The default v2 config parser rejects local.config's `def X = ...` statements
# mixed with config blocks. Confirmed during the previous sarek and rnaseq runs' preflight.
export NXF_SYNTAX_PARSER=v1

mkdir -p "$NXFDIR/work" "$NXFDIR/results"
cd "$NXFDIR"   # launch dir MUST be ext4: .nextflow/cache lives here, resume depends on it

# --- Verification run for PR #4 (fix/rnaseq-igenomes-alias) ---
# Uses the repo-standard `--genome R64-1-1` COMPACT form (no explicit --fasta/--gtf), which is
# specifically the form that was still vulnerable to nf-core/rnaseq's AWS-iGenomes filename
# heuristic before this PR (config/genomes.config's genomes.R64-1-1.fasta/.gtf now point at the
# build-named ALIAS, not the canonical genome.fa/genes.gtf.gz, so this should resolve safely).
# --igenomes_ignore MUST be on the command line, not in a -c file — see genomes.config section 2.
#
# --star_index false --salmon_index false: DISCOVERED DURING THIS VERIFICATION RUN, separate
# from the PR #4 alias bug. genomes.config's R64-1-1 map unconditionally declares star_index/
# salmon_index (paths not yet on disk -- [!] build). With the --genome compact form those two
# keys are auto-populated as params regardless, and nf-schema's file-must-exist check then fails
# validation before the run starts (confirmed via -stub-run without this override: "the file or
# directory '/refs/genomes/R64-1-1/index/star' does not exist"). Passing bare '' is parsed as
# boolean true by the CLI (wrong type); `false` is what nf-schema accepts to mean "unset, build
# it". This is the compact-form equivalent of genomes.config section 2's documented "first run on
# this host: omit --star_index and --salmon_index" -- omission alone does not work for the
# --genome form since the map itself sets them.
# FOREGROUND, and the session that launches this stays open for the whole run -- see
# agents/bioinfo-tech.md and runbook.md: `nohup ... &` does not survive a WSL session tearing
# down and has previously killed a run silently (no log, no error). A prior invocation of this
# file used nohup; restored to the documented foreground shape.
nextflow -log "$NXFDIR/.nextflow.log" \
  run "$PIPE" \
    -r "$REV" \
    -profile docker \
    -c /mnt/d/bioinfo-agent/config/local.config \
    -c /mnt/d/bioinfo-agent/config/genomes.config \
    --igenomes_ignore \
    --genome         R64-1-1 \
    --star_index     false \
    --salmon_index   false \
    --input          "$RUNDIR/samplesheet.csv" \
    --save_reference \
    --outdir         "$NXFDIR/results" \
    -work-dir        "$NXFDIR/work" \
    -ansi-log false \
    -resume \
  2>&1 | tee "$NXFDIR/nextflow.stdout.log"
echo "EXIT_CODE=${PIPESTATUS[0]}"
