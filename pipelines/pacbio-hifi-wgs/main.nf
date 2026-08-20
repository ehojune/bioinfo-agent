#!/usr/bin/env nextflow
/*
 * pacbio-hifi-wgs — PacBio HiFi human WGS germline pipeline.
 * See nextflow.config header and README.md for usage. Zero plugins by design.
 */
nextflow.enable.dsl = 2

VALID_TYPES = ['subreads', 'hifi_bam', 'hifi_fastq', 'aligned_bam']
NAME_RE     = ~/^[A-Za-z0-9._-]+$/

def helpMessage() {
    log.info """
    pacbio-hifi-wgs v${workflow.manifest.version}
    ============================================
    Usage:
      nextflow run pipelines/pacbio-hifi-wgs -profile docker \\
        --input samplesheet.csv --fasta GRCh38.fa --outdir results

    Samplesheet (CSV, header required):
      sample,dataset,input_type,file[,index]
        sample      e.g. HG002                     [A-Za-z0-9._-]
        dataset     e.g. PacBio_CCS_15kb           [A-Za-z0-9._-]
        input_type  subreads | hifi_bam | hifi_fastq | aligned_bam
        file        path to .subreads.bam / hifi uBAM / .fastq(.gz) / sorted .bam
        index       optional: .pbi (subreads) or .bai (aligned_bam)
      Rows sharing (sample,dataset) are merged after alignment.

    Key params (see nextflow.config for all):
      --fasta               reference FASTA (required)
      --ref_name            name used in output files [default: fasta basename]
      --skip_deepvariant / --skip_clair3 / --skip_pbsv / --skip_phasing / --skip_qc
      --gvcf                also emit DeepVariant gVCF
      --ccs_chunks N        CCS scatter width per movie [8]
      --clair3_model        hifi | hifi_revio | hifi_sequel2 [hifi_revio]
      --phase_vcf           deepvariant | clair3 [deepvariant]
      --pbsv_tandem_repeats optional TRF bed
    Profiles: docker, singularity, sge (combine: -profile sge,singularity), test
    """.stripIndent()
}

// Minimal CSV parser: no quoted fields, comma-separated, '#' comments allowed.
def parseSamplesheet(sheet) {
    def lines = sheet.readLines().findAll { it.trim() && !it.trim().startsWith('#') }
    if (lines.size() < 2) error "Samplesheet has no data rows: ${sheet}"
    def header = lines[0].split(',', -1)*.trim()
    def required = ['sample', 'dataset', 'input_type', 'file']
    def missing = required - header.toList()
    if (missing) error "Samplesheet is missing required column(s): ${missing.join(', ')}"
    def rows = []
    lines.tail().eachWithIndex { line, i ->
        def vals = line.split(',', -1)*.trim()
        if (vals.size() != header.size())
            error "Samplesheet line ${i + 2}: expected ${header.size()} fields, got ${vals.size()}: '${line}'"
        def row = [header, vals].transpose().collectEntries { k, v -> [k, v] }
        if (!(row.sample ==~ NAME_RE))  error "Line ${i + 2}: bad sample '${row.sample}' (allowed: A-Za-z0-9._-)"
        if (!(row.dataset ==~ NAME_RE)) error "Line ${i + 2}: bad dataset '${row.dataset}' (allowed: A-Za-z0-9._-)"
        if (!(row.input_type in VALID_TYPES))
            error "Line ${i + 2}: input_type '${row.input_type}' not one of ${VALID_TYPES.join('|')}"
        if (!row.file) error "Line ${i + 2}: 'file' is empty"
        if (row.input_type == 'subreads'   && row.index && !row.index.endsWith('.pbi'))
            error "Line ${i + 2}: index for subreads must be a .pbi"
        if (row.input_type == 'aligned_bam' && row.index && !row.index.endsWith('.bai'))
            error "Line ${i + 2}: index for aligned_bam must be a .bai"
        if (row.input_type in ['hifi_bam', 'hifi_fastq'] && row.index)
            error "Line ${i + 2}: index column must be empty for ${row.input_type}"
        rows << row
    }
    return rows
}

def unitName(path) {
    // movie/unit id from filename: strip common extensions
    def n = path.getName()
    n = n.replaceAll(/\.(subreads|hifi_reads|reads|ccs)\.bam$/, '')
    n = n.replaceAll(/\.(bam|fastq\.gz|fq\.gz|fastq|fq)$/, '')
    return n
}

workflow {

    if (params.containsKey('help') && params.help) { helpMessage(); exit 0 }
    if (!params.input) { helpMessage(); error "--input samplesheet.csv is required" }
    if (!params.fasta) { helpMessage(); error "--fasta reference.fa is required" }
    if (!(params.phase_vcf in ['deepvariant', 'clair3']))
        error "--phase_vcf must be 'deepvariant' or 'clair3'"
    if (!params.skip_phasing && params.phase_vcf == 'deepvariant' && params.skip_deepvariant)
        error "--phase_vcf deepvariant conflicts with --skip_deepvariant (use --phase_vcf clair3 or --skip_phasing)"
    if (!params.skip_phasing && params.phase_vcf == 'clair3' && params.skip_clair3)
        error "--phase_vcf clair3 conflicts with --skip_clair3 (use --phase_vcf deepvariant or --skip_phasing)"

    def ref_name = params.ref_name ?: file(params.fasta).getBaseName()
    def rows     = parseSamplesheet(file(params.input, checkIfExists: true))
    def n_units  = rows.countBy { [it.sample, it.dataset] }   // for groupKey sizes

    // fail fast on duplicates: the same file twice, or two rows in one group whose
    // filenames collapse to the same unit name (=> output filename collisions later)
    def dup_file = rows.countBy { it.file }.findAll { it.value > 1 }
    if (dup_file)
        error "Samplesheet lists the same file more than once: ${dup_file.keySet().join(', ')}"
    def dup_unit = rows.countBy { [it.sample, it.dataset, unitName(file(it.file))] }
                       .findAll { it.value > 1 }
    if (dup_unit)
        error "Rows within one (sample,dataset) resolve to the same unit name after " +
              "extension stripping: ${dup_unit.keySet().join(' ; ')}. Rename the inputs."

    log.info "pacbio-hifi-wgs v${workflow.manifest.version} | ${rows.size()} row(s), " +
             "${n_units.size()} sample-dataset group(s) | ref: ${ref_name}"

    ch_fasta = Channel.value(file(params.fasta, checkIfExists: true))

    ch_rows = Channel.fromList(rows).map { r ->
        def f    = file(r.file, checkIfExists: true)
        def idx  = r.index ? file(r.index, checkIfExists: true) : null
        def meta = [sample: r.sample, dataset: r.dataset, type: r.input_type, unit: unitName(f)]
        tuple(meta, f, idx)
    }

    ch_in = ch_rows.branch {
        subreads:   it[0].type == 'subreads'
        hifi_bam:   it[0].type == 'hifi_bam'
        hifi_fastq: it[0].type == 'hifi_fastq'
        aligned:    it[0].type == 'aligned_bam'
    }

    // ---- reference prep -------------------------------------------------
    SAMTOOLS_FAIDX(ch_fasta)
    ch_fai = SAMTOOLS_FAIDX.out.fai

    // ---- entry point 1: subreads -> CCS -> HiFi uBAM ---------------------
    ch_sub = ch_in.subreads.branch {
        with_pbi: it[2] != null
        no_pbi:   true
    }
    PBINDEX(ch_sub.no_pbi.map { m, f, i -> tuple(m, f) })
    ch_subreads = ch_sub.with_pbi
        .map { m, f, i -> tuple(m, f, i) }
        .mix(PBINDEX.out.indexed)

    ch_ccs_in = ch_subreads.combine(Channel.of(1..params.ccs_chunks))
    CCS(ch_ccs_in)
    ch_hifi_ccs = MERGE_HIFI(
        // sort: true — completion order is nondeterministic and would change the
        // task hash between runs, defeating -resume
        CCS.out.bam.groupTuple(size: params.ccs_chunks, sort: true)
    ).bam

    // ---- entry points 2+3: HiFi reads -> pbmm2 --------------------------
    // The whole-genome .mmi build costs ~10-15 GB RAM and PBMM2_INDEX is fed by a value
    // channel, so it would fire even on an alignment-free run — gate it on the
    // samplesheet actually containing something to align.
    ch_aligned_new = Channel.empty()
    if (rows.any { it.input_type != 'aligned_bam' }) {
        PBMM2_INDEX(ch_fasta)
        ch_align_in = ch_hifi_ccs
            .mix(ch_in.hifi_bam.map   { m, f, i -> tuple(m, f) })
            .mix(ch_in.hifi_fastq.map { m, f, i -> tuple(m, f) })
        PBMM2_ALIGN(ch_align_in, PBMM2_INDEX.out.mmi)
        ch_aligned_new = PBMM2_ALIGN.out.bam
    }

    // ---- entry point 4: pre-aligned BAM ----------------------------------
    ch_pre = ch_in.aligned.branch {
        with_bai: it[2] != null
        no_bai:   true
    }
    SAMTOOLS_INDEX_INPUT(ch_pre.no_bai.map { m, f, i -> tuple(m, f) })
    ch_prealigned = ch_pre.with_bai
        .map { m, f, i -> tuple(m, f, i, 'preexisting') }
        .mix(SAMTOOLS_INDEX_INPUT.out.indexed.map { m, f, i -> tuple(m, f, i, 'preexisting') })

    // ---- group per (sample,dataset), merge if multiple units -------------
    ch_grouped = ch_aligned_new
        .map { m, bam, bai -> tuple(m, bam, bai, 'new') }
        .mix(ch_prealigned)
        .map { m, bam, bai, origin ->
            def key = "${m.sample}\t${m.dataset}".toString()
            tuple(groupKey(key, n_units[[m.sample, m.dataset]]), bam, bai, origin)
        }
        .groupTuple()
        .map { key, bams, bais, origins ->
            def (s, d) = key.toString().split('\t')
            // deterministic member order (arrival order varies run to run and would
            // change FINALIZE_BAM's task hash, defeating -resume)
            def trip = [bams, bais, origins].transpose().sort { a, b -> a[0].name <=> b[0].name }
            tuple([sample: s, dataset: d, id: "${s}.${d}".toString()],
                  trip.collect { it[0] }, trip.collect { it[1] }, trip.collect { it[2] })
        }
        .branch {
            passthrough: it[1].size() == 1 && it[3][0] == 'preexisting'
            finalize:    true
        }

    FINALIZE_BAM(ch_grouped.finalize.map { m, bams, bais, o -> tuple(m, bams, bais) }, ref_name)

    // guard against the two silent failure modes: a BAM aligned to a different
    // reference than --fasta (chimeric merges, empty caller output), and a BAM with
    // zero mapped reads (all callers would emit empty VCFs without complaint)
    CHECK_BAM(
        FINALIZE_BAM.out.bam
            .mix(ch_grouped.passthrough.map { m, bams, bais, o -> tuple(m, bams[0], bais[0]) }),
        ch_fai
    )
    ch_bam = CHECK_BAM.out.bam

    // ---- small variants ---------------------------------------------------
    ch_dv_vcf     = Channel.empty()
    ch_clair3_vcf = Channel.empty()
    if (!params.skip_deepvariant) {
        DEEPVARIANT(ch_bam, ch_fasta, ch_fai, ref_name)
        ch_dv_vcf = DEEPVARIANT.out.vcf
    }
    if (!params.skip_clair3) {
        CLAIR3(ch_bam, ch_fasta, ch_fai, ref_name)
        ch_clair3_vcf = CLAIR3.out.vcf
    }

    // ---- phasing + haplotagging ------------------------------------------
    ch_phased_vcf = Channel.empty()
    if (!params.skip_phasing) {
        ch_phase_src = params.phase_vcf == 'deepvariant' ? ch_dv_vcf : ch_clair3_vcf
        WHATSHAP_PHASE(
            ch_phase_src.map { m, v, t -> tuple(m, v, t) }.join(ch_bam),
            ch_fasta, ch_fai, ref_name
        )
        TABIX_PHASED(WHATSHAP_PHASE.out.vcf)
        ch_phased_vcf = TABIX_PHASED.out.vcf
        WHATSHAP_STATS(ch_phased_vcf, ref_name)
        WHATSHAP_HAPLOTAG(ch_phased_vcf.join(ch_bam), ch_fasta, ch_fai, ref_name)
        SAMTOOLS_INDEX_HAPLOTAG(WHATSHAP_HAPLOTAG.out.bam)
    }

    // ---- structural variants ----------------------------------------------
    ch_pbsv_vcf = Channel.empty()
    if (!params.skip_pbsv) {
        ch_trf = params.pbsv_tandem_repeats
            ? Channel.value(file(params.pbsv_tandem_repeats, checkIfExists: true))
            : Channel.value(file("${projectDir}/assets/NO_TRF"))
        PBSV_DISCOVER(ch_bam, ch_trf)
        PBSV_CALL(PBSV_DISCOVER.out.svsig, ch_fasta, ch_fai, ref_name)
        BCFTOOLS_SORT_PBSV(PBSV_CALL.out.vcf_raw)
        ch_pbsv_vcf = BCFTOOLS_SORT_PBSV.out.vcf
    }

    // ---- SNV / indel convenience splits ------------------------------------
    ch_split_in = ch_dv_vcf.map     { m, v, t -> tuple(m, 'deepvariant', v, t) }
        .mix(ch_clair3_vcf.map      { m, v, t -> tuple(m, 'clair3', v, t) })
    BCFTOOLS_SPLIT(ch_split_in, ch_fasta, ch_fai, ref_name)

    // ---- QC -----------------------------------------------------------------
    if (!params.skip_qc) {
        MOSDEPTH(ch_bam, ref_name)
        SAMTOOLS_STATS(ch_bam, ref_name)
        ch_stats_in = ch_dv_vcf.map { m, v, t -> tuple(m, 'deepvariant', v) }
            .mix(ch_clair3_vcf.map  { m, v, t -> tuple(m, 'clair3', v) })
            .mix(ch_pbsv_vcf.map    { m, v, t -> tuple(m, 'pbsv', v) })
        BCFTOOLS_STATS(ch_stats_in, ref_name)

        ch_mqc = MOSDEPTH.out.reports.map { m, f -> f }.flatten()
            .mix(SAMTOOLS_STATS.out.reports.map { m, f -> f }.flatten())
            .mix(BCFTOOLS_STATS.out.reports.map { m, f -> f }.flatten())
        if (!params.skip_phasing)
            ch_mqc = ch_mqc.mix(WHATSHAP_STATS.out.reports.map { m, f -> f }.flatten())
        MULTIQC(ch_mqc.collect())
    }

}

workflow.onComplete {
    log.info "pacbio-hifi-wgs finished: ${workflow.success ? 'OK' : 'FAILED'} | outdir: ${params.outdir}"
}

/* ===========================================================================
 * Processes
 * =========================================================================== */

def outbase(meta) { "${params.outdir}/${meta.sample}/${params.platform_subdir}/${meta.dataset}" }

process SAMTOOLS_FAIDX {
    label 'process_low'
    container params.container_samtools
    input:  path fasta
    output: path "${fasta}.fai", emit: fai
    script:
    """
    samtools faidx ${fasta}
    """
    stub:
    """
    touch ${fasta}.fai
    """
}

process PBINDEX {
    tag "${meta.unit}"
    label 'process_low'
    container params.container_pbtk
    input:  tuple val(meta), path(bam)
    output: tuple val(meta), path(bam), path("${bam}.pbi"), emit: indexed
    script:
    """
    pbindex ${bam}
    """
    stub:
    """
    touch ${bam}.pbi
    """
}

process CCS {
    tag "${meta.unit}:${chunk}/${params.ccs_chunks}"
    label 'process_medium'
    container params.container_pbccs
    publishDir path: { "${outbase(meta)}/01_HIFI/ccs_reports" }, mode: 'copy', pattern: '*.ccs_report.txt'
    input:  tuple val(meta), path(bam), path(pbi), val(chunk)
    output:
        tuple val(meta), path("${meta.unit}.chunk${chunk}.hifi.bam"), emit: bam
        path "${meta.unit}.chunk${chunk}.ccs_report.txt",             emit: report
    script:
    """
    [ -f ${bam}.pbi ] || ln -s ${pbi} ${bam}.pbi
    ccs --num-threads ${task.cpus} \\
        --chunk ${chunk}/${params.ccs_chunks} \\
        --report-file ${meta.unit}.chunk${chunk}.ccs_report.txt \\
        --log-level INFO \\
        ${params.ccs_args} \\
        ${bam} ${meta.unit}.chunk${chunk}.hifi.bam
    """
    stub:
    """
    touch ${meta.unit}.chunk${chunk}.hifi.bam ${meta.unit}.chunk${chunk}.ccs_report.txt
    """
}

process MERGE_HIFI {
    tag "${meta.unit}"
    label 'process_low'
    container params.container_pbtk
    publishDir path: { "${outbase(meta)}/01_HIFI" }, mode: 'copy'
    input:  tuple val(meta), path(chunks)
    output: tuple val(meta), path("${meta.unit}.hifi_reads.bam"), emit: bam
    script:
    """
    pbmerge -o ${meta.unit}.hifi_reads.bam ${chunks}
    """
    stub:
    """
    touch ${meta.unit}.hifi_reads.bam
    """
}

process PBMM2_INDEX {
    label 'process_high'
    container params.container_pbmm2
    input:  path fasta
    output: path "${fasta.baseName}.mmi", emit: mmi
    script:
    """
    pbmm2 index --preset ${params.pbmm2_preset} -j ${task.cpus} ${fasta} ${fasta.baseName}.mmi
    """
    stub:
    """
    touch ${fasta.baseName}.mmi
    """
}

process PBMM2_ALIGN {
    tag "${meta.unit}"
    label 'process_high'
    container params.container_pbmm2
    input:
        tuple val(meta), path(reads)
        path mmi
    output: tuple val(meta), path("${meta.unit}.aligned.bam"), path("${meta.unit}.aligned.bam.bai"), emit: bam
    script:
    def rg = reads.name.endsWith('.bam') ? '' : "--rg '@RG\\tID:${meta.unit}'"
    """
    pbmm2 align --preset ${params.pbmm2_preset} -j ${task.cpus} \\
        --sort -J 4 --sort-memory 1G --bam-index BAI --unmapped \\
        --sample ${meta.sample} ${rg} ${params.pbmm2_args} \\
        ${mmi} ${reads} ${meta.unit}.aligned.bam
    """
    stub:
    """
    touch ${meta.unit}.aligned.bam ${meta.unit}.aligned.bam.bai
    """
}

process SAMTOOLS_INDEX_INPUT {
    tag "${meta.unit}"
    label 'process_low'
    container params.container_samtools
    input:  tuple val(meta), path(bam)
    output: tuple val(meta), path(bam), path("${bam}.bai"), emit: indexed
    script:
    """
    samtools index -@ ${task.cpus} ${bam}
    """
    stub:
    """
    touch ${bam}.bai
    """
}

process FINALIZE_BAM {
    tag "${meta.id}"
    label 'process_medium'
    container params.container_samtools
    publishDir path: { "${outbase(meta)}/02_alignedBAM" }, mode: 'copy'
    input:
        tuple val(meta), path(bams, stageAs: 'in/*'), path(bais, stageAs: 'in/*')
        val ref_name
    output: tuple val(meta), path("${meta.id}.${ref_name}.bam"), path("${meta.id}.${ref_name}.bam.bai"), emit: bam
    script:
    // Nextflow unwraps a one-element collection on a path input to a bare Path, whose
    // .size() is the FILE size in bytes — normalize before counting
    def bam_list = bams instanceof List ? bams : [bams]
    def out = "${meta.id}.${ref_name}.bam"
    if (bam_list.size() > 1)
        """
        samtools merge -@ ${task.cpus} -o ${out} in/*.bam
        samtools index -@ ${task.cpus} ${out}
        """
    else
        """
        ln -f \$(readlink -f in/*.bam) ${out} 2>/dev/null || cp in/*.bam ${out}
        samtools index -@ ${task.cpus} ${out}
        """
    stub:
    """
    touch ${meta.id}.${ref_name}.bam ${meta.id}.${ref_name}.bam.bai
    """
}

process CHECK_BAM {
    tag "${meta.id}"
    container params.container_samtools
    input:
        tuple val(meta), path(bam), path(bai)
        path fai
    output: tuple val(meta), path(bam), path(bai), emit: bam
    script:
    """
    samtools view -H ${bam} | awk -F'\\t' '\$1=="@SQ"{for(i=2;i<=NF;i++) if(\$i ~ /^SN:/) print substr(\$i,4)}' | sort > bam_contigs.txt
    cut -f1 ${fai} | sort > ref_contigs.txt
    missing=\$(comm -23 bam_contigs.txt ref_contigs.txt)
    if [ -n "\$missing" ]; then
        echo "ERROR: ${bam} contains contigs absent from --fasta (aligned to a different reference?):" >&2
        echo "\$missing" | head >&2
        exit 1
    fi
    mapped=\$(samtools idxstats ${bam} | awk '{s+=\$3} END{print s+0}')
    if [ "\$mapped" -eq 0 ]; then
        echo "ERROR: ${bam} has zero mapped reads — wrong reference or wrong input type" >&2
        exit 1
    fi
    """
    stub:
    """
    true
    """
}

process DEEPVARIANT {
    tag "${meta.id}"
    label 'process_high'
    container params.container_deepvariant
    publishDir path: { "${outbase(meta)}/03_VCF/deepvariant" }, mode: 'copy'
    input:
        tuple val(meta), path(bam), path(bai)
        path fasta
        path fai
        val ref_name
    output:
        tuple val(meta), path("${meta.id}.${ref_name}.deepvariant.vcf.gz"), path("${meta.id}.${ref_name}.deepvariant.vcf.gz.tbi"), emit: vcf
        path "${meta.id}.${ref_name}.deepvariant.g.vcf.gz*", optional: true, emit: gvcf
        path "${meta.id}.${ref_name}.deepvariant.visual_report.html", optional: true, emit: report
    script:
    def prefix = "${meta.id}.${ref_name}.deepvariant"
    def gvcf   = params.gvcf ? "--output_gvcf=${prefix}.g.vcf.gz" : ''
    """
    export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1
    mkdir -p dv_intermediate
    /opt/deepvariant/bin/run_deepvariant \\
        --model_type=${params.deepvariant_model} \\
        --ref=${fasta} \\
        --reads=${bam} \\
        --output_vcf=${prefix}.vcf.gz \\
        ${gvcf} \\
        --sample_name=${meta.sample} \\
        --vcf_stats_report=true \\
        --num_shards=${task.cpus} \\
        --intermediate_results_dir=dv_intermediate \\
        ${params.deepvariant_args}
    """
    stub:
    """
    touch ${meta.id}.${ref_name}.deepvariant.vcf.gz ${meta.id}.${ref_name}.deepvariant.vcf.gz.tbi
    """
}

process CLAIR3 {
    tag "${meta.id}"
    label 'process_high'
    container params.container_clair3
    publishDir path: { "${outbase(meta)}/03_VCF/clair3" }, mode: 'copy'
    input:
        tuple val(meta), path(bam), path(bai)
        path fasta
        path fai
        val ref_name
    output:
        tuple val(meta), path("${meta.id}.${ref_name}.clair3.vcf.gz"), path("${meta.id}.${ref_name}.clair3.vcf.gz.tbi"), emit: vcf
    script:
    def prefix = "${meta.id}.${ref_name}.clair3"
    """
    if [ ! -d /opt/models/${params.clair3_model} ]; then
        echo "ERROR: model '/opt/models/${params.clair3_model}' not in this clair3 image. Available:" >&2
        ls /opt/models/ >&2
        exit 1
    fi
    /opt/bin/run_clair3.sh \\
        --bam_fn=${bam} \\
        --ref_fn=${fasta} \\
        --threads=${task.cpus} \\
        --platform=${params.clair3_platform} \\
        --model_path=/opt/models/${params.clair3_model} \\
        --sample_name=${meta.sample} \\
        --output=clair3_out \\
        ${params.clair3_args}
    mv clair3_out/merge_output.vcf.gz     ${prefix}.vcf.gz
    mv clair3_out/merge_output.vcf.gz.tbi ${prefix}.vcf.gz.tbi
    """
    stub:
    """
    touch ${meta.id}.${ref_name}.clair3.vcf.gz ${meta.id}.${ref_name}.clair3.vcf.gz.tbi
    """
}

process WHATSHAP_PHASE {
    tag "${meta.id}"
    label 'process_medium'
    container params.container_whatshap
    input:
        tuple val(meta), path(vcf), path(tbi), path(bam), path(bai)
        path fasta
        path fai
        val ref_name
    output: tuple val(meta), path("${meta.id}.${ref_name}.${params.phase_vcf}.phased.vcf.gz"), emit: vcf
    script:
    def prefix = "${meta.id}.${ref_name}.${params.phase_vcf}.phased"
    """
    whatshap phase \\
        --reference ${fasta} \\
        --output ${prefix}.vcf.gz \\
        --ignore-read-groups \\
        ${params.whatshap_args} \\
        ${vcf} ${bam}
    """
    stub:
    """
    touch ${meta.id}.${ref_name}.${params.phase_vcf}.phased.vcf.gz
    """
}

process TABIX_PHASED {
    tag "${meta.id}"
    label 'process_low'
    container params.container_bcftools
    publishDir path: { "${outbase(meta)}/03_VCF/phased_whatshap" }, mode: 'copy'
    input:  tuple val(meta), path(vcf)
    output: tuple val(meta), path(vcf), path("${vcf}.tbi"), emit: vcf
    script:
    """
    tabix -p vcf ${vcf}
    """
    stub:
    """
    touch ${vcf}.tbi
    """
}

process WHATSHAP_STATS {
    tag "${meta.id}"
    label 'process_low'
    container params.container_whatshap
    publishDir path: { "${outbase(meta)}/03_VCF/phased_whatshap" }, mode: 'copy'
    input:
        tuple val(meta), path(vcf), path(tbi)
        val ref_name
    output: tuple val(meta), path("${meta.id}.${ref_name}.whatshap_stats.txt"), emit: reports
    script:
    """
    whatshap stats --tsv=${meta.id}.${ref_name}.whatshap_stats.txt ${vcf}
    """
    stub:
    """
    touch ${meta.id}.${ref_name}.whatshap_stats.txt
    """
}

process WHATSHAP_HAPLOTAG {
    tag "${meta.id}"
    label 'process_medium'
    container params.container_whatshap
    input:
        tuple val(meta), path(vcf), path(tbi), path(bam), path(bai)
        path fasta
        path fai
        val ref_name
    output: tuple val(meta), path("${meta.id}.${ref_name}.haplotagged.bam"), emit: bam
    script:
    """
    whatshap haplotag \\
        --reference ${fasta} \\
        --output ${meta.id}.${ref_name}.haplotagged.bam \\
        --output-threads ${task.cpus} \\
        --ignore-read-groups \\
        ${vcf} ${bam}
    """
    stub:
    """
    touch ${meta.id}.${ref_name}.haplotagged.bam
    """
}

process SAMTOOLS_INDEX_HAPLOTAG {
    tag "${meta.id}"
    label 'process_low'
    container params.container_samtools
    publishDir path: { "${outbase(meta)}/02_alignedBAM/haplotagged" }, mode: 'copy'
    input:  tuple val(meta), path(bam)
    output: tuple val(meta), path(bam), path("${bam}.bai"), emit: bam
    script:
    """
    samtools index -@ ${task.cpus} ${bam}
    """
    stub:
    """
    touch ${bam}.bai
    """
}

process PBSV_DISCOVER {
    tag "${meta.id}"
    label 'process_medium'
    container params.container_pbsv
    input:
        tuple val(meta), path(bam), path(bai)
        path trf
    output: tuple val(meta), path("${meta.id}.svsig.gz"), emit: svsig
    script:
    def trf_arg = trf.name != 'NO_TRF' ? "--tandem-repeats ${trf}" : ''
    """
    pbsv discover --hifi ${trf_arg} ${params.pbsv_discover_args} ${bam} ${meta.id}.svsig.gz
    """
    stub:
    """
    touch ${meta.id}.svsig.gz
    """
}

process PBSV_CALL {
    tag "${meta.id}"
    label 'process_high'
    container params.container_pbsv
    input:
        tuple val(meta), path(svsig)
        path fasta
        path fai
        val ref_name
    output: tuple val(meta), path("${meta.id}.${ref_name}.pbsv.vcf"), emit: vcf_raw
    script:
    """
    pbsv call --hifi -j ${task.cpus} ${params.pbsv_call_args} \\
        ${fasta} ${svsig} ${meta.id}.${ref_name}.pbsv.vcf
    """
    stub:
    """
    touch ${meta.id}.${ref_name}.pbsv.vcf
    """
}

process BCFTOOLS_SORT_PBSV {
    tag "${meta.id}"
    label 'process_low'
    container params.container_bcftools
    publishDir path: { "${outbase(meta)}/03_VCF/SV_pbsv" }, mode: 'copy'
    input:  tuple val(meta), path(vcf)
    output: tuple val(meta), path("${vcf}.gz"), path("${vcf}.gz.tbi"), emit: vcf
    script:
    """
    bcftools sort -Oz -o ${vcf}.gz ${vcf}
    tabix -p vcf ${vcf}.gz
    """
    stub:
    """
    touch ${vcf}.gz ${vcf}.gz.tbi
    """
}

process BCFTOOLS_SPLIT {
    tag "${meta.id}:${caller}"
    label 'process_low'
    container params.container_bcftools
    publishDir path: { "${outbase(meta)}/03_VCF/SNV_${caller}" },   mode: 'copy', pattern: '*.snv.vcf.gz*'
    publishDir path: { "${outbase(meta)}/03_VCF/INDEL_${caller}" }, mode: 'copy', pattern: '*.indel.vcf.gz*'
    input:
        tuple val(meta), val(caller), path(vcf), path(tbi)
        path fasta
        path fai
        val ref_name
    output:
        tuple val(meta), path("${meta.id}.${ref_name}.${caller}.snv.vcf.gz"),   path("${meta.id}.${ref_name}.${caller}.snv.vcf.gz.tbi"),   emit: snv
        tuple val(meta), path("${meta.id}.${ref_name}.${caller}.indel.vcf.gz"), path("${meta.id}.${ref_name}.${caller}.indel.vcf.gz.tbi"), emit: indel
    script:
    def prefix = "${meta.id}.${ref_name}.${caller}"
    """
    # split multiallelics first so mixed SNP+indel records land in exactly one split
    bcftools norm -f ${fasta} -m -any --check-ref w -Oz -o norm.vcf.gz ${vcf}
    tabix -p vcf norm.vcf.gz
    bcftools view -v snps   -Oz -o ${prefix}.snv.vcf.gz   norm.vcf.gz
    tabix -p vcf ${prefix}.snv.vcf.gz
    bcftools view -v indels -Oz -o ${prefix}.indel.vcf.gz norm.vcf.gz
    tabix -p vcf ${prefix}.indel.vcf.gz
    """
    stub:
    """
    touch ${meta.id}.${ref_name}.${caller}.snv.vcf.gz ${meta.id}.${ref_name}.${caller}.snv.vcf.gz.tbi
    touch ${meta.id}.${ref_name}.${caller}.indel.vcf.gz ${meta.id}.${ref_name}.${caller}.indel.vcf.gz.tbi
    """
}

process MOSDEPTH {
    tag "${meta.id}"
    label 'process_low'
    container params.container_mosdepth
    publishDir path: { "${outbase(meta)}/04_QC/mosdepth" }, mode: 'copy'
    input:
        tuple val(meta), path(bam), path(bai)
        val ref_name
    output: tuple val(meta), path("${meta.id}.${ref_name}.{mosdepth,regions}.*"), emit: reports
    script:
    """
    mosdepth -t ${task.cpus} --no-per-base --by 500 ${meta.id}.${ref_name} ${bam}
    """
    stub:
    """
    touch ${meta.id}.${ref_name}.mosdepth.global.dist.txt ${meta.id}.${ref_name}.mosdepth.summary.txt \\
          ${meta.id}.${ref_name}.mosdepth.region.dist.txt ${meta.id}.${ref_name}.regions.bed.gz
    """
}

process SAMTOOLS_STATS {
    tag "${meta.id}"
    label 'process_low'
    container params.container_samtools
    publishDir path: { "${outbase(meta)}/04_QC/samtools" }, mode: 'copy'
    input:
        tuple val(meta), path(bam), path(bai)
        val ref_name
    output: tuple val(meta), path("${meta.id}.${ref_name}.{stats,flagstat}.txt"), emit: reports
    script:
    """
    samtools stats -@ ${task.cpus} ${bam} > ${meta.id}.${ref_name}.stats.txt
    samtools flagstat -@ ${task.cpus} ${bam} > ${meta.id}.${ref_name}.flagstat.txt
    """
    stub:
    """
    touch ${meta.id}.${ref_name}.stats.txt ${meta.id}.${ref_name}.flagstat.txt
    """
}

process BCFTOOLS_STATS {
    tag "${meta.id}:${caller}"
    label 'process_low'
    container params.container_bcftools
    publishDir path: { "${outbase(meta)}/04_QC/bcftools_stats" }, mode: 'copy'
    input:
        tuple val(meta), val(caller), path(vcf)
        val ref_name
    output: tuple val(meta), path("${meta.id}.${ref_name}.${caller}.bcftools_stats.txt"), emit: reports
    script:
    """
    bcftools stats ${vcf} > ${meta.id}.${ref_name}.${caller}.bcftools_stats.txt
    """
    stub:
    """
    touch ${meta.id}.${ref_name}.${caller}.bcftools_stats.txt
    """
}

process MULTIQC {
    label 'process_low'
    container params.container_multiqc
    publishDir path: { "${params.outdir}/multiqc" }, mode: 'copy'
    input:  path 'qc_inputs/*'
    output: path "multiqc_report.html", emit: report
            path "multiqc_report_data", emit: data
    script:
    """
    multiqc -f --title pacbio-hifi-wgs -n multiqc_report.html qc_inputs
    """
    stub:
    """
    touch multiqc_report.html
    mkdir -p multiqc_report_data
    """
}
