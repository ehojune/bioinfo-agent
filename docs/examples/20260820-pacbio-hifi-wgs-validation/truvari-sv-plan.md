# Truvari SV accuracy validation — work instruction (NOT YET RUN)

`hap-py-accuracy.md` closed the small-variant half of accuracy validation. **pbsv is still
unbenchmarked.** This file is the instruction for closing that gap; it is a plan, not a result.
Nothing here has been executed — every number below is a property of a truth set, verified by
reading it, not a measurement of our pipeline.

## Why hap.py cannot be reused

hap.py is a GA4GH **small-variant** comparator. Its haplotype-aware matching builds local ALT
sequences to decide whether two differently-written variant sets are the same, which requires
sequence-resolved ALTs; pbsv emits symbolic `<DEL>`/`<DUP>`/`<INV>` and `BND` records. And the
GIAB small-variant truth set (v4.2.1) contains nothing ≥50 bp, so there would be nothing to
compare against. SV benchmarking needs a different tool and a different truth set.

**Truvari** is that tool, and it is GIAB's own choice: `NIST_SV_v0.6/README_SV_v0.6.txt`
recommends it by name, and `NIST_SV_v0.6/GIAB_Evaluations/` contains GIAB's own
`Truvari_Report_*.xlsx` outputs.

## Truth set — pick one, and the choice is forced by reference build

| | Tier1 SV v0.6 | T2T-Q100 draft (`stvar`) |
|---|---|---|
| reference | **GRCh37 only** ("GRCh38 callsets are under development" — its README) | GRCh37, **GRCh38**, CHM13 |
| status | stable, peer-reviewed (doi:10.1101/664623) | **draft** (`defrabbV0.012-20231107`) |
| content | sequence-resolved INS/DEL ≥50 bp, `PASS` filter meaningful | INS/DEL, **FILTER column is all `.`** |
| in manifest | `release_truthsets.tsv` → `NIST_SV_v0.6/` | `trio_analysis.tsv` → `NIST_HG002_DraftBenchmark_defrabbV0.012-20231107/` |
| S3 mirror | present | **FTP only** — S3 returns NoSuchKey (verified) |

**Both are HG002-only.** No other GIAB sample has an SV truth set, so SV accuracy is a
single-sample claim no matter which you pick. Small-variant validation stays available for
HG001–HG007; SV validation does not.

The pipeline was validated on GRCh38, so **Q100 `stvar` on GRCh38 is the path that needs no
liftover** — at the cost of benchmarking against a set its own authors label draft. The
alternative is running pbsv on hs37d5/GRCh37-aligned GIAB data (which exists — see
`giab-pacbio-states.md`) and using the stable Tier1 v0.6. State whichever you choose as a
bounded choice, the way `hap-py-accuracy.md` did for v4.2.1-over-v5.0q.

### Q100 GRCh38 `stvar` coverage, verified by reading the files

```
GRCh38_HG002-T2TQ100-V1.0_stvar.benchmark.bed   264 intervals, 2,792,296,536 bp (genome-wide)
  chr20: 10 intervals / 58,920,408 bp; the first spans 81,335-25,737,456
GRCh38_HG002-T2TQ100-V1.0_stvar.vcf.gz          9.5 MB
```

Fetch from `https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/analysis/NIST_HG002_DraftBenchmark_defrabbV0.012-20231107/`
(not the S3 mirror).

## Scope decision: the existing chr20:1-3 Mb slice is enough for mechanics, not for accuracy

The hap.py work reused a chr20:1-3,000,000 slice. That region overlaps a Q100 benchmark interval
(chr20 81,335-25,737,456) but is **not fully inside it** — bases 1-81,334 precede the benchmark.
So the include BED must be the **intersection**, not the raw slice: a raw 1-3 Mb BED would let
pbsv calls in that first 81 kb count as false positives and understate precision.

```bash
# clip the Q100 benchmark BED to the slice -> chr20 81,335-3,000,000 (2,918,665 bp evaluated).
# Default whitespace splitting handles BED; the \t lives inside awk printf, so no
# shell-level tab escaping is involved.
awk '$1=="chr20" && $2<3000000 {
       s=$2; e=($3>3000000?3000000:$3)
       if (e>s) printf "%s\t%d\t%d\n",$1,s,e
 }' \
    GRCh38_HG002-T2TQ100-V1.0_stvar.benchmark.bed > stvar_chr20_1_3M.bed
```

Truth records in the slice, before and after that intersection (remote `tabix`, verified) — the
difference is exactly why it matters:

| | raw chr20:1-3,000,000 | benchmark-clipped (81,336-3,000,000) |
|---|---|---|
| DEL | 33 total / 16 ≥50 bp | 32 total / 16 ≥50 bp |
| INS | 59 total / 35 ≥50 bp | 58 total / 34 ≥50 bp |
| **sum** | **92 / 51** | **90 / 50** |

**50** benchmarkable SVs is the real denominator, and it means **one missed call moves recall by
2 points**. That is fine for proving the Truvari branch runs and produces a sane report; it is not
an accuracy claim. Say so explicitly in the writeup, and if a real accuracy number is wanted,
widen the region (chr20 whole: ~59 Mb of benchmark regions) or go whole-genome and budget
accordingly.

## Method

Pin `quay.io/biocontainers/truvari:5.4.0--pyhdfd78af_0` (verified active on quay 2026-08-21;
5.x is current, 4.3.1 is the last 4.x). Note GIAB's README shows the **pre-4.0** CLI
(`truvari.py -b … -c …`); modern Truvari is `truvari bench`, and `--giabreport` no longer exists.

```bash
# inputs: bgzipped + tabix-indexed on both sides; -f is the same FASTA the pipeline called against
truvari bench \
  -b GRCh38_HG002-T2TQ100-V1.0_stvar.vcf.gz \
  -c <run>/03_VCF/SV_pbsv/HG002.<dataset>.<ref>.pbsv.vcf.gz \
  -f chr20.fa \
  --includebed stvar_chr20_1_3M.bed \
  --sizemin 50 \
  -o truvari-out/
```

Parameters that are decisions, not defaults:

- **`--sizemin 50`** — pbsv's default `--min-sv-length 20` emits 20-49 bp calls. Those fall in
  neither benchmark: the small-variant set stops at ~50 bp, and Q100/Tier1 start at 50 bp
  (Tier1's confident regions deliberately *exclude* regions containing 20-49 bp variants). Cut
  at 50 and record that you did.
- **Restrict to DEL/INS before comparing.** Tier1's README states outright that all its calls are
  DEL or INS; Q100 `stvar` in the slice is likewise DEL+INS only. pbsv's `DUP`/`INV`/`BND` have
  no truth to match and would score as pure false positives, understating precision for a reason
  that has nothing to do with the caller. Filter them out (`bcftools view -i 'SVTYPE="DEL" ||
  SVTYPE="INS"'`) and report their count separately as "not benchmarkable against this truth set".
- **Do NOT pass `--passonly` with Q100.** Its FILTER column is entirely `.` (verified on the
  92 slice records) — `--passonly` would be a no-op at best. With Tier1 v0.6 the opposite holds:
  GIAB's own recommendation uses `--passonly` because PASS is what marks its high-confidence set.
- `--refdist` (GIAB's example used `-r 2000`; Truvari's default is 500) and `--pctseq` /
  `--pctsize` (default 0.7 each) set matching stringency. Run at defaults first, and if you also
  report a looser pass, report both — do not quietly pick whichever looks better. `--pctseq 0`
  matches on size+type only, which GIAB's README suggests for non-sequence-resolved callsets.

## Deliverable

A `truvari-sv-accuracy.md` beside `hap-py-accuracy.md`, plus the raw `truvari-out/summary.json`
committed like `happy-outputs/` was. Follow that file's discipline: measured numbers only, the
denominator stated (how many truth SVs were in scope), every bounded choice named, and no
threshold invented — report precision/recall/F1 and let the reader judge. Also mirror its honesty
about what the region does *not* cover.

Then update: this folder's `handoff.md` (SV gap closed), the pipeline `README.md` Validation
section, and `pipeline-selection.md` §4.20.

## Scripts to write

`prepare-truvari-inputs.sh` and `run-truvari.sh`, mirroring `prepare-happy-inputs.sh` /
`run-happy.sh` — the point of those two files is that scratch dirs get reclaimed on this host and
the inputs must be rebuildable from committed commands.
