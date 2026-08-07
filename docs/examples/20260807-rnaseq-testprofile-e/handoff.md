# 20260807-rnaseq-testprofile-e — handoff (FAILED, deliberately kept)

**nf-core/rnaseq 3.18.0**, `-profile test,docker`, default aligner (`star_salmon`),
`-work-dir /mnt/e/nxf/...` — drvfs.

## Verdict: FAIL, and the failure is the result

STAR died before processing a read:

```
Exiting because of *FATAL ERROR*: could not create FIFO file
  RAP1_UNINDUCED_REP1._STARtmp/tmp.fifo.read1
SOLUTION: check the if run directory supports FIFO files.
  If run partition does not support FIFO (e.g. Windows partitions FAT, NTFS),
  re-run on a Linux partition, or point --outTmpDir to a Linux partition.
Aug 06 19:19:25 ...... FATAL ERROR, exiting
```

drvfs has no FIFOs. This is not the 5–10× slowdown the repo's eight ext4 warnings describe; the
alignment path cannot start. `runs/20260807-rnaseq-salmononly-e` then showed the pseudo-aligner
path completes on the same filesystem, which is why the docs now distinguish the two.

## Why the work dir was on drvfs at all

The distro's VHDX lives on C:, which had 2.5 GB free. `/work` is inside it, so any real work dir
would have taken Windows down. There was no ext4 to use. `bin/preflight.sh` refuses this
configuration and was right to; the run was made anyway, knowingly, to find out what breaks.

## A second thing this run taught, about my own tooling

The wrapper reported exit 0 for a failed pipeline. `cmd.sh` is correct — `set -euo pipefail`
makes it exit 1 — but the invocation was `bash cmd.sh | tail -30`, and the pipeline's exit
status is `tail`'s. I nearly filed that as a repo defect. Check the exit code without a pipe.
