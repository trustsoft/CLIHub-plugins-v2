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
#>
[CmdletBinding()]
param(
    [string]$RepoOwner = 'trustsoft',
    [string]$RepoName = 'CLIHub-plugins-v2',
    [string]$Branch = 'master'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

    if ($d.id -cne $id) {
        $errors.Add("$id/: descriptor id '$($d.id)' does not match the folder name")
    }
    foreach ($field in 'id', 'name', 'description', 'version', 'publisher', 'homepage') {
        if (-not $d.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace($d.$field)) {
            $errors.Add("$id/: missing required field '$field'")
        }
    }
    if ($d.version -notmatch '^\d+\.\d+\.\d+$') {
        $errors.Add("$id/: version '$($d.version)' is not major.minor.patch")
    }
    if (-not $d.commands -or -not $d.commands.launch -or -not $d.commands.launch.executable) {
        $errors.Add("$id/: commands.launch.executable is required")
    }
    foreach ($cmd in 'resume', 'version', 'update') {
        if ($d.commands.PSObject.Properties[$cmd] -and $d.commands.$cmd -and -not $d.commands.$cmd.executable) {
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
        if ($f.compatibility) { $compatibility = $f.compatibility }
        if ($f.channel) { $channel = $f.channel }
        $releaseNotesUrl = $f.releaseNotesUrl
        if ($f.package) {
            $package = $f.package
            if (-not $package.url -or $package.url -notlike 'https://*') {
                $errors.Add("$id/: package.url must be an https URL")
            }
            if (-not $package.sha256 -or $package.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
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
        name = $d.name
        description = $d.description
        version = $d.version
        compatibility = $compatibility
        channel = $channel
        publisher = $d.publisher
        homepage = $d.homepage
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
