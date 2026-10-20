# Run evidence and execution helpers

Lookup only. These helpers use Python 3.10+ / Bash; detached gates also need tmux.
They do not execute a scientific workload during their fixture tests.

## Detached stub gate

Validate the **entire** samplesheet and run preflight first. After plan approval:

```bash
bash "$BIOINFO_HOME/scripts/stub-gate.sh" launch "$RUN" auto -- \
  nextflow run nf-core/rnaseq -r "$REVISION" -params-file "$RUN/stub-params.json" \
  -work-dir "$STUB_WORK" -stub-run
bash "$BIOINFO_HOME/scripts/stub-gate.sh" status "$RUN" auto
```

| Contract | Meaning |
|---|---|
| Full approved samplesheet | Preserve pairing, controls, groups and entry points; no arbitrary first-row sampling. |
| Separate stub work/output paths | Set them in the approved command/params. A module without `stub:` may execute real tools. |
| New label per attempt | Records under `.stub-gates/<label>/` are never overwritten by a retry. |
| Helper-owned log/trace | `nextflow.log`, `trace.txt`, `console.log`, `head.pid`, `exit-code`, `state`. |
| Runtime environment | Forward current contract/TLS/proxy settings; remove stale contract variables in the new session only. |
| `PASS` | Stub command exited 0; does not establish scientific validity or full-run success. |
| `INTERRUPTED` / `UNKNOWN` | Not a pipeline-specific stub waiver. Diagnose and rerun. |

Detachment protects against a caller disconnect; it does **not** reduce task count or
survive an OS/VM shutdown. Full-sheet stub cost remains O(N). Each required auto/concrete
strandedness gate keeps its own label. An owner-tagged `active/` lock refuses concurrent
gates in one run directory. The runner acknowledges readiness before launch is confirmed;
a disconnected launcher cannot release its lock. After a VM shutdown or SIGKILL, confirm
the old process is gone before manually removing that lock and its `owner` file; never
clear it merely because metadata says the run completed.
Preview/help/version flags are refused: their zero exit does not execute the stub gate.

## Pinned upstream repair

```bash
python3 "$BIOINFO_HOME/scripts/apply-pipeline-patch.py" "$NXF_ASSETS/nf-core/cutandrun"
# Explicitly apply only after reviewing the check:
python3 "$BIOINFO_HOME/scripts/apply-pipeline-patch.py" "$NXF_ASSETS/nf-core/cutandrun" --apply
```

[Manifest](../../patches/cutandrun-3.2.2.json) pins commit and before/after SHA256.
Only the two `optional true` output declarations in
`modules/local/for_patch/trimgalore/main.nf` change to `, optional: true`.
Wrong revision, unknown/partial preimage or a symlink target is refused; repeat application
is a no-op. The helper never fetches assets or changes them during bootstrap.

The fixture is the [upstream 3.2.2 module](https://github.com/nf-core/cutandrun/blob/6e1125d4fee4ea7c8b70ed836bb0e92a89e3305f/modules/local/for_patch/trimgalore/main.nf),
under nf-core/cutandrun's [MIT license](https://github.com/nf-core/cutandrun/blob/6e1125d4fee4ea7c8b70ed836bb0e92a89e3305f/LICENSE).
Fixture PASS verifies the bounded edit, not a new Nextflow/container integration run.

## Structured run snapshot

```bash
python3 "$BIOINFO_HOME/scripts/run-meta.py" init "$RUN" \
  --pipeline nf-core/rnaseq --revision "$REVISION" \
  --samplesheet samplesheet.csv --params params.json --command cmd.sh \
  --approval plan.md > "$RUN/run-meta.json"
python3 "$BIOINFO_HOME/scripts/run-meta.py" validate "$RUN/run-meta.json" --check-files
```

The [schema](../../schemas/run-meta.schema.json) records pinned pipeline/engine, relative
evidence paths plus SHA256, execution status, QC verdict and predicted/observed resources
(seconds/bytes; unknown values are `null`). Init prints to stdout and hashes only the
specified small run records. It starts `unknown` / `NOT_ASSESSED`; approval-file presence
does not verify human consent.

Validation rejects unknown fields, duplicate keys, non-finite numbers, invalid types,
escaping paths and inconsistent execution status/exit codes. Status assertions and QC
verdicts and non-null resource metrics require evidence. `--check-files` also verifies
existence, containment and hashes.
The standard-library validator supports this schema's explicit subset; unsupported schema
keywords fail closed. It additionally checks status/QC consistency.

Metadata is an **evidence snapshot**, not live state or cleanup authorization. Inspect
current logs/PIDs with `triage-run.sh`; keep the existing workdir protection gates.
Evidence hashes establish identity, not truth, and do not automate QC judgment.
Do not publish private samplesheets, paths, identifiers or credentials.

```bash
python3 scripts/run-contract.test.py
```
