# Probe body for verify-profile-windows.sh. Runs ON the guest.
# Env: DAP_GROUP (the simulated team group), DAP_PROFILE (profile name).
# Two hard-won assertions live here:
#  * WMSVC grants land in administration.config under
#    authorizationRules/scope/add - NOT a flat //authorization/add.
#  * SDDL restore is compared as an ACE SET: Windows canonicalises
#    DACL order on write, so byte comparison reports a false diff.
$fail=0
function Check($l,$c,$d){ if($c){"  PASS  {0,-46} {1}" -f $l,$d} else {"  FAIL  {0,-46} {1}" -f $l,$d; $script:fail=1} }
$grp=$env:DAP_GROUP
$prof=$env:DAP_PROFILE
$sid=(New-Object System.Security.Principal.NTAccount($grp)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$xml=[xml](Get-Content "$env:windir\system32\inetsrv\config\administration.config")
$sc=@(); foreach($s in $xml.SelectNodes('//authorizationRules/scope')){ $sc += @($s.SelectNodes('add')|%{$_.name}) }
Check 'revoked: wmsvc authorization empty of team' ($sc -notcontains $grp) ($sc -join ',')
$acl=Get-Acl 'C:\inetpub\sites\app'
Check 'revoked: no team ACE on content' (($acl.Access|?{$_.IdentityReference -like "*$grp"}) -eq $null) ''
$w=Get-Acl 'C:\inetpub\sites\app\web.config'
Check 'revoked: pool deny ACE removed' (($w.Access|?{$_.AccessControlType -eq 'Deny'}) -eq $null) ''
$sd=(& sc.exe sdshow W3SVC|?{$_ -match '^D:'}) -join ''
Check 'revoked: W3SVC SDDL no longer grants team' ($sd -notmatch [regex]::Escape($sid)) ''
# Compare ACE SETS, not the raw string: Windows canonicalises DACL order on
# write (interactive/service ACEs sort ahead of SY/BA), so a byte comparison
# reports a false difference on a restore that is semantically exact.
$snap=(Get-Content 'C:\bootstrap\dap-snapshots\W3SVC.sddl' -Raw).Trim()
$re=[regex]'\([^)]*\)'
$sa=@($re.Matches($snap)|%{$_.Value}|Sort-Object); $na=@($re.Matches($sd)|%{$_.Value}|Sort-Object)
$same = (@($sa|?{$na -notcontains $_}).Count -eq 0) -and (@($na|?{$sa -notcontains $_}).Count -eq 0)
Check 'revoked: SDDL ACE-set restored from snapshot' $same "$($sa.Count) ACEs, order canonicalised by Windows"
Check 'revoked: jea endpoint unregistered' ((Get-PSSessionConfiguration -Name $prof -ErrorAction SilentlyContinue) -eq $null) ''
$elr=(Get-LocalGroupMember -Group 'Event Log Readers' -ErrorAction SilentlyContinue).Name -join ','
Check 'revoked: out of Event Log Readers' ($elr -notmatch $grp) $elr
Check 'retained: snapshots kept for audit' (Test-Path 'C:\bootstrap\dap-snapshots\W3SVC.sddl') ''
Check 'intact: IIS still serving (revoke is not destructive)' ((Get-Service W3SVC).Status -eq 'Running' -and (Get-Website -Name app).State -eq 'Started') ''
if($fail){"RESULT: FAIL"}else{"RESULT: PASS"}
