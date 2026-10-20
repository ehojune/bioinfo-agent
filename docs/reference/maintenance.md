# Operations and maintenance reference

Lookup-only commands and history. Start with the [README](../../README.md) for ordinary use.

## Diagnose an installation or run

Run these from the repository in the pipeline user's Linux shell:

```bash
bash bootstrap/05-verify.sh
NXFDIR=/path/to/run
bash scripts/triage-run.sh "$NXFDIR"
bash scripts/triage-run.sh --json "$NXFDIR"
```

`NXFDIR` is the existing run directory containing the launch logs and results, not the
repository directory. Triage reads logs, trace and process evidence without modifying them.
A failed task attempt does not by itself mean the entire run failed; absent evidence means
`unknown`, not `running`. Preserve the work tree before considering `-resume`.

## Long runs and session lifetime

The agent launches long runs in `tmux`; exact commands and exit-status recording belong in
the [runbook](../../skills/bioinfo-analyze/references/runbook.md). Backgrounding with `nohup`
inside an agent turn has lost runs in this repository. `tmux` separates the run from that
turn, but cannot survive a host reboot or an explicit WSL shutdown.

## Plugin cache and version gate

```bash
claude plugin details bioinfo@bioinfo
claude plugin update bioinfo@bioinfo
```

Installed plugins use version-named cache directories. A merged change must also receive a
plugin version bump to reach an existing installation. The 2026-08-10 maintenance record
found the cached 0.1.0 runbook 117 lines behind the checkout; an agent was still following
that older procedure. This is maintenance history, not a benchmark.

[PR #26](https://github.com/ehojune/bioinfo-agent/pull/26) and
[`check-plugin-version.sh`](../../scripts/check-plugin-version.sh) document the correction.
Changes under `skills/`, `agents/`, `hooks/` or `.claude-plugin/` must pass that gate.

## Historical benchmark revisions

The [whole-genome handoff](../examples/20260926-pacbio-hifi-wgs-giab-wholegenome/handoff.md)
records germline results at `48ec463` and somatic results at `f2de95e`. It is not a same-data
rerun of every later pipeline revision. Small-variant accuracy covers HG001–HG007, SV
accuracy HG002, and somatic accuracy the tested HG008 pairs. Invocation flags, truth regions
and metric denominators stay in that record.
