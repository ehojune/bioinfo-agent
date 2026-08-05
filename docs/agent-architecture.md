# Design notes — layering, references, guardrails

Background for maintainers, and for an AI working on this repo. None of it is needed to *use* the
agent; the [README](../README.md) covers that. It sits here because a first-time user does not need
it and loses nothing by reading it later.

**This file summarises. It does not decide.** `skills/bioinfo-analyze/SKILL.md` is what the agent
actually reads, and `hooks/guard-workdir.sh` is the only rule enforced mechanically. Where either
disagrees with this file, they win.

---

## Why three layers

- **Substrate** (`bootstrap/`, `config/`) — machine-specific and constantly changing; re-running
  rebuilds it from scratch.
- **Skill** (`skills/bioinfo-analyze/`) — just markdown. You edit it, diff it, read it. Knowledge
  trapped in an agent prompt is knowledge you cannot grep.
- **Agent** (`agents/`) — execution isolation. Logs stay in the subagent; only the conclusion
  crosses over.

A pipeline that dies gets diagnosed from the skill's failure-mode reference, and whatever you worked
out gets written back into the skill. **The agent is disposable; the skill compounds.**

## References travel as a manifest, not as bytes

Pipeline commands name only the standard path
`$BIOINFO_REFS/genomes/GRCh38/fasta/genome.fa`, never the original `hg38.fa`.
`config/refs.manifest.tsv` connects the two, so moving to another machine means fixing one column —
`source`. **What is portable is the manifest, not the bytes.**

## Guardrails

- Nothing estimated over **24 hours** starts without approval
- No skipped **stub-run**; no deleted work directory (that kills `-resume`)
- Refuses when free disk is under **1.5×** the estimate; warns before any download over **10 GB**
- If it narrowed the scope, it says so out loud. QC verdicts only, no biological interpretation
- **Does not hand-reproduce an existing pipeline** — wiring `bwa` + `samtools` + `gatk` together
  yourself is rewriting sarek, and it costs you reproducibility, `-resume` and MultiQC
- **Does not run binaries it found on disk** — tools come from containers

Only the work-directory rule is machine-checked. `hooks/guard-workdir.sh` registers as a PreToolUse
hook and refuses `-with-cleanup`, `cleanup = true`, `nextflow clean` while a run is live, and any
`rm -rf` on a work directory unless that run is finished, handed off, and past the hold
(`BIOINFO_WORKDIR_HOLD_DAYS`, 7 by default). It sees every Bash call in the session, not only the
subagent's, and it fails open if it cannot parse its input — a guard that blocks everything when
`jq` is missing is worse than no guard.

Both install routes register it: the plugin from `hooks/hooks.json`, `install.ps1` by merging one
entry into the config dir's `settings.json`. Hand-made symlinks do not, so on that route every rule
above is a sentence in a prompt.

Both use **shell form** — a `command` string, no `args` array — and on Windows that is load-bearing.
`args` would make it exec form: no shell, `command` resolved against PATH, and the first `bash.exe`
on a Windows PATH is `System32\bash.exe`, the WSL launcher (Git's own lives in `Git\usr\bin`, which
is on PATH only inside a Git Bash session). WSL cannot open the path, exits 127, and Claude Code
treats any code but 0 or 2 as non-blocking — so the guard would fail open silently. `install.ps1`
therefore probes the command against a must-block and a must-allow payload before registering it,
and refuses rather than leave an entry that does nothing.
