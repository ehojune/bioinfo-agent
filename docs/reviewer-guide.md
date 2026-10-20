# Five-minute review

Start with [what the agent does](../README.en.md), then inspect the
[four control boundaries](agent-architecture.md). Historical evidence and its
limits are in [Tables 1–3](reference/evidence-tables.md).

## No-data check

In a normal Linux checkout with Bash, Python 3.10+, standard GNU utilities and tmux:

```bash
git rev-parse HEAD
bash hooks/guard-workdir.test.sh
bash scripts/triage-run.test.sh
bash scripts/preflight.test.sh
python3 scripts/run-contract.test.py
python3 scripts/check-pipeline-routing.py
bash scripts/check-plugin-version.sh origin/main
bash scripts/triage-run.sh --json scripts/fixtures/triage-run/hard-stopped
```

These use synthetic fixtures and fake Nextflow. No FASTQ, reference genome, Docker,
Nextflow installation or scientific download is required. Expect guard/triage
tests to pass, the metadata/patch/detachment tests to pass, and hard-stopped triage
to return `unknown`. If tmux is absent, detached test coverage is skipped locally;
install it or use the CI result before claiming the complete suite passed.

The plugin gate needs a resolvable base ref; a `SKIP` message is not a full check.
Windows-created worktrees may have a Windows absolute gitdir that Linux Git cannot
read. Use a normal Linux clone or run the gate with a compatible Git executable.

## What each check establishes

| Check | Establishes | Does not establish |
|---|---|---|
| Guard fixtures | Recognized cleanup is allowed/blocked as expected | Arbitrary command sandboxing |
| Triage fixtures | Evidence-based state, failure separation, read-only behavior | Scientific correctness |
| Preflight fixtures | Capacity checks use the actual output filesystem and supplied estimate | Accuracy of an operator's resource estimate |
| Contract fixtures | Metadata validation, pinned patch, detached process lifecycle | Real Nextflow/container compatibility or speedup |
| Routing/version | Discoverable selected-pipeline docs, consistent manifests and required version bump when compared with a changed base | Every upstream pipeline feature |

For a scientific reproduction, select **one row** of Table 1 and its archived
command/data version, inspect [setup](agent-setup.md), and approve an explicit
resource plan. `bootstrap/05-verify.sh` is a host diagnostic; its dependencies and
reference checks make it unsuitable as the no-install quick check above.

Current omissions to assess before publication: fresh fixed-release reruns,
matched agent/baseline experiments, and public evidence for the 90-sample claims.
These checks and historical reports are a reproducibility starting point.
