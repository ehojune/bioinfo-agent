# Worked examples

This directory contains **26 archived handoff documents** (2026-10-20): real data,
test profiles, slices, resumed attempts and deliberately retained failures.
They are historical reports, not 26 independent accuracy benchmarks or current-release reruns.

| Start with | What it shows |
|---|---|
| [Small-genome RNA-seq](20260804-rnaseq-scer-verify/handoff.md) | Plan, gates, outputs and measured resources |
| [Failed STAR run](20260807-rnaseq-testprofile-e/handoff.md) | drvfs FIFO failure |
| [Sarek re-entry](20260816-sarek-revalidate2/handoff.md) | Reused alignment, scoped calling and provenance limits |
| [ChIP-seq QC FAIL](20260806-chipseq-vsmc-h3k27me3-smoke/handoff.md) | Completed execution is distinct from acceptable signal |
| [PacBio whole-genome record](20260926-pacbio-hifi-wgs-giab-wholegenome/handoff.md) | Versioned truth-set results and their denominators |

Find the remaining pipelines and validation levels in the
[evidence tables](../reference/evidence-tables.md). Browse each example directory for
its retained plan, command and samplesheet; some historical exports are incomplete.

New user runs belong in gitignored `runs/`, not here. Publish a reviewed, sanitized
example only after checking data permissions and provenance.
