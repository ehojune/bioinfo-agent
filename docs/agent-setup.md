# Setup guide for the AI doing the install

You are an AI assistant. A user has handed you this repository URL and asked you to make it usable.
This file is the whole procedure. The human-facing README is not the instruction set — this is.

Everything here is written for you. Do not paste it at the user.

---

## First: decide whether the user needs the substrate at all

Two very different requests hide behind "set this up".

**(1) They only want the skill and agent available in Claude Code.** No pipelines yet. This is one
command and no clone:

```bash
claude plugin marketplace add ehojune/bioinfo-agent
claude plugin install bioinfo@bioinfo
```

Verify with `claude plugin details bioinfo@bioinfo`. Report the always-on token cost. Stop here.
Do not install Docker, Nextflow, or references — the user has not asked to run anything yet, and
the substrate is tens of GB.

**(2) They want to actually run a pipeline.** Then the substrate is required, and you continue.

Ask which one it is if the request is ambiguous. "설정해줘" alone does not distinguish them.

---

## Substrate install — the ordered procedure

### Step 0 — classify the host before touching anything

Run these and read them. Do not assume.

```bash
uname -a; nproc; free -g; df -h
command -v docker apptainer singularity nextflow java git
command -v sbatch qsub bsub          # scheduler?
id                                    # sudo/root?
```

Three host classes, and the branch matters more than anything else here:

| | A. personal workstation | B. shared server, no root | C. HPC cluster |
|---|---|---|---|
| container | Docker engine | **Apptainer/Singularity** | Apptainer |
| executor | `local` | `local`, ceilings well below the box | **`slurm`/`pbs`/`lsf`** |
| bootstrap | `00`→`06` | `03 04 05 06` only | `03 04 05 06` only |
| references | build from manifest | **usually already present — ask first** | usually already present |

On B and C you do not have root. Do not attempt `02-docker.sh`. Do not `sudo apt install`. If Java
17 is missing, ask the administrator or use a module system (`module avail java`).

On C, `executor = 'local'` on a login node is a policy violation at most sites. Set the executor to
the scheduler before the first run, not after someone complains.

### Step 1 — clone and write `config/host.env`

```bash
git clone https://github.com/ehojune/bioinfo-agent.git ~/bioinfo-agent
cd ~/bioinfo-agent
cp config/host.env.example config/host.env
```

Read the copy top to bottom and set every value to something real on this host — the active roots
(`BIOINFO_HOME`, `BIOINFO_REFS`, `BIOINFO_WORK`, `BIOINFO_RUNLOG`), legacy `BIOINFO_RUNS` reserve,
the identity block, and the ceilings. Bootstrap sources this file when it exists.

```bash
set -a; . config/host.env; set +a
```

`BIOINFO_WORK` on a quota'd home directory is the single most common way a multi-hour run dies at
hour eleven. Check `df -h` and quota before choosing.

### Step 2 — run bootstrap in this order

Note `06` runs **before** `04`. Reference fetching needs working TLS.

| # | script | run as | skip when |
|---|---|---|---|
| 00 | `00-windows-wsl.ps1` | Windows PowerShell | not Windows |
| 01 | `01-wsl-base.sh` | root | no root — request Java 17 + build tools instead |
| 02 | `02-docker.sh` | root | no root, or using Apptainer |
| 03 | `03-nextflow.sh` | **the pipeline user, not root** | never |
| 06 | `06-tls-trust.sh` | user, then root if it reports interception | never — it exits immediately when clean |
| 04 | `04-refs.sh` | user | never |
| 05 | `05-verify.sh` | user | never |

All are idempotent. Re-running a finished step re-verifies and changes nothing.

**Say this to the user before running 01 and 02.** `01` installs a `NOPASSWD:ALL` sudoers drop-in
for the pipeline user and `02` puts that user in the `docker` group, which is root-equivalent
because the daemon runs as root. Both are scoped to that distro. On a machine with other users,
skip both and ask the administrator.

`03-nextflow.sh` writes the environment contract to `~/.config/bioinfo/env.sh`; every later shell
and script reads it from there. It **refuses to run as root** by design — as root it would install
Nextflow into `/root/.local/bin` and write that contract into root's home, where the pipeline user
never sees it.

### Step 3 — TLS, if `06` reports interception

Institutional networks often re-sign TLS with a private CA. It is **selective**: some domains pass
and others do not, so "github works" proves nothing about `get.nextflow.io`.

There are **three trust stores** and fixing one is not enough:

| store | used by | consequence of missing it |
|---|---|---|
| system CA | curl, apt, git | downloads fail with `curl: (60)` |
| **JVM cacerts** | **Nextflow itself** | curl works, pipeline pulls still fail |
| Python certifi | nf-core tools | `nf-core` subcommands fail |

```bash
bash bootstrap/06-tls-trust.sh                 # report only
sudo bash bootstrap/06-tls-trust.sh --accept   # install into all three
```

**Show the user the issuer before running `--accept`.** Trusting an interception CA means that
appliance can read this machine's TLS traffic. That is the user's decision, not yours. Never use
`curl -k` or `GIT_SSL_NO_VERIFY` as a workaround.

### Step 4 — references

Edit **only the third column (source)** of `config/refs.manifest.tsv`. The first column is the
standard path and is a contract — never change it.

```bash
bash bootstrap/04-refs.sh --dry-run   # read the plan first
bash bootstrap/04-refs.sh
```

Modes: `link` (symlink), `copy` (materialise — for random-access-heavy index files on slow
storage), `build` (a tool generates it), `fetch` (needs downloading).

On a shared server, **ask before downloading anything**. Sites usually have iGenomes or a GATK
bundle already staged; re-downloading 30 GB that exists two directories away is a real cost.

Rows reported `NOT BUILT` and `MISSING` on a fresh host are expected, not failures.

### Step 5 — verify, then register the skill

```bash
bash bootstrap/05-verify.sh
```

It must print `READY`. On Apptainer hosts the Docker checks fail — that is correct, note it and
move on. Then:

```bash
claude plugin marketplace add ehojune/bioinfo-agent
claude plugin install bioinfo@bioinfo
```

Or, if the user will be editing the repo, symlink instead (Linux):

```bash
mkdir -p ~/.claude/skills ~/.claude/agents
ln -sfn "$BIOINFO_HOME/skills/bioinfo-analyze" ~/.claude/skills/bioinfo-analyze
ln -sfn "$BIOINFO_HOME/agents/bioinfo-tech.md" ~/.claude/agents/bioinfo-tech.md
```

**Pick one mechanism.** Plugin *and* symlink registers the same skill twice.

On Windows use `install.ps1` — it uses junctions, which need no administrator rights, unlike
symbolic links. It also registers the work-directory guard hook in the config dir's `settings.json`,
which the symlink commands above do not; `-NoHook` skips that and `-UninstallHook` reverses it.

---

## Procuring a pipeline that is not one of the nine

The skill documents nine pipelines in depth. nf-core has over a hundred. Do not pre-document the
rest — a table nobody verifies rots into confident misinformation. Procure on demand:

```bash
nf-core pipelines list
```

Before committing to one, check: release maturity, date of last release, whether it is archived,
whether containers exist, and whether `-profile test` passes **on this host**. Then pin the
revision with `-r` and never run unpinned.

If it becomes part of the regular workload, add a row to `config/pipelines.tsv` — the only place in
this repo that states a revision — plus `pipeline-selection.md`, `samplesheets.md`, `estimates.md`,
and any needed rows in `refs.manifest.tsv` so the next machine inherits it. Full procedure:
[`new-pipeline.md`](../skills/bioinfo-analyze/references/new-pipeline.md).

**When nf-core genuinely has no pipeline** — STR callers like ExpansionHunter, TRGT, HipSTR, and
most long-read work — run the tool directly. Pin it to a container, record the exact invocation in
the run log, and say in the handoff that this step was not an nf-core pipeline. This does not
conflict with the rule against hand-rolling: that rule means *do not rebuild sarek out of bwa and
samtools when sarek exists*.

---

## Schema drift

nf-core samplesheet columns and parameter names change between revisions. `config/pipelines.tsv`
holds the pinned revision for every stocked pipeline and the date its schema was last checked.
Re-derive before the first run at an unfamiliar revision:

```bash
nextflow info nf-core/<pipeline>
nextflow run nf-core/<pipeline> -r <rev> --help
find "$NXF_ASSETS" -path '*nf-core/<pipeline>*' -name schema_input.json | head -1
```

Nextflow 26.x stores assets under `$NXF_ASSETS/.repos/<org>/<pipe>/clones/<commit-sha>/`. The sha
directory means **hardcoded asset paths break**. Use `find`, or a glob that absorbs the sha.

---

## Things that will bite you

| symptom | cause |
|---|---|
| run dies at hour 11, disk full | `BIOINFO_WORK` or container cache under `$HOME` on a quota |
| `curl: (60)` | TLS interception. `06-tls-trust.sh` |
| curl fine, Nextflow can't pull | JVM cacerts not done. All three stores, not one |
| `exit 137`, often at STAR index | memory ceiling. Human STAR index needs ~38 GB. On WSL check `.wslconfig` first |
| `.command.sh: Permission denied` | work dir on a `noexec` mount |
| `-resume` re-runs everything | work dir moved or deleted. **Never delete a work directory** |
| skill registered twice | plugin and symlink both used |
| env vars empty in `bash -lc` | hook only in `.bashrc`; Ubuntu's `.bashrc` returns early when non-interactive. `03-nextflow.sh` writes `.profile` too |
| admin emails about the login node | `executor = 'local'` on a scheduler-managed cluster |

---

## Report back like this

When finished, tell the user:

1. Host class (A/B/C) and what you concluded from what evidence
2. `05-verify.sh` result — `READY` or the numbered failures
3. What the reference store has, and what is `MISSING`/`NOT BUILT` and therefore blocks which
   pipelines. **Say this now, not when a run fails twelve hours in.**
4. Anything you deliberately skipped and why
5. One concrete next command they can run

Do not report success while `05-verify.sh` is failing.
