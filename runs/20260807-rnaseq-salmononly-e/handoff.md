# 20260807-rnaseq-salmononly-e — handoff

**nf-core/rnaseq 3.18.0**, `-profile test,docker`, `--skip_alignment --pseudo_aligner salmon`.
Completed successfully. Work dir and outputs on `/mnt/e` (drvfs), deliberately — see below.

## Why this run existed

Not to analyse anything. To find out whether **any** pipeline can complete while the distro's
VHDX sits on a full C:, since `/work` (ext4) can only grow ~2.5 GB before Windows runs out.

## What it established

| path | on drvfs |
|---|---|
| STAR (`--aligner star_salmon`, the default) | **impossible** — `could not create FIFO file … Windows partitions FAT, NTFS` |
| salmon (`--skip_alignment --pseudo_aligner salmon`) | **works** — completed, 0 FIFO errors |

The repo justifies its ext4 rule as speed ("5–10× slower") in eight places. That understates it:
the alignment path does not run at all on drvfs. Documented in this PR.

## Verdict

**The pipeline PASSES. The data is a toy and is not being judged.**

Metrics against `references/qc-interpretation.md`:

| sample | reads | salmon mapping | library |
|---|---|---|---|
| RAP1_IAA_30M_REP1 | 49,591 | 80.99% | ISR |
| RAP1_UNINDUCED_REP1 | 48,567 | 80.95% | SR |
| RAP1_UNINDUCED_REP2 | 97,654 | 80.78% | SR |
| WT_REP1 | 99,227 | 79.88% | ISR |
| WT_REP2 | 49,551 | 79.81% | ISR |

- **Salmon mapping rate**: threshold ≥70% PASS. All five at 79.8–81.0% → **PASS**.
- **Depth**: threshold ≥25 M PASS, <10 M FAIL. All five at 48–99 K → nominally FAIL.
  This is nf-core's subsampled test data; the depth row does not apply and reporting it as a
  sample failure would be a misreading. Stated rather than silently dropped.
- Compatible fragment ratio 100%, strand mapping bias 0.0 across all five.

## Outputs

```
/mnt/e/nxf/20260807-rnaseq-salmononly-e/results/     37 MB
  multiqc/multiqc_report.html
  salmon/salmon.merged.gene_counts.tsv               (+ length_scaled, + .rds)
  fastqc/  trimgalore/  fq_lint/  bbsplit/  pipeline_info/
work: 136 MB
```

C: free went 2.50 → 2.45 GB across the whole run — the point of putting it on E:.

## What this does NOT clear

A real run. 42× human WGS through sarek needs the alignment path, needs ext4, and needs hundreds
of GB. None of that is available until C: has room. The blocker is the VHDX location, not the
pipeline.
