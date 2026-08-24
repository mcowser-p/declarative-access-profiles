# Probe body for verify-profile-windows.sh. Runs ON the guest.
# Env: DAP_GROUP (the simulated team group), DAP_PROFILE (profile name).
# Two hard-won assertions live here:
#  * WMSVC grants land in administration.config under
#    authorizationRules/scope/add - NOT a flat //authorization/add.
#  * SDDL restore is compared as an ACE SET: Windows canonicalises
#    DACL order on write, so byte comparison reports a false diff.
$fail = 0
function Check($label, $cond, $detail) {
  if ($cond) { "  PASS  {0,-46} {1}" -f $label, $detail }
  else { "  FAIL  {0,-46} {1}" -f $label, $detail; $script:fail = 1 }
}
$grp = $env:DAP_GROUP
$prof = $env:DAP_PROFILE

# 1. WMSVC per-site delegation (the vendor path)
$admin = "$env:windir\system32\inetsrv\config\administration.config"
$xml = [xml](Get-Content $admin)
$scoped = @{}
foreach ($sc in $xml.SelectNodes('//authorizationRules/scope')) {
  $scoped[$sc.path] = @($sc.SelectNodes('add') | ForEach-Object { $_.name })
}
Check 'wmsvc: team authorized on app' ($scoped['/app'] -contains $grp) ($scoped['/app'] -join ',')
Check 'wmsvc: team authorized on www' ($scoped['/www'] -contains $grp) ($scoped['/www'] -join ',')

# 2. NTFS content Modify + inheritance
$acl = Get-Acl 'C:\inetpub\sites\app'
$ace = $acl.Access | Where-Object { $_.IdentityReference -like "*$grp" -and $_.AccessControlType -eq 'Allow' }
Check 'ntfs: team Modify on content root' ($ace -and $ace.FileSystemRights -match 'Modify') "$($ace.FileSystemRights)"
Check 'ntfs: grant is inheritable (OI)(CI)' ($ace -and $ace.InheritanceFlags -match 'ContainerInherit' -and $ace.InheritanceFlags -match 'ObjectInherit') "$($ace.InheritanceFlags)"

# 3. per-site logs read
$lacl = Get-Acl 'C:\inetpub\logs\LogFiles\W3SVC1'
Check 'ntfs: team Read on own log dir' (($lacl.Access | Where-Object { $_.IdentityReference -like "*$grp" }) -ne $null) ''

# 4. the deny: pool identity cannot rewrite its own config
$wacl = Get-Acl 'C:\inetpub\sites\app\web.config'
$deny = $wacl.Access | Where-Object { $_.AccessControlType -eq 'Deny' -and $_.IdentityReference -like '*app*' }
Check 'deny: pool identity Write on web.config' ($deny -ne $null) "$($deny.IdentityReference) $($deny.FileSystemRights)"

# 5. service SDDL carries the team SID
$sid = (New-Object System.Security.Principal.NTAccount($grp)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$sd = (& sc.exe sdshow W3SVC | Where-Object { $_ -match '^D:' }) -join ''
Check 'sdset: W3SVC grants the team SID' ($sd -match [regex]::Escape($sid)) $sid
$sdw = (& sc.exe sdshow WAS | Where-Object { $_ -match '^D:' }) -join ''
Check 'sdset: WAS grants the team SID' ($sdw -match [regex]::Escape($sid)) ''
Check 'sdset: snapshot exists for rollback' (Test-Path 'C:\bootstrap\dap-snapshots\W3SVC.sddl') ''

# 6. JEA endpoint
$pssc = Get-PSSessionConfiguration -Name $prof -ErrorAction SilentlyContinue
Check 'jea: endpoint registered' ($pssc -ne $null) "$($pssc.Name)"
$psrc = Get-Content 'C:\Program Files\WindowsPowerShell\Modules\DeclarativeAccessJEA\RoleCapabilities\$prof.psrc' -Raw
Check 'jea: pool names are ValidateSet-constrained' ($psrc -match "'app'" -and $psrc -match "'www'") ''
Check 'jea: only catalogue functions exposed' ($psrc -notmatch 'DefaultAppPool') ''

# 7. NEVER granted
$hacl = Get-Acl "$env:windir\system32\inetsrv\config\applicationHost.config"
Check 'deny: team has NO ace on applicationHost.config' (($hacl.Access | Where-Object { $_.IdentityReference -like "*$grp" }) -eq $null) ''
$admins = (Get-LocalGroupMember -Group 'Administrators').Name -join ','
Check 'deny: team NOT in local Administrators' ($admins -notmatch $grp) $admins

# 8. event log readers
$elr = (Get-LocalGroupMember -Group 'Event Log Readers' -ErrorAction SilentlyContinue).Name -join ','
Check 'event: team in Event Log Readers' ($elr -match $grp) $elr

if ($fail) { "RESULT: FAIL" } else { "RESULT: PASS" }
