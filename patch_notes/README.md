# Patch notes

Notable project changes, newest first. Detailed evidence belongs in
[docs/reference](../docs/reference/README.md).

## 2026-10-29

| Change | Evidence |
|---|---|
| Add descriptive text headings to Korean and English READMEs for Claude Code, Nextflow and nf-core discovery | [README](../README.md), [English](../README.en.md) |

## 2026-10-21

| Change | Evidence |
|---|---|
| Add Bio Research as a direct baseline; revise publication/filing gates and scope a selective LabHQ trial | [#76](https://github.com/ehojune/bioinfo-agent/issues/76), [source audit](../docs/reference/bio-research.md) |

## 2026-10-20

| Change | Evidence |
|---|---|
| Distinguish failed/aborted tasks; recover live-run detection after stale PID | [#63](https://github.com/ehojune/bioinfo-agent/pull/63), 77 triage + 132 guard tests |
| Preserve beginner narratives; update 19 nf-core + local PacBio inventory and separate maintenance docs | [#64](https://github.com/ehojune/bioinfo-agent/pull/64) |
| Add detached stub gates, bounded cutandrun repair and structured run evidence | [#71](https://github.com/ehojune/bioinfo-agent/pull/71) |
| Route to per-pipeline cards and active host configuration | [#72](https://github.com/ehojune/bioinfo-agent/pull/72) |
| Check the actual result filesystem; replace comment-count merging with reminders | [#72](https://github.com/ehojune/bioinfo-agent/pull/72), [#73](https://github.com/ehojune/bioinfo-agent/pull/73) |
| Compare work capacity in bytes to prevent rounded-up free space from passing | [#75](https://github.com/ehojune/bioinfo-agent/pull/75), 18 preflight tests |
| Add reviewer checks, evidence tables and control states; correct two literature identifiers | [#74](https://github.com/ehojune/bioinfo-agent/pull/74), [one-month priorities](../docs/priorities.md) |
