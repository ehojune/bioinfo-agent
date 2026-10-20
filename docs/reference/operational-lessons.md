# Operational lessons carried into the contract

Lookup-only synthesis for #68. The local source buffer remains private and intact;
this document does not claim that an external personal archive was updated.

| Lesson | Durable rule / evidence |
|---|---|
| Stub work grows with sample count and can outlive the caller | Validate the full sheet, detach the full gate, record exit state. Interruption never qualifies as an upstream waiver. [Helper contract](run-contract.md) |
| Reusable Salmon index avoids rebuilding | Confirm reference/index provenance, set the explicit index parameter and omit unneeded `save_reference`. [rnaseq card](../../skills/bioinfo-analyze/references/pipelines/rnaseq.md) |
| PR comments must not authorize merging | Trusted comments may trigger a reminder; comment counts and timeouts never merge a PR. [Workflow](../../.github/workflows/pr-comment-monitor.yml) |
| Repeated FASTQ scans can dominate slow-storage runs | Compare I/O cost and required QC before an approved `skip_fastqc` / `skip_linting` change. Preserve fastp/Salmon metrics and disclose missing QC; never auto-skip by sample count alone. [#68](https://github.com/ehojune/bioinfo-agent/issues/68) |
| Trace columns drift | Parse by header names; keep aborted siblings distinct from failed tasks. [Triage](../../scripts/triage-run.sh) |
| Read-only promises need tests | Hash fixtures before and after diagnosis. [Regression suite](../../scripts/triage-run.test.sh) |
| No terminal marker is not “running” | Require live head evidence; otherwise report unknown. [Triage fixtures](../../scripts/fixtures/triage-run/) |

The issue also proposes numerical cohort estimates and selective interrupted
download recovery. Those are not the same seven source-buffer entries.
Do not copy their numbers into default estimates without a trace/plan bundle.
Resume downloads only with the expected URL, size and checksum; never label a
partial file complete from its filename alone. [Evidence status](evidence-tables.md).

The original cutandrun patch target in #68 was incorrect. The repair is in
`modules/local/for_patch/trimgalore/main.nf`, pinned by revision and whole-file
before/after hashes in [the patch manifest](../../patches/cutandrun-3.2.2.json).
