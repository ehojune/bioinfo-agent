<#
.SYNOPSIS
    Link this repo's skills/ and agents/ into one or more Claude Code config directories.

.DESCRIPTION
    Claude Code discovers skills and agents from local files under a config directory
    (default: $env:USERPROFILE\.claude). They are NOT synced with an Anthropic account.
    This script points that directory at the canonical copy in this repo so there is
    exactly one set of files to edit and version.

    Skills are linked with directory JUNCTIONS rather than symbolic links. Junctions
    require neither administrator rights nor Developer Mode; symbolic links require one
    or the other. That is the entire reason for the choice.

    Agent definitions are single .md files, and a junction cannot link a file. A cross-
    volume hard link is also impossible (repo on D:, config on C:). So the script tries a
    file symbolic link first and falls back to a copy. Copies are snapshots: if yours were
    copied, re-run this script after editing an agent.

    Nothing is ever clobbered silently. A target that already exists and is not a link we
    would have made is reported and skipped. -Force replaces a junction that points at the
    wrong place; it will still not delete a real directory.

.PARAMETER ExtraConfigDirs
    Additional config directories to link. Use when one machine has several Windows
    profiles that should share one canonical copy of the repo, e.g.
        .\install.ps1 -ExtraConfigDirs 'C:\Users\admin\.claude'

.PARAMETER Force
    Replace a junction or symlink that points somewhere other than this repo. Never
    replaces a real (non-reparse-point) directory or an unmanaged regular file.

.EXAMPLE
    .\install.ps1 -WhatIf
    Dry run. Prints every action it would take and changes nothing.

.EXAMPLE
    .\install.ps1 -ExtraConfigDirs 'C:\Users\admin\.claude'
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]] $ExtraConfigDirs = @(),
    [switch]   $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot   = $PSScriptRoot
$SkillsRoot = Join-Path $RepoRoot 'skills'
$AgentsRoot = Join-Path $RepoRoot 'agents'

$Results = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------------------- helpers

function Add-Result {
    param([string]$Scope, [string]$Item, [string]$Status, [string]$Detail)
    $null = $Results.Add([pscustomobject]@{
        Config = $Scope
        Item   = $Item
        Status = $Status
        Detail = $Detail
    })
}

function Get-NormalPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path
    # Reparse-point targets sometimes come back in NT device form.
    if ($p.StartsWith('\??\'))       { $p = $p.Substring(4) }
    elseif ($p.StartsWith('\\?\'))   { $p = $p.Substring(4) }
    try { $p = [System.IO.Path]::GetFullPath($p) } catch { }
    return $p.TrimEnd('\')
}

# Returns the target of a junction/symlink, or $null if the path is not a reparse point.
function Get-LinkTarget {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $null }
    foreach ($prop in @('LinkTarget', 'Target')) {          # PS7 name, then PS5.1 name
        if ($item.PSObject.Properties.Name -contains $prop) {
            $v = $item.$prop
            if ($null -ne $v -and "$v" -ne '') {
                if ($v -is [array]) { if ($v.Count -gt 0) { return [string]$v[0] } }
                else                { return [string]$v }
            }
        }
    }
    return '<unresolvable>'
}

function Test-IsReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

# Deletes ONLY the reparse point, never the contents of what it points at.
# Remove-Item -Recurse on a junction has historically followed the link. Do not use it here.
function Remove-LinkOnly {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) { [System.IO.Directory]::Delete($Path, $false) }
    else                     { [System.IO.File]::Delete($Path) }
}

function Ensure-Directory {
    param([string]$Path, [string]$Purpose)
    if (Test-Path -LiteralPath $Path) { return $true }
    if ($PSCmdlet.ShouldProcess($Path, "create directory ($Purpose)")) {
        $null = New-Item -ItemType Directory -Path $Path -Force
        return $true
    }
    return $false
}

# ------------------------------------------------------------------- link installers

function Install-SkillJunction {
    param([string]$Scope, [string]$Source, [string]$Target, [string]$Name)

    $srcN = Get-NormalPath $Source

    if (Test-Path -LiteralPath $Target) {
        if (-not (Test-IsReparsePoint $Target)) {
            Add-Result $Scope $Name 'REFUSED' 'a real directory already exists there - not touching it'
            return
        }
        $cur  = Get-LinkTarget $Target
        $curN = Get-NormalPath $cur
        if ($curN -ieq $srcN) {
            Add-Result $Scope $Name 'OK' 'already linked to this repo'
            return
        }
        if (-not $Force) {
            Add-Result $Scope $Name 'REFUSED' "junction points elsewhere ($cur) - re-run with -Force to replace"
            return
        }
        if (-not $PSCmdlet.ShouldProcess($Target, "replace junction (was $cur) -> $srcN")) {
            Add-Result $Scope $Name 'DRY-RUN' "would replace junction -> $srcN"
            return
        }
        Remove-LinkOnly $Target
        $null = New-Item -ItemType Junction -Path $Target -Target $Source
        Add-Result $Scope $Name 'REPLACED' "junction -> $srcN"
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Target, "create junction -> $srcN")) {
        Add-Result $Scope $Name 'DRY-RUN' "would create junction -> $srcN"
        return
    }
    $null = New-Item -ItemType Junction -Path $Target -Target $Source
    Add-Result $Scope $Name 'LINKED' "junction -> $srcN"
}

function Install-AgentFile {
    param([string]$Scope, [string]$Source, [string]$Target, [string]$Name)

    $srcN = Get-NormalPath $Source

    if (Test-Path -LiteralPath $Target) {
        if (Test-IsReparsePoint $Target) {
            $cur  = Get-LinkTarget $Target
            if ((Get-NormalPath $cur) -ieq $srcN) {
                Add-Result $Scope $Name 'OK' 'already symlinked to this repo'
                return
            }
            if (-not $Force) {
                Add-Result $Scope $Name 'REFUSED' "symlink points elsewhere ($cur) - re-run with -Force"
                return
            }
            if (-not $PSCmdlet.ShouldProcess($Target, "replace symlink -> $srcN")) {
                Add-Result $Scope $Name 'DRY-RUN' "would replace symlink -> $srcN"
                return
            }
            Remove-LinkOnly $Target
        }
        else {
            # A plain file. Identical content means it is our own earlier copy: refresh silently.
            $srcHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
            $tgtHash = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash
            if ($srcHash -eq $tgtHash) {
                Add-Result $Scope $Name 'OK' 'copy is up to date'
                return
            }
            if (-not $Force) {
                Add-Result $Scope $Name 'REFUSED' 'a different file already exists there - re-run with -Force to overwrite'
                return
            }
            if (-not $PSCmdlet.ShouldProcess($Target, 'overwrite differing agent file')) {
                Add-Result $Scope $Name 'DRY-RUN' 'would overwrite differing file'
                return
            }
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Target, "link or copy agent <- $srcN")) {
        Add-Result $Scope $Name 'DRY-RUN' "would link (or copy) <- $srcN"
        return
    }

    # Symlink if the OS lets us (Developer Mode or elevated); copy otherwise.
    try {
        $null = New-Item -ItemType SymbolicLink -Path $Target -Target $Source -ErrorAction Stop
        Add-Result $Scope $Name 'LINKED' "symlink -> $srcN"
    }
    catch {
        Copy-Item -LiteralPath $Source -Destination $Target -Force
        Add-Result $Scope $Name 'COPIED' 'symlink unavailable - COPY, re-run install.ps1 after editing'
    }
}

# ------------------------------------------------------------------------ per-config

function Install-IntoConfigDir {
    param([string]$ConfigDir)

    $label = $ConfigDir
    Write-Host ""
    Write-Host "config dir: $ConfigDir" -ForegroundColor Cyan

    if (-not (Ensure-Directory -Path $ConfigDir -Purpose 'claude config root')) {
        Add-Result $label '(config dir)' 'DRY-RUN' 'does not exist yet - would be created'
    }

    # --- skills: one junction per skill folder, never a junction over skills/ itself,
    #     because that directory usually already holds skills from elsewhere.
    if (Test-Path -LiteralPath $SkillsRoot) {
        $skillDirs = @(Get-ChildItem -LiteralPath $SkillsRoot -Directory -ErrorAction SilentlyContinue)
        if ($skillDirs.Count -eq 0) {
            Add-Result $label 'skills/' 'SKIPPED' 'no skill directories in repo'
        }
        else {
            $dest = Join-Path $ConfigDir 'skills'
            # Ensure-Directory only returns $false in a dry run; the installers below
            # then record DRY-RUN rows of their own, so keep going either way.
            $null = Ensure-Directory -Path $dest -Purpose 'skills root'
            foreach ($s in $skillDirs) {
                Install-SkillJunction -Scope $label -Source $s.FullName `
                    -Target (Join-Path $dest $s.Name) -Name ("skills/" + $s.Name)
            }
        }
    }
    else {
        Add-Result $label 'skills/' 'SKIPPED' 'repo has no skills/ directory'
    }

    # --- agents: .md definitions as files; any agent packaged as a folder gets a junction.
    if (Test-Path -LiteralPath $AgentsRoot) {
        $agentFiles = @(Get-ChildItem -LiteralPath $AgentsRoot -Filter '*.md' -File -ErrorAction SilentlyContinue)
        $agentDirs  = @(Get-ChildItem -LiteralPath $AgentsRoot -Directory -ErrorAction SilentlyContinue)
        if ($agentFiles.Count -eq 0 -and $agentDirs.Count -eq 0) {
            Add-Result $label 'agents/' 'SKIPPED' 'no agent definitions in repo yet'
        }
        else {
            $dest = Join-Path $ConfigDir 'agents'
            $null = Ensure-Directory -Path $dest -Purpose 'agents root'
            foreach ($a in $agentFiles) {
                Install-AgentFile -Scope $label -Source $a.FullName `
                    -Target (Join-Path $dest $a.Name) -Name ("agents/" + $a.Name)
            }
            foreach ($a in $agentDirs) {
                Install-SkillJunction -Scope $label -Source $a.FullName `
                    -Target (Join-Path $dest $a.Name) -Name ("agents/" + $a.Name)
            }
        }
    }
    else {
        Add-Result $label 'agents/' 'SKIPPED' 'repo has no agents/ directory'
    }
}

# ----------------------------------------------------------------------------- main

Write-Host "bioinfo installer" -ForegroundColor Green
Write-Host "repo: $RepoRoot"

$targets = New-Object System.Collections.ArrayList

if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) {
    # Some setups allow a comma-separated list here.
    foreach ($p in ($env:CLAUDE_CONFIG_DIR -split ',')) {
        $t = $p.Trim()
        if ($t -ne '') { $null = $targets.Add((Get-NormalPath $t)) }
    }
    Write-Host "primary: from CLAUDE_CONFIG_DIR"
}
else {
    $null = $targets.Add((Get-NormalPath (Join-Path $env:USERPROFILE '.claude')))
    Write-Host "primary: `$env:USERPROFILE\.claude (CLAUDE_CONFIG_DIR not set)"
}

foreach ($extra in $ExtraConfigDirs) {
    if ([string]::IsNullOrWhiteSpace($extra)) { continue }
    $n = Get-NormalPath $extra
    if ($targets -notcontains $n) { $null = $targets.Add($n) }
}

foreach ($t in $targets) { Install-IntoConfigDir -ConfigDir $t }

# --------------------------------------------------------------------------- report

Write-Host ""
Write-Host "---- result ----------------------------------------------------" -ForegroundColor Green
$Results | Format-Table -Property Config, Item, Status, Detail -AutoSize -Wrap |
    Out-String -Width 200 | Write-Host

Write-Host "---- resolved --------------------------------------------------" -ForegroundColor Green
foreach ($t in $targets) {
    foreach ($sub in @('skills', 'agents')) {
        $d = Join-Path $t $sub
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($e in (Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)) {
            $tgt = Get-LinkTarget $e.FullName
            if ($null -ne $tgt) { Write-Host ("  {0}  ->  {1}" -f $e.FullName, $tgt) }
            elseif (-not $e.PSIsContainer) { Write-Host ("  {0}  (regular file)" -f $e.FullName) }
        }
    }
}

$bad = @($Results | Where-Object { $_.Status -eq 'REFUSED' })
if ($bad.Count -gt 0) {
    Write-Host ""
    Write-Host "$($bad.Count) item(s) REFUSED. Nothing was destroyed. Read the Detail column," -ForegroundColor Yellow
    Write-Host "resolve by hand, or re-run with -Force if the blocker is a link we own." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "done. Restart Claude Code so it re-scans the config directory." -ForegroundColor Green
