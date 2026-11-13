#Requires -Version 7.0

<#
.SYNOPSIS
    Tests the Windows build on a throwaway Windows machine (the GitHub runner), as
    administrator.

.DESCRIPTION
    -OutDir: the zip of this build. Its contents, the version resource and the icon, the
    plugins, and windows/Update-Caddy.ps1 (from the zip) against a real Windows service:
    first Caddy's own caddy.exe of the same Caddy version runs as the service, the script
    replaces it with this build, then: nothing to do on a second run, a wrong SHA-256, a zip
    whose caddy.exe is not the one its name says, a service that runs a different folder, a
    new version that does not come up (rollback), a stopped service, a folder without a
    service, and the .cmd launcher. Also that a service gets environment variables from its
    registry value "Environment", as the README describes it for the Cloudflare token.

    Signatures: a signed build (build.yml's signing job) must carry, on caddy.exe and
    Update-Caddy.ps1, the Artifact Signing profile that Update-Caddy.ps1 trusts by default
    (-SignerEku), and every update run then checks it. An unsigned build (pull requests) runs
    them with -SkipSignatureCheck, and with -Publishing it fails. The check itself is tested on
    every build against git.exe of Git for Windows, which is signed with Artifact Signing too:
    its own profile passes; another profile, a changed byte and an unsigned caddy.exe do not,
    and the refusals say what to do (or, for a changed file, that it must not be installed).

    -PublishedVersion: after publishing, Update-Caddy.ps1 from the repository installs the
    newest release from GitHub into an empty folder; it must be that version, with the
    plugins, and a second run must find nothing to do.

    GITHUB_TOKEN, if set, is used for the GitHub API.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'Build')]
    [string] $OutDir,

    [Parameter(ParameterSetName = 'Build')]
    [switch] $Publishing,

    [Parameter(Mandatory, ParameterSetName = 'Release')]
    [string] $PublishedVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pwshExe = Join-Path $PSHOME 'pwsh.exe'
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$testRoot = Join-Path $tempRoot 'caddy-deb-windows-test'
$testService = 'caddy-deb-test'
$noService = 'caddy-deb-none'
$port = 8089
$siteUrl = "http://127.0.0.1:$port/"

function Write-Step([string] $Text)
{
    Write-Host ''
    Write-Host "== $Text"
}

function Assert-True([bool] $Condition, [string] $Text)
{
    if (-not $Condition)
    {
        throw "FAIL: $Text"
    }
    Write-Host "ok: $Text"
}

# The plugin imports of main.go, as scripts/plugins.sh reads them
function Get-PluginImport
{
    $inBlock = $false
    $found = @()
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $repoRoot 'main.go')))
    {
        if ($line.Contains('plugins of this build'))
        {
            $inBlock = $true
            continue
        }
        if ($inBlock -and $line.Trim() -eq ')')
        {
            break
        }
        $m = [regex]::Match($line, '^\s*_ "([^"]+)"')
        if ($inBlock -and $m.Success)
        {
            $found += $m.Groups[1].Value
        }
    }
    if ($found.Count -eq 0)
    {
        throw 'FAIL: no plugin imports found in main.go'
    }
    return $found
}

# Every plugin import must come from a module Caddy lists as non-standard
# ("caddy list-modules --packages --skip-standard": "<module id> <go module path>").
function Assert-Plugin([string] $Binary)
{
    $listed = @(& $Binary list-modules --packages --skip-standard)
    Assert-True ($LASTEXITCODE -eq 0) "$Binary list-modules runs"
    foreach ($import in Get-PluginImport)
    {
        $hit = @($listed | Where-Object {
                $fields = @(([string]$_).Trim() -split '\s+')
                $fields.Count -ge 2 -and ($import -ceq $fields[1] -or $import.StartsWith($fields[1] + '/', [StringComparison]::Ordinal))
            })
        Assert-True ($hit.Count -gt 0) "plugin $import is in $Binary"
    }
}

$publicTrustEku = '1.3.6.1.4.1.311.97.1.0'

# The Artifact Signing profile EKU (1.3.6.1.4.1.311.97.<numbers>) of a file whose signature is
# valid, or '' if it has no valid signature or not exactly one profile EKU
function Get-ProfileEku([string] $Path)
{
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid)
    {
        return ''
    }
    $ekus = @($signature.SignerCertificate.Extensions |
            Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
            ForEach-Object { $_.EnhancedKeyUsages } |
            ForEach-Object { [string]$_.Value })
    $profiles = @($ekus | Where-Object { $_.StartsWith('1.3.6.1.4.1.311.97.', [StringComparison]::Ordinal) -and $_ -cne $publicTrustEku })
    if ($ekus -cnotcontains $publicTrustEku -or $profiles.Count -ne 1)
    {
        return ''
    }
    return $profiles[0]
}

# The default of -SignerEku in Update-Caddy.ps1: the profile it trusts
function Get-PinnedEku([string] $Script)
{
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0)
    {
        throw "FAIL: $Script does not parse: $($errors[0].Message)"
    }
    $parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'SignerEku' })
    if ($parameter.Count -ne 1 -or $null -eq $parameter[0].DefaultValue)
    {
        throw "FAIL: $Script has no parameter SignerEku with a default"
    }
    return [string]$parameter[0].DefaultValue.SafeGetValue()
}

function Get-ApiHeader
{
    $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($env:GITHUB_TOKEN)
    {
        $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
    }
    return $headers
}

# Runs Update-Caddy.ps1 in its own pwsh and returns its exit code
function Invoke-UpdateScript([string] $Script, [string[]] $Arguments)
{
    Write-Host "-- Update-Caddy.ps1 $($Arguments -join ' ')"
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments | Out-Host
    return $LASTEXITCODE
}

function Get-LastLogLine([string] $Folder)
{
    return @(Get-Content -LiteralPath (Join-Path $Folder 'update-caddy.log'))[-1]
}

function Get-ServicePid
{
    return [uint32]@(Get-CimInstance -ClassName Win32_Service -Filter "Name='$testService'")[0].ProcessId
}

function Get-SiteText
{
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($true)
    {
        try
        {
            return (Invoke-WebRequest -Uri $siteUrl -TimeoutSec 5).Content
        }
        catch [System.Net.Http.HttpRequestException]
        {
            if ([DateTime]::UtcNow -gt $deadline)
            {
                throw
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

if (Test-Path -LiteralPath $testRoot)
{
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
$null = New-Item -ItemType Directory -Path $testRoot

if ($PSCmdlet.ParameterSetName -eq 'Release')
{
    Write-Step "the published release $PublishedVersion, installed by Update-Caddy.ps1 from GitHub"
    $releaseDir = Join-Path $testRoot 'release'
    $updateScript = Join-Path $repoRoot 'windows\Update-Caddy.ps1'
    $code = Invoke-UpdateScript $updateScript @('-InstallDir', $releaseDir, '-ServiceName', $noService)
    Assert-True ($code -eq 0) 'Update-Caddy.ps1 installed the newest release'
    $exe = Join-Path $releaseDir 'caddy.exe'
    $installed = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
    Assert-True ($installed -ceq $PublishedVersion) "the installed caddy.exe is $PublishedVersion (it is $installed)"
    Assert-Plugin $exe
    # Update-Caddy.ps1 has checked the signature already
    $releaseEku = Get-ProfileEku $exe
    Write-Host "the installed caddy.exe is $(if ($releaseEku) { "signed by the Artifact Signing profile $releaseEku" } else { 'not signed' })"
    $code = Invoke-UpdateScript $updateScript @('-InstallDir', $releaseDir, '-ServiceName', $noService)
    Assert-True ($code -eq 0 -and (Get-LastLogLine $releaseDir).Contains('nothing to do')) 'a second run finds nothing to do'
    Write-Host ''
    Write-Host 'release test passed'
    exit 0
}

# ---- the build ----

$zips = @(Get-ChildItem -LiteralPath $OutDir -File | Where-Object { $_.Name -match '^caddy_.+_windows_amd64\.zip$' })
Assert-True ($zips.Count -eq 1) "exactly one Windows zip in $OutDir"
$zip = $zips[0].FullName
$packageVersion = [regex]::Match($zips[0].Name, '^caddy_(\d+\.\d+\.\d+-\d+)_windows_amd64\.zip$').Groups[1].Value
Assert-True ($packageVersion -ne '') "the zip name carries a package version ($packageVersion)"
$caddyVersion = $packageVersion.Substring(0, $packageVersion.LastIndexOf('-'))
$numbers = [version]($packageVersion.Replace('-', '.'))
$zipSha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Step "contents of $($zips[0].Name)"
$unpacked = Join-Path $testRoot 'zip'
Expand-Archive -LiteralPath $zip -DestinationPath $unpacked
$names = @(Get-ChildItem -LiteralPath $unpacked -Recurse -File | ForEach-Object Name | Sort-Object)
Assert-True (($names -join ' ') -ceq 'caddy.exe LICENSE Update-Caddy.cmd Update-Caddy.ps1') "the zip holds caddy.exe, LICENSE, Update-Caddy.cmd and Update-Caddy.ps1 ($($names -join ', '))"
$updateScript = Join-Path $unpacked 'Update-Caddy.ps1'
$launcher = Join-Path $unpacked 'Update-Caddy.cmd'
$scriptText = [System.IO.File]::ReadAllText($updateScript)
Assert-True (-not $scriptText.Contains('@PACKAGING_VERSION@')) 'the packaging version is filled into Update-Caddy.ps1'
$exe = Join-Path $unpacked 'caddy.exe'

Write-Step 'version resource and icon'
$info = (Get-Item -LiteralPath $exe).VersionInfo
Assert-True ($info.FileVersion -ceq $packageVersion) "file version text is $packageVersion ($($info.FileVersion))"
Assert-True ($info.ProductVersion -ceq $packageVersion) "product version text is $packageVersion ($($info.ProductVersion))"
$parts = [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
Assert-True ($parts -eq $numbers) "file version numbers are $numbers ($parts)"
Assert-True ($info.ProductName -ceq 'Caddy' -and $info.OriginalFilename -ceq 'caddy.exe') 'product name Caddy, original file name caddy.exe'
Assert-True ([string]$info.Comments).Contains('MarcFauser/caddy-deb') "the comment names caddy-deb ($($info.Comments))"
Add-Type -Namespace CaddyDebTest -Name Shell -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern uint ExtractIconEx(string lpszFile, int nIconIndex, IntPtr[] phiconLarge, IntPtr[] phiconSmall, uint nIcons);
'@
$icons = [CaddyDebTest.Shell]::ExtractIconEx($exe, -1, $null, $null, 0)
Assert-True ($icons -ge 1) "caddy.exe has an icon ($icons)"

Write-Step 'signatures'
$exeSignature = Get-AuthenticodeSignature -LiteralPath $exe
$pinnedEku = Get-PinnedEku $updateScript
Write-Host "Update-Caddy.ps1 trusts the Artifact Signing profile $pinnedEku"
$buildEku = ''
if ($exeSignature.Status -eq [System.Management.Automation.SignatureStatus]::NotSigned)
{
    # the servers' Update-Caddy.ps1 would refuse it
    Assert-True (-not $Publishing) 'a build that is published is signed (unsigned is fine only where nothing is published)'
    # the update runs below test everything but the signature, which comes further down
    $signerArgs = @('-SkipSignatureCheck')
}
else
{
    $buildEku = Get-ProfileEku $exe
    Assert-True ($buildEku -ne '') "caddy.exe is signed by one Artifact Signing profile ($($exeSignature.Status), $buildEku, $($exeSignature.SignerCertificate.Subject))"
    Assert-True ($null -ne $exeSignature.TimeStamperCertificate) 'the signature of caddy.exe is timestamped'
    Assert-True ((Get-ProfileEku $updateScript) -ceq $buildEku) 'Update-Caddy.ps1 is signed by the same profile'
    # a new profile needs its EKU as the default of -SignerEku first (README, "Code signing")
    Assert-True ($pinnedEku -ceq $buildEku) "Update-Caddy.ps1 trusts this build's profile ($buildEku)"
    # every update run below checks the signature of this build with the script's default
    $signerArgs = @()
}

Write-Step 'the binary runs and has the plugins'
$versionLine = [string]@(& $exe version)[0]
Assert-True ($LASTEXITCODE -eq 0 -and $versionLine.StartsWith("v$caddyVersion ", [StringComparison]::Ordinal)) "caddy version says v$caddyVersion ($versionLine)"
Assert-Plugin $exe

Write-Step "Caddy's own caddy.exe $caddyVersion as a Windows service"
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/caddyserver/caddy/releases/tags/v$caddyVersion" -Headers (Get-ApiHeader)
$officialName = "caddy_${caddyVersion}_windows_amd64.zip"
$assets = @($release.assets | Where-Object { [string]$_.name -ceq $officialName })
Assert-True ($assets.Count -eq 1) "Caddy's release v$caddyVersion has $officialName"
$officialZip = Join-Path $testRoot $officialName
Invoke-WebRequest -Uri ([string]$assets[0].browser_download_url) -OutFile $officialZip
$officialSha = (Get-FileHash -LiteralPath $officialZip -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-True ("sha256:$officialSha" -ceq [string]$assets[0].digest) "$officialName matches the digest GitHub records"
$officialDir = Join-Path $testRoot 'official'
Expand-Archive -LiteralPath $officialZip -DestinationPath $officialDir
$officialExe = Join-Path $officialDir 'caddy.exe'
$officialVersion = (Get-Item -LiteralPath $officialExe).VersionInfo
$officialParts = [version]::new($officialVersion.FileMajorPart, $officialVersion.FileMinorPart, $officialVersion.FileBuildPart, $officialVersion.FilePrivatePart)
Assert-True ($officialParts -lt $numbers) "Caddy's own caddy.exe ($officialParts) is older than this build ($numbers)"

$serviceDir = Join-Path $testRoot 'service'
$null = New-Item -ItemType Directory -Path $serviceDir
$serviceExe = Join-Path $serviceDir 'caddy.exe'
Copy-Item -LiteralPath $officialExe -Destination $serviceExe
$dataDir = (Join-Path $serviceDir 'data').Replace('\', '/')
$caddyfile = @"
{
	admin localhost:2019
	storage file_system "$dataDir"
}

:$port {
	bind 127.0.0.1
	respond "caddy-deb test {env.CADDY_DEB_TEST}"
}
"@
[System.IO.File]::WriteAllText((Join-Path $serviceDir 'Caddyfile'), $caddyfile.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
$binaryPath = '"{0}" run --config "{1}" --adapter caddyfile' -f $serviceExe, (Join-Path $serviceDir 'Caddyfile')
$null = New-Service -Name $testService -BinaryPathName $binaryPath -StartupType Manual
$null = New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$testService" -Name Environment -PropertyType MultiString -Value @('CADDY_DEB_TEST=env-ok')
Start-Service -Name $testService
Assert-True ((Get-Service -Name $testService).Status -eq 'Running') 'the service runs'
Assert-True ((Get-SiteText) -ceq 'caddy-deb test env-ok') 'the site answers, with the variable from the registry value Environment'

try
{
    Write-Step 'update: Caddy''s own caddy.exe -> this build'
    $pidBefore = Get-ServicePid
    $base = @('-InstallDir', $serviceDir, '-ServiceName', $testService)
    $common = $base + $signerArgs
    $code = Invoke-UpdateScript $updateScript ($common + @('-ZipPath', $zip, '-ZipSha256', $zipSha, '-HealthUrl', $siteUrl))
    Assert-True ($code -eq 0) 'Update-Caddy.ps1 succeeded'
    Assert-True ((Get-Item -LiteralPath $serviceExe).VersionInfo.FileVersion -ceq $packageVersion) "caddy.exe is now $packageVersion"
    $previous = Join-Path $serviceDir 'caddy.exe.previous'
    Assert-True ((Test-Path -LiteralPath $previous) -and (Get-FileHash -LiteralPath $previous).Hash -ceq (Get-FileHash -LiteralPath $officialExe).Hash) 'the old caddy.exe is kept as caddy.exe.previous'
    $pidAfter = Get-ServicePid
    Assert-True ($pidAfter -ne 0 -and $pidAfter -ne $pidBefore) "the service was restarted (PID $pidBefore -> $pidAfter)"
    $running = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$pidAfter")
    Assert-True ($running.Count -eq 1 -and [string]::Equals([string]$running[0].ExecutablePath, $serviceExe, [StringComparison]::OrdinalIgnoreCase)) "the service process runs $serviceExe"
    Assert-True ((Get-SiteText) -ceq 'caddy-deb test env-ok') 'the site answers'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $serviceDir '.caddy-update'))) 'the work folder is gone'

    Write-Step 'second run: nothing to do'
    $code = Invoke-UpdateScript $updateScript ($common + @('-ZipPath', $zip, '-ZipSha256', $zipSha))
    Assert-True ($code -eq 0 -and (Get-LastLogLine $serviceDir).Contains('nothing to do')) 'exit code 0, "nothing to do"'
    Assert-True ((Get-ServicePid) -eq $pidAfter) 'the service was not restarted'

    Write-Step 'wrong SHA-256: refused before anything is stopped'
    $code = Invoke-UpdateScript $updateScript ($common + @('-ZipPath', $zip, '-ZipSha256', ('0' * 64), '-Force'))
    Assert-True ($code -eq 1 -and (Get-LastLogLine $serviceDir).Contains('SHA-256')) 'exit code 1, the log names the SHA-256'
    Assert-True ((Get-ServicePid) -eq $pidAfter) 'the service was not touched'

    Write-Step 'a zip whose caddy.exe is not the version its name says: refused'
    $fakeDir = Join-Path $testRoot 'fake'
    $null = New-Item -ItemType Directory -Path $fakeDir
    $fakeZip = Join-Path $fakeDir $zips[0].Name
    Compress-Archive -LiteralPath $officialExe -DestinationPath $fakeZip
    # without the signature check, which would refuse it first
    $code = Invoke-UpdateScript $updateScript ($base + @('-SkipSignatureCheck', '-ZipPath', $fakeZip, '-Force'))
    Assert-True ($code -eq 1 -and (Get-LastLogLine $serviceDir).Contains('file version')) 'exit code 1, the log names the file version'
    Assert-True ((Get-ServicePid) -eq $pidAfter -and (Get-Item -LiteralPath $serviceExe).VersionInfo.FileVersion -ceq $packageVersion) 'service and caddy.exe were not touched'

    Write-Step 'a service that runs caddy.exe from another folder: refused'
    $otherDir = Join-Path $testRoot 'other'
    $code = Invoke-UpdateScript $updateScript @('-InstallDir', $otherDir, '-ServiceName', $testService, '-ZipPath', $zip)
    Assert-True ($code -eq 1 -and (Get-LastLogLine $otherDir).Contains('refusing')) 'exit code 1, the log says it refuses'
    Assert-True ((Get-ServicePid) -eq $pidAfter) 'the service was not touched'

    Write-Step 'a new version that does not come up: rolled back'
    $code = Invoke-UpdateScript $updateScript ($common + @('-ZipPath', $zip, '-Force', '-HealthUrl', 'http://127.0.0.1:1/', '-StartTimeoutSeconds', '10'))
    $logText = [System.IO.File]::ReadAllText((Join-Path $serviceDir 'update-caddy.log'))
    Assert-True ($code -eq 1 -and $logText.Contains('rolling back')) 'exit code 1, the log says it rolls back'
    Assert-True ((Test-Path -LiteralPath $serviceExe) -and -not (Test-Path -LiteralPath $previous)) 'caddy.exe.previous went back to caddy.exe'
    Assert-True ((Get-Service -Name $testService).Status -eq 'Running') 'the service runs again'
    Assert-True ((Get-SiteText) -ceq 'caddy-deb test env-ok') 'the site answers'

    Write-Step 'a stopped service stays stopped'
    Stop-Service -Name $testService
    $code = Invoke-UpdateScript $updateScript ($common + @('-ZipPath', $zip, '-Force'))
    Assert-True ($code -eq 0 -and (Get-LastLogLine $serviceDir).Contains('stays stopped')) 'exit code 0, the log says the service stays stopped'
    Assert-True ((Get-Service -Name $testService).Status -eq 'Stopped') 'the service is still stopped'

    Write-Step 'a folder without a service: caddy.exe is put there'
    $freshDir = Join-Path $testRoot 'fresh'
    $freshArgs = @('-InstallDir', $freshDir, '-ServiceName', $noService) + $signerArgs
    $code = Invoke-UpdateScript $updateScript ($freshArgs + @('-ZipPath', $zip))
    Assert-True ($code -eq 0 -and (Get-LastLogLine $freshDir).Contains("no service $noService")) 'exit code 0, the log says there is no service'
    Assert-True ((Get-Item -LiteralPath (Join-Path $freshDir 'caddy.exe')).VersionInfo.FileVersion -ceq $packageVersion) "caddy.exe $packageVersion is there"

    Write-Step 'the .cmd launcher passes arguments and exit codes on'
    Assert-True (-not ($launcher + $freshDir + $zip).Contains(' ')) 'the test paths have no spaces (the cmd line below is unquoted)'
    $enter = Join-Path $testRoot 'enter.txt'
    [System.IO.File]::WriteAllText($enter, "`r`n`r`n")
    $okRun = Start-Process -FilePath cmd.exe -ArgumentList "/d /c $launcher -InstallDir $freshDir -ServiceName $noService -ZipPath $zip" -RedirectStandardInput $enter -NoNewWindow -Wait -PassThru
    Assert-True ($okRun.ExitCode -eq 0 -and (Get-LastLogLine $freshDir).Contains('nothing to do')) "through the .cmd: exit code 0, nothing to do ($($okRun.ExitCode))"
    $failRun = Start-Process -FilePath cmd.exe -ArgumentList "/d /c $launcher -InstallDir $freshDir -ServiceName $noService -ZipPath $zip -ZipSha256 $('0' * 64) -Force" -RedirectStandardInput $enter -NoNewWindow -Wait -PassThru
    Assert-True ($failRun.ExitCode -eq 1) "through the .cmd: a failure gives exit code 1 ($($failRun.ExitCode))"

    Write-Step 'the signature check, against git.exe of Git for Windows (Artifact Signing)'
    $gitExe = Join-Path $env:ProgramFiles 'Git\bin\git.exe'
    $gitEku = Get-ProfileEku $gitExe
    Assert-True ($gitEku -ne '') "$gitExe is signed by one Artifact Signing profile ($gitEku), the positive control"
    $sigRoot = Join-Path $testRoot 'signature'
    $gitZip = Join-Path $sigRoot "git\$($zips[0].Name)"
    $tamperedZip = Join-Path $sigRoot "tampered\$($zips[0].Name)"
    $null = New-Item -ItemType Directory -Path (Join-Path $sigRoot 'git-exe'), (Join-Path $sigRoot 'tampered-exe'), (Split-Path $gitZip), (Split-Path $tamperedZip)
    $gitCopy = Join-Path $sigRoot 'git-exe\caddy.exe'
    Copy-Item -LiteralPath $gitExe -Destination $gitCopy
    Compress-Archive -LiteralPath $gitCopy -DestinationPath $gitZip
    $bytes = [System.IO.File]::ReadAllBytes($gitExe)
    $middle = [int][Math]::Floor($bytes.Length / 2)
    $bytes[$middle] = $bytes[$middle] -bxor 0xFF
    $tamperedCopy = Join-Path $sigRoot 'tampered-exe\caddy.exe'
    [System.IO.File]::WriteAllBytes($tamperedCopy, $bytes)
    Compress-Archive -LiteralPath $tamperedCopy -DestinationPath $tamperedZip
    $sigDir = Join-Path $sigRoot 'install'
    $sigArgs = @('-InstallDir', $sigDir, '-ServiceName', $noService)

    $code = Invoke-UpdateScript $updateScript ($sigArgs + @('-ZipPath', $gitZip, '-SignerEku', $gitEku))
    $logLines = @(Get-Content -LiteralPath (Join-Path $sigDir 'update-caddy.log'))
    Assert-True ($code -eq 1 -and ($logLines -join "`n").Contains("(Artifact Signing profile $gitEku)") -and $logLines[-1].Contains('file version')) 'with its own profile, git.exe passes the signature check and then fails the file version'
    $otherEku = '1.3.6.1.4.1.311.97.4242.4242'
    $code = Invoke-UpdateScript $updateScript ($sigArgs + @('-ZipPath', $gitZip, '-SignerEku', $otherEku))
    $last = Get-LastLogLine $sigDir
    Assert-True ($code -eq 1 -and $last.Contains("not from the Artifact Signing profile $otherEku") -and $last.Contains("run once with -SignerEku $gitEku")) 'another profile is refused, and the refusal names the profile the file has'
    $code = Invoke-UpdateScript $updateScript ($sigArgs + @('-ZipPath', $gitZip))
    $last = Get-LastLogLine $sigDir
    Assert-True ($code -eq 1 -and $last.Contains("not from the Artifact Signing profile $pinnedEku") -and $last.Contains("-SignerEku $gitEku")) "by default, only the profile $pinnedEku is trusted"
    $code = Invoke-UpdateScript $updateScript ($sigArgs + @('-ZipPath', $tamperedZip, '-SignerEku', $gitEku))
    $last = Get-LastLogLine $sigDir
    Assert-True ($code -eq 1 -and $last.Contains('was changed after it was signed (HashMismatch)') -and -not $last.Contains('SkipSignatureCheck')) 'a changed byte is refused, without offering a way past it'
    $code = Invoke-UpdateScript $updateScript ($sigArgs + @('-ZipPath', $fakeZip, '-Force'))
    $last = Get-LastLogLine $sigDir
    Assert-True ($code -eq 1 -and $last.Contains('caddy.exe is not signed') -and $last.Contains('-SkipSignatureCheck')) "Caddy's own caddy.exe is refused, and the refusal names -SkipSignatureCheck: $last"
    $code = Invoke-UpdateScript $updateScript ($sigArgs + @('-ZipPath', $gitZip, '-SkipSignatureCheck'))
    $logLines = @(Get-Content -LiteralPath (Join-Path $sigDir 'update-caddy.log'))
    Assert-True ($code -eq 1 -and $logLines[-2].Contains('not checking the signature') -and $logLines[-1].Contains('file version')) '-SkipSignatureCheck skips the check (and the file version still stops git.exe)'
    $code = Invoke-UpdateScript $updateScript ($sigArgs + @('-ZipPath', $gitZip, '-SignerEku', $publicTrustEku))
    Assert-True ($code -eq 1 -and (Get-LastLogLine $sigDir).Contains('needs the EKU of one certificate profile')) 'the Public Trust EKU is refused as a profile'
    if ($buildEku -eq '')
    {
        $code = Invoke-UpdateScript $updateScript ($sigArgs + @('-ZipPath', $zip))
        Assert-True ($code -eq 1 -and (Get-LastLogLine $sigDir).Contains('caddy.exe is not signed')) 'by default, Update-Caddy.ps1 refuses this unsigned build'
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sigDir 'caddy.exe'))) 'none of these was installed'
}
finally
{
    $left = Get-Service -Name $testService -ErrorAction Ignore
    if ($null -ne $left)
    {
        Stop-Service -Name $testService -Force -ErrorAction Continue
        Remove-Service -Name $testService -ErrorAction Continue
    }
}

Write-Host ''
Write-Host 'Windows test passed'
# GitHub's pwsh wrapper exits with $LASTEXITCODE if it is set, and the last update run above
# fails on purpose (build #20: "Windows test passed", then exit code 1)
exit 0
