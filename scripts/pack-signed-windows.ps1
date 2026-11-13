#Requires -Version 7.0

<#
.SYNOPSIS
    Checks the signatures that build.yml's signing job put on caddy.exe and
    Update-Caddy.ps1, and packs the files into the release zip again.

.DESCRIPTION
    -Folder holds the unpacked Windows zip after signing: caddy.exe, LICENSE,
    Update-Caddy.ps1 and Update-Caddy.cmd, nothing else. caddy.exe and Update-Caddy.ps1
    must carry a valid, timestamped signature from one and the same Azure Artifact Signing
    certificate profile. The zip goes to -Destination under the name -ZipName.

    Prints the profile's EKU (1.3.6.1.4.1.311.97.<numbers>), the value
    windows/Update-Caddy.ps1 pins in -SignerEku, and adds it to the job summary.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Folder,

    [Parameter(Mandatory)]
    [ValidatePattern('^caddy_\d+\.\d+\.\d+-\d+_windows_amd64\.zip$')]
    [string] $ZipName,

    [Parameter(Mandatory)]
    [string] $Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$publicTrustEku = '1.3.6.1.4.1.311.97.1.0'
$profilePrefix = '1.3.6.1.4.1.311.97.'
$expected = @('caddy.exe', 'LICENSE', 'Update-Caddy.cmd', 'Update-Caddy.ps1')

# The profile EKU of a file with a valid, timestamped Artifact Signing (Public Trust) signature
function Get-SignatureProfile([string] $Path)
{
    $name = Split-Path -Leaf $Path
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid)
    {
        throw "FAIL: ${name}: $($signature.Status), $($signature.StatusMessage)"
    }
    if ($null -eq $signature.TimeStamperCertificate)
    {
        throw "FAIL: the signature of $name has no timestamp"
    }
    $ekus = @($signature.SignerCertificate.Extensions |
            Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
            ForEach-Object { $_.EnhancedKeyUsages } |
            ForEach-Object { [string]$_.Value })
    $profiles = @($ekus | Where-Object { $_.StartsWith($profilePrefix, [StringComparison]::Ordinal) -and $_ -cne $publicTrustEku })
    if ($ekus -cnotcontains $publicTrustEku -or $profiles.Count -ne 1)
    {
        throw "FAIL: $name is not signed by one Artifact Signing (Public Trust) profile; its EKUs: $($ekus -join ', ')"
    }
    Write-Host "${name}: signed by $($signature.SignerCertificate.Subject), profile $($profiles[0])"
    return $profiles[0]
}

$names = @(Get-ChildItem -LiteralPath $Folder -Recurse -File | ForEach-Object Name | Sort-Object)
if (($names -join ' ') -cne ($expected -join ' '))
{
    throw "FAIL: $Folder holds $($names -join ', '), expected $($expected -join ', ')"
}

$exeProfile = Get-SignatureProfile (Join-Path $Folder 'caddy.exe')
$scriptProfile = Get-SignatureProfile (Join-Path $Folder 'Update-Caddy.ps1')
if ($exeProfile -cne $scriptProfile)
{
    throw "FAIL: caddy.exe ($exeProfile) and Update-Caddy.ps1 ($scriptProfile) are signed by different profiles"
}

if (-not (Test-Path -LiteralPath $Destination))
{
    $null = New-Item -ItemType Directory -Path $Destination
}
$zip = Join-Path $Destination $ZipName
if (Test-Path -LiteralPath $zip)
{
    throw "FAIL: $zip exists already"
}
Compress-Archive -LiteralPath @($expected | ForEach-Object { Join-Path $Folder $_ }) -DestinationPath $zip -CompressionLevel Optimal
Write-Host "packed $zip"
Write-Host "Artifact Signing profile (Update-Caddy.ps1 -SignerEku): $exeProfile"
if ($env:GITHUB_STEP_SUMMARY)
{
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8NoBOM -Value "Signed with the Artifact Signing profile ``$exeProfile`` (``Update-Caddy.ps1 -SignerEku``)."
}
