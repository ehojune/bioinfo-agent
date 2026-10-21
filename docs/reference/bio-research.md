# Bio Research: scope and comparison plan

Checked **2026-10-21**. Recommendation: use Bio Research for broad research tasks;
evaluate bioinfo-agent's operational contribution before claiming an advantage or
submitting another general bioinformatics plugin. No comparative runs were made.
Evaluation and conditional adoption are tracked in [#76](https://github.com/ehojune/bioinfo-agent/issues/76).

## Identity and dates

Anthropic publishes [Bio Research][listing]. The inspected [source][source] is
version **1.2.0**, commit `bc8f6922cfeea215a202cdcc9f0d299a990889a8`, Apache-2.0.
Connected services have separate terms and authentication requirements.

| Date | Verified event |
|---|---|
| 2025-10-20 | [Claude for Life Sciences][life] introduced scientific skills, including single-cell QC |
| 2026-01-11 | [Expansion announcement][expansion]: Nextflow, scvi-tools, Allotrope and problem selection |
| 2026-01-30 | [Cowork plugin launch][launch] explicitly included Biology research |
| Unknown | First publication date of the current Directory listing |

The earliest accessible `bio-research/` [commit][initial] is dated Jan 29 at
22:36 UTC (Jan 30 KST). Its importer, Matt Piccolella, is not thereby the sole
author of every skill. A commit timestamp does not prove when a repository became
public. Current features must not be backdated to the initial launch.

## Current source inventory

| Skill | Scope |
|---|---|
| `single-cell-rna-qc` | Single-cell RNA QC, MAD filtering and plots |
| `scvi-tools` | Single-cell integration, batch correction and annotation |
| `nextflow-development` | nf-core rnaseq 3.22.2, sarek 3.7.1, atacseq 2.1.2; environment/test checks, samplesheets, execution, resume and QC |
| `instrument-data-to-allotrope` | Instrument files to Allotrope Simple Model JSON or flattened CSV |
| `scientific-problem-selection` | Research question selection and project assessment |
| `start` | Orientation and available-tool discovery |

The [MCP configuration][mcp] has 11 entries: 10 nonempty URLs (PubMed, BioRender,
bioRxiv, Consensus, ClinicalTrials.gov, ChEMBL, Synapse, Wiley, Owkin, Open Targets)
and an empty Benchling URL. 10x Genomics and ToolUniverse are optional separate
server installations. Endpoints were inspected, not connectivity-tested.

The listing advertises six analysis skills and clinical-trial protocol generation;
the inspected tree contains **five analysis skills plus `start`**, without that
protocol skill. Use the pinned source inventory for experiments. The Nextflow
skill specifically describes itself as a research/education prototype requiring
use-case validation; this is not a disclaimer about every Bio Research skill.

## What bioinfo-agent must demonstrate

Version pinning, input checks, test runs, resume and technical QC already overlap.
Potential additional contributions are actual output-filesystem checks, bounded
cache-retention guards, existing-BAM re-entry checks and evidence-based run-state
triage. Their implementation and limits are in [control-spec.md](control-spec.md);
presence alone establishes neither superiority nor patentability.

Use the [matched evaluation contract](related-work.md#evaluation-contract-before-claiming-an-advantage):
standard completion, interrupted recovery, existing BAM reuse and invalid-input
controls. Compare direct nf-core, Bio Research and bioinfo-agent, then ablate the
relevant guards. Report failures, interventions and avoidable recomputation as
well as completion, QC-boundary errors, cost and runtime. Hold models, pins,
cache state and budgets fixed; provide documented setup to every baseline.
Start with shared ATAC-seq 2.1.2. Shipped rnaseq/sarek pins differ (bioinfo-agent:
3.18.0/3.5.1); test any common-pin adaptation explicitly and report it separately
from as-shipped compatibility. A deliberate pin refusal is not a reliability failure.

For publication and filing implications, see [submission-filing.md](submission-filing.md).
Map each candidate technical feature to dated prior-art evidence; today's source
tree and a product launch date cannot substitute for that search.

## Distribution and LabHQ decision

Keep one source repository. A future Directory package should offer a bounded,
validated task: run-evidence inspection, recovery planning and technical-QC
handoff. Full Git setup retains containers, reference data, host tuning and long
pipeline execution. Shared contracts should be bundled at release, not fetched
as changing remote instructions. Package design remains provisional until the
comparison establishes a useful gap; no rename or listing is implemented here.

[Vercel agent-browser][vercel] separates skill installation from CLI/browser setup;
[Microsoft playwright-cli][playwright] separates runtime setup from `install --skills`.
Both keep these pieces in one repository. These are packaging precedents, not
verified Claude Directory approvals or instructions to copy their loading model.

[Directory submission][submit] accepts plugin bundles, but validation does not
guarantee listing or placement in Health & life sciences. Similar scope alone is
not a demonstrated rejection rule. Admission is not scientific validation.

LabHQ source at `8487fc8c` already integrates overlapping literature/drug MCP
services and bioinfo-agent. A selective trial is feasible:

- Start with `scientific-problem-selection` for the biologist; consider scvi-tools
  or single-cell QC only if the role's existing methods leave a gap.
- Package only the chosen skill and required references, preserving attribution.
  LabHQ's [`required_skills`][adapter] checks presence, not exposure: pointing at
  the full plugin loads the full directory. Plugin fields are Claude-Code-only.
- Preserve tool permissions, strict MCP configuration, read-only isolation and
  data-release rules. New services inherit no private-data permission. Compare
  fixed public cases before role-level adoption. No LabHQ runtime was changed.

[listing]: https://claude.com/marketplace/plugins/bio-research
[source]: https://github.com/anthropics/knowledge-work-plugins/tree/bc8f6922cfeea215a202cdcc9f0d299a990889a8/bio-research
[mcp]: https://github.com/anthropics/knowledge-work-plugins/blob/bc8f6922cfeea215a202cdcc9f0d299a990889a8/bio-research/.mcp.json
[life]: https://www.anthropic.com/news/claude-for-life-sciences
[expansion]: https://www.anthropic.com/news/healthcare-life-sciences
[launch]: https://claude.com/resources/articles/cowork-plugins?via=join
[initial]: https://github.com/anthropics/knowledge-work-plugins/commit/7c35640e492acda9dfbd18c05d88e32776036b51
[submit]: https://claude.com/docs/plugins/submit
[adapter]: https://github.com/ehojune/bioinfo-team-3d/blob/8487fc8c/labhq/adapters/claude_code.py#L298
[vercel]: https://github.com/vercel-labs/agent-browser/blob/fd93075e55a21a47fcb36d7433361daa867a0580/README.md#installation
[playwright]: https://github.com/microsoft/playwright-cli/blob/b1a5903c5b633b8c9f843ad7b629c2a78437040c/README.md#installation
