<#
.SYNOPSIS
    Exports AppDynamics application configuration and custom dashboards from one
    controller to a folder, and imports that folder into another controller.

.DESCRIPTION
    Uses the AppDynamics Configuration Import and Export REST API.

    Export mode writes these files to -Folder:
        application-backup.xml            Full application config (backup only, never imported)
        transaction-detection-custom.xml  Custom business transaction detection rules
        health-rules.xml                  Health rules
        actions.json                      Actions
        policies.json                     Policies
        dashboards\dashboard-<id>.json    Custom dashboards listed in -DashboardIds

    Import mode uploads the same files to the target application in this order:
    transaction detection, health rules, actions, policies, dashboards.
    Policies refer to health rules and actions by name, so those go first.

    The password is asked for at run time and is never written to disk.

.EXAMPLE
    .\Copy-AppDConfig.ps1 -Mode Export -ControllerUrl https://pobal-ncs-dev.saas.appdynamics.com `
        -Account pobal-ncs-dev -Application "NCS-PREPROD" -DashboardIds 101,102 -Folder .\ncs-export

.EXAMPLE
    .\Copy-AppDConfig.ps1 -Mode Import -ControllerUrl https://pobal-ncs.saas.appdynamics.com `
        -Account pobal-ncs -Application "NCS-PROD" -Folder .\ncs-export `
        -Replace @{ 'NCS-PREPROD' = 'NCS-PROD' }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Export', 'Import')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$ControllerUrl,

    [Parameter(Mandatory = $true)]
    [string]$Account,

    [string]$Application,

    [string]$Folder = '.\appd-config-export',

    [int[]]$DashboardIds = @(),

    [ValidateSet('TransactionDetection', 'HealthRules', 'Actions', 'Policies', 'Dashboards', 'AppBackup')]
    [string[]]$Include = @('TransactionDetection', 'HealthRules', 'Actions', 'Policies', 'Dashboards', 'AppBackup'),

    # Replace existing health rules and transaction detection rules with the same name.
    [switch]$Overwrite,

    # Literal, case-sensitive text replacements applied to every file before import,
    # for example application or tier names that differ between non-prod and prod.
    [hashtable]$Replace = @{},

    [System.Management.Automation.PSCredential]$Credential,

    # Skip the "type YES" confirmation before importing.
    [switch]$Force
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if ($ControllerUrl -notmatch '^https://') {
    throw "ControllerUrl must start with https:// (got '$ControllerUrl')."
}
$appScoped = @('TransactionDetection', 'HealthRules', 'Actions', 'Policies', 'AppBackup')
if (-not $Application -and @($Include | Where-Object { $appScoped -contains $_ }).Count -gt 0) {
    throw "-Application is required unless -Include is only 'Dashboards'."
}

Add-Type -AssemblyName System.Net.Http

# Windows 10 Schannel has no TLS 1.3, so only request it where the OS supports it.
$tls = [Net.SecurityProtocolType]::Tls12
if ([Environment]::OSVersion.Version.Build -ge 20348) {
    try { $tls = $tls -bor [Net.SecurityProtocolType]::Tls13 } catch { }
}
[Net.ServicePointManager]::SecurityProtocol = $tls

if (-not $Credential) {
    $Credential = Get-Credential -Message "Local AppDynamics user for $ControllerUrl (user name only, without @$Account)"
}
if (-not $Credential) { throw 'No credentials entered.' }
$basicPair = '{0}@{1}:{2}' -f $Credential.UserName, $Account, $Credential.GetNetworkCredential().Password
$basicAuth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($basicPair))
$basicPair = $null

$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.Proxy = [Net.WebRequest]::GetSystemWebProxy()
$handler.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromMinutes(5)
$client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Basic', $basicAuth)

$base = $ControllerUrl.TrimEnd('/')
if ($base -notmatch '/controller$') { $base = "$base/controller" }

$folderPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Folder)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$results = New-Object System.Collections.Generic.List[object]

function Invoke-AppDGet([string]$Path) {
    $resp = $client.GetAsync("$base$Path").GetAwaiter().GetResult()
    $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) {
        throw "GET $Path returned HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase). $body"
    }
    return $body
}

function Invoke-AppDUpload([string]$Path, [string]$FileName, [string]$Content) {
    $form = [System.Net.Http.MultipartFormDataContent]::new()
    $file = [System.Net.Http.ByteArrayContent]::new($utf8.GetBytes($Content))
    $file.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
    $form.Add($file, 'file', $FileName)
    $resp = $client.PostAsync("$base$Path", $form).GetAwaiter().GetResult()
    $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) {
        throw "POST $Path returned HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase). $body"
    }
    return $body
}

function Add-Result([string]$Item, [string]$Status, [string]$Detail) {
    $results.Add([pscustomobject]@{ Item = $Item; Status = $Status; Detail = $Detail })
    $color = if ($Status -eq 'OK') { 'Green' } elseif ($Status -eq 'SKIPPED') { 'Yellow' } else { 'Red' }
    Write-Host ("  [{0}] {1} {2}" -f $Status, $Item, $Detail) -ForegroundColor $color
}

function Get-AppDApplicationId([string]$Name) {
    $apps = Invoke-AppDGet '/rest/applications?output=JSON' | ConvertFrom-Json
    $match = @($apps | Where-Object { $_.name -eq $Name })
    if ($match.Count -eq 0) {
        throw "Application '$Name' not found on $base. Applications found: $(($apps | ForEach-Object { $_.name }) -join ', ')"
    }
    return $match[0].id
}

function Save-Text([string]$RelativePath, [string]$Content) {
    $full = Join-Path $folderPath $RelativePath
    $dir = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($full, $Content, $utf8)
    return $full
}

function Read-ForImport([string]$RelativePath) {
    $full = Join-Path $folderPath $RelativePath
    if (-not (Test-Path $full)) { return $null }
    $text = [IO.File]::ReadAllText($full, $utf8)
    foreach ($key in $Replace.Keys) { $text = $text.Replace([string]$key, [string]$Replace[$key]) }
    return $text
}

Write-Host "Controller : $base (account $Account, user $($Credential.UserName))"
Write-Host "Mode       : $Mode"
Write-Host "Folder     : $folderPath"

$appId = $null
$appPath = $null
if ($Application) {
    $appId = Get-AppDApplicationId $Application
    $appPath = [Uri]::EscapeDataString($Application)
    Write-Host "Application: $Application (id $appId)"
}
Write-Host ''

if ($Mode -eq 'Export') {
    $steps = @(
        @{ Name = 'AppBackup';            File = 'application-backup.xml';           Path = "/ConfigObjectImportExportServlet?applicationId=${appId}" },
        @{ Name = 'TransactionDetection'; File = 'transaction-detection-custom.xml'; Path = "/transactiondetection/$appPath/custom" },
        @{ Name = 'HealthRules';          File = 'health-rules.xml';                 Path = "/healthrules/$appId" },
        @{ Name = 'Actions';              File = 'actions.json';                     Path = "/actions/$appId" },
        @{ Name = 'Policies';             File = 'policies.json';                    Path = "/policies/$appId" }
    )
    foreach ($step in $steps) {
        if ($Include -notcontains $step.Name) { continue }
        try {
            $body = Invoke-AppDGet $step.Path
            $saved = Save-Text $step.File $body
            Add-Result $step.Name 'OK' "-> $saved ($($body.Length) chars)"
        } catch {
            Add-Result $step.Name 'FAILED' $_.Exception.Message
        }
    }

    if ($Include -contains 'Dashboards') {
        if ($DashboardIds.Count -eq 0) {
            Add-Result 'Dashboards' 'SKIPPED' 'no -DashboardIds given'
        }
        foreach ($id in $DashboardIds) {
            try {
                $body = Invoke-AppDGet "/CustomDashboardImportExportServlet?dashboardId=${id}"
                $saved = Save-Text "dashboards\dashboard-$id.json" $body
                Add-Result "Dashboard $id" 'OK' "-> $saved"
            } catch {
                Add-Result "Dashboard $id" 'FAILED' $_.Exception.Message
            }
        }
    }

    $manifest = @(
        "Exported : $(Get-Date -Format s)"
        "Source   : $base"
        "Account  : $Account"
        "App      : $Application (id $appId)"
        "User     : $($Credential.UserName)"
    ) -join "`r`n"
    Save-Text 'export-info.txt' $manifest | Out-Null
}
else {
    if (-not (Test-Path $folderPath)) { throw "Folder '$folderPath' does not exist. Run the export first." }

    if (-not $Force) {
        Write-Host "This will WRITE configuration into $base, application '$Application'." -ForegroundColor Yellow
        if ($Replace.Count -gt 0) {
            Write-Host 'Text replacements applied before upload:' -ForegroundColor Yellow
            foreach ($key in $Replace.Keys) { Write-Host "    '$key' -> '$($Replace[$key])'" -ForegroundColor Yellow }
        }
        $answer = Read-Host 'Type YES to continue'
        if ($answer -cne 'YES') { Write-Host 'Cancelled.'; exit 1 }
    }

    $ow = if ($Overwrite) { 'true' } else { 'false' }
    $steps = @(
        @{ Name = 'TransactionDetection'; File = 'transaction-detection-custom.xml'; Path = "/transactiondetection/${appPath}/custom?overwrite=${ow}" },
        @{ Name = 'HealthRules';          File = 'health-rules.xml';                 Path = "/healthrules/${appId}?overwrite=${ow}" },
        @{ Name = 'Actions';              File = 'actions.json';                     Path = "/actions/$appId" },
        @{ Name = 'Policies';             File = 'policies.json';                    Path = "/policies/$appId" }
    )
    foreach ($step in $steps) {
        if ($Include -notcontains $step.Name) { continue }
        $content = Read-ForImport $step.File
        if ($null -eq $content) { Add-Result $step.Name 'SKIPPED' "$($step.File) not found"; continue }
        try {
            $body = Invoke-AppDUpload $step.Path $step.File $content
            Add-Result $step.Name 'OK' $body.Trim()
        } catch {
            Add-Result $step.Name 'FAILED' $_.Exception.Message
        }
    }

    if ($Include -contains 'Dashboards') {
        $dashDir = Join-Path $folderPath 'dashboards'
        $files = @()
        if (Test-Path $dashDir) { $files = @(Get-ChildItem -Path $dashDir -Filter '*.json' | Sort-Object Name) }
        if ($files.Count -eq 0) { Add-Result 'Dashboards' 'SKIPPED' 'no files in dashboards\' }
        foreach ($f in $files) {
            try {
                $content = Read-ForImport "dashboards\$($f.Name)"
                $body = Invoke-AppDUpload '/CustomDashboardImportExportServlet' $f.Name $content
                Add-Result "Dashboard $($f.Name)" 'OK' $body.Trim()
            } catch {
                Add-Result "Dashboard $($f.Name)" 'FAILED' $_.Exception.Message
            }
        }
    }
}

$client.Dispose()
Write-Host ''
$failed = @($results | Where-Object { $_.Status -eq 'FAILED' }).Count
Write-Host ("Done: {0} OK, {1} skipped, {2} failed." -f `
    @($results | Where-Object { $_.Status -eq 'OK' }).Count,
    @($results | Where-Object { $_.Status -eq 'SKIPPED' }).Count,
    $failed)
if ($failed -gt 0) { exit 2 }
