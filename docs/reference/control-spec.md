# Control specification

Lookup-only engineering evidence for [architecture](../agent-architecture.md).
State names below describe existing behavior; they are not an implemented state-machine API.

## 1. Container header inspection and re-entry

| State | Input / predicate | Transition / output |
|---|---|---|
| Candidate | Existing BAM/CRAM and intended assay | Read-only, pinned-container header inspection |
| Inspected | `@SQ` names/lengths, `@RG`, sort order; reference manifest and required index | Record reference/sample compatibility; reject ambiguous identity/build |
| Planned | Compatible artifacts and an upstream-supported starting step | Plan records reused artifacts, skipped stages and estimated costs |
| Approved | Researcher accepts scope; full sheet, reference paths and disk checks pass | Preview and pipeline-specific stub gate |
| Runnable | Gate passes, or exact documented upstream failure qualifies for a narrow waiver | Launch pinned command with reuse provenance |

Implementation: [intake protocol](../../skills/bioinfo-analyze/SKILL.md),
[samplesheets](../../skills/bioinfo-analyze/references/samplesheets.md),
[preflight](../../bin/preflight.sh), [reference manifest](../../config/refs.manifest.tsv).
Example: [sarek re-entry](../examples/20260816-sarek-revalidate2/handoff.md).

Header matching is necessary, not sufficient: `SO:coordinate` is a declaration,
contig name/length matching is not a sequence checksum, and matching aggregate
variant counts is not record-level identity. No generic executable BAM identity
attestor is shipped. Re-entry is a recorded agent decision, not an autonomous
header-to-command classifier.

## 2. Work-directory retention

| State | Predicate | Result |
|---|---|---|
| Command received | Hook JSON parses and command matches supported shell/wrapper syntax | Extract cleanup flags and target paths |
| Unconditional deny | Recognized `-with-cleanup`, `cleanup=true`, `nextflow clean`, whole protected root or unresolved protected target | Exit 2; diagnostic; no approved tool execution |
| Per-run check | PID is live or run-specific Nextflow JVM detected | Deny |
| Handoff check | No visible `handoff.md` | Deny |
| Hold check | Handoff modification age below `BIOINFO_WORKDIR_HOLD_DAYS` (default 7) | Deny |
| Eligible | No detected live process, visible handoff, hold elapsed | Allow recognized per-run deletion |

Sources: [guard](../../hooks/guard-workdir.sh),
[hook registration](../../hooks/hooks.json),
[132-case fixture suite](../../hooks/guard-workdir.test.sh).

The hook checks **handoff existence and age**, not its content, researcher sign-off
or successful result synchronization. Those are runbook obligations. Missing
liveness evidence does not prove completion. Parsing failures may fail open;
encoded/wrapped scripts and external terminals bypass this heuristic. A Windows
hook may not see WSL handoff paths. These limitations belong in any experimental
protocol or claim chart; do not describe this as kernel interception or a security boundary.

The plugin registers the hook through `hooks/hooks.json`; `install.ps1` registers
it in the selected configuration directory after must-block/must-allow probes.
Hand-made skill symlinks do not register a hook. Preserve the shell-form command:
on Windows an exec-form `bash` can select the WSL launcher instead of Git Bash,
fail to open the script and leave a non-blocking error.

## 3. Storage placement, detached lifetime and triage

| Observation | Decision / output |
|---|---|
| Work path under `/mnt/*` | Preflight rejects the conventional WSL drvfs placement |
| Available work-disk bytes below 1.5× estimated work GiB, rounded up to whole GiB | Preflight refuses launch; available capacity is never rounded up |
| Actual result filesystem below 1.5× supplied output estimate, or unreadable capacity | Preflight refuses; query `RUNDIR` or its nearest existing ancestor, not the repository mount |
| Approved command in detached tmux | Survives client disconnect; host shutdown still terminates it |
| Latest run/session terminal marker | Triage reports succeeded / failed / cancelled |
| No terminal marker, live PID or run-specific Java head | Triage reports running |
| Neither terminal nor liveness evidence | Triage reports unknown |
| Trace `FAILED`, `ABORTED`, other non-clean rows | Report separately; root-failure candidates exclude collateral aborts |

Sources: [preflight](../../bin/preflight.sh), [runbook](../../skills/bioinfo-analyze/references/runbook.md),
[triage](../../scripts/triage-run.sh), [77-case regression suite](../../scripts/triage-run.test.sh).
The suite checks input checksums before/after diagnostic reads and covers stale,
malformed and unreadable PID fallback, rotated logs, CRLF and JSON control characters.
It is synthetic test evidence, not 77 independent production incidents.

The path heuristic does not detect arbitrary mount locations or remote filesystems.
Result capacity uses the optional third preflight argument in decimal MB; old
two-argument callers receive a warning that output capacity is unchecked.
The execution protocol supplies that estimate. [Preflight fixtures](../../scripts/preflight.test.sh)
cover distinct mounts, absent directories, spaces, symlinks and byte boundaries.
Triage does not repair a run, infer biological correctness or prove causal failure
from a trace alone. [STAR's recorded drvfs FIFO failure](../examples/20260807-rnaseq-testprofile-e/handoff.md)
is a real execution record; it does not establish a general storage speedup.

## 4. Resource control and technical QC

1. Operator measures host/VM CPU and memory, then reserves head-JVM and OS capacity.
2. Environment variables supply `BIOINFO_MAX_CPUS`, `BIOINFO_MAX_MEMORY`, `BIOINFO_MAX_TIME`.
3. [`local.config`](../../config/local.config) sets the local executor pool,
   per-process `resourceLimits` and compatible legacy `params.max_*`.
4. The selected workflow emits metrics; the agent applies assay-specific
   [QC bands](../../skills/bioinfo-analyze/references/qc-interpretation.md).
5. Handoff records PASS/WARN/FAIL, missing metrics and scope changes. It stops at
   technical interpretation; the researcher decides biological meaning.

Host > VM > pool is a sizing constraint, **not an automatic three-level hardware
clamp**. Default limits must be checked on each host. Scheduling limits are not
measured RSS; SGE maxvmem is virtual memory. Missing QC metrics are unknown, never
implicit PASS. See the [STARsolo OOM and recovery record](../examples/20260805-scrnaseq-skin-cd3/handoff.md)
and [completed ChIP-seq with signal FAIL](../examples/20260806-chipseq-vsmc-h3k27me3-smoke/handoff.md).
