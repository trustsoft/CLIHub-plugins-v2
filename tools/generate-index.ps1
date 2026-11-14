#requires -Version 7
<#
.SYNOPSIS
    Validates every plugins/<id>/ descriptor folder and generates index.json (schemaVersion 2).

.DESCRIPTION
    This is the only index authoring path (ADR-0015 in the CLIHub repository): per-plugin folders
    are the source of truth, index.json is generated. The script is idempotent — it rewrites
    index.json only when the plugin set actually changes, so lastUpdated does not flap.

.NOTES
    Validation rules per folder:
      - plugin.json is valid JSON with required, non-empty fields:
        id, name, description, version, publisher, homepage.
      - descriptor id matches the folder name.
      - version is major.minor.patch.
      - commands.launch.executable is required; resume/version/update need executable when present.
      - feed.json (optional overlay): compatibility, channel (only "stable" today),
        releaseNotesUrl, and an optional package (zip) with an https URL and a 64-hex sha256.
      - compatibility is a comma-separated list of ">=|<=|>|<|= major.minor.patch" constraints.
      - A folder with any validation error is reported and skipped; any error fails the run.
#>
[CmdletBinding()]
param(
    [string]$RepoOwner = 'trustsoft',
    [string]$RepoName = 'CLIHub-plugins-v2',
    [string]$Branch = 'master'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Strict-mode-safe property read: returns $null when the property is absent.
function Get-Prop($Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}

$root = Split-Path -Parent $PSScriptRoot
$pluginsDir = Join-Path $root 'plugins'
$indexPath = Join-Path $root 'index.json'
$errors = [System.Collections.Generic.List[string]]::new()
$entries = [System.Collections.Generic.List[object]]::new()

foreach ($folder in (Get-ChildItem $pluginsDir -Directory | Sort-Object Name)) {
    $id = $folder.Name
    $descriptorPath = Join-Path $folder.FullName 'plugin.json'
    if (-not (Test-Path $descriptorPath)) {
        $errors.Add("$id/: missing plugin.json")
        continue
    }

    try {
        $d = Get-Content $descriptorPath -Raw | ConvertFrom-Json
    }
    catch {
        $errors.Add("$id/: plugin.json is not valid JSON ($($_.Exception.Message))")
        continue
    }

    $descriptorId = Get-Prop $d 'id'
    $name = Get-Prop $d 'name'
    $description = Get-Prop $d 'description'
    $version = Get-Prop $d 'version'
    $publisher = Get-Prop $d 'publisher'
    $homepage = Get-Prop $d 'homepage'

    $hardFail = $false
    if ([string]::IsNullOrWhiteSpace($descriptorId)) { $errors.Add("$id/: missing required field 'id'"); $hardFail = $true }
    elseif ($descriptorId -cne $id) { $errors.Add("$id/: descriptor id '$descriptorId' does not match the folder name"); $hardFail = $true }
    foreach ($pair in @(@('name', $name), @('description', $description), @('publisher', $publisher), @('homepage', $homepage))) {
        if ([string]::IsNullOrWhiteSpace($pair[1])) { $errors.Add("$id/: missing required field '$($pair[0])'"); $hardFail = $true }
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        $errors.Add("$id/: missing required field 'version'")
        $hardFail = $true
    } elseif ($version -notmatch '^\d+\.\d+\.\d+$') {
        $errors.Add("$id/: version '$version' is not major.minor.patch")
        $hardFail = $true
    }
    if ($hardFail) { continue }

    $commands = Get-Prop $d 'commands'
    $launch = if ($commands) { Get-Prop $commands 'launch' } else { $null }
    if (-not $launch -or -not (Get-Prop $launch 'executable')) {
        $errors.Add("$id/: commands.launch.executable is required")
        continue
    }
    foreach ($cmd in 'resume', 'version', 'update') {
        $cmdObject = if ($commands) { Get-Prop $commands $cmd } else { $null }
        if ($cmdObject -and -not (Get-Prop $cmdObject 'executable')) {
            $errors.Add("$id/: commands.$cmd.executable is required")
        }
    }

    # feed.json is the feed-metadata overlay: compatibility, channel, releaseNotesUrl, package.
    $compatibility = '>=1.0.0'
    $channel = 'stable'
    $releaseNotesUrl = $null
    $package = $null
    $feedPath = Join-Path $folder.FullName 'feed.json'
    if (Test-Path $feedPath) {
        try {
            $f = Get-Content $feedPath -Raw | ConvertFrom-Json
        }
        catch {
            $errors.Add("$id/: feed.json is not valid JSON ($($_.Exception.Message))")
            continue
        }
        $feedCompatibility = Get-Prop $f 'compatibility'
        if ($feedCompatibility) { $compatibility = $feedCompatibility }
        $feedChannel = Get-Prop $f 'channel'
        if ($feedChannel) { $channel = $feedChannel }
        $releaseNotesUrl = Get-Prop $f 'releaseNotesUrl'
        $feedPackage = Get-Prop $f 'package'
        if ($feedPackage) {
            $package = $feedPackage
            $packageUrl = Get-Prop $package 'url'
            $packageSha256 = Get-Prop $package 'sha256'
            if (-not $packageUrl -or $packageUrl -notlike 'https://*') {
                $errors.Add("$id/: package.url must be an https URL")
            }
            if (-not $packageSha256 -or $packageSha256 -notmatch '^[0-9a-fA-F]{64}$') {
                $errors.Add("$id/: package.sha256 must be 64 hex characters")
            }
        }
    }
    if ($channel -ne 'stable') {
        $errors.Add("$id/: unsupported channel '$channel'")
    }
    foreach ($part in ($compatibility -split ',')) {
        if ($part.Trim() -notmatch '^(>=|<=|>|<|=)?\d+\.\d+\.\d+$') {
            $errors.Add("$id/: bad compatibility constraint '$($part.Trim())'")
        }
    }

    $logoUrl = if (Test-Path (Join-Path $folder.FullName 'logo.png')) {
        "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/plugins/$id/logo.png"
    } else {
        $null
    }

    $entries.Add([ordered]@{
        id = $id
        name = $name
        description = $description
        version = $version
        compatibility = $compatibility
        channel = $channel
        publisher = $publisher
        homepage = $homepage
        descriptor = $d
        package = $package
        logoUrl = $logoUrl
        releaseNotesUrl = $releaseNotesUrl
        signature = $null
    })
}

if ($errors.Count -gt 0) {
    foreach ($e in $errors) {
        Write-Error "INVALID: $e"
    }
    exit 1
}

# Idempotency: rewrite only when the plugin set changed, so lastUpdated does not flap.
$newPluginsJson = ConvertTo-Json $entries -Depth 12
if (Test-Path $indexPath) {
    try {
        $existing = Get-Content $indexPath -Raw | ConvertFrom-Json
        if ((ConvertTo-Json $existing.plugins -Depth 12) -eq $newPluginsJson) {
            Write-Host "index.json unchanged ($($entries.Count) plugin(s))"
            exit 0
        }
    }
    catch {
        Write-Host 'Existing index.json is unreadable; regenerating'
    }
}

$index = [ordered]@{
    schemaVersion = 2
    lastUpdated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    plugins = $entries
}
Set-Content -Path $indexPath -Value (ConvertTo-Json $index -Depth 12) -Encoding utf8
Write-Host "index.json generated: $($entries.Count) plugin(s)"
