<#
.SYNOPSIS
  Stage 0 - take a bare Windows box to a registered WSL2 distro on a chosen drive.

.DESCRIPTION
  Diagnoses first, acts second. Every precondition that can only be fixed by an
  elevated command or a reboot is reported as such, by name, with the exact command
  to run - rather than letting `wsl --install` fail with its usual opaque error.

  Deliberately does NOT require administrator rights. It only needs them if Windows
  itself needs them (enabling optional features), and in that case it prints the
  commands instead of trying and failing.

.PARAMETER Drive
  Drive letter (no colon) that will hold the distro's ext4.vhdx. Default D, which on
  this machine has 2.2 TB free. Never use C: - it has ~74 GB and pipelines will eat it.

.PARAMETER Distro
  WSL distribution name. Default Ubuntu-24.04.

.PARAMETER Location
  Full path for the distro directory. Defaults to <Drive>:\wsl\ubuntu-24.04.

.PARAMETER DryRun
  Run every check, print the plan, change nothing.

.PARAMETER SkipInstall
  Diagnostics only. Useful for "why can't I see my distro?" triage.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File D:\bioinfo\bootstrap\00-windows-wsl.ps1

.EXAMPLE
  .\00-windows-wsl.ps1 -Drive E -Distro Ubuntu-24.04 -DryRun

.NOTES
  Written for Windows PowerShell 5.1 (no ternary, no ?? , no pipeline chain operators)
  so it runs on a stock box with nothing installed.
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]$')]
    [string]$Drive = 'D',

    [string]$Distro = 'Ubuntu-24.04',

    [string]$Location,

    [switch]$DryRun,

    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

if (-not $Location -or $Location -eq '') {
    $Location = "$($Drive.ToUpper()):\wsl\ubuntu-24.04"
}
$VhdxPath = Join-Path $Location 'ext4.vhdx'

# --------------------------------------------------------------------------- output
$script:Blockers = New-Object System.Collections.ArrayList
$script:Notes    = New-Object System.Collections.ArrayList

function Write-Head { param([string]$m) Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "   [ ok ] $m" -ForegroundColor Green }
function Write-Note { param([string]$m) Write-Host "   [info] $m" -ForegroundColor Gray }
function Write-Warn { param([string]$m) Write-Host "   [warn] $m" -ForegroundColor Yellow; [void]$script:Notes.Add($m) }
function Write-Bad  { param([string]$m) Write-Host "   [FAIL] $m" -ForegroundColor Red;    [void]$script:Blockers.Add($m) }

# --------------------------------------------------------------------------- helpers

# wsl.exe emits UTF-16LE on most Windows builds. Captured through PowerShell's default
# console encoding that arrives as text interleaved with NULs, which silently breaks
# every -match and -eq you write against it. Flip the console encoding for the call,
# strip surviving NULs, restore. This is the single most common reason ad-hoc WSL
# scripts "can't find" a distro that plainly exists.
function Invoke-Wsl {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $prev = [Console]::OutputEncoding
    $out = $null
    try {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::Unicode } catch { }
        # No 2>&1 : in PS 5.1 redirecting a native command's stderr wraps each line in a
        # NativeCommandError and poisons $? even on exit code 0.
        $out = & wsl.exe @Arguments
        $script:WslExit = $LASTEXITCODE
    }
    catch {
        $script:WslExit = 9009
        $out = @()
    }
    finally {
        try { [Console]::OutputEncoding = $prev } catch { }
    }

    $clean = @()
    foreach ($line in $out) {
        if ($null -eq $line) { continue }
        $t = ([string]$line) -replace "`0", ''
        $t = $t.Trim()
        if ($t -ne '') { $clean += $t }
    }
    return $clean
}

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreeGb {
    param([string]$DriveLetter)
    try {
        $d = Get-PSDrive -Name $DriveLetter -PSProvider FileSystem
        return [math]::Round($d.Free / 1GB, 1)
    }
    catch { return -1 }
}

# --------------------------------------------------------------------------- banner
Write-Host ''
Write-Host 'bioinfo bootstrap 00 - Windows / WSL substrate' -ForegroundColor White
Write-Host "  distro   : $Distro"
Write-Host "  location : $Location"
Write-Host "  vhdx     : $VhdxPath"
if ($DryRun)     { Write-Host '  mode     : DRY RUN (nothing will be changed)' -ForegroundColor Yellow }
if ($SkipInstall){ Write-Host '  mode     : diagnostics only' -ForegroundColor Yellow }

$elevated = Test-IsElevated
Write-Host "  elevated : $elevated"

# ============================================================ 1. Windows build level
Write-Head 'Windows build'
$os = Get-CimInstance Win32_OperatingSystem
$buildNumber = [int]($os.BuildNumber)
Write-Note "$($os.Caption)  build $($os.BuildNumber)"
if ($buildNumber -lt 19041) {
    Write-Bad "WSL2 needs build 19041 or newer; this is $buildNumber. Update Windows."
}
else {
    Write-Ok 'build supports WSL2'
}

# ============================================================ 2. virtualization
Write-Head 'Virtualization'
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.HypervisorPresent) {
    Write-Ok 'hypervisor present (VirtualMachinePlatform is active)'
}
else {
    # Two different root causes, and they need different fixes. Distinguish them.
    $fwEnabled = $null
    try { $fwEnabled = (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled } catch { }
    if ($fwEnabled -eq $false) {
        Write-Bad 'CPU virtualization is DISABLED IN FIRMWARE. Reboot into BIOS/UEFI and enable Intel VT-x / AMD-V. No software fix exists.'
    }
    else {
        Write-Warn 'no hypervisor running yet - usually means VirtualMachinePlatform is off or a reboot is pending (checked below)'
    }
}

# ============================================================ 3. optional features
Write-Head 'Optional Windows features'

# Get-WindowsOptionalFeature -Online requires administrator. Rather than demand
# elevation for a read, try it and fall back to probing the artefacts the features
# install (service + binary), which any user can see.
$featureState = @{}
$featureNames = @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')
$authoritative = $false
try {
    foreach ($f in $featureNames) {
        $r = Get-WindowsOptionalFeature -Online -FeatureName $f
        $featureState[$f] = [string]$r.State
    }
    $authoritative = $true
}
catch {
    foreach ($f in $featureNames) { $featureState[$f] = 'unknown' }
}

if (-not $authoritative) {
    Write-Note 'not elevated - inferring feature state from installed artefacts instead of DISM'
    $vmcompute = Test-Path (Join-Path $env:WINDIR 'System32\vmcompute.exe')
    $wslExe    = Test-Path (Join-Path $env:WINDIR 'System32\wsl.exe')
    if ($vmcompute) { $featureState['VirtualMachinePlatform'] = 'Enabled(inferred)' }        else { $featureState['VirtualMachinePlatform'] = 'Disabled(inferred)' }
    if ($wslExe)    { $featureState['Microsoft-Windows-Subsystem-Linux'] = 'Enabled(inferred)' } else { $featureState['Microsoft-Windows-Subsystem-Linux'] = 'Disabled(inferred)' }
}

$needFeatureEnable = @()
foreach ($f in $featureNames) {
    $st = $featureState[$f]
    if ($st -like 'Enabled*') {
        Write-Ok "$f = $st"
    }
    else {
        Write-Bad "$f = $st"
        $needFeatureEnable += $f
    }
}

if ($needFeatureEnable.Count -gt 0) {
    Write-Host ''
    Write-Host '   This is the one genuinely elevated step. Open an ADMIN PowerShell and run:' -ForegroundColor Yellow
    foreach ($f in $needFeatureEnable) {
        Write-Host "     dism.exe /online /enable-feature /featurename:$f /all /norestart" -ForegroundColor Yellow
    }
    Write-Host '   then reboot, then re-run this script (non-elevated is fine).' -ForegroundColor Yellow
}

# ============================================================ 4. pending reboot
Write-Head 'Pending reboot'
$rebootReasons = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
    $rebootReasons += 'Component Based Servicing'
}
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
    $rebootReasons += 'Windows Update'
}
try {
    $sm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    if ($sm.PSObject.Properties.Name -contains 'PendingFileRenameOperations') {
        $rebootReasons += 'PendingFileRenameOperations'
    }
}
catch { }

if ($rebootReasons.Count -gt 0) {
    Write-Bad ("reboot pending (" + ($rebootReasons -join ', ') + "). Feature enablement will not take effect until you reboot.")
}
else {
    Write-Ok 'no reboot pending'
}

# ============================================================ 5. wsl runtime
Write-Head 'WSL runtime'
$wslPresent = $false
try {
    $null = Get-Command wsl.exe
    $wslPresent = $true
}
catch {
    Write-Bad 'wsl.exe not found on PATH. Enable the optional features above and reboot.'
}

if ($wslPresent) {
    $ver = Invoke-Wsl @('--version')
    if ($script:WslExit -eq 0 -and $ver.Count -gt 0) {
        foreach ($l in $ver) { Write-Note $l }
        Write-Ok 'modern (Store / MSI) WSL runtime present'
    }
    else {
        # `wsl --version` is unsupported by the old inbox WSL that shipped with 1903-21H2.
        Write-Warn 'wsl --version failed: this is probably the legacy inbox WSL. Run `wsl --update` (may prompt for elevation) to get the Store runtime, which is what --location and --import-in-place need.'
    }

    if (-not $DryRun) {
        $null = Invoke-Wsl @('--set-default-version', '2')
        if ($script:WslExit -eq 0) { Write-Ok 'default WSL version set to 2' }
        else { Write-Warn 'could not set default WSL version to 2' }
    }
    else {
        Write-Note 'DRY RUN: would run  wsl --set-default-version 2'
    }
}

# ============================================================ 6. per-user registration
Write-Head 'Distro registration (HKCU - per Windows user)'

# THIS IS THE TRAP. WSL registers distros under HKCU, not HKLM. A distro installed by
# another Windows account - or by the same human under a different profile, e.g. a
# local account vs a Microsoft account, or an admin-elevated first run - is completely
# invisible here, even though its ext4.vhdx is sitting right there on disk.
$lxssRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
$registered = @()
if (Test-Path $lxssRoot) {
    foreach ($k in (Get-ChildItem $lxssRoot)) {
        try {
            $p = Get-ItemProperty -Path $k.PSPath
            if ($p.PSObject.Properties.Name -contains 'DistributionName') {
                $registered += [pscustomobject]@{
                    Name     = [string]$p.DistributionName
                    BasePath = [string]$p.BasePath
                    Version  = [string]$p.Version
                }
            }
        }
        catch { }
    }
}

Write-Note ("current Windows user: " + $env:USERDOMAIN + "\" + $env:USERNAME)
if ($registered.Count -eq 0) {
    Write-Note 'no distros registered under this Windows account'
}
else {
    foreach ($r in $registered) {
        Write-Note ("registered: {0}   ->  {1}" -f $r.Name, ($r.BasePath -replace '^\\\\\?\\', ''))
    }
}

$alreadyRegistered = $false
foreach ($r in $registered) {
    if ($r.Name -eq $Distro) { $alreadyRegistered = $true }
}

$vhdxExists = Test-Path $VhdxPath

if ($alreadyRegistered) {
    Write-Ok "$Distro is registered to this account"
}
elseif ($vhdxExists) {
    # Exactly the situation this machine hit. Explain it instead of "install failed".
    Write-Bad "$Distro is NOT registered to this account, but $VhdxPath exists on disk."
    Write-Host ''
    Write-Host '   Diagnosis: that VHDX belongs to a different Windows user profile.' -ForegroundColor Yellow
    Write-Host '   WSL registration lives in HKCU, so it is per-account and does not transfer.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '   Two ways forward:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '   (a) Clean install to a NEW location (what this script does by default).' -ForegroundColor Yellow
    Write-Host "       Re-run with a different -Location, e.g. -Location $($Drive.ToUpper()):\wsl\ubuntu-24.04-new" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '   (b) Adopt the existing filesystem. COPY IT FIRST. Never register the' -ForegroundColor Yellow
    Write-Host '       original file to a second account - two accounts mounting one ext4' -ForegroundColor Yellow
    Write-Host '       image is a real path to filesystem corruption.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '         wsl --shutdown                      # both accounts must be idle' -ForegroundColor Yellow
    Write-Host "         mkdir $($Drive.ToUpper()):\wsl\adopted" -ForegroundColor Yellow
    Write-Host "         copy `"$VhdxPath`" $($Drive.ToUpper()):\wsl\adopted\ext4.vhdx" -ForegroundColor Yellow
    Write-Host "         wsl --import-in-place $Distro $($Drive.ToUpper()):\wsl\adopted\ext4.vhdx" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '       Then continue at bootstrap/01-wsl-base.sh as normal.' -ForegroundColor Yellow

    # A locked VHDX means the other account still has it running. Registering it now
    # would be the worst case. Detect it cheaply - opening a handle does not read 1 TB.
    $locked = $false
    try {
        $fs = [System.IO.File]::Open($VhdxPath, 'Open', 'ReadWrite', 'None')
        $fs.Close()
    }
    catch { $locked = $true }
    if ($locked) {
        Write-Host ''
        Write-Bad 'that VHDX is currently LOCKED - another session has it mounted. Run `wsl --shutdown` in the owning account before copying.'
    }
    $SkipInstall = $true
}
else {
    Write-Note "$Distro not registered and no VHDX at the target location - clean install path"
}

# ============================================================ 7. target drive
Write-Head 'Target drive'
$freeGb = Get-FreeGb -DriveLetter $Drive.ToUpper()
if ($freeGb -lt 0) {
    Write-Bad "drive $($Drive.ToUpper()): not found"
}
else {
    Write-Note "$($Drive.ToUpper()): has $freeGb GB free"
    # 250 GB is the floor for anything real: a sarek WGS trio plus containers plus a
    # STAR index will pass 200 GB of work directory on its own.
    if ($freeGb -lt 250) {
        Write-Warn "only $freeGb GB free. Pipeline work directories routinely need 200+ GB. Pick a bigger drive."
    }
    else {
        Write-Ok 'enough headroom'
    }
    if ($Drive.ToUpper() -eq 'C') {
        Write-Warn 'installing to C: is a bad idea on this class of machine - the system drive fills and Windows starts failing in unrelated ways.'
    }
}

# ============================================================ 8. install
Write-Head 'Install'

if ($script:Blockers.Count -gt 0) {
    Write-Host ''
    Write-Host 'Not installing - unresolved blockers:' -ForegroundColor Red
    $i = 1
    foreach ($b in $script:Blockers) { Write-Host "  $i. $b" -ForegroundColor Red; $i++ }
    Write-Host ''
    Write-Host 'Fix those, reboot if a reboot is pending, then re-run.' -ForegroundColor Red
    exit 1
}

if ($SkipInstall) {
    Write-Note 'skipping install (either -SkipInstall, or an adoption decision is pending)'
}
elseif ($alreadyRegistered) {
    Write-Ok 'nothing to do - distro already registered (this script is idempotent)'
}
else {
    if (-not (Test-Path $Location)) {
        if ($DryRun) { Write-Note "DRY RUN: would create $Location" }
        else { New-Item -ItemType Directory -Path $Location -Force | Out-Null; Write-Ok "created $Location" }
    }

    $installArgs = @('--install', '-d', $Distro, '--location', $Location, '--no-launch')
    Write-Note ('wsl.exe ' + ($installArgs -join ' '))

    if ($DryRun) {
        Write-Note 'DRY RUN: install not executed'
    }
    else {
        # --no-launch matters: it registers the distro without running the interactive
        # OOBE that asks for a UNIX username and password. 01-wsl-base.sh creates the
        # user non-interactively instead, which is what makes this scriptable.
        $out = Invoke-Wsl $installArgs
        foreach ($l in $out) { Write-Note $l }

        if ($script:WslExit -ne 0) {
            Write-Warn "wsl --install exited $($script:WslExit)."
            Write-Host ''
            Write-Host '   If the complaint was about --location, this WSL runtime is too old for it.' -ForegroundColor Yellow
            Write-Host '   Either `wsl --update` first, or install to the default location and move it:' -ForegroundColor Yellow
            Write-Host '' -ForegroundColor Yellow
            Write-Host "     wsl --install -d $Distro --no-launch" -ForegroundColor Yellow
            Write-Host '     wsl --shutdown' -ForegroundColor Yellow
            Write-Host "     wsl --manage $Distro --move `"$Location`"" -ForegroundColor Yellow
            Write-Host '' -ForegroundColor Yellow
            Write-Host '   Last resort if --manage is also unavailable (destructive - it unregisters):' -ForegroundColor Yellow
            Write-Host "     wsl --export $Distro $($Drive.ToUpper()):\wsl\$Distro.tar" -ForegroundColor Yellow
            Write-Host "     wsl --unregister $Distro" -ForegroundColor Yellow
            Write-Host "     wsl --import $Distro `"$Location`" $($Drive.ToUpper()):\wsl\$Distro.tar --version 2" -ForegroundColor Yellow
            # <!-- UNVERIFIED: confirm `--location` and `wsl --manage <d> --move` are
            #      supported by this runtime with:  wsl --help  |  wsl --manage --help -->
            exit 1
        }

        # Registration is asynchronous on some builds - confirm rather than assume.
        $list = Invoke-Wsl @('--list', '--quiet')
        $found = $false
        foreach ($l in $list) { if ($l -eq $Distro) { $found = $true } }
        if ($found) { Write-Ok "$Distro registered" }
        else { Write-Bad "wsl --install returned 0 but $Distro is not in `wsl --list --quiet`. Inspect with: wsl --list --verbose" }
    }
}

# ============================================================ 9. next steps
Write-Head 'Next'

$repo = '/mnt/' + $Drive.ToLower() + '/bioinfo'

Write-Host ''
Write-Host '  Run these in order. Note `bash <script>` rather than `./<script>` -' -ForegroundColor White
Write-Host '  the repo lives on NTFS, so the exec bit is not reliable and a CRLF' -ForegroundColor White
Write-Host '  checkout would otherwise die on the shebang.' -ForegroundColor White
Write-Host ''
Write-Host "    wsl -d $Distro -u root -- bash $repo/bootstrap/01-wsl-base.sh"
Write-Host "    wsl --terminate $Distro                       # wsl.conf needs a restart"
Write-Host "    wsl -d $Distro -u root -- bash $repo/bootstrap/02-docker.sh"
Write-Host "    wsl -d $Distro -- bash $repo/bootstrap/03-nextflow.sh"
Write-Host "    wsl -d $Distro -- bash $repo/bootstrap/04-refs.sh"
Write-Host "    wsl -d $Distro -- bash $repo/bootstrap/05-verify.sh"
Write-Host ''

if ($script:Notes.Count -gt 0) {
    Write-Host '  Warnings raised this run:' -ForegroundColor Yellow
    $i = 1
    foreach ($n in $script:Notes) { Write-Host "    $i. $n" -ForegroundColor Yellow; $i++ }
    Write-Host ''
}

if ($script:Blockers.Count -gt 0) { exit 1 }
exit 0
