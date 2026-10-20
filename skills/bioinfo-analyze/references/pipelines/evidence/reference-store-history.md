# Reference-store history

Lookup only: dated observations, not current file existence. Run the manifest dry-run again.

## 9. Reference-store gaps this document exposes

Selecting a pipeline surfaces references the manifest does not yet carry. These are missing rows,
not missing files — fix `config/refs.manifest.tsv` and re-run `bootstrap/04-refs.sh` rather than
hand-placing anything under `/refs`.

**This table is about rows only, and a row is not a file.** Rows removed from it over time because
the row does exist: `genomes/GRCh38/index/bowtie2/` (a `build` row from day one),
`genomes/GRCh38/index/bwameth/` (added 2026-08-05, exactly as section 4 already said),
`genomes/GRCh38/bed/blacklist.bed` (`fetch` row, PR #10), and — added 2026-08-06 during run
`20260806-cutandrun-hpsc-h3k27me3-smoke`, see §4.8 — the E. coli K12 spike-in fasta and its
bowtie2 index, plus cutandrun's own bundled GRCh38 blacklist.

**Which of those files actually exist is a separate question, and this paragraph has been wrong
about it in both directions.** It first implied a missing row meant a missing file; the correction
then overshot and asserted bowtie2/bwameth/blacklist were "still absent" with
`/refs/genomes/GRCh38/index/` an empty directory. Re-checked with `bash bootstrap/04-refs.sh
--dry-run` on 2026-08-07: **bowtie2 `OK` (6 entries), blacklist `OK`, E. coli fasta `OK`** —
bwameth is the one still `NOT BUILT`, as is the E. coli bowtie2 index. Do not repeat any of these
statuses from memory; the file-level list lives in `references/reference-store.md` and the dry-run
outranks both documents.

| Standard path | Mode | Needed by | Note |
|---|---|---|---|
| `genomes/GRCh38/index/bwa/` | build | chipseq (`--aligner bwa`), methylseq bwameth | the existing BWA index is on `GRCh38gatk`, a different FASTA |
| `genomes/GRCh38/fasta/genome.dict` | build | any GATK-adjacent step on the UCSC build | already a `build` row; still absent |

Everything already flagged missing in `references/reference-store.md` — both `.dict` files, the
GATK bundle, STAR/salmon/bismark indexes, VEP/snpEff caches — applies here too. State the missing
pieces in the run plan **before** starting, with the time cost of producing each.
