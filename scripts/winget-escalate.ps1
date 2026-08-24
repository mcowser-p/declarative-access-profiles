# winget-escalate.ps1 — test the two non-interactive routes to winget that an
# SSH session cannot use directly.
#
# CONTEXT: scripts/winget-recon.ps1 established that winget is unreachable
# from an SSH session: MSIX must be registered into a user profile, the
# registration happens at INTERACTIVE logon, and the AppX Deployment Service
# refuses a network logon with 0x80073D19. Two routes remain untested, and
# both avoid needing a registration at all or produce a different logon type:
#
#   route 1  SYSTEM scheduled task invoking the PROVISIONED winget.exe by
#            absolute path. This is how Intune/ConfigMgr automate winget.
#            SYSTEM can read C:\Program Files\WindowsApps (an elevated
#            Administrator over SSH cannot), and a scheduled task runs outside
#            the SSH session's job object.
#   route 2  Start-Process -Credential — the scriptable equivalent of
#            `runas /user:...`. Both call CreateProcessWithLogonW, which
#            performs a LOGON32_LOGON_INTERACTIVE logon rather than the
#            network logon SSH gives. The profile is deliberately LOADED
#            (no /noprofile): MSIX registration writes into the user's
#            profile and hive, so skipping it would defeat the test.
#
# Read-only with respect to packages: only `--version` and `show`, never
# `install`. Emits JSON on stdout; diagnostics go to stderr.
$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false

function Note($m) { [Console]::Error.WriteLine("[i] $m") }
New-Item -ItemType Directory -Path C:\bootstrap -Force | Out-Null

$result = [ordered]@{
    schema       = '1.0-winget-escalation'
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    host         = $env:COMPUTERNAME
    image        = (Get-ItemProperty HKLM:\SOFTWARE\ImageRelease -ErrorAction SilentlyContinue).IMAGE_NAME
    os           = (Get-CimInstance Win32_OperatingSystem).Caption
    routes       = @()
}

# ---------------------------------------------------------------- route 1
# The payload runs as SYSTEM and writes its findings to a file, because a
# scheduled task's stdout is not connected to anything we can read.
$sysProbe = @'
$ErrorActionPreference = 'Continue'
$log = 'C:\bootstrap\winget-system-probe.txt'
"identity: $(whoami)" | Out-File $log -Encoding ascii
try {
    $dir = Get-ChildItem 'C:\Program Files\WindowsApps' `
        -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction Stop |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $dir) { "windowsapps: enumerable but NO DesktopAppInstaller dir" | Out-File $log -Append; exit }
    "windowsapps: enumerable, dir=$($dir.Name)" | Out-File $log -Append
    $exe = Join-Path $dir.FullName 'winget.exe'
    "exe_present: $(Test-Path $exe)" | Out-File $log -Append
    if (Test-Path $exe) {
        $v = (& $exe --version 2>&1 | Out-String).Trim()
        "version_exit: $LASTEXITCODE" | Out-File $log -Append
        "version_out: $v" | Out-File $log -Append
        $s = (& $exe show --id nginx.nginx --exact --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
        "show_exit: $LASTEXITCODE" | Out-File $log -Append
        "show_out: $($s.Substring(0, [Math]::Min(500, $s.Length)))" | Out-File $log -Append
    }
} catch {
    "error: $($_.Exception.Message)" | Out-File $log -Append
}
'@
$sysProbePath = 'C:\bootstrap\winget-system-probe.ps1'
Set-Content -Path $sysProbePath -Value $sysProbe -Encoding ascii
Remove-Item 'C:\bootstrap\winget-system-probe.txt' -ErrorAction SilentlyContinue

$r1 = [ordered]@{ route = 'system-scheduled-task'; ran = $false; winget_usable = $false; detail = $null; log = $null }
try {
    schtasks /Create /TN dap-winget-probe /SC ONCE /ST 23:59 /RU SYSTEM /RL HIGHEST /F `
        /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sysProbePath" 2>&1 | Out-Null
    schtasks /Run /TN dap-winget-probe 2>&1 | Out-Null
    $r1.ran = $true
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 2
        $st = (schtasks /Query /TN dap-winget-probe /FO LIST 2>&1 | Select-String 'Status:') -join ''
        if ($st -notmatch 'Running') { break }
    }
    Start-Sleep -Seconds 3
    if (Test-Path 'C:\bootstrap\winget-system-probe.txt') {
        $r1.log = (Get-Content 'C:\bootstrap\winget-system-probe.txt' -Raw).Trim()
        $r1.winget_usable = ($r1.log -match 'version_exit: 0')
        $r1.detail = if ($r1.winget_usable) { 'winget ran as SYSTEM from the provisioned package path' }
                     else { 'task ran but winget did not execute cleanly' }
    } else {
        $r1.detail = 'scheduled task produced no log'
    }
} catch {
    $r1.detail = "failed: $($_.Exception.Message)"
} finally {
    schtasks /Delete /TN dap-winget-probe /F 2>&1 | Out-Null
}
Note "route1 system-task -> usable=$($r1.winget_usable)"
$result.routes += $r1

# ---------------------------------------------------------------- route 2
# runas-equivalent: CreateProcessWithLogonW gives an INTERACTIVE logon type,
# unlike SSH's network logon. Profile is loaded on purpose.
$r2 = [ordered]@{ route = 'start-process-credential'; ran = $false; winget_usable = $false; detail = $null; log = $null }
$u = 'dapesc'
$p = 'D@pEsc-' + -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 10 | ForEach-Object { [char]$_ })
try {
    $sec = ConvertTo-SecureString $p -AsPlainText -Force
    if (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $u }
    New-LocalUser -Name $u -Password $sec -PasswordNeverExpires -AccountNeverExpires | Out-Null
    Add-LocalGroupMember -Group Administrators -Member $u -ErrorAction SilentlyContinue
    $cred = New-Object System.Management.Automation.PSCredential($u, $sec)

    $inner = @'
$log = 'C:\bootstrap\winget-runas-probe.txt'
"identity: $(whoami)" | Out-File $log -Encoding ascii
$w = Get-Command winget -ErrorAction SilentlyContinue
"winget_on_path: $([bool]$w)" | Out-File $log -Append
$pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue
"appx_registered_for_this_user: $([bool]$pkg)" | Out-File $log -Append
if (-not $pkg) {
    try {
        $prov = Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction Stop | Select-Object -Last 1
        if ($prov) {
            Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path $prov.InstallLocation 'AppXManifest.xml') -ErrorAction Stop
            "register: succeeded" | Out-File $log -Append
        } else { "register: no staged package visible" | Out-File $log -Append }
    } catch { "register_error: $($_.Exception.Message)" | Out-File $log -Append }
    $w = Get-Command winget -ErrorAction SilentlyContinue
}
if ($w) {
    $v = (& winget --version 2>&1 | Out-String).Trim()
    "version_exit: $LASTEXITCODE" | Out-File $log -Append
    "version_out: $v" | Out-File $log -Append
} else { "winget still unavailable after register attempt" | Out-File $log -Append }
'@
    $innerPath = 'C:\bootstrap\winget-runas-probe.ps1'
    Set-Content -Path $innerPath -Value $inner -Encoding ascii
    # world-readable so the second identity can read the script
    icacls $innerPath /grant "${u}:(RX)" 2>&1 | Out-Null
    icacls 'C:\bootstrap' /grant "${u}:(OI)(CI)M" 2>&1 | Out-Null
    Remove-Item 'C:\bootstrap\winget-runas-probe.txt' -ErrorAction SilentlyContinue

    Start-Process -FilePath 'powershell.exe' -Credential $cred `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $innerPath `
        -WorkingDirectory 'C:\bootstrap' -WindowStyle Hidden -Wait -ErrorAction Stop
    $r2.ran = $true
    Start-Sleep -Seconds 2
    if (Test-Path 'C:\bootstrap\winget-runas-probe.txt') {
        $r2.log = (Get-Content 'C:\bootstrap\winget-runas-probe.txt' -Raw).Trim()
        $r2.winget_usable = ($r2.log -match 'version_exit: 0')
        $r2.detail = if ($r2.winget_usable) { 'winget ran under an interactive-type logon (CreateProcessWithLogonW)' }
                     else { 'process ran but winget did not execute cleanly' }
    } else { $r2.detail = 'process ran but produced no log' }
} catch {
    $r2.detail = "failed: $($_.Exception.Message)"
} finally {
    Remove-LocalUser -Name $u -ErrorAction SilentlyContinue
}
Note "route2 start-process-credential -> usable=$($r2.winget_usable)"
$result.routes += $r2

$result | ConvertTo-Json -Depth 6
