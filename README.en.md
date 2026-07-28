# bioinfo (English)

> **[README.md](README.md) (Korean) is canonical.** This file is the original English draft, kept
> for reference. It predates several measured corrections — the `00-` script filename, the WSL
> memory cap that breaks STAR index builds, the corporate TLS-inspection handling, and the fact
> that WSL distro registration is per Windows account. Trust the Korean file where they disagree.

A self-contained bioinformatics execution environment: a WSL2 Linux substrate that actually runs
nf-core pipelines, a skill that encodes how to run them correctly, and an agent that does the running
without dumping twelve hours of Nextflow log into your conversation. Everything in this repo is text
— scripts, configs, and knowledge — so the whole setup is reproducible on a new machine from a git
clone plus one bootstrap sequence.

It is built for human genomics work: short-read WGS/WES, RNA-seq, methylation, ATAC/ChIP, single
cell, plus the STR / repeat-expansion and Korean-population allele-frequency work this machine
already has references for.

---

## Architecture

Three layers, deliberately separated.

| Layer | Lives in | What it is | Why it is its own layer |
|---|---|---|---|
| **Substrate** | `bootstrap/`, `config/`, WSL2 distro `Ubuntu-24.04` | Linux, Docker engine, Java, Nextflow, the `/refs` reference store | Machine-specific and mutable. Rebuildable from scratch by re-running the bootstrap scripts. |
| **Skill** | `skills/bioinfo-analyze/` | The knowledge: which pipeline for which question, samplesheet schemas, resource estimation, QC thresholds, failure modes | Plain markdown. Editable by hand, diffable in git, reusable by any agent or by you reading it directly. Knowledge that lives in an agent's prompt is knowledge you cannot grep. |
| **Agent** | `agents/` | `bioinfo-tech`, a subagent that plans, stub-runs, executes, monitors, and reports | Execution isolation. A four-hour `nextflow run` emits tens of thousands of log lines. Run inside a subagent, that traffic stays in the subagent's context and only the verdict comes back. Run in the main conversation, it evicts everything you were actually thinking about. |

The split matters most when something goes wrong. A pipeline failure is diagnosed by reading the
skill's failure-mode reference, not by re-deriving it — and the fix gets written back into the skill,
so the next run is smarter. The agent is disposable; the skill compounds.

**What the agent will not do:** it reports QC verdicts and output locations. It does not interpret
biology. "MultiQC shows 8% duplication and all samples pass" is its job. "Therefore this gene is
upregulated in disease" is yours.

---

## Repo map

```
bioinfo/
├── README.md                  this file
├── install.ps1                links skills/ and agents/ into your Claude config dir
├── .gitignore                 keeps run outputs, work dirs and references out of git
├── .gitattributes             forces LF on *.sh so a Windows checkout does not break bash
├── .claude-plugin/            plugin/marketplace packaging (UNVERIFIED — see below)
│   ├── marketplace.json
│   └── plugin.json
├── bootstrap/                 numbered, idempotent setup scripts, 00 → 05
├── config/                    Nextflow configs + the reference manifest
│   ├── local.config           executor, CPU/RAM caps, container engine, work dir
│   ├── genomes.config         maps genome build names onto $BIOINFO_REFS paths
│   └── refs.manifest.tsv      SOURCE OF TRUTH for what /refs contains and where it came from
├── skills/
│   └── bioinfo-analyze/       SKILL.md + references/ + assets/
│       ├── references/        per-pipeline runbooks, reference-store standard, QC thresholds
│       └── assets/            samplesheet templates, config snippets
├── agents/                    bioinfo-tech agent definition
└── runs/                      one directory per analysis run (gitignored)
```

`/refs` itself is **not** in this repo and never will be. It is hundreds of gigabytes, it lives on
ext4 inside the WSL VHDX, and it is reconstructed from `config/refs.manifest.tsv` by
`bootstrap/04-refs.sh`. That manifest is the portable artifact; the bytes are not.

---

## Set up on a new machine

Run in order. Every script is idempotent — re-running a completed step is a no-op that re-verifies.

<!-- UNVERIFIED: filenames for steps 00 and 03 are the intended names; confirm with `ls bootstrap/`
     before quoting them to anyone. 01, 02, 04, 05 are referenced by name from existing files. -->

| # | Script | Where it runs | Roughly | What it does |
|---|---|---|---|---|
| 00 | `bootstrap/00-wsl-install.ps1` | Windows PowerShell | 10–20 min | Enables the VM Platform / WSL features, installs the `Ubuntu-24.04` distro, moves its VHDX off C:, sets the max VHD size. |
| 01 | `bootstrap/01-wsl-base.sh` | WSL, as root | 5–10 min | User `ehojune` + NOPASSWD sudo, `/etc/wsl.conf` (systemd, default user, `appendWindowsPath=false`), OpenJDK 17, git/curl/unzip/pigz/build-essential. |
| 02 | `bootstrap/02-docker.sh` | WSL, as root | 3–5 min | Docker **engine** (not Docker Desktop) from the upstream apt repo, `docker` group, systemd unit, `hello-world` smoke test. |
| 03 | `bootstrap/03-nextflow.sh` | WSL, as user | 2–5 min | Nextflow, `nf-core` tooling, `NXF_*` environment (assets, work dir, container cache) pointed at ext4. |
| 04 | `bootstrap/04-refs.sh` | WSL, as user | seconds → ~15 min | Reads `config/refs.manifest.tsv`, builds `$BIOINFO_REFS`. Symlinks are instant; the ~5 GB of `copy`-mode BWA index files come across drvfs and take the time. |
| 05 | `bootstrap/05-verify.sh` | WSL, as user | < 1 min | Checks every layer and prints OK / MISSING / STALE per item. Nothing is "installed" until this is clean. |
| — | `install.ps1` | Windows PowerShell | seconds | Links `skills/` and `agents/` into your Claude Code config directory. |

**The one manual step is 00.** `wsl --install -d Ubuntu-24.04` drops you into an interactive prompt
for a UNIX username and password, and on a machine where virtualization features were not already
enabled it requires a reboot before the distro will start. Neither can be scripted away. Budget for
being present.

After 05 passes on a machine that is not this one, do this:

1. Open `config/refs.manifest.tsv`.
2. Edit the **source** column — the third field — so it points at wherever that machine keeps its
   reference files. Do not touch the first column. Standard paths are the contract; source paths are
   the local detail.
3. Re-run `bootstrap/04-refs.sh`. It rebuilds the tree against the new sources.
4. Re-run `bootstrap/05-verify.sh`. Expect rows marked `MISSING` for anything genuinely absent —
   that is the script working, not failing. Fill those in with `mode=fetch` or `mode=build`.

Total wall clock on a machine with the reference files already local: 30–45 minutes, most of it
apt and the index copy. On a machine that has to download references, add hours and plan the
downloads explicitly.

---

## Install the skill and agent

**Read this even if you skip everything else.** Claude Code skills and agents are **local files on
disk**. They are not attached to your Anthropic account and they do not sync. Signing into Claude
Code on a new computer gets you the model; it does not get you `bioinfo-analyze` or `bioinfo-tech`.
Until you run one of the two mechanisms below on that computer, the agent does not exist there. This
surprises people. Do not let it surprise you at the start of a run.

Both mechanisms point Claude at the same files. Pick one.

### (a) `install.ps1` — junctions. Verified working on this machine.

```powershell
cd D:\bioinfo-agent
.\install.ps1 -WhatIf          # dry run, shows every action, changes nothing
.\install.ps1                  # do it
```

It creates a directory **junction** per skill at `<config>\skills\<name>` and links each agent
definition into `<config>\agents\`. Junctions, not symbolic links, because junctions need neither
administrator rights nor Developer Mode. The repo on `D:` stays the single canonical copy: edit a
file there and Claude sees the edit immediately, no re-install.

Config directory resolution: `$env:CLAUDE_CONFIG_DIR` if set, otherwise `$env:USERPROFILE\.claude`.
This machine has two Windows profiles, so link both from the one copy:

```powershell
.\install.ps1 -ExtraConfigDirs 'C:\Users\admin\.claude'
```

The script refuses to clobber. If `<config>\skills\bioinfo-analyze` already exists as a real
directory, or as a junction pointing somewhere else, it stops and tells you rather than deleting
someone's work. `-Force` replaces a *wrong junction* only. Agent `.md` files are symlinked when the
OS allows it and copied otherwise; if yours were copied, the script says so, and you must re-run it
after editing the agent.

### (b) Claude Code plugin marketplace — portable, schema **UNVERIFIED**.

```
/plugin marketplace add <git-url-or-local-path-to-this-repo>
/plugin install bioinfo@bioinfo
```

<!-- UNVERIFIED: exact command spelling and JSON schema. Validate by running the marketplace-add
     command against this repo and reading the error, then correct .claude-plugin/*.json. -->

> **The two files in `.claude-plugin/` are best-effort and have not been validated against a real
> marketplace load.** JSON has no comment syntax, so the warning lives here instead. `plugin.json`
> relies on Claude Code auto-discovering the top-level `skills/` and `agents/` directories by
> convention rather than declaring explicit path arrays — a wrong path array fails harder than an
> absent one. If auto-discovery does not pick them up, add explicit arrays and correct the schema
> against whatever the marketplace-add command complains about. Until someone has actually watched
> `/plugin install` succeed, **`install.ps1` is the supported path** and this is the experiment.

---

## Troubleshooting

Start here, always, before theorising:

```bash
bash /mnt/d/bioinfo-agent/bootstrap/05-verify.sh
```

It walks every layer — distro, systemd, Docker daemon, Java, Nextflow, `$BIOINFO_REFS` contents,
free space on the ext4 volume — and prints a per-item verdict. Most "the pipeline is broken" reports
are one of these instead:

| Symptom | Usually |
|---|---|
| `Missing reference` / file-not-found on a genome path | A manifest row is `MISSING` or its source moved. Fix the source column, re-run `04-refs.sh`. Never hand-place a file into `/refs`. |
| Everything is inexplicably 5–10× slow | Something hot is on `/mnt/d`. Work dir, container cache, or an index file still symlinked instead of copied. Move it to ext4. |
| `Cannot connect to the Docker daemon` | The distro was not restarted after `01-wsl-base.sh` wrote `/etc/wsl.conf`, so PID 1 is not systemd. `wsl --terminate Ubuntu-24.04` from Windows, then reopen. |
| `docker: permission denied` | Group membership from `02-docker.sh` needs a fresh login shell. Terminate the distro. |
| Run died partway | `-resume`. Always. **Never clean or delete the work directory** — that is what makes resume possible, and deleting it converts a ten-minute restart into a full re-run. |
| Out of disk mid-run | The VHDX grew into its 1 TB cap, or the host D: filled. Check both; the guardrail is to refuse to start below 1.5× the estimate, so this means an estimate was wrong. Say so. |
| STAR index build OOMs | Human STAR genome generation wants ~40 GB RAM. Check the WSL memory cap in `.wslconfig` before blaming the pipeline. |
| Claude has no `bioinfo-tech` agent | You are on a machine where neither install mechanism has been run. See above. |

---

## Appendix — this machine, concretely

Facts, measured. Everything above is general; this is the specific instance.

**Host**

- Windows 11 Pro, build 26200. 24 logical cores, 63.5 GB RAM.
- `C:` 74 GB free — **tight, never target it.** No work dirs, no caches, no outputs.
- `D:` 2.2 TB free — repo, references, VHDX.
- `E:` 3.7 TB free — bulk data and archive.

**WSL distros**

| Distro | VHDX | Size | Role |
|---|---|---|---|
| `Ubuntu-24.04` | `D:\wsl\ubuntu-24.04\ext4.vhdx` | 1 TB max, 955 GB free inside | **The pipeline substrate.** Everything runs here. |
| `Ubuntu-legacy` | `D:\wsl\legacy\ext4.vhdx` | 31.5 GB | Read-only archive of the pre-existing environment (`/home/ehojune` 28 GB, anaconda3). Pull old scripts and data out of it. **Never run pipelines there.** |

Inside `Ubuntu-24.04`: user `ehojune` (uid 1000, sudo, NOPASSWD). `/etc/wsl.conf` sets
`systemd=true`, default user `ehojune`, `appendWindowsPath=false`. OpenJDK 17.0.19. Docker engine
with the default data-root `/var/lib/docker`, which is already inside the D: VHDX, so there is
nothing to relocate.

**Path translation:** `D:\bioinfo-agent` (Windows) == `/mnt/d/bioinfo-agent` (WSL). Write file paths in whichever
form matches the shell you are in.

**Performance rule that overrides convenience:** `/mnt/c`, `/mnt/d`, `/mnt/e` go through Windows
drvfs and run roughly 5–10× slower than the distro's native ext4. Nextflow work directories,
container images, and random-access index files live on ext4, full stop. Only sequentially-read
reference files may be symlinked out to `/mnt/d`.

**Reference store — present locally, wired through the manifest, no download needed**

- UCSC `hg38.fa` + `.fai`
- GATK analysis set `Homo_sapiens_assembly38_noALT_noHLA_noDecoy.fasta` + `.fai` + a complete BWA
  index (`.amb .ann .bwt .pac .sa`) — this is the build sarek should use, exposed as `GRCh38gatk`
- GENCODE v50 annotation GTF and a genes BED
- KOREF1 Korean reference assembly, plus its chrY
- HipSTR reference BED; TRGT full and pathogenic repeat catalogs; ExpansionHunter full and
  disease-locus variant catalogs

**Reference store — genuinely missing. Say so in a run plan; do not discover it twelve hours in.**

- Sequence `.dict` for both `GRCh38` and `GRCh38gatk` — two minutes of
  `gatk CreateSequenceDictionary`, but sarek will not start without it
- STAR, salmon and bismark indexes — the first RNA-seq or methylseq run pays the build cost
  (~1 h, ~40 GB RAM for human STAR). Use `--save_reference` so it is paid once.
- The GATK resource bundle: dbsnp, known_indels, and an af-only gnomAD germline resource. Required
  for BQSR and HaplotypeCaller. Several GB of download.
- A VEP or snpEff cache — ~25 GB for GRCh38, needed only if you are annotating.

**Pipelines covered in depth by the skill:** `nf-core/rnaseq`, `differentialabundance`, `fetchngs`,
`sarek`, `methylseq`, `atacseq`, `chipseq`, `cutandrun`, `scrnaseq`. Anything else is procured on
demand at request time rather than pre-documented.

---

## Guardrails

Non-negotiable, enforced by the skill and the agent, restated here because they are the whole point:

- Never start a job estimated over **24 hours** without explicit approval.
- Never skip the **stub-run / `-preview`** validation step.
- **Never delete or clean a work directory.** It destroys `-resume`.
- Refuse to start when free disk is under **1.5×** the estimate.
- Always `-resume` on restart. Never silently re-run from scratch.
- Report QC verdicts. Do not interpret biology.
- If a bounded choice was made — top-N, subsampling, a skipped sample — **say so out loud** in the
  handoff, not in a log line nobody reads.

---

## Version note on anything schema-shaped

nf-core samplesheet columns and parameter names drift between pipeline revisions. Any schema table
you find in this repo names the revision it was written against, and comes with the command that
re-derives it from the pipeline you are actually about to run:

```bash
nextflow run nf-core/<pipeline> -r <rev> --help
cat "$NXF_ASSETS/nf-core/<pipeline>/assets/schema_input.json"
nf-core pipelines schema docs
```

Re-derive before the first run on a revision you have not used here before. A samplesheet that was
correct two releases ago fails in a way that looks like a data problem.
