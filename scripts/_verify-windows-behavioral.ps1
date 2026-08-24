# _verify-windows-behavioral.ps1 -- probe the IIS grants AS THE TEAM MEMBER.
#
# WHY THIS EXISTS: _verify-windows-granted.ps1 asserts that the grants LANDED
# (ACEs present, SDDL carries the SID, WMSVC authorization written, JEA
# endpoint registered). That is necessary but not sufficient -- every one of
# those checks runs as Administrator, who passes regardless of whether the
# delegation actually works. The Linux harness never had this weakness:
# _verify-remote.sh really becomes another user (`sudo -u appdev ...`, plus a
# real SSH login for the pam_group test) and proves allow AND deny.
#
# This is the Windows equivalent. Start-Process -Credential calls
# CreateProcessWithLogonW, the same API `runas` uses, so the probe body runs
# under the team member's own token -- the claim the profile actually makes.
#
# Env: DAP_GROUP (team group), DAP_USER, DAP_USER_PW, DAP_PROFILE.
$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false

$grp  = $env:DAP_GROUP
$user = $env:DAP_USER
$pw   = $env:DAP_USER_PW
$prof = $env:DAP_PROFILE
$fail = 0

# Fail loudly on a missing input rather than deep inside New-Object
# PSCredential, whose "Object reference not set" tells you nothing.
foreach ($v in @('DAP_GROUP', 'DAP_USER', 'DAP_USER_PW', 'DAP_PROFILE')) {
    if (-not (Get-Item "env:$v" -ErrorAction SilentlyContinue).Value) {
        throw "$v is not set -- the driver must export it (see win_run_ps1_env)"
    }
}

function Check($label, $cond, $detail) {
    if ($cond) { "  PASS  {0,-50} {1}" -f $label, $detail }
    else { "  FAIL  {0,-50} {1}" -f $label, $detail; $script:fail = 1 }
}

$sec  = ConvertTo-SecureString $pw -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($user, $sec)
New-Item -ItemType Directory -Path C:\bootstrap\probe -Force | Out-Null
icacls 'C:\bootstrap\probe' /grant "${user}:(OI)(CI)M" 2>&1 | Out-Null

# The probe account must hold SeBatchLogonRight or Task Scheduler registers
# the task, reports success from /Run, and then never starts it: Last Result
# 0x41303 ("has not yet run") with Last Run Time 11/30/1999. schtasks does
# NOT grant the right (the Task Scheduler GUI does, which is why this is easy
# to miss). This is a harness concession, not part of the profile - it only
# lets the process start as that user; the token still carries exactly the
# group memberships and privileges the profile granted.
function Grant-BatchLogon($who) {
    $sid = (New-Object System.Security.Principal.NTAccount($who)).Translate(
        [System.Security.Principal.SecurityIdentifier]).Value
    $inf = "$env:TEMP\dap-userrights.inf"
    $db  = "$env:TEMP\dap-userrights.sdb"
    secedit /export /cfg $inf /areas USER_RIGHTS 2>&1 | Out-Null
    $lines = @(Get-Content $inf)
    $cur = $lines | Where-Object { $_ -match '^SeBatchLogonRight' } | Select-Object -First 1
    if ($cur) {
        if ($cur -match [regex]::Escape($sid)) { return 'already held' }
        $lines = $lines | ForEach-Object {
            if ($_ -match '^SeBatchLogonRight') { "$_,*$sid" } else { $_ }
        }
    } else {
        # insert INSIDE [Privilege Rights]; appending at EOF would land in
        # whatever section happens to be last
        $out = @()
        foreach ($l in $lines) {
            $out += $l
            if ($l -match '^\[Privilege Rights\]') { $out += "SeBatchLogonRight = *$sid" }
        }
        $lines = $out
    }
    # secedit requires a Unicode INF
    Set-Content -Path $inf -Value $lines -Encoding Unicode
    $r = secedit /configure /db $db /cfg $inf /areas USER_RIGHTS 2>&1 | Out-String
    return $r.Trim()
}
$brights = Grant-BatchLogon $user
[Console]::Error.WriteLine("[i] SeBatchLogonRight for ${user}: $brights")

# Run a scriptblock as the team member and return what it wrote.
#
# LAUNCHER: a per-probe SCHEDULED TASK (`schtasks /RU <user> /RP <pw>`), not
# Start-Process -Credential. Start-Process was tried first and every probe
# came back NO-OUTPUT: it launches without throwing, but a process started as
# a different user from a NON-INTERACTIVE SSH session has no window station
# or desktop to attach to and dies instantly. A scheduled task runs in its
# own batch logon session, so the problem does not arise -- the same reason
# holy-qcow uses a SYSTEM task in seal.ps1 to escape the SSH job object.
#
# /RL LIMITED on purpose: the probe must run with the team member's ORDINARY
# token. /RL HIGHEST would elevate it and quietly invalidate every deny test.
#
# The body writes its verdict to __OUT__, substituted here, so the parent
# never has to infer intent from an exit code.
function As-User([string]$body) {
    $id  = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $ps1 = "C:\bootstrap\probe\p-$id.ps1"
    $out = "C:\bootstrap\probe\p-$id.out"
    $tn  = "dap-probe-$id"
    $wrapped = "Start-Transcript -Path '$ps1.log' -Force | Out-Null`r`n" + $body.Replace('__OUT__', $out)
    Set-Content -Path $ps1 -Value $wrapped -Encoding ascii
    icacls $ps1 /grant "${user}:(RX)" 2>&1 | Out-Null
    $created = schtasks /Create /TN $tn /SC ONCE /ST 23:59 /RU $user /RP $pw /RL LIMITED /F `
        /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return "TASK-CREATE-FAILED: $($created.Trim())" }
    $runOut = schtasks /Run /TN $tn 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { schtasks /Delete /TN $tn /F 2>&1 | Out-Null; return "TASK-RUN-FAILED: $($runOut.Trim())" }
    for ($i = 0; $i -lt 45; $i++) {
        Start-Sleep -Seconds 2
        $st = (schtasks /Query /TN $tn /FO LIST 2>&1 | Select-String 'Status:') -join ''
        if ($st -notmatch 'Running') { break }
    }
    Start-Sleep -Seconds 2
    # Capture WHY before deleting the task. "Last Result" is the child's exit
    # code: 0x0 ran fine, 0x1 generic failure, 0x2 file not found,
    # 0xE0434352 a .NET exception, 0x41303 never ran. Without this the only
    # symptom is a missing output file, which says nothing.
    $verbose  = schtasks /Query /TN $tn /FO LIST /V 2>&1 | Out-String
    $lastRes  = ($verbose -split "`n" | Where-Object { $_ -match 'Last Result' }) -join ' '
    $lastRun  = ($verbose -split "`n" | Where-Object { $_ -match 'Last Run Time' }) -join ' '
    schtasks /Delete /TN $tn /F 2>&1 | Out-Null
    if (Test-Path $out) { return (Get-Content $out -Raw).Trim() }
    # transcript of the child, if the shell got far enough to write one
    $tr = "$ps1.log"
    $trTail = if (Test-Path $tr) { (Get-Content $tr -Raw).Trim() } else { '(no transcript)' }
    return "NO-OUTPUT [$($lastRes.Trim()) | $($lastRun.Trim())] $trTail"
}

"===== BEHAVIORAL PROBES as $user (member of $grp) ====="

# who the token actually is -- proves we are not silently still Administrator
$who = As-User @'
"$(whoami)" | Out-File '__OUT__' -Encoding ascii
'@
Check 'identity: probe runs as the team member, not admin' ($who -match [regex]::Escape($user)) $who

# 1. ALLOW -- write into the granted content root
$r = As-User @'
$out = '__OUT__'
try {
  $f = 'C:\inetpub\sites\app\dap-behavioral.txt'
  Set-Content -Path $f -Value 'written by the team member' -ErrorAction Stop
  Remove-Item $f -ErrorAction SilentlyContinue
  "OK: wrote content root" | Out-File $out -Encoding ascii
} catch { "DENIED: $($_.Exception.Message)" | Out-File $out -Encoding ascii }
'@
Check 'allow: write in granted content root' ($r -like 'OK:*') $r

# 2. DENY -- the server-wide config is granted to nobody, at any tenancy
$r = As-User @'
$out = '__OUT__'
try {
  Add-Content -Path "$env:windir\system32\inetsrv\config\applicationHost.config" -Value '<!-- dap -->' -ErrorAction Stop
  "ALLOWED: wrote applicationHost.config" | Out-File $out -Encoding ascii
} catch { "DENIED: $($_.Exception.Message)" | Out-File $out -Encoding ascii }
'@
Check 'deny: cannot write applicationHost.config' ($r -like 'DENIED:*') ($r -replace '\s+', ' ').Substring(0, [Math]::Min(70, ($r -replace '\s+', ' ').Length))

# 3. ALLOW -- read own request logs
$r = As-User @'
$out = '__OUT__'
try {
  $null = Get-ChildItem 'C:\inetpub\logs\LogFiles\W3SVC1' -ErrorAction Stop
  "OK: listed own log dir" | Out-File $out -Encoding ascii
} catch { "DENIED: $($_.Exception.Message)" | Out-File $out -Encoding ascii }
'@
Check 'allow: read own per-site log directory' ($r -like 'OK:*') $r

# 4. ALLOW -- service control via the SDDL grant (single-tenant host)
$r = As-User @'
$out = '__OUT__'
$q = (& sc.exe query W3SVC 2>&1 | Out-String)
if ($LASTEXITCODE -eq 0) { "OK: sc query W3SVC ($LASTEXITCODE)" | Out-File $out -Encoding ascii }
else { "DENIED: exit $LASTEXITCODE :: $($q.Trim())" | Out-File $out -Encoding ascii }
'@
Check 'allow: query W3SVC (SDDL grant)' ($r -like 'OK:*') $r

# 5. DENY -- WMSVC is the delegation channel itself and is never granted
$r = As-User @'
$out = '__OUT__'
$q = (& sc.exe stop WMSVC 2>&1 | Out-String)
if ($LASTEXITCODE -eq 0) { "ALLOWED: stopped WMSVC" | Out-File $out -Encoding ascii }
else { "DENIED: exit $LASTEXITCODE" | Out-File $out -Encoding ascii }
'@
Check 'deny: cannot stop WMSVC (the delegation channel)' ($r -like 'DENIED:*') $r

# 6. DENY -- a foreign service the profile never granted
$r = As-User @'
$out = '__OUT__'
$q = (& sc.exe stop sshd 2>&1 | Out-String)
if ($LASTEXITCODE -eq 0) { "ALLOWED: stopped a foreign service" | Out-File $out -Encoding ascii }
else { "DENIED: exit $LASTEXITCODE" | Out-File $out -Encoding ascii }
'@
Check 'deny: cannot stop a foreign service' ($r -like 'DENIED:*') $r

# 7. JEA -- needs WinRM. Disabled at seal on 2025 images, so report rather
#    than fail: the profile already records that limitation.
$winrm = (Get-Service WinRM -ErrorAction SilentlyContinue)
if ($winrm -and $winrm.Status -eq 'Running') {
    $r = As-User (@'
$out = '__OUT__'
try {
  $so = New-PSSessionOption -SkipCACheck -SkipCNCheck
  $r = Invoke-Command -ComputerName localhost -UseSSL -SessionOption $so -ConfigurationName __PROFILE__ -ScriptBlock { Get-AppPoolStatus } -ErrorAction Stop
  "OK: JEA Get-AppPoolStatus -> $r" | Out-File $out -Encoding ascii
} catch { "DENIED: $($_.Exception.Message)" | Out-File $out -Encoding ascii }
'@.Replace('__PROFILE__', $prof))
    Check 'allow: JEA endpoint reachable by the team' ($r -like 'OK:*') ($r.Substring(0, [Math]::Min(80, $r.Length)))

    $r = As-User (@'
$out = '__OUT__'
try {
  $so = New-PSSessionOption -SkipCACheck -SkipCNCheck
  Invoke-Command -ComputerName localhost -UseSSL -SessionOption $so -ConfigurationName __PROFILE__ -ScriptBlock { Restart-AppPool -Name DefaultAppPool } -ErrorAction Stop
  "ALLOWED: recycled a pool outside the ValidateSet" | Out-File $out -Encoding ascii
} catch { "DENIED: $($_.Exception.Message)" | Out-File $out -Encoding ascii }
'@.Replace('__PROFILE__', $prof))
    $transportFailed = $r -match 'Connecting to remote server'
    Check 'deny: JEA rejects a pool outside the ValidateSet' `
        (($r -like 'DENIED:*') -and -not $transportFailed) `
        $(if ($transportFailed) { 'INCONCLUSIVE: transport failed, not a policy denial' }
          else { $r.Substring(0, [Math]::Min(80, $r.Length)) })
} else {
    "  SKIP  {0,-50} {1}" -f 'JEA probes', 'WinRM not running (disabled at seal on 2025 images)'
}

Remove-Item 'C:\bootstrap\probe' -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { "RESULT: FAIL" } else { "RESULT: PASS" }
