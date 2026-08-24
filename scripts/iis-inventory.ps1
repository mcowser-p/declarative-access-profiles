# iis-inventory.ps1 -- live enumeration of an IIS host's access surface.
#
# WHY THIS EXISTS INSTEAD OF A TREADMARK FOOTPRINT: IIS installs through the
# Windows Feature channel, whose payload is pre-staged in the component store.
# A baseline diff therefore captures ZERO services -- W3SVC and WAS are already
# in the baseline. treadmark says so itself ("absent services are not evidence
# of absence -- complete them from app knowledge and say so") and its IIS smoke
# test asserts only that no NOISE service appears, never that an IIS service
# does. Diffing cannot produce an IIS principal model, so the evidence for an
# IIS access profile is a LIVE READ of the running server instead: same
# discipline (observed, not assumed), different instrument.
#
# Emits JSON on stdout. Read-only: no Set-*, no New-*, nothing mutating.
#
#   ssh Administrator@host 'powershell -NoProfile -' < scripts/iis-inventory.ps1
$ErrorActionPreference = 'Stop'
Import-Module WebAdministration -ErrorAction SilentlyContinue
Import-Module IISAdministration -ErrorAction SilentlyContinue

function Get-AclSummary($path) {
  if (-not (Test-Path $path)) { return $null }
  $acl = Get-Acl -Path $path
  [ordered]@{
    path     = $path
    owner    = $acl.Owner
    # SDDL is the reviewable form; the ACE list is the readable one
    sddl     = $acl.Sddl
    inherits = -not $acl.AreAccessRulesProtected
    aces     = @($acl.Access | ForEach-Object {
      [ordered]@{
        identity    = $_.IdentityReference.Value
        rights      = $_.FileSystemRights.ToString()
        type        = $_.AccessControlType.ToString()
        inherited   = $_.IsInherited
        inheritance = $_.InheritanceFlags.ToString()
      }
    })
  }
}

$sites = @(Get-Website | ForEach-Object {
  $site = $_
  $logDir = [System.Environment]::ExpandEnvironmentVariables($site.logFile.directory)
  [ordered]@{
    name          = $site.Name
    id            = $site.Id
    state         = $site.State
    physical_path = [System.Environment]::ExpandEnvironmentVariables($site.PhysicalPath)
    app_pool      = $site.applicationPool
    bindings      = @($site.Bindings.Collection | ForEach-Object {
      [ordered]@{
        protocol           = $_.protocol
        binding            = $_.bindingInformation
        cert_hash          = if ($_.certificateHash) { ($_.certificateHash | ForEach-Object { $_.ToString('x2') }) -join '' } else { $null }
        cert_store         = $_.certificateStoreName
        sslflags           = $_.sslFlags
      }
    })
    log_directory = $logDir
    log_site_dir  = Join-Path $logDir ("W3SVC" + $site.Id)
    content_acl   = Get-AclSummary ([System.Environment]::ExpandEnvironmentVariables($site.PhysicalPath))
  }
})

$pools = @(Get-ChildItem IIS:\AppPools | ForEach-Object {
  $p = $_
  [ordered]@{
    name              = $p.Name
    state             = $p.State
    identity_type     = $p.processModel.identityType
    # ApplicationPoolIdentity resolves to the virtual account IIS AppPool\<name>
    resolved_identity = if ($p.processModel.identityType -eq 'ApplicationPoolIdentity') { "IIS AppPool\$($p.Name)" } else { $p.processModel.userName }
    runtime_version   = $p.managedRuntimeVersion
    pipeline_mode     = $p.managedPipelineMode
  }
})

$services = @('W3SVC', 'WAS', 'WMSVC') | ForEach-Object {
  $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
  if ($svc) {
    # sdshow is the rollback snapshot for any sdset grant -- capture it as evidence
    $sddl = (& sc.exe sdshow $_ 2>$null | Where-Object { $_ -match '^D:' }) -join ''
    [ordered]@{
      name        = $_
      status      = $svc.Status.ToString()
      start_type  = $svc.StartType.ToString()
      run_as      = (Get-CimInstance Win32_Service -Filter "Name='$_'").StartName
      sddl        = $sddl
    }
  }
}

$wmsvc = [ordered]@{
  feature_installed      = [bool](Get-WindowsFeature -Name Web-Mgmt-Service -ErrorAction SilentlyContinue | Where-Object Installed)
  enable_remote_mgmt     = (Get-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\WebManagement\Server -Name EnableRemoteManagement -ErrorAction SilentlyContinue).EnableRemoteManagement
  requires_windows_creds = (Get-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\WebManagement\Server -Name RequiresWindowsCredentials -ErrorAction SilentlyContinue).RequiresWindowsCredentials
  # who is authorized to connect, per site -- empty means "local admins only",
  # which is the shipped default and precisely the gap a profile closes
  authorized_users       = @(
    $adminConfig = "$env:windir\system32\inetsrv\config\administration.config"
    if (Test-Path $adminConfig) {
      ([xml](Get-Content $adminConfig)).SelectNodes('//authorization/add') | ForEach-Object {
        [ordered]@{ name = $_.name; path = $_.path; is_role = $_.isRole }
      }
    }
  )
}

# Feature delegation: which sections a delegated connection may write.
$delegation = @()
try {
  $delegation = @(& "$env:windir\system32\inetsrv\appcmd.exe" list config -section:system.webServer/@delegation 2>$null)
} catch { }
$delegationState = @(
  Get-IISConfigSection -SectionPath 'system.webServer/defaultDocument' -ErrorAction SilentlyContinue |
    ForEach-Object { [ordered]@{ section = 'system.webServer/defaultDocument'; override_mode = $_.OverrideMode.ToString() } }
)

$certs = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | ForEach-Object {
  [ordered]@{
    thumbprint   = $_.Thumbprint
    subject      = $_.Subject
    not_after    = $_.NotAfter.ToString('o')
    has_private  = $_.HasPrivateKey
    exportable   = try { $_.PrivateKey.CspKeyContainerInfo.Exportable } catch { $null }
  }
})

$localGroups = @(Get-LocalGroup -ErrorAction SilentlyContinue | Where-Object {
  $_.Name -in @('Administrators', 'IIS_IUSRS', 'Event Log Readers', 'Remote Management Users')
} | ForEach-Object {
  [ordered]@{
    name    = $_.Name
    members = @(Get-LocalGroupMember -Group $_.Name -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  }
})

[ordered]@{
  schema        = '1.0-iis-inventory'
  evidence_type = 'live_enumeration'
  evidence_note = 'IIS installs via the Windows Feature channel (pre-staged payload), so a baseline diff captures no services. This is a live read of the running host, not a footprint diff.'
  generated_at  = (Get-Date).ToUniversalTime().ToString('o')
  host          = $env:COMPUTERNAME
  image         = (Get-ItemProperty HKLM:\SOFTWARE\ImageRelease -ErrorAction SilentlyContinue).IMAGE_NAME
  os            = (Get-CimInstance Win32_OperatingSystem).Caption
  sites         = $sites
  app_pools     = $pools
  services      = @($services)
  wmsvc         = $wmsvc
  delegation    = @{ raw = $delegation; sections = $delegationState }
  certificates  = $certs
  local_groups  = $localGroups
  config_acl    = @(
    Get-AclSummary "$env:windir\system32\inetsrv\config\applicationHost.config"
    Get-AclSummary "$env:windir\system32\inetsrv\config"
  )
} | ConvertTo-Json -Depth 8
