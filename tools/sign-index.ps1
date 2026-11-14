#requires -Version 7
<#
.SYNOPSIS
    Signs index.json with an ECDSA P-256 key (index.sig envelope), or verifies an existing signature.

.DESCRIPTION
    Sign mode reads the base64-encoded PEM private key from $env:INDEX_SIGNING_KEY, writes it to an
    owner-only temporary file, signs index.json with openssl (SHA-256, DER output), base64-encodes the
    DER signature and writes the JSON envelope { "algorithm": "ecdsa-p256-sha256", "signature": ...,
    "signedAt": ... } to index.sig (UTF-8 without BOM). The script is idempotent: an unchanged
    signature does not rewrite the envelope, so signedAt does not flap.

    Verify mode (-Verify) checks index.sig against public.pem; an absent index.sig is the transition
    window (warn, exit 0), a mismatch fails.

    The algorithm matches CLIHub's PluginFeedSigner (ECDSA P-256 / SHA-256, RFC 3279 DER).
#>
[CmdletBinding()]
param(
    [switch]$Verify
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$indexPath = Join-Path $root 'index.json'
$signaturePath = Join-Path $root 'index.sig'
$publicKeyPath = Join-Path $root 'public.pem'
$algorithm = 'ecdsa-p256-sha256'

$openssl = $null
$opensslCommand = Get-Command openssl -ErrorAction SilentlyContinue -CommandType Application |
    Select-Object -First 1
if ($opensslCommand) {
    $openssl = $opensslCommand.Source
}
if (-not $openssl) {
    $openssl = @('/usr/bin/openssl', '/usr/local/bin/openssl', 'C:\Program Files\Git\usr\bin\openssl.exe') |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $openssl) {
    throw 'openssl was not found on PATH'
}

if ($Verify) {
    if (-not (Test-Path $signaturePath)) {
        Write-Host 'index.sig is absent (transition window); nothing to verify'
        exit 0
    }
    if (-not (Test-Path $publicKeyPath)) {
        Write-Warning 'public.pem is absent; cannot verify index.sig'
        exit 0
    }
    $envelope = Get-Content $signaturePath -Raw | ConvertFrom-Json
    if ($envelope.algorithm -ne $algorithm) {
        Write-Error "Unsupported signature algorithm '$($envelope.algorithm)'"
        exit 1
    }
    $temporarySignature = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllBytes($temporarySignature, [Convert]::FromBase64String($envelope.signature))
        & $openssl dgst -sha256 -verify $publicKeyPath -signature $temporarySignature $indexPath | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error 'index.sig does not match index.json'
            exit 1
        }
        Write-Host 'index.sig verified'
    }
    finally {
        Remove-Item $temporarySignature -ErrorAction SilentlyContinue
    }
    exit 0
}

$keyBase64 = $env:INDEX_SIGNING_KEY
if ([string]::IsNullOrWhiteSpace($keyBase64)) {
    Write-Warning 'INDEX_SIGNING_KEY is not set; skipping signing (transition window)'
    exit 0
}

$temporaryKey = Join-Path ([System.IO.Path]::GetTempPath()) ("clihub-signing-{0}.pem" -f [guid]::NewGuid().ToString('N'))
$temporarySignature = "$temporaryKey.sig"
try {
    [System.IO.File]::WriteAllBytes($temporaryKey, [Convert]::FromBase64String($keyBase64))
    if (-not $IsWindows) {
        & chmod 600 $temporaryKey
    }
    & $openssl dgst -sha256 -sign $temporaryKey -out $temporarySignature $indexPath
    if ($LASTEXITCODE -ne 0) {
        throw 'openssl signing failed'
    }
    $signature = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($temporarySignature))

    # Idempotence: an unchanged signature keeps the existing envelope (signedAt does not flap).
    if (Test-Path $signaturePath) {
        try {
            $existing = Get-Content $signaturePath -Raw | ConvertFrom-Json
            if ($existing.algorithm -eq $algorithm -and $existing.signature -eq $signature) {
                Write-Host 'index.sig unchanged'
                exit 0
            }
        }
        catch {
            Write-Host 'Existing index.sig is unreadable; regenerating'
        }
    }

    $envelope = [ordered]@{
        algorithm = $algorithm
        signature = $signature
        signedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    [System.IO.File]::WriteAllText($signaturePath, (ConvertTo-Json $envelope), [System.Text.UTF8Encoding]::new($false))
    Write-Host "index.sig written ($algorithm)"
}
finally {
    Remove-Item $temporaryKey, $temporarySignature -ErrorAction SilentlyContinue
}
