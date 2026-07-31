# Execution runbook

The exact sequence for getting an nf-core pipeline from "the user asked for X" to "here are the
results and here is the QC verdict", on this host. Deviating from the order below is how runs get
lost twelve hours in.

Host facts this runbook is written against: WSL2 `Ubuntu-24.04`, 24 logical cores, 63.5 GB host RAM,
Docker **engine** inside the distro, distro ext4 on `D:\wsl\ubuntu-24.04\ext4.vhdx` (1 TB max,
~955 GB free), `appendWindowsPath=false`, references under `$BIOINFO_REFS` (default `/refs`).

## Sequence at a glance

1. Pick pipeline + revision. Pin the revision.
2. Write the run plan to `$RUNDIR/plan.md`. Get approval if the estimate exceeds 24 h.
3. Write `samplesheet.csv`, `params.yaml`, `cmd.sh` into `$RUNDIR`.
4. Preflight. Any FAIL is a hard stop.
5. `-preview`, then `-stub-run`. Both must be clean.
6. Launch backgrounded on ext4 with reports and `-resume`.
7. Monitor the trace, not the terminal.
8. On completion: read MultiQC, rsync results out to `/mnt/d`, write the handoff.
9. Leave the work dir alone for at least 7 days.

---

## 1. Directory layout

Two directories per run, one on each filesystem, sharing a run ID.

```
RUNID = <YYYYMMDD>-<pipeline>-<slug>          e.g. 20260728-rnaseq-koges-pilot

/mnt/d/bioinfo-agent/runs/$RUNID/            NTFS via drvfs — human-visible, small text + deliverables
  ├── plan.md                            written BEFORE launch, never edited after
  ├── samplesheet.csv
  ├── params.yaml
  ├── cmd.sh                             the literal command that was run
  ├── results/                           rsync target, populated at the END
  ├── reports/                           rsync target: report/trace/timeline per attempt
  └── handoff.md                         written at the END

/work/nxf/$RUNID/                      ext4 inside the distro — everything live
  ├── work/                              -work-dir, task scratch
  ├── .nextflow/                         resume cache (LevelDB)  <-- must be ext4
  ├── .nextflow.log[.1.2…]
  ├── nextflow.stdout.log
  ├── nextflow.pid
  ├── results/                           --outdir during the run
  └── reports/
```

### Why the split, precisely

**The work dir must never be under `/mnt/*`.** Four independent reasons, any one of which is
sufficient:

- drvfs is 5–10× slower than ext4, and task scratch is the most I/O-intensive thing in the run.
- Nextflow's resume cache is a LevelDB under the *launch* directory. LevelDB needs real POSIX file
  locking; on drvfs it intermittently fails to acquire the lock, which does not just slow the run
  down, it makes `-resume` unreliable.
- The nf-core `docker` profile runs containers as `-u $(id -u):$(id -g)`. drvfs synthesises
  ownership from the mount options rather than storing it, so container-side `chown`/`chmod` inside
  the work dir behaves differently from ext4 and some modules fail on it.
- Hardlinks do not cross the ext4↔drvfs boundary. Nextflow stages inputs into task dirs by hardlink
  where it can and falls back to copying where it cannot; splitting the work dir across the boundary
  turns every stage-in into a full copy.

**The launch dir is also on ext4** — not only `-work-dir`. `.nextflow/cache` and `.nextflow.log` are
created relative to the current directory, so launching from `/mnt/d/...` puts the resume cache on
drvfs even when `-work-dir` is correct. Always `cd /work/nxf/$RUNID` first.

**`--outdir` points at ext4 during the run**, and results are rsynced to `/mnt/d` once at the end.
nf-core's default `publish_dir_mode = 'copy'` means every published file is copied out of the work
dir as it is produced; doing that across drvfs, thousands of times, during the run, is pure waste.
One sequential rsync at the end costs a fraction of it. Corollary: never set
`publish_dir_mode = 'link'` or `'symlink'` with an outdir on `/mnt/d` — hardlinks cannot cross the
boundary and drvfs symlinks require Windows developer mode.

**You can still look at live results from Windows.** The distro's ext4 is browsable at
`\\wsl.localhost\Ubuntu-24.04\work\nxf\<RUNID>\` in Explorer, and MultiQC HTML opens fine from
there. Windows-visibility is not a reason to put the outdir on drvfs.

**Input FASTQs may stay on `/mnt/d`.** They are read sequentially, once or twice, and drvfs
sequential throughput is adequate. If the trace shows alignment tasks pinned at low `%cpu` with high
`wa`, copy the FASTQs to `/work/staging/$RUNID/` and re-point the samplesheet — but see the
`-resume` section first, because doing that mid-run changes input mtimes and busts the cache.

### One-time host setup

```bash
sudo mkdir -p /work/nxf /work/staging
sudo chown -R "$USER:$USER" /work
```

Put this in `~/.bashrc` (or the skill's env preamble):

```bash
export BIOINFO_HOME=/mnt/d/bioinfo-agent
export BIOINFO_REFS=/refs
export NXF_WORKROOT=/work/nxf
export NXF_ASSETS="$BIOINFO_REFS/cache/nf-assets"    # pipeline clones live on ext4
export NXF_OPTS='-Xms1g -Xmx8g'                       # cap the launcher JVM (03-nextflow.sh sets this)
export NXF_ANSI_LOG=false                             # backgrounded logs must not be redraw spam
```

Two Windows-side settings that decide whether a long run survives. Run these from PowerShell, not
from inside the distro — `appendWindowsPath=false` means `wsl.exe` and `powercfg.exe` are not on the
distro's `PATH` (reach them at `/mnt/c/Windows/System32/…` if you must).

- **WSL memory ceiling.** WSL2 defaults to roughly half of host RAM, i.e. ~31 GB here. That is below
  what a human STAR index build wants (~40 GB) and well below comfortable for sarek. Check inside
  the distro with `free -g`; if `total` is ~31, copy `config/wslconfig.example` to
  `%USERPROFILE%\.wslconfig` — it is the tested source for the VM budget — then `wsl --shutdown`
  from PowerShell and restart the distro. Leaving the balance to Windows is not optional; starving
  the host makes the whole machine unusable and does not speed up the run.
- **Sleep and updates.** A 30-hour sarek run does not survive S3 sleep or a Windows Update reboot.
  `powercfg /change standby-timeout-ac 0` and set Active Hours before launching anything long.

---

## 2. The run plan

Written to `$RUNDIR/plan.md` **before** anything is launched, and not edited afterwards — if
the plan changes, the run gets a new RUNID. It is the artifact the user approves.

Required fields:

| Field | Content |
|---|---|
| `pipeline` | `nf-core/<name>` |
| `revision` | exact tag from `config/pipelines.tsv`. Never `dev`, never blank |
| `question` | one sentence: what the user wants out of this |
| `samples` | count, layout (SE/PE), read length, per-sample input size, total GB |
| `reference` | build name from the manifest (`GRCh38`, `GRCh38gatk`, `KOREF1`) and the standard paths used |
| `params` | the full contents of `params.yaml`, inline |
| `missing` | every reference the manifest marks `build`/`fetch` that this run needs, and how it will be obtained |
| `disk_estimate` | work dir GB, published results GB, and the 1.5× gate figure |
| `time_estimate` | wall-clock hours, with the basis for the number |
| `bounded_choices` | anything narrowed: samples dropped, top-N, subsampling, a caller skipped |
| `approval` | required if `time_estimate > 24 h`; record the user's yes here |

### Estimation anchors

Every time and disk figure comes from `references/estimates.md`. Do not restate numbers here.

A single 30× WGS through sarek trips the 24-hour rule on its own. Say so in the plan and get an
explicit yes before launching; do not discover it at hour 25.

**Host-specific gotcha to put in the plan for any sarek run:** the manifest gives us a classic
**BWA** index for `GRCh38gatk`, not a bwa-mem2 index. Recent sarek defaults to `bwa-mem2`, whose
index *construction* for human peaks well above this machine's RAM. Set `aligner: bwa-mem` in
`params.yaml` to reuse the index we already have.
<!-- UNVERIFIED: confirm the aligner option name and accepted values for the pinned revision via
     `nextflow run nf-core/sarek -r <REV> --help` and `grep -n aligner $NXF_ASSETS/.repos/nf-core/sarek/clones/*/nextflow_schema.json` -->

### Samplesheet schema: re-derive it, do not trust a table

nf-core samplesheet columns and parameter names drift between revisions. Before writing the
samplesheet for a pipeline/revision combination you have not used before:

```bash
PIPE=rnaseq; REV=3.18.0                        # revision from config/pipelines.tsv
nextflow pull nf-core/$PIPE -r $REV
nextflow run nf-core/$PIPE -r $REV --help
cat "$(find "$NXF_ASSETS" -path "*nf-core/$PIPE*" -name schema_input.json | head -1)"
head -3 "$(find "$NXF_ASSETS" -path "*nf-core/$PIPE*" -name samplesheet.csv | head -1)"   # shipped example, if present
```

`schema_input.json` is authoritative: it lists required columns, allowed values (e.g. `strandedness`
enums), and filename patterns. Record in the run plan which revision the samplesheet was written
against.

---

## 3. Preflight

`bin/preflight.sh` ships with the repo. Invoke it; never restate it and never overwrite it.

```bash
RUNID=20260728-rnaseq-koges-pilot
RUNDIR=$BIOINFO_HOME/runs/$RUNID
bash "$BIOINFO_HOME/bin/preflight.sh" "$RUNDIR" 180      # 180 = estimated work-dir GB
```

Exit 0 = clean, exit 1 = at least one FAIL.

Any FAIL is a hard stop. The disk check is the 1.5× gate: with an estimate of 180 GB, preflight
demands 270 GB free on ext4 and refuses otherwise. Do not talk yourself past it — an out-of-disk
death at hour 18 costs more than the wait.

---

## 4. Preview, then stub

Two cheap gates, in this order. Never skip either.

**`-preview`** resolves params and builds the DAG without executing anything. It catches schema
violations, missing required params, and unresolvable reference paths in seconds.

```bash
cd /work/nxf/$RUNID
nextflow run nf-core/rnaseq -r 3.18.0 -profile docker \
  -params-file $RUNDIR/params.yaml \
  -c $BIOINFO_HOME/config/local.config \
  -preview
```

**`-stub-run`** actually walks the whole workflow, running each module's `stub:` block instead of
the real command. It creates empty output files, so it validates channel wiring, samplesheet
parsing, and the full topology end to end — in minutes, on kilobytes.

```bash
cd /work/nxf/$RUNID
nextflow run nf-core/rnaseq -r 3.18.0 -profile docker \
  -params-file $RUNDIR/params.yaml \
  -c $BIOINFO_HOME/config/local.config \
  -work-dir /work/nxf/$RUNID/stub-work \
  --outdir /work/nxf/$RUNID/stub-results \
  -stub-run -ansi-log false
```

Use a **separate** `stub-work` directory. Stub outputs are empty files; if they land in the real
work dir, a later `-resume` can cache-hit on them and you will ship a run full of zero-byte BAMs.
Delete `stub-work` and `stub-results` before the real launch.

**Pass looks like:** the nf-core ASCII header, a params summary listing your reference paths, every
process reaching `[100%] N of N ✔`, `Completed at: …`, `Succeeded: N`, exit status 0, and
`stub-results/` containing the expected directory tree of empty files.

**Fail looks like:**

| Symptom | Meaning |
|---|---|
| `ERROR ~ Validation of pipeline parameters failed` + a bullet list | schema rejection; the bullets name the offending param or samplesheet column |
| `Missing required parameter: --outdir` | params.yaml incomplete |
| `does not exist` on a `/refs/...` path | manifest gap; run `bootstrap/04-refs.sh`, do not hand-place the file |
| `Process 'X' doesn't have a stub block` | that module has no stub upstream. Not your bug; note it and rely on `-preview` plus a real 1-sample run for that branch |
| `Unable to pull docker image` | see failure taxonomy below; fix before the real launch, not during |

A stub run that fails is a launch that would have failed after burning real hours. Fix, re-stub,
then launch.

---

## 5. Launch

Write this into `$RUNDIR/cmd.sh` verbatim so the exact invocation is recorded next to the plan, then
source it. Timestamped report filenames mean a re-launch after a failure never collides with the
previous attempt's reports, and you keep the history of attempts.

```bash
#!/usr/bin/env bash
set -euo pipefail

RUNID=20260728-rnaseq-koges-pilot
PIPE=nf-core/rnaseq
REV=3.18.0                                  # from config/pipelines.tsv
RUNDIR=/mnt/d/bioinfo-agent/runs/$RUNID
NXFDIR=/work/nxf/$RUNID
TS=$(date +%Y%m%d-%H%M%S)

mkdir -p "$NXFDIR/work" "$NXFDIR/results" "$NXFDIR/reports"
cd "$NXFDIR"                                # launch dir MUST be ext4: .nextflow/cache lives here

nohup nextflow -log "$NXFDIR/.nextflow.log" \
  run "$PIPE" \
    -r "$REV" \
    -profile docker \
    -params-file "$RUNDIR/params.yaml" \
    -c /mnt/d/bioinfo-agent/config/local.config \
    --outdir "$NXFDIR/results" \
    -work-dir "$NXFDIR/work" \
    -with-report   "$NXFDIR/reports/report.$TS.html" \
    -with-trace    "$NXFDIR/reports/trace.$TS.txt" \
    -with-timeline "$NXFDIR/reports/timeline.$TS.html" \
    -with-dag      "$NXFDIR/reports/dag.$TS.html" \
    -ansi-log false \
    -resume \
  > "$NXFDIR/nextflow.stdout.log" 2>&1 &

echo $! > "$NXFDIR/nextflow.pid"
echo "launched $RUNID pid $(cat "$NXFDIR/nextflow.pid"); log: $NXFDIR/nextflow.stdout.log"
```

Notes on the shape:

- `-log` is a **core** option and must appear before `run`; `-with-*`, `-resume`, `-profile` are
  **run** options and must appear after the pipeline name. Getting this backwards produces an
  unhelpful "Unknown option" error.
- `-resume` is on the first launch too. There is no cache yet so it does nothing, and it makes the
  command byte-identical on every attempt — which is the whole point.
- `-ansi-log false` turns the live-redraw display into append-only lines. Without it,
  `nextflow.stdout.log` is megabytes of escape sequences.
- `--outdir` is a pipeline param and could equally live in `params.yaml`; keep it in exactly one
  place, and if it is in the params file, drop it here.
- Reports are per-attempt. The alternative is `report.overwrite = true` / `trace.overwrite = true`
  in `local.config`; without one or the other, the second launch aborts because the report file
  already exists.
- Set `trace.raw = true` in `local.config`. The default trace writes durations as `1h 2m` and memory
  as `3.4 GB`, which is unsortable; raw writes milliseconds and bytes.
- `nohup … &` survives the terminal closing. It does **not** survive `wsl --shutdown`, Windows
  sleep, or a forced reboot. If `tmux` is available (`sudo apt-get install -y tmux`) prefer running
  under it so you can re-attach and see live output.

**Stopping cleanly:** `kill -TERM "$(cat $NXFDIR/nextflow.pid)"`. Nextflow traps SIGTERM, kills
running tasks, and flushes the cache — the run stays resumable. `kill -9` leaves orphaned containers
holding CPU and disk; if you must, follow with `docker ps` and `docker kill <ids>`.

---

## 6. Monitoring

Four things to read, in decreasing order of usefulness.

**The trace file** is appended as tasks complete and is the only machine-readable live view. Resolve
columns by header name, not position — the field set is configurable and nf-core changes it.

```bash
T=$(ls -t /work/nxf/$RUNID/reports/trace.*.txt | head -1)

# status counts
awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next}{c[$h["status"]]++}END{for(s in c)print s, c[s]}' "$T"

# anything that did not finish clean
awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} $h["exit"]!="0" && $h["status"]!="RUNNING" \
  {print $h["name"], $h["status"], "exit="$h["exit"]}' "$T"

# peak memory per process (peak_rss, falling back to rss on older field sets)
awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)h[$i]=i; m=("peak_rss" in h)?h["peak_rss"]:h["rss"]; next}
            {printf "%-55s %s\n", $h["name"], $m}' "$T" | sort -k2 -h | tail -15
```

**`nextflow.stdout.log`** — `tail -f` it. With `-ansi-log false` you get one line per state change
plus the final summary block.

**`.nextflow.log`** — the real diagnostics. When a task fails, the error block names the work
directory; that is where you go next.

```bash
grep -nE 'ERROR|WARN|Caused by|Command exit status|Work dir' /work/nxf/$RUNID/.nextflow.log | tail -40
```

**The HTML execution report** is written at completion (success or failure), not incrementally.
Do not wait on it mid-run; the trace is the live source.

### Slow but healthy vs wedged

| Signal | Healthy | Wedged |
|---|---|---|
| `docker stats --no-stream` | at least one container with meaningful CPU% | all near 0% |
| `vmstat 5 3` | `r` non-zero, or `wa` high (I/O-bound but progressing) | `r`=0, `wa`=0, `si`/`so`=0 |
| `find /work/nxf/$RUNID/work -newermt '-10 min' \| head` | files appearing | nothing for >10 min |
| `df -h /work` | shrinking slowly | pinned at 0% avail |
| trace last line timestamp | advancing | frozen |

Two specific slow-but-healthy states worth recognising before you kill anything: heavy **swap**
(`si`/`so` non-zero in `vmstat`, `free -g` showing swap used) means the memory ceiling is too low and
the run will finish, eventually, badly — lower concurrency rather than killing; and **drvfs read
stalls** (high `wa`, low CPU, all inputs under `/mnt/d`) means the inputs should have been staged to
ext4.

Genuinely wedged, with all four "wedged" signals true, is almost always the Docker daemon
(`docker ps` hangs → `sudo systemctl restart docker`) or an exhausted filesystem. Neither is fixed
by waiting.

---

## 7. Failure taxonomy

Always start at the work dir named in the error block:

```bash
cd <work-dir-from-error>
cat .command.sh    # the exact command, after interpolation
cat .command.err   # stderr — the actual reason, 90% of the time
cat .command.log   # stdout+stderr combined
bash .command.run  # re-run this one task standalone, in its container, to iterate
```

| Exit | Name | What it means here | Fix |
|---|---|---|---|
| 137 | 128+SIGKILL | OOM. On a single-node local executor this is usually the **WSL VM's** OOM killer, not a per-container cgroup limit | see below |
| 140 | walltime | task exceeded its `time` directive | raise `time` for that process in `local.config`, `-resume` |
| 143 | 128+SIGTERM | Nextflow terminated the task — a *different* task failed first, or you sent SIGTERM | find the real failure above it in the log |
| 1 | tool error | read `.command.err` | depends |
| 125/126/127 | docker layer | daemon rejected the run / binary not executable / not found in image | container or profile problem, not a data problem |

**137 / OOM.** Because Nextflow's local executor uses the `memory` directive for *scheduling*, not
as a hard container limit, an over-allocating task can get an innocent neighbour killed instead of
itself. Confirm who died before changing anything:

```bash
sudo dmesg -T | grep -iE 'out of memory|killed process' | tail
free -g
```
<!-- UNVERIFIED: whether the pinned Nextflow version applies a hard cgroup memory limit to
     local-executor docker tasks; confirm with `docker inspect <cid> --format '{{.HostConfig.Memory}}'`
     on a live task -->

Three fixes, in order of preference: raise the WSL memory ceiling in `.wslconfig` (if `free -g`
shows ~31 GB, this is the real bug); lower the effective concurrency so fewer heavy tasks co-run;
raise the `memory` directive for the offending process in `local.config`. Then `-resume`. Raising
`memory` alone does not invalidate the cache, so completed tasks are reused.

**Disk full.** `.command.err` contains `No space left on device`, or Nextflow reports a staging
failure. `df -h /work`. Recovery: free space *outside* the current work dir — old runs' work dirs
(section 9), `docker image prune`, `/work/staging`. Never delete the current run's work dir to make
room; you lose the resume cache and start over. Then `-resume`. If there is genuinely no room, the
estimate was wrong: stop, re-plan, re-scope.

**Container pull failure.** `Unable to pull docker image` / `TLS handshake timeout` /
`toomanyrequests`. Test the daemon's network first, since WSL DNS breaks in a recognisable way:

```bash
docker run --rm quay.io/biocontainers/fastqc:0.12.1--hdfd78af_0 fastqc --version
cat /etc/resolv.conf
```

If DNS is the problem, `/etc/resolv.conf` is regenerated on every distro start unless
`generateResolvConf=false` is set in `/etc/wsl.conf`; write a working nameserver and pin it. If it
is Docker Hub rate-limiting, note that nf-core images come mostly from `quay.io` — the rate limit
usually only bites on a base image, and `docker pull` retried by hand succeeds. Pre-pull before a
long run: `nextflow inspect nf-core/<pipe> -r <REV> -profile docker` lists every image the run will
need.
<!-- UNVERIFIED: `nextflow inspect` availability and exact output shape on the installed Nextflow
     version; confirm with `nextflow inspect -help` -->

**Missing reference.** Do not hand-place the file. Add a manifest row in
`config/refs.manifest.tsv`, re-run `bootstrap/04-refs.sh`, re-run preflight, `-resume`. A file that
is not in the manifest is invisible to the next machine and to the next run.

**Samplesheet rejection.** The nf-schema error names the row and column. The three that actually
happen: CRLF line endings from a Windows editor (preflight catches this); a `strandedness` or
similar enum value not in `schema_input.json`; a path that exists but is relative to the wrong
directory. Fix the samplesheet, `-resume`. Because modern nf-core pipelines parse the samplesheet at
the DSL level rather than through a process, editing it does not by itself invalidate downstream
tasks whose own inputs are unchanged.

**One sample failing vs the whole run.** Decide deliberately, and say which you chose:

- *Fix and resume* — the sample is salvageable (truncated FASTQ re-copied, wrong path corrected).
  Preferred. `-resume` re-runs only that sample's branch.
- *Drop the sample* — remove its row from the samplesheet, `-resume`. Other samples cache-hit.
  This is a **bounded choice**: it goes in the handoff, named, with the reason.
- *Tolerate the failure* — add to `local.config`:
  ```groovy
  process { withName: '.*:SOME_PROCESS' { errorStrategy = 'ignore' } }
  ```
  Use sparingly. MultiQC will then be built from partial input, and the QC verdict must say so.

Never respond to a single failing sample by re-running the whole cohort from scratch.

---

## 8. `-resume` semantics

Nextflow hashes each task and skips it if a matching entry exists in the cache *and* the outputs are
still in the work dir. **Both** halves are required: `.nextflow/cache/<session-id>/` in the launch
dir, and `/work/nxf/$RUNID/work/`. Lose either and resume degrades to a full re-run, silently.

Part of the hash:

- the task's command text **after interpolation** — so any param that reaches the command line, and
  `ext.args` in the config, and `${task.cpus}` where the tool takes a thread count;
- each input file's path, size and last-modified time (default caching mode);
- the container image reference, tag included;
- the module's own code, which is why bumping `-r` invalidates broadly.

**Not** part of the hash: the `memory` directive, `time`, `errorStrategy`, `maxRetries`. You can
raise memory and resume with the cache fully intact. `cpus` is the trap — it usually *does* appear
in the command (`-@ ${task.cpus}`), so changing it invalidates that process.

Things that quietly destroy the cache on this host:

- Changing `-work-dir`. Cache entries hold absolute paths; a different work dir is a different run.
- Relaunching from a different directory. `.nextflow/cache` is relative to the launch dir. Always
  `cd /work/nxf/$RUNID` first.
- Copying or re-syncing input FASTQs. `cp` sets a new mtime, and the default cache mode reads mtime.
  If inputs live on drvfs, or you expect to move them, set `cache = 'lenient'` (path+size only) in
  `local.config` before the first run — not after.
- Editing `params.yaml` for a value that reaches a command line.
- A floating revision. `-r dev` or an unpinned branch changes under you.

Targeting a specific session:

```bash
nextflow log                                 # session IDs, run names, status
nextflow log <run-name> -f name,status,exit,workdir
nextflow run … -resume <session-id>          # resume a specific one, not just the last
```

**Standing rule: the work directory is never deleted while a run may still be resumed.** Not to free
disk, not to tidy up, not because the run "finished anyway". This rule has no exceptions inside the
7-day hold.

---

## 9. Cleanup

Reclaiming the work dir is safe only when **all** of these hold:

1. The run reached `Succeeded: N` with no `Failed`/`Ignored` you have not accounted for.
2. Results are rsynced to `/mnt/d` and verified — file count and `du -sh` match, MultiQC opens.
3. The handoff is written and the user has seen it.
4. At least 7 days have passed, or the user has explicitly said they are done with the run.

Never on a run that can still be resumed, and never as a mid-run fix for a full disk — free space
somewhere else instead (§7, Disk full).

The sync-out and the verification:

```bash
rsync -a --info=progress2 /work/nxf/$RUNID/results/  "$RUNDIR/results/"
rsync -a                  /work/nxf/$RUNID/reports/  "$RUNDIR/reports/"
cp /work/nxf/$RUNID/.nextflow.log "$RUNDIR/reports/nextflow.log"
diff <(cd /work/nxf/$RUNID/results && find . -type f | sort) \
     <(cd "$RUNDIR/results"        && find . -type f | sort) && echo "results synced clean"
du -sh /work/nxf/$RUNID/work /work/nxf/$RUNID/results
```

Then, and only then:

```bash
nextflow log                                       # find the run name
nextflow clean -n -before <run-name>               # DRY RUN first, always
nextflow clean -f -before <run-name>               # removes work dirs + cache entries for older runs
```

Or, for one finished run: `rm -rf /work/nxf/$RUNID/work` and keep `.nextflow/`, the logs and the
reports — they are small and they are the record.

How much this frees: the work dir is typically 80–95% of a run's footprint. Concretely, ~90% of
~400 GB for a 30× WGS sarek run, ~90% of ~120 GB for a six-sample human RNA-seq run. Published
results are the small part.

**Deleting inside ext4 does not give the space back to Windows.** The VHDX grows and never shrinks
on its own; it will sit at its high-water mark on `D:`. To actually reclaim, from PowerShell:

```powershell
wsl --shutdown
wsl --manage Ubuntu-24.04 --set-sparse true     # WSL 2.0+; makes the VHDX auto-shrinking
```
<!-- UNVERIFIED: --set-sparse flag name/availability on the installed WSL version; check `wsl --help`.
     Fallback: diskpart → select vdisk file="D:\wsl\ubuntu-24.04\ext4.vhdx" → attach vdisk readonly
     → compact vdisk → detach vdisk -->

Docker's image cache also accretes. `docker system df` to see it; `docker image prune -a` only when
it exceeds ~100 GB, and understand it forces a re-pull of everything on the next run.

---

## 10. Concurrency policy

**One heavy pipeline at a time on this host.** A second heavy run is not a speedup, it is a slowdown
with extra failure modes.

- Two Nextflow processes do not know about each other. Each sizes its local executor pool from its
  own config, so each schedules up to the full pool in `config/local.config` — two runs put twice
  that many CPU-slots' worth of tasks on the VM, plus context-switch overhead.
- RAM is the hard wall, not CPU. The WSL VM has a fixed ceiling (`config/wslconfig.example`).
  Two STAR alignments at ~35 GB each do not fit, and the resulting OOM kill lands on
  whichever process the kernel picks — quite possibly the run you cared about.
- Both runs write to the same 1 TB VHDX. Disk-full kills both, and the disk estimate you approved
  was computed for one.
- Page cache thrash. Two runs streaming different multi-GB references evict each other's cache and
  both lose the benefit.
- Attribution. When the machine wedges, you cannot tell which run did it, and you have to kill both.

Budget: the Nextflow pool is set once in `config/local.config` and already sits below the WSL VM
ceiling. Do not override it per-run without saying why in the run plan.
<!-- UNVERIFIED: nf-core moved from `--max_cpus/--max_memory` to the `resourceLimits` directive
     around nf-core/tools 3.x; confirm which the pinned revision uses via
     `nextflow run nf-core/<pipe> -r <REV> --help | grep -iE 'max_cpus|resourceLimits'` -->

What *is* allowed alongside a heavy run: a stub run, a `-preview`, an `nf-core/fetchngs` download
(network-bound, near-zero CPU), or `nf-core/differentialabundance` on a counts matrix — each
explicitly capped, e.g. `-c` with a small override giving it 4 CPUs and 8 GB.

Enforce it rather than remembering it. Wrap the launch:

```bash
exec 9>/work/nxf/.heavy.lock
flock -n 9 || { echo "another heavy run holds the lock; not launching"; exit 1; }
# … launch here; the lock is released when this shell exits
```

---

## 11. Handoff

When the run completes, write `$RUNDIR/handoff.md`:

- run ID, pipeline, revision, wall-clock duration, exit status;
- where the results are (the `/mnt/d` path and the `\\wsl.localhost\…` path);
- MultiQC location and the **QC verdict**: per-sample pass / borderline / fail against stated
  thresholds, with the metric and the number;
- every bounded choice made, named — samples dropped, processes set to `ignore`, top-N cuts,
  a reference substituted;
- anything still missing from the reference store that limited the run;
- work dir path and the date it becomes eligible for cleanup.

The ceiling holds: report QC verdicts and file locations. "Sample 7 has 42% duplication and 18M
assigned reads, below the 25M we set as the floor" is the job. "Therefore *GENE* is upregulated in
the Korean cohort" is not.

---

## Stop conditions

Hard stops. Each requires the user, not a judgement call:

- Estimated wall clock > 24 h → explicit approval before launch.
- Free ext4 space < 1.5 × the disk estimate → refuse.
- Preflight FAIL → refuse.
- Stub run fails → refuse to launch the real run.
- A second heavy pipeline requested while one is running → queue it, do not co-run it.
- Any request to delete or clean a work dir that a run might still resume from → refuse and explain.
- A biological interpretation is being asked for → hand back the QC numbers and the file paths.
