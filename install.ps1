<#
.SYNOPSIS
    Link this repo's skills/ and agents/ into one or more Claude Code config directories,
    and register the work-directory guard hook.

.DESCRIPTION
    Claude Code discovers skills and agents from local files under a config directory
    (default: $env:USERPROFILE\.claude). They are NOT synced with an Anthropic account.
    This script points that directory at the canonical copy in this repo so there is
    exactly one set of files to edit and version.

    THE HOOK IS NOT A LINK. Skills and agents are discovered by their presence on disk, so
    a junction is enough. Hooks are not: outside a plugin, Claude Code only runs a hook that
    is declared in settings.json. So `hooks/hooks.json` cannot simply be linked into place --
    this script merges one PreToolUse entry into the primary config dir's settings.json,
    which is a user-owned file. It therefore backs the file up first, never rewrites anything
    it did not put there, refuses outright rather than guess at unparseable JSON, and can take
    the entry back out again (-UninstallHook). -NoHook skips the whole business.

    It also proves the hook works before writing it. The command is run against a payload that
    must be blocked and one that must be allowed, and the entry goes in only if both come back
    right. A guard registered but silently failing open is worse than an install that says no:
    on Windows with no Git Bash, Claude Code hands a shell-form hook to PowerShell instead,
    `bash /c/...` there resolves to the WSL launcher, and the hook exits 127 -- which Claude Code
    treats as a non-blocking error and ignores.

    One side effect worth knowing about: writing that entry means round-tripping the file
    through ConvertTo-Json, which reindents the whole thing and drops any comments. Content and
    meaning survive; your formatting does not. The backup next to it is the original.

    Without that entry the guard in hooks/guard-workdir.sh does not run on this route, and the
    work-directory rule -- the only guardrail in the repo that is machine-checked rather than
    written in a prompt -- is unenforced. That is what this closes.

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

    This script and `claude plugin marketplace add` are ALTERNATIVES, not steps. The repo
    also ships .claude-plugin/plugin.json; install by both routes and every agent registers
    twice, because agents are not de-duplicated. See -AgentsEverywhere. Pick one route.

.PARAMETER ExtraConfigDirs
    Additional config directories to link. Use when one machine has several Windows
    profiles that should share one canonical copy of the repo, e.g.
        .\install.ps1 -ExtraConfigDirs 'C:\Users\admin\.claude'

.PARAMETER AgentsEverywhere
    Install agent definitions into the extra config directories too. OFF by default, and
    you almost certainly want it off.

    Skills and agents are not discovered the same way. Claude Code de-duplicates skills by
    name, so the same skill junctioned into two config directories shows up once. Agents are
    NOT de-duplicated: the same agent file in two discoverable config directories registers
    twice, and the agent picker lists it twice with identical descriptions.

    This bites specifically when a second config directory sits on the path from the drive
    root down to your working directory, because Claude Code walks parents looking for
    project config. On the machine this repo was built on, the primary is
    C:\Users\<user>\.claude while work happens in C:\Users\admin\llm-wiki — so
    C:\Users\admin\.claude is discovered as project config and every agent under it doubles.

    Default behaviour: skills go into every config directory, agents only into the primary.

.PARAMETER Force
    Replace a junction or symlink that points somewhere other than this repo. Never
    replaces a real (non-reparse-point) directory or an unmanaged regular file.

    Also lets the hook registration repoint a stale entry -- one left by a copy of this repo
    at another path -- at this repo. Without -Force that is REFUSED, because two checkouts
    both claiming the hook is a situation the user should see rather than have resolved
    silently.

.PARAMETER NoHook
    Skip registering the work-directory guard hook. Everything else installs as usual.

    Use it if you would rather not have this script write to settings.json, or if you run the
    plugin route in parallel on the same config dir -- the plugin already carries the hook via
    hooks/hooks.json, and both routes at once means the guard runs twice on every Bash call.
    Twice is harmless (both copies reach the same verdict) but the second one is noise.

.PARAMETER UninstallHook
    Remove the guard hook entry from settings.json and exit. Touches nothing else: skills and
    agents links are left exactly as they are, because removing them is not what this asks for.

.EXAMPLE
    .\install.ps1 -WhatIf
    Dry run. Prints every action it would take and changes nothing.

.EXAMPLE
    .\install.ps1 -ExtraConfigDirs 'C:\Users\admin\.claude'

.EXAMPLE
    .\install.ps1 -UninstallHook
    Takes the PreToolUse entry back out of settings.json. Leaves the links alone.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]] $ExtraConfigDirs = @(),
    [switch]   $AgentsEverywhere,
    [switch]   $Force,
    [switch]   $NoHook,
    [switch]   $UninstallHook
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot   = $PSScriptRoot
$SkillsRoot = Join-Path $RepoRoot 'skills'
$AgentsRoot = Join-Path $RepoRoot 'agents'
$GuardRel   = 'hooks/guard-workdir.sh'
$GuardPath  = Join-Path $RepoRoot 'hooks\guard-workdir.sh'

# What identifies our entry in a settings.json we do not own. The script filename, not the
# full path: a repo that moved still has to be recognised as ours, or -UninstallHook would
# leave an orphan behind and re-running would stack a second copy.
$GuardMarker = 'guard-workdir.sh'

# $IsWindows is a PS 6+ automatic variable. On 5.1 there is no question what the platform is.
$IsWindowsHost = if ($null -ne (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) { $IsWindows }
                 else { $true }

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

# D:\bioinfo-agent -> /d/bioinfo-agent
#
# The hook command is a shell string, and on Windows Claude Code runs it through Git Bash. A
# Windows path cannot survive that as-is: inside double quotes bash treats each backslash as an
# escape, so "D:\bioinfo-agent\hooks\guard-workdir.sh" arrives as D:bioinfo-agenthooksguard-
# workdir.sh and the hook exits 127 -- which Claude Code classes as a non-blocking error and
# ignores. A guard that silently does not run is worse than no guard, so convert here.
function ConvertTo-PosixPath {
    param([string]$Path)
    $p = (Get-NormalPath $Path) -replace '\\', '/'
    if     ($p -match '^([A-Za-z]):(?<rest>/.*)$') { return '/' + $Matches[1].ToLowerInvariant() + $Matches['rest'] }
    elseif ($p -match '^([A-Za-z]):$')             { return '/' + $Matches[1].ToLowerInvariant() }
    return $p
}

# Quote for bash only when the path actually needs it. ConvertTo-Json on PS 5.1 escapes an
# apostrophe to ', so unconditional single-quoting turns a readable settings.json line into
# "bash '/d/bioinfo-agent/...'". Valid, and it parses back correctly, but this is a
# file the user owns and may well read. Ordinary paths get no quotes; only a path with a space
# or a shell metacharacter pays the cost.
function ConvertTo-BashArgument {
    param([string]$Text)
    if ($Text -match '^[A-Za-z0-9_./:+@-]+$') { return $Text }
    return "'" + ($Text -replace "'", "'\''") + "'"
}

# The bash that will actually run the hook. $null means there is none, and that is a reason to
# refuse the registration rather than a detail to report afterwards: with no Git Bash on Windows,
# Claude Code falls back to PowerShell for a shell-form hook, `bash /c/...` there resolves to the
# WSL launcher, /c/... is not a path WSL has, and the hook exits 127 -- a non-blocking error, so
# the guard fails open. Writing the entry anyway would leave the user believing otherwise.
#
# System32\bash.exe is excluded deliberately. It is the WSL launcher, and it is the FIRST bash on
# the Windows PATH, so a naive lookup finds the one interpreter that cannot open the path we emit.
function Resolve-GuardBash {
    if (-not $IsWindowsHost) {
        $b = Get-Command bash -ErrorAction SilentlyContinue
        if ($null -ne $b -and -not [string]::IsNullOrWhiteSpace($b.Source)) { return $b.Source }
        return $null
    }

    $cands = New-Object System.Collections.ArrayList
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:LOCALAPPDATA)) {
        if (-not [string]::IsNullOrWhiteSpace($base)) {
            $null = $cands.Add((Join-Path $base 'Git\bin\bash.exe'))
        }
    }
    # Where Git for Windows records itself, which covers a non-default install directory.
    foreach ($key in @('HKLM:\SOFTWARE\GitForWindows', 'HKCU:\SOFTWARE\GitForWindows')) {
        try {
            $ip = (Get-ItemProperty -Path $key -Name InstallPath -ErrorAction Stop).InstallPath
            if (-not [string]::IsNullOrWhiteSpace($ip)) { $null = $cands.Add((Join-Path $ip 'bin\bash.exe')) }
        }
        catch { }
    }
    # Derive from git.exe: <...>\Git\cmd\git.exe -> <...>\Git\bin\bash.exe. Catches scoop, choco
    # and portable installs that neither of the above knows about.
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -ne $git -and -not [string]::IsNullOrWhiteSpace($git.Source)) {
        $gitDir = Split-Path -Parent (Split-Path -Parent $git.Source)
        $null = $cands.Add((Join-Path $gitDir 'bin\bash.exe'))
        $null = $cands.Add((Join-Path $gitDir 'usr\bin\bash.exe'))
    }
    # Anything else named bash on PATH, minus the WSL launcher.
    $sys32 = Join-Path $env:WINDIR 'System32'
    foreach ($b in @(Get-Command bash -All -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($b.Source)) { continue }
        $dir = Split-Path -Parent $b.Source
        if ((Get-NormalPath $dir) -ieq (Get-NormalPath $sys32)) { continue }
        if ($b.Source -like '*\WindowsApps\*') { continue }      # the Store's WSL alias
        $null = $cands.Add($b.Source)
    }

    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

# Reads a property that may not exist. Set-StrictMode -Version Latest turns a missing property
# on a PSCustomObject into a terminating error, so every settings.json lookup goes through here.
#
# Indexes PSObject.Properties instead of testing `.Properties.Name -contains`. The latter is
# member enumeration over the collection, and on an EMPTY collection -- which is exactly what a
# fresh `{}` settings.json gives us -- StrictMode raises PropertyNotFoundStrict on 'Name'.
function Get-JsonProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
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
            # Clear the way, or New-Item -ItemType SymbolicLink below fails on the existing
            # file and the catch misreports a hand-edited copy as "symlink unavailable".
            Remove-Item -LiteralPath $Target -Force
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

# ----------------------------------------------------------------------- guard hook
#
# SHELL FORM ON PURPOSE -- no "args" key. Claude Code reads a hook with "args" as exec form:
# it skips the shell and resolves "command" against PATH as an executable. On Windows that is
# the wrong answer for `bash`, because Git ships bash.exe in Git\usr\bin, which is on PATH only
# inside a Git Bash session. From a Windows process the first bash.exe on PATH is
# C:\Windows\System32\bash.exe -- the WSL launcher -- and handing WSL a Windows path exits 127.
# Omitting "args" puts us in shell form, where Claude Code runs the string through Git Bash
# itself and we never depend on which bash PATH happens to find.

function Get-GuardHookCommand {
    return 'bash ' + (ConvertTo-BashArgument (ConvertTo-PosixPath $GuardPath))
}

function New-GuardHookEntry {
    return [pscustomobject]@{
        matcher = 'Bash'
        hooks   = @([pscustomobject]@{
            type    = 'command'
            command = (Get-GuardHookCommand)
            timeout = 10
        })
    }
}

# @{ Ok; Object; Error; Existed }. Ok=$false means do not write: we could not understand the
# file, and a settings.json we cannot parse is one we must not overwrite.
function Read-SettingsFile {
    param([string]$Path)
    $res = @{ Ok = $true; Object = [pscustomobject]@{}; Error = ''; Existed = $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $res }
    $res.Existed = $true
    try   { $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 }
    catch { $res.Ok = $false; $res.Error = "cannot read it ($($_.Exception.Message))"; return $res }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $res }   # empty file == {}
    try   { $parsed = $raw | ConvertFrom-Json }
    catch { $res.Ok = $false; $res.Error = 'not valid JSON'; return $res }
    if ($parsed -isnot [System.Management.Automation.PSCustomObject]) {
        $res.Ok = $false; $res.Error = 'top level is not a JSON object'; return $res
    }
    $res.Object = $parsed
    return $res
}

function Save-SettingsFile {
    param([string]$Path, $Settings, [string]$BackupStamp)

    if (Test-Path -LiteralPath $Path) {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak-$BackupStamp" -Force
    }
    # -Depth: the default is 2 and this structure is 4 deep, which would serialise the inner
    # hook objects as the literal string "System.Management.Automation.PSCustomObject".
    $json = $Settings | ConvertTo-Json -Depth 20
    # UTF8Encoding($false) == no BOM. Set-Content -Encoding utf8 on PS 5.1 writes one.
    [System.IO.File]::WriteAllText($Path, ($json + [Environment]::NewLine),
        (New-Object System.Text.UTF8Encoding($false)))
}

# Every hook entry in PreToolUse that mentions our script, whatever path it names, as
# @{ Text; ExecForm }.
#
# ExecForm is not cosmetic. Flattening `"command": "bash"` + `"args": ["<path>"]` into one string
# produces the same text as the shell form `"command": "bash <path>"`, so comparing text alone
# reports an exec-form entry for this very checkout as already correct and leaves the args key
# in place -- the one shape that fails open on Windows, which is what this whole change exists to
# remove. The caller needs to tell the two apart.
function Get-RegisteredGuardCommands {
    param($Settings)
    $found = New-Object System.Collections.ArrayList
    $hooks = Get-JsonProp $Settings 'hooks'
    if ($null -eq $hooks) { return $found }
    foreach ($g in @(Get-JsonProp $hooks 'PreToolUse')) {
        foreach ($h in @(Get-JsonProp $g 'hooks')) {
            $blob = [string](Get-JsonProp $h 'command')
            $a = Get-JsonProp $h 'args'
            if ($null -ne $a) { $blob = $blob + ' ' + ((@($a) | ForEach-Object { [string]$_ }) -join ' ') }
            if ($blob -like "*$GuardMarker*") {
                $null = $found.Add([pscustomobject]@{ Text = $blob.Trim(); ExecForm = ($null -ne $a) })
            }
        }
    }
    return $found
}

# Strips our hook and leaves everything else untouched -- including unrelated hooks that share
# a matcher group with ours, which is why this filters individual entries and not whole groups.
# Empty containers are removed rather than left as "PreToolUse": [], so that uninstalling
# really does put the file back the way it was.
function Remove-GuardEntries {
    param($Settings)
    $removed = 0
    $hooks = Get-JsonProp $Settings 'hooks'
    if ($null -eq $hooks) { return 0 }
    $pre = Get-JsonProp $hooks 'PreToolUse'
    if ($null -eq $pre) { return 0 }

    $keptGroups = New-Object System.Collections.ArrayList
    foreach ($g in @($pre)) {
        $groupHooks = @(Get-JsonProp $g 'hooks')
        if ($groupHooks.Count -eq 0) { $null = $keptGroups.Add($g); continue }

        $keptHooks = New-Object System.Collections.ArrayList
        foreach ($h in $groupHooks) {
            $blob = [string](Get-JsonProp $h 'command')
            $a = Get-JsonProp $h 'args'
            if ($null -ne $a) { $blob = $blob + ' ' + ((@($a) | ForEach-Object { [string]$_ }) -join ' ') }
            if ($blob -like "*$GuardMarker*") { $removed++ } else { $null = $keptHooks.Add($h) }
        }
        if ($keptHooks.Count -eq $groupHooks.Count) { $null = $keptGroups.Add($g); continue }
        if ($keptHooks.Count -gt 0) {
            $g.hooks = @($keptHooks.ToArray())
            $null = $keptGroups.Add($g)
        }
        # else the group held nothing but ours: drop it
    }

    if ($keptGroups.Count -gt 0) { $hooks.PreToolUse = @($keptGroups.ToArray()) }
    else {
        $hooks.PSObject.Properties.Remove('PreToolUse')
        if (@($hooks.PSObject.Properties).Count -eq 0) { $Settings.PSObject.Properties.Remove('hooks') }
    }
    return $removed
}

function Install-GuardHook {
    param([string]$Scope, [string]$ConfigDir)

    $item = 'hooks -> settings.json'

    if (-not (Test-Path -LiteralPath $GuardPath)) {
        Add-Result $Scope $item 'REFUSED' "repo has no $GuardRel - nothing to register"
        return
    }

    # PROVE IT BEFORE WRITING IT. Registering first and testing afterwards leaves the failure
    # cases -- no usable bash, a guard that does not actually block -- reported next to an entry
    # that is already in the user's settings.json and already fails open. Nothing is written
    # unless the command has been observed to block on this machine.
    $probe = Test-GuardCommand
    Add-Result $Scope 'hook self-test' $probe.Status $probe.Detail
    if ($probe.Status -ne 'OK') {
        Add-Result $Scope $item 'REFUSED' 'self-test did not pass - refusing to register a guard that would fail open'
        return
    }

    $settingsPath = Join-Path $ConfigDir 'settings.json'
    $read = Read-SettingsFile -Path $settingsPath
    if (-not $read.Ok) {
        Add-Result $Scope $item 'REFUSED' "settings.json $($read.Error) - fix or move it, then re-run. Not overwritten"
        return
    }
    $settings = $read.Object

    # hooks / hooks.PreToolUse must be the shapes we are about to index into.
    $hooksProp = Get-JsonProp $settings 'hooks'
    if ($null -ne $hooksProp -and $hooksProp -isnot [System.Management.Automation.PSCustomObject]) {
        Add-Result $Scope $item 'REFUSED' 'settings.json has a "hooks" key that is not an object - resolve by hand'
        return
    }
    if ($null -ne $hooksProp) {
        $preProp = Get-JsonProp $hooksProp 'PreToolUse'
        if ($null -ne $preProp -and $preProp -is [string]) {
            Add-Result $Scope $item 'REFUSED' 'settings.json has a "hooks.PreToolUse" that is not a list - resolve by hand'
            return
        }
    }

    $want     = Get-GuardHookCommand
    $existing = @(Get-RegisteredGuardCommands -Settings $settings)
    $foreign  = @($existing | Where-Object { $_.Text -ne $want })
    $stale    = @($existing | Where-Object { $_.Text -eq $want -and $_.ExecForm })

    if ($foreign.Count -eq 0 -and $existing.Count -eq 1 -and $stale.Count -eq 0) {
        Add-Result $Scope $item 'OK' 'already registered for this repo'
        return
    }

    # -Force gates one thing only: a registration naming a DIFFERENT path, which means two
    # checkouts disagree and the user should see that rather than have it resolved silently.
    # Everything left over here is ours -- an exec-form entry for this same checkout, or a
    # duplicate of it -- and rewriting that needs no permission. Exec form is the fail-open
    # shape; refusing to fix it without a flag would strand the user on the broken one.
    if ($foreign.Count -gt 0 -and -not $Force) {
        $detail = if ($existing.Count -gt 1) {
            "$($existing.Count) guard hooks already registered - re-run with -Force to collapse to one"
        } else {
            "a guard hook is registered for another path ($($existing[0].Text)) - re-run with -Force to repoint"
        }
        Add-Result $Scope $item 'REFUSED' $detail
        return
    }

    $verb = if ($existing.Count -gt 0) { 'REPLACED' } else { 'LINKED' }
    $why  = if ($stale.Count -gt 0 -and $foreign.Count -eq 0) { ' (was exec form: "args" resolves bash on PATH and fails open on Windows)' } else { '' }
    if (-not $PSCmdlet.ShouldProcess($settingsPath, "register PreToolUse hook -> $want$why")) {
        Add-Result $Scope $item 'DRY-RUN' "would register PreToolUse hook -> $want$why"
        return
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $null  = Remove-GuardEntries -Settings $settings

    if ($null -eq (Get-JsonProp $settings 'hooks')) {
        $settings | Add-Member -MemberType NoteProperty -Name 'hooks' -Value ([pscustomobject]@{})
    }
    $hooks = $settings.hooks
    if ($null -eq (Get-JsonProp $hooks 'PreToolUse')) {
        $hooks | Add-Member -MemberType NoteProperty -Name 'PreToolUse' -Value @()
    }
    $hooks.PreToolUse = @(@($hooks.PreToolUse) + (New-GuardHookEntry))

    Save-SettingsFile -Path $settingsPath -Settings $settings -BackupStamp $stamp
    $detail = "PreToolUse on Bash -> $want$why"
    if ($read.Existed) { $detail += " (backup: settings.json.bak-$stamp)" }
    Add-Result $Scope $item $verb $detail
}

function Uninstall-GuardHook {
    param([string]$Scope, [string]$ConfigDir)

    $item = 'hooks -> settings.json'
    $settingsPath = Join-Path $ConfigDir 'settings.json'

    if (-not (Test-Path -LiteralPath $settingsPath)) {
        Add-Result $Scope $item 'SKIPPED' 'no settings.json here'
        return
    }
    $read = Read-SettingsFile -Path $settingsPath
    if (-not $read.Ok) {
        Add-Result $Scope $item 'REFUSED' "settings.json $($read.Error) - not touched"
        return
    }
    $settings = $read.Object
    if (@(Get-RegisteredGuardCommands -Settings $settings).Count -eq 0) {
        Add-Result $Scope $item 'SKIPPED' 'no guard hook registered'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($settingsPath, 'remove the guard PreToolUse hook')) {
        Add-Result $Scope $item 'DRY-RUN' 'would remove the guard PreToolUse hook'
        return
    }
    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $removed = Remove-GuardEntries -Settings $settings
    Save-SettingsFile -Path $settingsPath -Settings $settings -BackupStamp $stamp
    Add-Result $Scope $item 'REMOVED' "$removed entry/entries removed (backup: settings.json.bak-$stamp)"
}

# Runs the exact command we are about to register, the way Claude Code will run it, and checks
# both directions: a cleanup flag must exit 2, an ordinary command must exit 0. The point is that
# "the hook is in settings.json" and "the hook works on this machine" are different claims,
# and only the second one is worth anything. jq is absent from Git Bash, so this also exercises
# the guard's sed fallback rather than its jq path.
function Invoke-HookProbe {
    param([string]$Bash, [string]$Command, [string]$Payload)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = $Payload | & $Bash -c $Command 2>$null
        return $LASTEXITCODE
    }
    catch { return -1 }
    finally { $ErrorActionPreference = $prevEAP }
}

# @{ Status; Detail }. Status 'OK' is the only value Install-GuardHook will write on.
function Test-GuardCommand {
    $bash = Resolve-GuardBash
    if ($null -eq $bash) {
        $detail = if ($IsWindowsHost) {
            'no usable bash found (System32\bash.exe is WSL and cannot open the path). Install Git for Windows, or -NoHook to install links only'
        } else {
            'no bash on PATH. Install one, or -NoHook to install links only'
        }
        return @{ Status = 'REFUSED'; Detail = $detail }
    }

    $cmd     = Get-GuardHookCommand
    $blocked = Invoke-HookProbe -Bash $bash -Command $cmd `
        -Payload '{"tool_name":"Bash","tool_input":{"command":"nextflow run x -with-cleanup"}}'
    $allowed = Invoke-HookProbe -Bash $bash -Command $cmd `
        -Payload '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'

    if ($blocked -eq 2 -and $allowed -eq 0) {
        return @{ Status = 'OK'; Detail = "blocks -with-cleanup (exit 2), allows a plain command (exit 0), via $bash" }
    }
    if ($blocked -ne 2) {
        return @{ Status = 'REFUSED'; Detail = "guard did not block -with-cleanup (exit $blocked, expected 2) - it would fail open" }
    }
    return @{ Status = 'REFUSED'; Detail = "guard blocked a harmless command (exit $allowed, expected 0) - it would block everything" }
}

# ------------------------------------------------------------------------ per-config

function Install-IntoConfigDir {
    param([string]$ConfigDir, [bool]$IsPrimary = $true)

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
    #
    # Skipped for non-primary config dirs by default. Claude Code de-duplicates skills by
    # name but NOT agents, so the same agent file discovered under two config directories
    # registers twice. See the -AgentsEverywhere help text.
    if (-not $IsPrimary -and -not $AgentsEverywhere) {
        Add-Result $label 'agents/' 'SKIPPED' 'not primary config dir - agents would register twice (-AgentsEverywhere to override)'
    }
    elseif (Test-Path -LiteralPath $AgentsRoot) {
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

    # --- the work-directory guard hook. Primary config dir only: the hook fires on every Bash
    #     call in the session, and a second registration just makes it fire twice.
    if ($NoHook) {
        Add-Result $label 'hooks -> settings.json' 'SKIPPED' '-NoHook given'
    }
    elseif (-not $IsPrimary) {
        Add-Result $label 'hooks -> settings.json' 'SKIPPED' 'not primary config dir - one registration is enough'
    }
    else {
        Install-GuardHook -Scope $label -ConfigDir $ConfigDir
    }
}

# ----------------------------------------------------------------------------- main

Write-Host "bioinfo installer" -ForegroundColor Green
Write-Host "repo: $RepoRoot"
if ($UninstallHook) {
    Write-Host "mode: -UninstallHook - removing the guard hook only, links left alone" -ForegroundColor Yellow
}
else {
    Write-Host "note: this is an ALTERNATIVE to 'claude plugin marketplace add'. Using both" -ForegroundColor Yellow
    Write-Host "      registers every agent twice - agents are not de-duplicated, and the" -ForegroundColor Yellow
    Write-Host "      guard hook then runs twice per Bash call (-NoHook avoids that half)." -ForegroundColor Yellow
}

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

$primary = $targets[0]

if ($UninstallHook) {
    # Every target, not just the primary: which dir was primary may have changed since the
    # hook went in, and an orphaned registration pointing at a moved repo is exactly the thing
    # this is for.
    foreach ($t in $targets) { Uninstall-GuardHook -Scope $t -ConfigDir $t }
}
else {
    foreach ($t in $targets) { Install-IntoConfigDir -ConfigDir $t -IsPrimary ($t -eq $primary) }
}

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
    # Read the hook back out of the file rather than reprinting what we meant to write.
    $sp = Join-Path $t 'settings.json'
    $rd = Read-SettingsFile -Path $sp
    if ($rd.Ok) {
        foreach ($c in @(Get-RegisteredGuardCommands -Settings $rd.Object)) {
            $form = if ($c.ExecForm) { '  [EXEC FORM - fails open on Windows]' } else { '' }
            Write-Host ("  {0}  ->  PreToolUse: {1}{2}" -f $sp, $c.Text, $form)
        }
    }
}

$bad = @($Results | Where-Object { $_.Status -eq 'REFUSED' })
if ($bad.Count -gt 0) {
    Write-Host ""
    Write-Host "$($bad.Count) item(s) REFUSED. Nothing was destroyed. Read the Detail column," -ForegroundColor Yellow
    Write-Host "resolve by hand, or re-run with -Force if the blocker is a link we own." -ForegroundColor Yellow
    Write-Host "A settings.json we could not parse is never overwritten; a backup is taken" -ForegroundColor Yellow
    Write-Host "before any write we do make." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
if ($UninstallHook) {
    Write-Host "done. Restart Claude Code: hooks are read at startup, so the entry stays" -ForegroundColor Green
    Write-Host "live in any session already running." -ForegroundColor Green
}
else {
    Write-Host "done. Restart Claude Code so it re-scans the config directory." -ForegroundColor Green
    if (-not $NoHook) {
        Write-Host "The guard hook is read at startup too - it does not protect a session" -ForegroundColor Green
        Write-Host "that is already open." -ForegroundColor Green
    }
}

# Explicit, because the REFUSED branch above exits 1 and a caller comparing the two needs the
# success side to actually set a code. Without this, a script that does not exit leaves
# $LASTEXITCODE at whatever the previous command set, and a clean run reads as the last failure.
exit 0
