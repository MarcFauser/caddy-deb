#Requires -Version 7.0

<#
.SYNOPSIS
    Installs the newest Windows build of caddy-deb (Caddy with plugins) into a folder and
    restarts the Windows service that runs Caddy from there.

.DESCRIPTION
    Asks GitHub for the newest release of the repository, and if its caddy.exe is newer than
    the installed one: downloads the zip, checks it against the SHA-256 digest GitHub records,
    stops the service, swaps caddy.exe (the old one stays as caddy.exe.previous), starts the
    service again and checks that it runs. If it does not, the previous caddy.exe goes back
    and the service is started with it.

    The installed version is read from caddy.exe itself (its file version, 2.11.9.16 for the
    package 2.11.9-16); there is no state file. A caddy.exe from elsewhere (Caddy's own
    download, "caddy upgrade") has a lower or no file version and is replaced by the next
    release.

    The new caddy.exe must also carry a valid, timestamped Authenticode signature from the
    Azure Artifact Signing certificate profile that signs this repository's builds
    (-SignerEku), checked before it is run or installed; otherwise the script refuses and
    says why. The SHA-256 digest only shows that the zip is the file in the release; the
    signature shows who signed it. -SkipSignatureCheck installs without that check.

    Like apt's try-restart: a service that was stopped stays stopped. Without a service of
    that name the script only puts caddy.exe into the folder (first installation). It
    refuses to touch a service that runs a different caddy.exe, and a caddy.exe from this
    folder that runs outside the service.

    Every run appends to update-caddy.log in the folder (timestamps in UTC). Exit code 0:
    installed or already current; 1: nothing changed or rolled back, see the log.

.PARAMETER InstallDir
    The folder with caddy.exe. Default: the folder of this script.

.PARAMETER ServiceName
    The Windows service that runs caddy.exe from InstallDir. Default: caddy.

.PARAMETER Repository
    GitHub repository (owner/name) whose newest release is installed.

.PARAMETER ZipPath
    Install this zip instead of the newest release (tests, servers without internet). Its
    name must be caddy_<version>_windows_amd64.zip as in the releases.

.PARAMETER ZipSha256
    With -ZipPath: the SHA-256 the zip must have.

.PARAMETER HealthUrl
    After the start, this URL must answer (any HTTP status), for example the admin endpoint
    http://localhost:2019/config/ if the configuration keeps it. Otherwise only the service
    state is checked.

.PARAMETER SignerEku
    The Azure Artifact Signing certificate profile whose signature the new caddy.exe must
    carry, as the profile's durable identity: an EKU 1.3.6.1.4.1.311.97.<numbers>. Artifact
    Signing renews its certificates daily and each is valid for 72 hours, so a thumbprint
    cannot be pinned; every certificate of one profile carries that profile's EKU. The
    signature must be valid for Windows, timestamped, carry the Public Trust EKU
    1.3.6.1.4.1.311.97.1.0 and lead to Microsoft's Identity Verification Root Certificate
    Authority 2020. Default: the profile fauser-public of FAUSER AG, which signs this
    repository's builds. If the signing profile changes, run once with the new profile's EKU
    (the refusal names it) and then use the Update-Caddy.ps1 of the new zip.

.PARAMETER SkipSignatureCheck
    Install caddy.exe without checking its signature, for example if the builds are no longer
    signed. The zip is still checked against its SHA-256 digest.

.PARAMETER StartTimeoutSeconds
    How long the service may take to report "running" after the start.

.PARAMETER Force
    Install even if the installed caddy.exe is not older.

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File C:\caddy\Update-Caddy.ps1
#>
# Part of caddy-deb @PACKAGING_VERSION@ (https://github.com/MarcFauser/caddy-deb). Tested
# with PowerShell 7.6 on Windows Server 2025.
[CmdletBinding()]
param(
    [string] $InstallDir = $PSScriptRoot,

    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string] $ServiceName = 'caddy',

    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository = 'MarcFauser/caddy-deb',

    [string] $ZipPath,

    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string] $ZipSha256,

    [string] $HealthUrl,

    # The Artifact Signing profile fauser-public, read from the signatures of build #22
    # (2026-11-13); README, "Code signing".
    [ValidatePattern('^1\.3\.6\.1\.4\.1\.311\.97\.\d+(\.\d+)+$')]
    [string] $SignerEku = '1.3.6.1.4.1.311.97.148201039.430108475.907146009.557048314',

    [switch] $SkipSignatureCheck,

    [ValidateRange(5, 600)]
    [int] $StartTimeoutSeconds = 60,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$zipNamePattern = '^caddy_(\d+\.\d+\.\d+-\d+)_windows_amd64\.zip$'

# Azure Artifact Signing: every Public Trust certificate carries the EKU 1.3.6.1.4.1.311.97.1.0
# besides code signing and its profile's EKU (Microsoft, "Artifact Signing certificate
# management"); the chain ends in Microsoft Identity Verification Root Certificate Authority
# 2020 (read from Artifact Signing signatures, 2026-11-13).
$codeSigningEku = '1.3.6.1.5.5.7.3.3'
$publicTrustEku = '1.3.6.1.4.1.311.97.1.0'
$identityRootThumbprint = 'F40042E2E5F7E8EF8189FED15519AECE42C3BFA2'

if (-not (Test-Path -LiteralPath $InstallDir -PathType Container))
{
    $null = New-Item -ItemType Directory -Path $InstallDir
}
$folder = (Resolve-Path -LiteralPath $InstallDir).ProviderPath
$exeFile = Join-Path $folder 'caddy.exe'
$previousFile = Join-Path $folder 'caddy.exe.previous'
$logFile = Join-Path $folder 'update-caddy.log'
$workFolder = Join-Path $folder '.caddy-update'

function Write-UpdateLog([string] $Message)
{
    $stamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH':'mm':'ss'Z'", $invariant)
    $line = "$stamp $Message"
    Write-Host $line
    Add-Content -LiteralPath $logFile -Value $line -Encoding utf8NoBOM
}

# "2.11.9-16" -> 2.11.9.16, or $null if it is not a package version of this repository
function ConvertTo-FileVersion([string] $PackageVersion)
{
    $m = [regex]::Match($PackageVersion, '^(\d+)\.(\d+)\.(\d+)-(\d+)$')
    if (-not $m.Success)
    {
        return $null
    }
    return [version]::new([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value, [int]$m.Groups[4].Value)
}

# The file version of a caddy.exe; 0.0.0.0 if it has none (or no version resource at all)
function Get-ExeVersion([string] $Path)
{
    $info = (Get-Item -LiteralPath $Path).VersionInfo
    return [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
}

function Get-ExeVersionText([string] $Path)
{
    $text = (Get-Item -LiteralPath $Path).VersionInfo.FileVersion
    if ([string]::IsNullOrWhiteSpace($text))
    {
        return 'without version information'
    }
    return $text
}

# The release to install: package version, zip name, where it comes from, expected SHA-256
function Get-Target
{
    if ($ZipPath)
    {
        $zipItem = Get-Item -LiteralPath $ZipPath
        $m = [regex]::Match($zipItem.Name, $zipNamePattern)
        if (-not $m.Success)
        {
            throw "$($zipItem.Name) is not named like a release zip (caddy_<version>_windows_amd64.zip)"
        }
        $sha = $null
        if ($ZipSha256)
        {
            $sha = $ZipSha256.ToLowerInvariant()
        }
        return [pscustomobject]@{ Version = $m.Groups[1].Value; Name = $zipItem.Name; Source = $zipItem.FullName; Sha256 = $sha; Local = $true }
    }

    $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($env:GITHUB_TOKEN)
    {
        $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
    }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers
    $tag = [string]$release.tag_name
    $assets = @($release.assets | Where-Object { [regex]::IsMatch([string]$_.name, $zipNamePattern) })
    if ($assets.Count -ne 1)
    {
        throw "release $tag of $Repository has $($assets.Count) Windows zips, expected 1"
    }
    $asset = $assets[0]
    $version = [regex]::Match([string]$asset.name, $zipNamePattern).Groups[1].Value
    if ($tag -cne "v$version")
    {
        throw "release $tag holds $($asset.name), which belongs to v$version"
    }
    # GitHub records a SHA-256 digest for every release asset; without it nothing is checked
    $digestProperty = $asset.PSObject.Properties['digest']
    $digest = if ($null -ne $digestProperty) { [string]$digestProperty.Value } else { '' }
    $dm = [regex]::Match($digest, '^sha256:([0-9a-f]{64})$')
    if (-not $dm.Success)
    {
        throw "GitHub records no SHA-256 digest for $($asset.name) ('$digest')"
    }
    return [pscustomobject]@{ Version = $version; Name = [string]$asset.name; Source = [string]$asset.browser_download_url; Sha256 = $dm.Groups[1].Value; Local = $false }
}

# Throws unless the file carries a valid, timestamped signature from the Artifact Signing
# profile $SignerEku. Windows decides whether the signature is valid and trusted
# (WinVerifyTrust, behind Get-AuthenticodeSignature); this adds which profile and which root.
function Assert-Signature([string] $Path)
{
    $name = Split-Path -Leaf $Path
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    # The advice in each refusal names a way past it only where passing may be right: never
    # for a file that was changed after it was signed.
    switch ($signature.Status)
    {
        ([System.Management.Automation.SignatureStatus]::Valid)
        {
            break
        }
        ([System.Management.Automation.SignatureStatus]::NotSigned)
        {
            throw "$name is not signed. If this repository's builds are no longer signed on purpose (README, `"Code signing`"), run once with -SkipSignatureCheck."
        }
        ([System.Management.Automation.SignatureStatus]::HashMismatch)
        {
            throw "$name was changed after it was signed (HashMismatch); do not install it."
        }
        default
        {
            throw "$name has no valid signature ($($signature.Status): $($signature.StatusMessage))"
        }
    }
    # The certificate is valid for 72 hours; only a timestamp keeps the signature valid after that.
    if ($null -eq $signature.TimeStamperCertificate)
    {
        throw "the signature of $name has no timestamp"
    }
    $certificate = $signature.SignerCertificate
    $ekus = @($certificate.Extensions |
            Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
            ForEach-Object { $_.EnhancedKeyUsages } |
            ForEach-Object { [string]$_.Value })
    if ($ekus -cnotcontains $codeSigningEku -or $ekus -cnotcontains $publicTrustEku -or $ekus -cnotcontains $SignerEku)
    {
        $message = "the signature of $name is from '$($certificate.Subject)' with the EKUs $($ekus -join ', '), not from the Artifact Signing profile $SignerEku that this script trusts."
        $profiles = @($ekus | Where-Object { $_.StartsWith('1.3.6.1.4.1.311.97.', [StringComparison]::Ordinal) -and $_ -cne $publicTrustEku })
        if ($ekus -ccontains $codeSigningEku -and $ekus -ccontains $publicTrustEku -and $profiles.Count -eq 1)
        {
            $message += " If the signing profile was changed on purpose (README, `"Code signing`"), run once with -SignerEku $($profiles[0]) and then use the Update-Caddy.ps1 of the new zip."
        }
        throw $message
    }
    # The chain from the certificates in the signature itself, so that it does not depend on
    # what this machine has cached. The signing certificate has expired after 72 hours.
    $embedded = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $embedded.Import($Path)
    $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
    try
    {
        $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid
        $chain.ChainPolicy.ExtraStore.AddRange($embedded)
        $null = $chain.Build($certificate)
        $root = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
        if ($root.Thumbprint -cne $identityRootThumbprint)
        {
            throw "the signature of $name leads to '$($root.Subject)' ($($root.Thumbprint)), not to Microsoft Identity Verification Root Certificate Authority 2020"
        }
    }
    finally
    {
        $chain.Dispose()
    }
    Write-UpdateLog "$name is signed by $($certificate.Subject) (Artifact Signing profile $SignerEku)"
}

# The service if it exists; it must run caddy.exe from this folder
function Get-CaddyService
{
    $found = @(Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'")
    if ($found.Count -eq 0)
    {
        return $null
    }
    $pathName = [string]$found[0].PathName
    $pm = [regex]::Match($pathName, '^\s*"([^"]+)"')
    if (-not $pm.Success)
    {
        $pm = [regex]::Match($pathName, '^\s*(\S+?\.exe)(\s|$)', 'IgnoreCase')
    }
    if (-not $pm.Success)
    {
        throw "cannot read the program of service $ServiceName from '$pathName'"
    }
    $serviceExe = [System.IO.Path]::GetFullPath($pm.Groups[1].Value)
    if (-not [string]::Equals($serviceExe, $exeFile, [StringComparison]::OrdinalIgnoreCase))
    {
        throw "service $ServiceName runs $serviceExe, not $exeFile; refusing to touch it"
    }
    return $found[0]
}

function Test-Administrator
{
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Wait-ProcessExit([uint32] $ProcessId, [int] $Seconds)
{
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while (@(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId").Count -gt 0)
    {
        if ([DateTime]::UtcNow -gt $deadline)
        {
            throw "process $ProcessId did not end within $Seconds seconds"
        }
        Start-Sleep -Milliseconds 250
    }
}

function Invoke-ServiceStop
{
    $info = @(Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'")[0]
    $procId = [uint32]$info.ProcessId
    Stop-Service -Name $ServiceName -Force -WarningAction SilentlyContinue
    if ($procId -ne 0)
    {
        # caddy.exe stays locked until the process has really ended
        Wait-ProcessExit -ProcessId $procId -Seconds 30
    }
}

# Starts the service and waits for "running"; Caddy reports it once its configuration is
# loaded and the listeners are up. Then HealthUrl, if given, must answer.
function Invoke-ServiceStart
{
    $controller = [System.ServiceProcess.ServiceController]::new($ServiceName)
    $controller.Start()
    $deadline = [DateTime]::UtcNow.AddSeconds($StartTimeoutSeconds)
    while ($true)
    {
        $controller.Refresh()
        if ($controller.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running)
        {
            break
        }
        if ($controller.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped)
        {
            throw "service $ServiceName stopped right after the start"
        }
        if ([DateTime]::UtcNow -gt $deadline)
        {
            throw "service $ServiceName is not running after $StartTimeoutSeconds seconds ($($controller.Status))"
        }
        Start-Sleep -Milliseconds 250
    }
    # still running a moment later
    Start-Sleep -Seconds 3
    $controller.Refresh()
    if ($controller.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running)
    {
        throw "service $ServiceName stopped after reporting running ($($controller.Status))"
    }
    if ($HealthUrl)
    {
        $lastError = ''
        while ($true)
        {
            try
            {
                $null = Invoke-WebRequest -Uri $HealthUrl -SkipHttpErrorCheck -SkipCertificateCheck -TimeoutSec 10
                break
            }
            catch [System.Net.Http.HttpRequestException], [System.Threading.Tasks.TaskCanceledException], [System.TimeoutException]
            {
                $lastError = $_.Exception.Message
            }
            if ([DateTime]::UtcNow -gt $deadline)
            {
                throw "$HealthUrl does not answer: $lastError"
            }
            Start-Sleep -Seconds 1
        }
    }
}

function Invoke-Update
{
    if ($SignerEku -ceq $publicTrustEku)
    {
        throw "$publicTrustEku is in every Public Trust certificate of Artifact Signing; -SignerEku needs the EKU of one certificate profile"
    }
    $target = Get-Target
    $targetVersion = ConvertTo-FileVersion $target.Version
    if ($null -eq $targetVersion)
    {
        throw "$($target.Version) is not a package version (x.y.z-n)"
    }

    $service = Get-CaddyService
    if ($null -ne $service -and -not (Test-Administrator))
    {
        throw "stopping and starting service $ServiceName needs an elevated PowerShell (or the SYSTEM account)"
    }

    # A caddy.exe from this folder that runs outside the service keeps the file locked and
    # would keep running the old version.
    $servicePid = if ($null -ne $service) { [uint32]$service.ProcessId } else { [uint32]0 }
    $strays = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='caddy.exe'" | Where-Object {
            $null -ne $_.ExecutablePath -and
            [string]::Equals([string]$_.ExecutablePath, $exeFile, [StringComparison]::OrdinalIgnoreCase) -and
            [uint32]$_.ProcessId -ne $servicePid
        })
    if ($strays.Count -gt 0)
    {
        throw "caddy.exe from $folder runs outside service $ServiceName (PID $(@($strays | ForEach-Object ProcessId) -join ', ')); stop it first"
    }

    $hasExe = Test-Path -LiteralPath $exeFile -PathType Leaf
    if ($hasExe)
    {
        $installedVersion = Get-ExeVersion $exeFile
        $installedText = Get-ExeVersionText $exeFile
        if (-not $Force -and $installedVersion -ge $targetVersion)
        {
            Write-UpdateLog "caddy $installedText is installed, the newest release is $($target.Version): nothing to do"
            return
        }
        Write-UpdateLog "installing caddy $($target.Version) over caddy $installedText"
    }
    else
    {
        Write-UpdateLog "installing caddy $($target.Version) into $folder (no caddy.exe there yet)"
    }

    if (Test-Path -LiteralPath $workFolder)
    {
        Remove-Item -LiteralPath $workFolder -Recurse -Force
    }
    $null = New-Item -ItemType Directory -Path $workFolder
    try
    {
        $zipFile = Join-Path $workFolder $target.Name
        if ($target.Local)
        {
            Copy-Item -LiteralPath $target.Source -Destination $zipFile
        }
        else
        {
            Invoke-WebRequest -Uri $target.Source -OutFile $zipFile
        }
        $actualSha = (Get-FileHash -LiteralPath $zipFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($null -ne $target.Sha256 -and $actualSha -cne $target.Sha256)
        {
            throw "$($target.Name) has SHA-256 $actualSha, expected $($target.Sha256)"
        }

        $unpacked = Join-Path $workFolder 'new'
        Expand-Archive -LiteralPath $zipFile -DestinationPath $unpacked
        $newExe = Join-Path $unpacked 'caddy.exe'
        if (-not (Test-Path -LiteralPath $newExe -PathType Leaf))
        {
            throw "$($target.Name) holds no caddy.exe"
        }
        # before caddy.exe runs below
        if ($SkipSignatureCheck)
        {
            Write-UpdateLog 'not checking the signature of caddy.exe (-SkipSignatureCheck)'
        }
        else
        {
            Assert-Signature $newExe
        }
        $newVersion = Get-ExeVersion $newExe
        if ($newVersion -ne $targetVersion)
        {
            throw "the caddy.exe in $($target.Name) has file version $newVersion, expected $targetVersion"
        }
        $caddyVersion = $target.Version.Substring(0, $target.Version.LastIndexOf('-'))
        $versionOutput = @(& $newExe version 2>&1)
        $versionExit = $LASTEXITCODE
        if ($versionExit -ne 0 -or $versionOutput.Count -eq 0 -or -not ([string]$versionOutput[0]).StartsWith("v$caddyVersion ", [StringComparison]::Ordinal))
        {
            throw "the new caddy.exe does not report v$caddyVersion (exit code $versionExit): $($versionOutput -join ' ')"
        }

        $wasRunning = $false
        if ($null -ne $service)
        {
            $wasRunning = (Get-Service -Name $ServiceName).Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running
            if ($wasRunning)
            {
                Write-UpdateLog "stopping service $ServiceName"
                Invoke-ServiceStop
            }
        }

        if (Test-Path -LiteralPath $previousFile)
        {
            [System.IO.File]::Delete($previousFile)
        }
        if ($hasExe)
        {
            [System.IO.File]::Move($exeFile, $previousFile)
        }
        try
        {
            [System.IO.File]::Move($newExe, $exeFile)
        }
        catch
        {
            if ($hasExe)
            {
                [System.IO.File]::Move($previousFile, $exeFile)
            }
            throw
        }

        if (-not $wasRunning)
        {
            if ($null -eq $service)
            {
                Write-UpdateLog "caddy $($target.Version) installed; there is no service $ServiceName to restart"
            }
            else
            {
                Write-UpdateLog "caddy $($target.Version) installed; service $ServiceName was not running and stays stopped"
            }
            return
        }

        Write-UpdateLog "starting service $ServiceName"
        try
        {
            Invoke-ServiceStart
        }
        catch
        {
            $startError = $_.Exception.Message
            if (-not $hasExe)
            {
                throw "caddy $($target.Version) does not start ($startError), and there is no previous caddy.exe to go back to"
            }
            Write-UpdateLog "caddy $($target.Version) does not start ($startError); rolling back to the previous caddy.exe"
            if ((Get-Service -Name $ServiceName).Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped)
            {
                Invoke-ServiceStop
            }
            [System.IO.File]::Delete($exeFile)
            [System.IO.File]::Move($previousFile, $exeFile)
            try
            {
                Invoke-ServiceStart
                Write-UpdateLog "rolled back: service $ServiceName runs caddy $(Get-ExeVersionText $exeFile) again"
            }
            catch
            {
                Write-UpdateLog "rolled back, but the previous caddy.exe does not start either: $($_.Exception.Message)"
            }
            throw "update to caddy $($target.Version) failed and was rolled back"
        }
        Write-UpdateLog "caddy $($target.Version) installed, service $ServiceName runs it"
    }
    finally
    {
        if (Test-Path -LiteralPath $workFolder)
        {
            Remove-Item -LiteralPath $workFolder -Recurse -Force
        }
    }
}

try
{
    Invoke-Update
    exit 0
}
catch
{
    Write-UpdateLog "FAILED: $($_.Exception.Message)"
    exit 1
}
