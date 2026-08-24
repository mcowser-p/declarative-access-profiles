# winget-recon.ps1 -- probe which winget packages resolve on this Windows host.
#
# READ-ONLY: uses `winget show`, never `winget install`. Nothing is installed,
# so there is no disk-space or interpreter-loss risk here (both are real
# concerns for the capture round that follows).
#
# WHY A BOOTSTRAP IS NEEDED: holy-qcow's images PROVISION the App Installer
# package (Add-AppxProvisionedPackage, which survives sysprep) but provisioning
# only stages it -- per-user registration happens at the first INTERACTIVE
# logon. Our automation path is SSH, a network logon, so winget may not be on
# PATH even though the package is present. This is NOT a privilege problem:
# sshd mints a full admin token for keys in administrators_authorized_keys.
# Resolve-Winget below is ported from treadmark scripts/win11-footprint.ps1,
# which hit exactly this on the arm64 runner ("the App Installer package isn't
# registered for the service account").
#
# Reads the candidate list as JSON on stdin-free footing: the driver converts
# scripts/winget-candidates.yml and stages it next to this script.
#
# Emits JSON on stdout. "winget unavailable" is a first-class RESULT, not a
# crash -- treadmark's own smoke test treats Server hosts the same way.
$ErrorActionPreference = 'Stop'
# treadmark's lesson: native tools legitimately exit non-zero here and we check
# $LASTEXITCODE ourselves; without this, the first winget miss aborts the run.
$PSNativeCommandUseErrorActionPreference = $false

$CandidatePath = Join-Path $PSScriptRoot 'winget-candidates.json'

# Diagnostics go to STDERR. Anything on stdout that is not JSON corrupts the
# evidence file (learned the hard way: a Write-Host here made the whole run
# unparseable).
# Every diagnostic must be survivable. On Server Core the DISM-backed Appx
# cmdlets can throw a COMException ("The specified module could not be
# found") that -ErrorAction SilentlyContinue does NOT suppress, because the
# failure is in loading the servicing provider rather than in the cmdlet. With
# $ErrorActionPreference = 'Stop' that kills the run before any evidence is
# emitted -- so each probe returns its error string as data instead.
function Try-Or {
    param([scriptblock]$Block, $Fallback = $null)
    try { & $Block } catch { "error: $($_.Exception.Message)" }
}

$script:Attempts = @()
function Note($step, $outcome) {
    $script:Attempts += [ordered]@{ step = $step; outcome = $outcome }
    [Console]::Error.WriteLine("[i] $step -> $outcome")
}

function Resolve-Winget {
    # 1. already on PATH?
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { Note 'path' 'winget already on PATH'; return $cmd.Source }
    Note 'path' 'not on PATH'

    # 2. registered for this user? Use the Appx API, NOT a glob of
    #    C:\Program Files\WindowsApps -- that directory is owned by
    #    TrustedInstaller and even an elevated admin gets access-denied
    #    enumerating it, which a silenced error turns into a phantom "absent".
    $pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
           Select-Object -Last 1
    if ($pkg -and $pkg.InstallLocation) {
        $exe = Join-Path $pkg.InstallLocation 'winget.exe'
        Note 'appx-current-user' "registered at $($pkg.InstallLocation)"
        if (Test-Path $exe) { return $exe }
    } else {
        Note 'appx-current-user' 'not registered for this user'
    }

    # 3. staged for other users / provisioned -- register it for THIS user,
    #    which is what an interactive logon would have done.
    $all = Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
           Select-Object -Last 1
    $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object DisplayName -eq 'Microsoft.DesktopAppInstaller' | Select-Object -Last 1
    $manifest = $null
    if ($all -and $all.InstallLocation) {
        $manifest = Join-Path $all.InstallLocation 'AppXManifest.xml'
        Note 'appx-all-users' "staged at $($all.InstallLocation)"
    } elseif ($prov) {
        $manifest = Join-Path "$env:ProgramFiles\WindowsApps\$($prov.PackageName)" 'AppXManifest.xml'
        Note 'appx-provisioned' "provisioned as $($prov.PackageName)"
    } else {
        Note 'appx-all-users/provisioned' 'no staged or provisioned package found'
    }

    if ($manifest) {
        try {
            Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
            Note 'appx-register' 'Add-AppxPackage -Register succeeded'
        } catch {
            Note 'appx-register' "failed: $($_.Exception.Message)"
        }
        $cmd = Get-Command winget -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        $pkg2 = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
                Select-Object -Last 1
        if ($pkg2 -and (Test-Path (Join-Path $pkg2.InstallLocation 'winget.exe'))) {
            return (Join-Path $pkg2.InstallLocation 'winget.exe')
        }
    }

    # 4. last resort: the official client module provisions/repairs winget.
    #    Non-interactive hardening -- Install-Module prompts for the NuGet
    #    provider and for untrusted-repo confirmation, and a prompt in an SSH
    #    session throws "ShouldContinue ... Object reference not set".
    try {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Get-PackageProvider -Name NuGet -ForceBootstrap -ErrorAction Stop | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module Microsoft.WinGet.Client -Force -AllowClobber -Scope AllUsers `
            -Repository PSGallery -Confirm:$false -ErrorAction Stop
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Repair-WinGetPackageManager -Force -Latest -ErrorAction Stop
        Note 'winget-client-module' 'Repair-WinGetPackageManager completed'
        $cmd = Get-Command winget -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    } catch {
        Note 'winget-client-module' "failed: $($_.Exception.Message)"
    }

    throw 'winget could not be resolved on this host'
}

$result = [ordered]@{
    schema        = '1.0-winget-recon'
    evidence_type = 'winget_probe'
    generated_at  = (Get-Date).ToUniversalTime().ToString('o')
    host          = $env:COMPUTERNAME
    image         = (Get-ItemProperty HKLM:\SOFTWARE\ImageRelease -ErrorAction SilentlyContinue).IMAGE_NAME
    os            = (Get-CimInstance Win32_OperatingSystem).Caption
    edition       = (Get-CimInstance Win32_OperatingSystem).OperatingSystemSKU
    # how winget was reached -- the finding this whole round hinges on
    winget_available = $false
    winget_path      = $null
    winget_version   = $null
    bootstrap_note   = $null
    bootstrap_attempts = @()
    # What the host actually has, so an "unavailable" verdict explains itself
    # (and tells the image fix exactly what to change).
    appx_state       = [ordered]@{
        provisioned             = (Try-Or { @(Get-AppxProvisionedPackage -Online |
            Where-Object DisplayName -like '*DesktopAppInstaller*' |
            ForEach-Object { [ordered]@{ name = $_.DisplayName; package = $_.PackageName; version = "$($_.Version)" } }) })
        registered_current_user = (Try-Or { @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller |
            ForEach-Object { [ordered]@{ full_name = $_.PackageFullName; location = $_.InstallLocation; status = "$($_.Status)" } }) })
        registered_all_users    = (Try-Or { @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller |
            ForEach-Object { [ordered]@{ full_name = $_.PackageFullName; location = $_.InstallLocation } }) })
        windowsapps_enumerable  = (Try-Or { $null = Get-ChildItem "$env:ProgramFiles\WindowsApps"; $true })
        appx_module             = (Try-Or { [bool](Get-Module -ListAvailable -Name Appx) })
        dism_module             = (Try-Or { [bool](Get-Module -ListAvailable -Name Dism) })
    }
    packages         = @()
}

$before = [bool](Get-Command winget -ErrorAction SilentlyContinue)
try {
    $wg = Resolve-Winget
    $result.winget_available = $true
    $result.winget_path = $wg
    $result.winget_version = (& $wg --version 2>&1 | Out-String).Trim()
    $result.bootstrap_note = if ($before) {
        'winget was already on PATH for this SSH session'
    } else {
        'winget required in-session bootstrap (provisioned but not registered for a network logon)'
    }
} catch {
    $result.bootstrap_note = "unavailable: $($_.Exception.Message)"
    $result.bootstrap_attempts = $script:Attempts
    $result | ConvertTo-Json -Depth 6
    exit 0    # unavailable is a result, not a failure
}
$result.bootstrap_attempts = $script:Attempts

# accept source agreements once, so each probe does not re-prompt
& $wg source update --accept-source-agreements 2>&1 | Out-Null

if (-not (Test-Path $CandidatePath)) { throw "candidate list not staged at $CandidatePath" }
$candidates = Get-Content $CandidatePath -Raw | ConvertFrom-Json

foreach ($c in $candidates) {
    $out = (& $wg show --id $c.id --exact --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
    $code = $LASTEXITCODE
    $entry = [ordered]@{
        id            = $c.id
        category      = $c.category
        expects_service = $c.service
        uncertain     = [bool]$c.uncertain
        control       = [bool]$c.control
        found         = $false
        version       = $null
        publisher     = $null
        installer_type = $null
        scope         = $null
        exit_code     = $code
        raw_tail      = $null
    }

    if ($code -eq 0 -and $out -notmatch 'No package found') {
        $entry.found = $true
        # Parse loosely and keep the raw text: winget's output is locale- and
        # version-sensitive, so a parse miss must stay recoverable.
        if ($out -match '(?m)^\s*Version:\s*(.+?)\s*$')        { $entry.version        = $Matches[1] }
        if ($out -match '(?m)^\s*Publisher:\s*(.+?)\s*$')      { $entry.publisher      = $Matches[1] }
        if ($out -match '(?m)^\s*Installer Type:\s*(.+?)\s*$') { $entry.installer_type = $Matches[1] }
        if ($out -match '(?m)^\s*Scope:\s*(.+?)\s*$')          { $entry.scope          = $Matches[1] }
        if (-not $entry.version) {
            # parsed nothing but winget said yes -- keep evidence for triage
            $entry.raw_tail = ($out -split "`n" | Select-Object -Last 8) -join ' | '
        }
    } elseif ($out -match 'No package found') {
        $entry.found = $false
    } else {
        # neither a clean hit nor a clean miss: a CDN hiccup must never be
        # recorded as "not available" -- that would silently shrink the corpus
        $entry.found = 'unknown'
        $entry.raw_tail = ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 6) -join ' | '
    }

    $result.packages += $entry
    Start-Sleep -Milliseconds 400
}

$result | ConvertTo-Json -Depth 6
