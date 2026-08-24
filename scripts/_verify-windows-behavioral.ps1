# _verify-windows-behavioral.ps1 — probe the IIS grants AS THE TEAM MEMBER.
#
# WHY THIS EXISTS: _verify-windows-granted.ps1 asserts that the grants LANDED
# (ACEs present, SDDL carries the SID, WMSVC authorization written, JEA
# endpoint registered). That is necessary but not sufficient — every one of
# those checks runs as Administrator, who passes regardless of whether the
# delegation actually works. The Linux harness never had this weakness:
# _verify-remote.sh really becomes another user (`sudo -u appdev ...`, plus a
# real SSH login for the pam_group test) and proves allow AND deny.
#
# This is the Windows equivalent. Start-Process -Credential calls
# CreateProcessWithLogonW, the same API `runas` uses, so the probe body runs
# under the team member's own token — the claim the profile actually makes.
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
        throw "$v is not set — the driver must export it (see win_run_ps1_env)"
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

# Run a scriptblock as the team member and return its stdout. The result is
# written to a file because Start-Process -Credential cannot share the
# parent's streams.
function As-User([string]$body) {
    $id  = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $ps1 = "C:\bootstrap\probe\p-$id.ps1"
    $out = "C:\bootstrap\probe\p-$id.out"
    # the probe body reports its own verdict as OK:/DENIED: so the parent
    # never has to infer intent from an exit code
    Set-Content -Path $ps1 -Value $body -Encoding ascii
    icacls $ps1 /grant "${user}:(RX)" 2>&1 | Out-Null
    try {
        Start-Process -FilePath 'powershell.exe' -Credential $cred `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ps1 `
            -WorkingDirectory 'C:\bootstrap\probe' -WindowStyle Hidden -Wait -ErrorAction Stop
    } catch {
        return "LAUNCH-FAILED: $($_.Exception.Message)"
    }
    if (Test-Path $out) { return (Get-Content $out -Raw).Trim() }
    return 'NO-OUTPUT'
}

"===== BEHAVIORAL PROBES as $user (member of $grp) ====="

# who the token actually is — proves we are not silently still Administrator
$who = As-User @'
$o='C:\bootstrap\probe\p-{0}.out'
"$(whoami)|$((Get-CimInstance Win32_ComputerSystem).Name)" | Out-File ($MyInvocation.MyCommand.Path -replace '\.ps1$','.out') -Encoding ascii
'@.Replace('{0}','x')
Check 'identity: probe runs as the team member, not admin' ($who -match [regex]::Escape($user)) $who

# 1. ALLOW — write into the granted content root
$r = As-User @'
$out = $MyInvocation.MyCommand.Path -replace '\.ps1$','.out'
try {
  $f = 'C:\inetpub\sites\app\dap-behavioral.txt'
  Set-Content -Path $f -Value 'written by the team member' -ErrorAction Stop
  Remove-Item $f -ErrorAction SilentlyContinue
  "OK: wrote content root" | Out-File $out -Encoding ascii
} catch { "DENIED: $($_.Exception.Message)" | Out-File $out -Encoding ascii }
'@
Check 'allow: write in granted content root' ($r -like 'OK:*') $r

# 2. DENY — the server-wide config is granted to nobody, at any tenancy
$r = As-User @'
$out = $MyInvocation.MyCommand.Path -replace '\.ps1$','.out'
try {
  Add-Content -Path "$env:windir\system32\inetsrv\config\applicationHost.config" -Value '<!-- dap -->' -ErrorAction Stop
  "ALLOWED: wrote applicationHost.config" | Out-File $out -Encoding ascii
} catch { "DENIED: $($_.Exception.Message)" | Out-File $out -Encoding ascii }
'@
Check 'deny: cannot write applicationHost.config' ($r -like 'DENIED:*') ($r -replace '\s+', ' ').Substring(0, [Math]::Min(70, ($r -replace '\s+', ' ').Length))

# 3. ALLOW — read own request logs
$r = As-User @'
$out = $MyInvocation.MyCommand.Path -replace '\.ps1$','.out'
try {
  $null = Get-ChildItem 'C:\inetpub\logs\LogFiles\W3SVC1' -ErrorAction Stop
  "OK: listed own log dir" | Out-File $out -Encoding ascii
} catch { "DENIED: $($_.Exception.Message)" | Out-File $out -Encoding ascii }
'@
Check 'allow: read own per-site log directory' ($r -like 'OK:*') $r

# 4. ALLOW — service control via the SDDL grant (single-tenant host)
$r = As-User @'
$out = $MyInvocation.MyCommand.Path -replace '\.ps1$','.out'
$q = (& sc.exe query W3SVC 2>&1 | Out-String)
if ($LASTEXITCODE -eq 0) { "OK: sc query W3SVC ($LASTEXITCODE)" | Out-File $out -Encoding ascii }
else { "DENIED: exit $LASTEXITCODE :: $($q.Trim())" | Out-File $out -Encoding ascii }
'@
Check 'allow: query W3SVC (SDDL grant)' ($r -like 'OK:*') $r

# 5. DENY — WMSVC is the delegation channel itself and is never granted
$r = As-User @'
$out = $MyInvocation.MyCommand.Path -replace '\.ps1$','.out'
$q = (& sc.exe stop WMSVC 2>&1 | Out-String)
if ($LASTEXITCODE -eq 0) { "ALLOWED: stopped WMSVC" | Out-File $out -Encoding ascii }
else { "DENIED: exit $LASTEXITCODE" | Out-File $out -Encoding ascii }
'@
Check 'deny: cannot stop WMSVC (the delegation channel)' ($r -like 'DENIED:*') $r

# 6. DENY — a foreign service the profile never granted
$r = As-User @'
$out = $MyInvocation.MyCommand.Path -replace '\.ps1$','.out'
$q = (& sc.exe stop sshd 2>&1 | Out-String)
if ($LASTEXITCODE -eq 0) { "ALLOWED: stopped a foreign service" | Out-File $out -Encoding ascii }
else { "DENIED: exit $LASTEXITCODE" | Out-File $out -Encoding ascii }
'@
Check 'deny: cannot stop a foreign service' ($r -like 'DENIED:*') $r

# 7. JEA — needs WinRM. Disabled at seal on 2025 images, so report rather
#    than fail: the profile already records that limitation.
$winrm = (Get-Service WinRM -ErrorAction SilentlyContinue)
if ($winrm -and $winrm.Status -eq 'Running') {
    $r = As-User (@'
$out = $MyInvocation.MyCommand.Path -replace '\.ps1$','.out'
try {
  $r = Invoke-Command -ComputerName localhost -ConfigurationName __PROFILE__ -ScriptBlock { Get-AppPoolStatus -Name app } -ErrorAction Stop
  "OK: JEA Get-AppPoolStatus -> $r" | Out-File $out -Encoding ascii
} catch { "DENIED: $($_.Exception.Message)" | Out-File $out -Encoding ascii }
'@ -replace '__PROFILE__', $prof)
    Check 'allow: JEA endpoint reachable by the team' ($r -like 'OK:*') ($r.Substring(0, [Math]::Min(80, $r.Length)))

    $r = As-User (@'
$out = $MyInvocation.MyCommand.Path -replace '\.ps1$','.out'
try {
  Invoke-Command -ComputerName localhost -ConfigurationName __PROFILE__ -ScriptBlock { Restart-AppPool -Name DefaultAppPool } -ErrorAction Stop
  "ALLOWED: recycled a pool outside the ValidateSet" | Out-File $out -Encoding ascii
} catch { "DENIED: $($_.Exception.Message)" | Out-File $out -Encoding ascii }
'@ -replace '__PROFILE__', $prof)
    Check 'deny: JEA rejects a pool outside the ValidateSet' ($r -like 'DENIED:*') ($r.Substring(0, [Math]::Min(80, $r.Length)))
} else {
    "  SKIP  {0,-50} {1}" -f 'JEA probes', 'WinRM not running (disabled at seal on 2025 images)'
}

Remove-Item 'C:\bootstrap\probe' -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { "RESULT: FAIL" } else { "RESULT: PASS" }
