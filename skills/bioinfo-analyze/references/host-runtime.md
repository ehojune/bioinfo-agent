# Host runtime contract

Read before composing any path, resource estimate or launch command. Machine-local configuration
is data; historical run records do not describe the current host.

## Load order

1. On Windows, read `config/host.env` as text to identify `BIOINFO_DISTRO`; confirm with `wsl -l -v`.
   Use `wsl -d <verified-distro> -- bash -lc '<command>'`. PowerShell reads
   `$env:BIOINFO_DISTRO`, not Bash's `$BIOINFO_DISTRO`.
2. In that distro, load the generated environment to locate the configured checkout.
3. Parse machine settings with the tracked literal-value loader, then load the generated
   environment again. It owns runtime paths and `NXF_*`; `env.local.sh` is loaded by it last.

```bash
test -r "$HOME/.config/bioinfo/env.sh" || {
  echo "Missing generated environment: complete host bootstrap first" >&2; exit 1;
}
. "$HOME/.config/bioinfo/env.sh"
: "${BIOINFO_HOME:?Missing configured repository root}"
. "$BIOINFO_HOME/bootstrap/lib/host-env.sh"
load_host_env "$BIOINFO_HOME/config/host.env"  # parse only; NEVER source host.env
. "$HOME/.config/bioinfo/env.sh"              # generated runtime values win
: "${BIOINFO_HOME:?}" "${BIOINFO_REFS:?}" "${BIOINFO_WORK:?}" "${BIOINFO_RUNLOG:?}"
: "${NXF_ASSETS:?}" "${NXF_HOME:?}" "${NXF_TEMP:?}"
```

Do not copy `export` values from an example host or edit the generated file.
`bootstrap/03-nextflow.sh` regenerates it; local TLS overrides belong in `env.local.sh`.
An absent environment is a setup problem, never a reason to compose paths from empty variables.
`BIOINFO_ARCHIVE_DISTRO`, if set, names a read-only archive: inspect files, never run pipelines there.

## Paths and budgets

| Value | Contract |
|---|---|
| `BIOINFO_HOME` | Configured checkout; use `config/local.config` on every run |
| `BIOINFO_REFS` | Manifest-governed reference root; never write through source symlinks |
| `BIOINFO_WORK` | ext4 scratch root |
| `BIOINFO_RUNLOG` | Run plan, parameters, samplesheet, command, handoff and copied deliverables |
| `BIOINFO_RUNS` | Legacy reserve; never the active output root |
| `NXFDIR` | `${NXF_WORKROOT:-$BIOINFO_WORK/nxf}/<runid>`; launch, work, live results and reports |
| `NXF_*` caches | Runtime environment; keep caches and indexes on ext4 |
| `BIOINFO_MAX_CPUS`, `BIOINFO_MAX_MEMORY`, `BIOINFO_MAX_TIME` | Task pool consumed by `config/local.config`; inspect its explicit defaults if unset |

The three limits are separate: physical host, WSL VM, and Nextflow task pool. Read current
`nproc`, `free -g`, `df -h`, Docker status and `nextflow -version`; keep headroom for Windows,
Docker and the launcher JVM. A configured cap is not a measurement of available resources.
Never quote old drive letters, free-space figures or VM sizes as current facts.

Launch directory, `work/`, live `results/`, `.nextflow/cache`, container cache and indexes must
be on ext4. Sequential input/reference reads may use drvfs; measured throughput depends on the
device and access pattern. Check the actual mounts and free space, including an `NXF_WORKROOT`
override, before applying the 1.5× disk gate. `$BIOINFO_RUNLOG` may be on a user-visible drive.
Finished results are copied there once; preflight and execution must target the same live tree.
Preflight's third argument estimates copied outputs in decimal MB. It checks the filesystem
containing the run-record directory (or its nearest existing ancestor), independently of the
repository mount. Omitting that estimate leaves a warning, not a result-capacity certification.

The common commands and conditional stub gates are in [runbook.md](runbook.md).
The selected pipeline card defines reference build and assay scope. Current manifest dry-run
results outrank historical missing-index lists.
