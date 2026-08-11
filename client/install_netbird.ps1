#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# NetBird system-wide installation for Windows 10 and later.
#
# Intended execution:
#   - Run from an elevated Windows PowerShell 5.1 session.
#   - In JumpCloud, use a Windows PowerShell command and Run As: SYSTEM.
#   - No setup key is used; users complete SSO from the NetBird UI.
#   - The NetBird UI starts at sign-in for every user.
#   - Each user receives a user-scoped SleekVPNTest profile at sign-in.
#
# The management URL is configured in three locations for compatibility:
#   1. C:\ProgramData\Netbird\default.json for the stable Windows client.
#   2. The NetBird Windows service arguments for startup persistence.
#   3. HKLM\Software\Policies\NetBird for clients that support MDM policy.

$ManagementUrl = 'https://nbvpn.sleek.com'
$ProfileName = 'SleekVPNTest'
$ExpectedPublisherPattern = '(?i)NetBird'

$PolicyRegistryPath = 'HKLM:\Software\Policies\NetBird'
$ServiceRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Netbird'
$ServiceName = 'Netbird'
$UiRunRegistryPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
$ProfileRunValueName = 'SleekNetBirdProfileProvisioner'

$SleekDataDirectory = Join-Path $env:ProgramData 'Sleek\NetBird'
$LogDirectory = Join-Path $env:ProgramData 'Sleek\Logs'
$InstallLog = Join-Path $LogDirectory 'netbird-jumpcloud-install.log'
$MsiLog = Join-Path $LogDirectory 'netbird-msi-install.log'
$ProfileProvisionerPath = Join-Path $SleekDataDirectory 'provision-netbird-profile.ps1'
$DefaultProfilePath = Join-Path $env:ProgramData 'Netbird\default.json'
$CachedMsiPath = Join-Path $SleekDataDirectory 'netbird-installer.msi'

$script:LogReady = $false
$script:TemporaryDirectory = $null
function Add-InstallerLogLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    if (-not $script:LogReady) {
        return
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            [System.IO.File]::AppendAllText(
                $InstallLog,
                $Line + [Environment]::NewLine,
                $encoding
            )
            return
        }
        catch {
            if ($attempt -lt 5) {
                Start-Sleep -Milliseconds (100 * $attempt)
            }
            else {
                $warning = '[{0}] WARN: Could not append to installer log {1}: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $InstallLog, $_.Exception.Message
                [Console]::Error.WriteLine($warning)
            }
        }
    }
}


function Write-InstallerLog {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = '[{0}] {1}: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    Add-InstallerLogLine -Line $line

    if ($Level -eq 'ERROR') {
        [Console]::Error.WriteLine($line)
    }
    else {
        Write-Host $line
    }
}

function Set-ProtectedDirectoryAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$AllowUsersRead
    )

    $arguments = @(
        $Path,
        '/inheritance:r',
        '/grant:r',
        '*S-1-5-18:(OI)(CI)F',
        '*S-1-5-32-544:(OI)(CI)F'
    )

    if ($AllowUsersRead) {
        $arguments += @('/grant:r', '*S-1-5-32-545:(OI)(CI)RX')
    }

    $output = & "$env:SystemRoot\System32\icacls.exe" @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not secure directory '$Path'. icacls output: $($output -join ' ')"
    }
}

function Initialize-InstallerLog {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    Set-ProtectedDirectoryAcl -Path $LogDirectory

    if (-not (Test-Path -LiteralPath $InstallLog -PathType Leaf)) {
        New-Item -Path $InstallLog -ItemType File -Force | Out-Null
    }

    $script:LogReady = $true
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WindowsArchitecture {
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }

    switch ($architecture.ToUpperInvariant()) {
        'AMD64' {
            return [PSCustomObject]@{
                PackageDirectory = 'x64'
                PackageSuffix = 'amd64'
            }
        }
        'ARM64' {
            return [PSCustomObject]@{
                PackageDirectory = 'arm64'
                PackageSuffix = 'arm64'
            }
        }
        default {
            throw "Unsupported Windows architecture: $architecture"
        }
    }
}

function Get-NetBirdPaths {
    $programFilesDirectory = $env:ProgramW6432
    if ([string]::IsNullOrWhiteSpace($programFilesDirectory)) {
        $programFilesDirectory = $env:ProgramFiles
    }

    $installDirectory = Join-Path $programFilesDirectory 'NetBird'
    return [PSCustomObject]@{
        InstallDirectory = $installDirectory
        Cli = Join-Path $installDirectory 'netbird.exe'
        Ui = Join-Path $installDirectory 'netbird-ui.exe'
    }
}

function Invoke-Preflight {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This installer supports Windows only.'
    }

    if (-not (Test-IsAdministrator)) {
        throw 'Run this installer as Administrator. In JumpCloud, set Run As to SYSTEM.'
    }

    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
    $windowsVersion = [version]$operatingSystem.Version
    if ($windowsVersion.Major -lt 10) {
        throw "Windows 10 or later is required. Detected version: $windowsVersion"
    }

    $managementUri = [uri]$ManagementUrl
    if ($managementUri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($managementUri.Host)) {
        throw "The configured management URL must be a valid HTTPS URL: $ManagementUrl"
    }

    Get-Command msiexec.exe -ErrorAction Stop | Out-Null
    Get-Command Get-AuthenticodeSignature -ErrorAction Stop | Out-Null
}

function Test-NetBirdSignature {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        return $false
    }

    if ($null -eq $signature.SignerCertificate) {
        return $false
    }

    return $signature.SignerCertificate.Subject -match $ExpectedPublisherPattern
}

function Test-HealthyNetBirdInstallation {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Paths
    )

    if (-not (Test-NetBirdSignature -Path $Paths.Cli)) {
        return $false
    }

    if (-not (Test-NetBirdSignature -Path $Paths.Ui)) {
        return $false
    }

    if ($null -eq (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
        return $false
    }

    $uiRunValues = Get-ItemProperty -LiteralPath $UiRunRegistryPath -ErrorAction SilentlyContinue
    $uiAutostartPresent = $false
    if ($null -ne $uiRunValues) {
        foreach ($property in $uiRunValues.PSObject.Properties) {
            if ([string]$property.Value -match '(?i)netbird-ui\.exe') {
                $uiAutostartPresent = $true
                break
            }
        }
    }

    if (-not $uiAutostartPresent) {
        return $false
    }

    $null = & $Paths.Cli version 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    $null = & $Paths.Cli service reconfigure --help 2>$null
    return $LASTEXITCODE -eq 0
}

function Invoke-DownloadWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [uri]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $maximumAttempts = 3
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -TimeoutSec 900

            $downloadedFile = Get-Item -LiteralPath $Destination
            if ($downloadedFile.Length -lt 1MB) {
                throw "The downloaded installer is unexpectedly small ($($downloadedFile.Length) bytes)."
            }

            return
        }
        catch {
            if ($attempt -eq $maximumAttempts) {
                throw
            }

            Write-InstallerLog -Level WARN -Message "Download attempt $attempt failed: $($_.Exception.Message)"
            Start-Sleep -Seconds (3 * $attempt)
        }
    }
}

function Install-NetBirdPackage {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Architecture
    )

    $packageName = 'netbird_installer_windows_{0}.msi' -f $Architecture.PackageSuffix
    $packageUrl = 'https://pkgs.netbird.io/windows/msi/{0}/{1}' -f $Architecture.PackageDirectory, $packageName

    New-Item -Path $SleekDataDirectory -ItemType Directory -Force | Out-Null
    Set-ProtectedDirectoryAcl -Path $SleekDataDirectory

    if (Test-NetBirdSignature -Path $CachedMsiPath) {
        Write-InstallerLog -Level INFO -Message "Reusing the signed cached NetBird MSI for $($Architecture.PackageSuffix)."
    }
    else {
        $script:TemporaryDirectory = Join-Path $env:TEMP ('sleek-netbird-install-{0}' -f [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:TemporaryDirectory -ItemType Directory -Force | Out-Null
        $downloadedPackagePath = Join-Path $script:TemporaryDirectory $packageName

        Write-InstallerLog -Level INFO -Message "Downloading the official NetBird MSI for $($Architecture.PackageSuffix)."
        Invoke-DownloadWithRetry -Uri ([uri]$packageUrl) -Destination $downloadedPackagePath

        if (-not (Test-NetBirdSignature -Path $downloadedPackagePath)) {
            $signature = Get-AuthenticodeSignature -LiteralPath $downloadedPackagePath
            $signerSubject = '<none>'
            if ($null -ne $signature.SignerCertificate) {
                $signerSubject = $signature.SignerCertificate.Subject
            }

            throw "The downloaded NetBird MSI did not have a valid NetBird Authenticode signature. Status: $($signature.Status); subject: $signerSubject"
        }

        Write-InstallerLog -Level INFO -Message 'Verified the NetBird MSI Authenticode signature.'
        Copy-Item -LiteralPath $downloadedPackagePath -Destination $CachedMsiPath -Force
    }
    $arguments = @(
        '/i', $CachedMsiPath,
        '/quiet',
        '/norestart',
        'AUTOSTART=1',
        "MANAGEMENT_URL=$ManagementUrl",
        '/L*v', $MsiLog
    )
    Write-InstallerLog -Level INFO -Message 'Installing the signed NetBird MSI for all users.'
    Write-InstallerLog -Level INFO -Message "MSI log: $MsiLog"
    & "$env:SystemRoot\System32\msiexec.exe" @arguments
    $exitCode = $LASTEXITCODE
    Write-InstallerLog -Level INFO -Message "Windows Installer exited with code $exitCode."

    if ($exitCode -notin @(0, 3010)) {
        $logTail = '<MSI log unavailable>'
        if (Test-Path -LiteralPath $MsiLog -PathType Leaf) {
            $logTail = ((Get-Content -LiteralPath $MsiLog -Tail 30 -ErrorAction SilentlyContinue) -join [Environment]::NewLine)
        }
        throw "NetBird MSI installation failed with exit code $exitCode. MSI log: $MsiLog`nLast MSI log lines:`n$logTail"
    }

    if ($exitCode -eq 3010) {
        Write-InstallerLog -Level WARN -Message 'Windows Installer reported that a restart is required. The script will not restart the computer.'
    }
}

function Invoke-NetBirdCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CliPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [switch]$IgnoreFailure
    )

    Write-InstallerLog -Level INFO -Message $Description
    $output = & $CliPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    foreach ($line in $output) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            Add-InstallerLogLine -Line ([string]$line)
        }
    }

    if ($exitCode -ne 0 -and -not $IgnoreFailure) {
        throw "$Description failed with exit code $exitCode."
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Confirm-NetBirdInstallation {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Paths
    )

    if (-not (Test-NetBirdSignature -Path $Paths.Cli)) {
        throw "NetBird CLI is missing or has an invalid signature: $($Paths.Cli)"
    }

    if (-not (Test-NetBirdSignature -Path $Paths.Ui)) {
        throw "NetBird UI is missing or has an invalid signature: $($Paths.Ui)"
    }

    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    $versionResult = Invoke-NetBirdCommand -CliPath $Paths.Cli -Arguments @('version') -Description 'Reading the installed NetBird version'
    $versionLine = ($versionResult.Output | Select-Object -First 1)

    $uiRunValues = Get-ItemProperty -LiteralPath $UiRunRegistryPath -ErrorAction Stop
    $uiAutostartPresent = $false
    foreach ($property in $uiRunValues.PSObject.Properties) {
        if ([string]$property.Value -match '(?i)netbird-ui\.exe') {
            $uiAutostartPresent = $true
            break
        }
    }

    if (-not $uiAutostartPresent) {
        throw 'The NetBird UI all-users autostart registry entry is missing.'
    }

    Write-InstallerLog -Level INFO -Message "Verified NetBird CLI, UI, service, signatures, and all-users UI autostart."
    Write-InstallerLog -Level INFO -Message "Installed NetBird version: $versionLine"
    Write-InstallerLog -Level INFO -Message "Service status after package installation: $($service.Status)"
}

function Set-NetBirdManagedPolicy {
    New-Item -Path $PolicyRegistryPath -Force | Out-Null
    New-ItemProperty -Path $PolicyRegistryPath -Name 'ManagementURL' -PropertyType String -Value $ManagementUrl -Force | Out-Null

    $configuredUrl = (Get-ItemPropertyValue -LiteralPath $PolicyRegistryPath -Name 'ManagementURL')
    if ($configuredUrl -ne $ManagementUrl) {
        throw "The NetBird Windows policy contains the wrong management URL: $configuredUrl"
    }

    Write-InstallerLog -Level INFO -Message "Configured machine policy ManagementURL=$ManagementUrl."
}

function Set-NetBirdDefaultProfile {
    $profileDirectory = Split-Path -Parent $DefaultProfilePath
    New-Item -Path $profileDirectory -ItemType Directory -Force | Out-Null

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $service -and $service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $ServiceName -Force
        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [timespan]::FromSeconds(30))
    }

    $configuration = [PSCustomObject]@{}
    if (Test-Path -LiteralPath $DefaultProfilePath -PathType Leaf) {
        try {
            $configuration = Get-Content -LiteralPath $DefaultProfilePath -Raw | ConvertFrom-Json
        }
        catch {
            throw "The existing NetBird default profile is not valid JSON: $DefaultProfilePath"
        }
    }

    $managementProperty = $configuration.PSObject.Properties['ManagementURL']
    if ($null -eq $managementProperty) {
        $configuration | Add-Member -MemberType NoteProperty -Name 'ManagementURL' -Value $ManagementUrl
    }
    else {
        $managementProperty.Value = $ManagementUrl
    }

    $temporaryProfile = "$DefaultProfilePath.sleek.tmp"
    $configuration | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $temporaryProfile -Encoding UTF8
    Move-Item -LiteralPath $temporaryProfile -Destination $DefaultProfilePath -Force

    $verifiedConfiguration = Get-Content -LiteralPath $DefaultProfilePath -Raw | ConvertFrom-Json
    if (-not (Test-EquivalentManagementUrl -Actual ([string]$verifiedConfiguration.ManagementURL) -Expected $ManagementUrl)) {
        throw 'The NetBird default profile did not retain the required management URL.'
    }

    Write-InstallerLog -Level INFO -Message "Persisted ManagementURL=$ManagementUrl in the NetBird default profile."
}

function Repair-NetBirdService {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CliPath
    )

    Write-InstallerLog -Level WARN -Message 'NetBird service reconfiguration failed; rebuilding the service definition.'
    Invoke-NetBirdCommand -CliPath $CliPath -Arguments @('service', 'stop') -Description 'Stopping the existing NetBird service' -IgnoreFailure | Out-Null
    Invoke-NetBirdCommand -CliPath $CliPath -Arguments @('service', 'uninstall') -Description 'Removing the existing NetBird service definition' -IgnoreFailure | Out-Null
    Invoke-NetBirdCommand -CliPath $CliPath -Arguments @('service', 'install', '--management-url', $ManagementUrl) -Description 'Installing the NetBird service with the Sleek management URL' | Out-Null
    Invoke-NetBirdCommand -CliPath $CliPath -Arguments @('service', 'start') -Description 'Starting the NetBird service' | Out-Null
}

function Set-NetBirdServiceConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CliPath
    )

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Invoke-NetBirdCommand -CliPath $CliPath -Arguments @('service', 'install', '--management-url', $ManagementUrl) -Description 'Installing the NetBird service with the Sleek management URL' | Out-Null
        Invoke-NetBirdCommand -CliPath $CliPath -Arguments @('service', 'start') -Description 'Starting the NetBird service' | Out-Null
    }
    else {
        $reconfigure = Invoke-NetBirdCommand -CliPath $CliPath -Arguments @('service', 'reconfigure', '--management-url', $ManagementUrl) -Description 'Persisting the Sleek management URL in the NetBird service' -IgnoreFailure
        if ($reconfigure.ExitCode -ne 0) {
            Repair-NetBirdService -CliPath $CliPath
        }
    }

    Set-Service -Name $ServiceName -StartupType Automatic
    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
        Start-Service -Name $ServiceName
    }

    $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [timespan]::FromSeconds(30))

    $imagePath = Get-ItemPropertyValue -LiteralPath $ServiceRegistryPath -Name 'ImagePath'
    if ([string]$imagePath -notmatch [regex]::Escape($ManagementUrl)) {
        throw 'The NetBird Windows service does not contain the required management URL.'
    }

    Write-InstallerLog -Level INFO -Message 'Verified the NetBird Windows service configuration.'
}

function Install-UserProfileProvisioner {
    New-Item -Path $SleekDataDirectory -ItemType Directory -Force | Out-Null

    $provisioner = @'
#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ProfileName = 'SleekVPNTest'
$ManagementUrl = 'https://nbvpn.sleek.com'
$ProgramFilesDirectory = $env:ProgramW6432
if ([string]::IsNullOrWhiteSpace($ProgramFilesDirectory)) {
    $ProgramFilesDirectory = $env:ProgramFiles
}

$NetBirdCli = Join-Path $ProgramFilesDirectory 'NetBird\netbird.exe'
$UserLogDirectory = Join-Path $env:LOCALAPPDATA 'Sleek\NetBird'
$UserLog = Join-Path $UserLogDirectory 'profile-provision.log'

function Write-ProfileLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    New-Item -Path $UserLogDirectory -ItemType Directory -Force | Out-Null
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $encoding = New-Object System.Text.UTF8Encoding($false)
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($UserLog, $line + [Environment]::NewLine, $encoding)
            return
        }
        catch {
            if ($attempt -lt 5) {
                Start-Sleep -Milliseconds (100 * $attempt)
            }
            else {
                [Console]::Error.WriteLine("Could not append to profile log ${UserLog}: $($_.Exception.Message)")
            }
        }
    }
}

function Invoke-ProfileCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & $NetBirdCli @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "netbird $($Arguments -join ' ') failed with exit code ${exitCode}: $($output -join ' ')"
    }

    return @($output)
}

function Get-TargetProfileRows {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows
    )

    $checkMark = [string][char]0x2713
    $crossMark = [string][char]0x2717
    $profileMatches = @()

    foreach ($rowObject in $Rows) {
        $row = ([string]$rowObject).Trim()
        if (
            [string]::IsNullOrWhiteSpace($row) -or
            $row -match '^Found\s+\d+\s+profiles?:' -or
            $row -match '^(ID\s+)?NAME\s+ACTIVE$'
        ) {
            continue
        }

        $normalizedName = $row.Replace($checkMark, '').Replace($crossMark, '').Trim()
        $columns = @($normalizedName -split '\s+')

        # Stable clients print "✓ name"/"✗ name". Newer clients without
        # --show-id print "name ✓". SleekVPNTest contains no whitespace, so
        # the normalized row must be exactly that profile name.
        if ($columns.Count -eq 1 -and $columns[0] -eq $ProfileName) {
            $profileMatches += [PSCustomObject]@{
                Active = $row.Contains($checkMark)
            }
        }
    }

    return @($profileMatches)
}

function Test-ProfileManagementUrl {
    $profileFiles = @(Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'Netbird') -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($profileFile in $profileFiles) {
        try {
            $configuration = Get-Content -LiteralPath $profileFile.FullName -Raw | ConvertFrom-Json
            $isTarget = $profileFile.BaseName -eq $ProfileName -or [string]$configuration.Name -eq $ProfileName
            if ($isTarget -and ([uri][string]$configuration.ManagementURL).Host -eq ([uri]$ManagementUrl).Host) {
                return $true
            }
        }
        catch {
            # Ignore state files and transient partial reads.
        }
    }

    return $false
}

function Set-ProfileManagementUrl {
    if (Test-ProfileManagementUrl) {
        return
    }

    # NetBird v0.71.x has no direct "set profile URL" command. Its Login RPC
    # persists --management-url before waiting for SSO, so start a no-browser
    # login, wait until the daemon writes the profile, then stop only the CLI
    # waiter. This does not complete authentication or store a setup key.
    $arguments = @(
        'login',
        '--profile', $ProfileName,
        '--management-url', $ManagementUrl,
        '--no-browser'
    )
    $loginProcess = Start-Process -FilePath $NetBirdCli -ArgumentList $arguments -WindowStyle Hidden -PassThru

    try {
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            if (Test-ProfileManagementUrl) {
                return
            }

            if ($loginProcess.HasExited) {
                throw "NetBird exited before persisting the management URL (exit code $($loginProcess.ExitCode))."
            }

            Start-Sleep -Seconds 1
            $loginProcess.Refresh()
        }

        throw "NetBird did not persist $ManagementUrl in profile $ProfileName within 30 seconds."
    }
    finally {
        if (-not $loginProcess.HasExited) {
            Stop-Process -Id $loginProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    if (-not (Test-Path -LiteralPath $NetBirdCli -PathType Leaf)) {
        throw "NetBird CLI is unavailable: $NetBirdCli"
    }

    $profileRows = $null
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $profileRows = Invoke-ProfileCommand -Arguments @('profile', 'list')
            break
        }
        catch {
            if ($attempt -eq 30) {
                throw
            }
            Start-Sleep -Seconds 2
        }
    }

    $matches = @(Get-TargetProfileRows -Rows $profileRows)
    if ($matches.Count -gt 1) {
        throw "Multiple profiles named $ProfileName exist for $env:USERDOMAIN\$env:USERNAME. Remove duplicates and sign in again."
    }

    if ($matches.Count -eq 0) {
        Invoke-ProfileCommand -Arguments @('profile', 'add', $ProfileName) | Out-Null
        $profileRows = Invoke-ProfileCommand -Arguments @('profile', 'list')
        $matches = @(Get-TargetProfileRows -Rows $profileRows)
    }

    if ($matches.Count -ne 1) {
        throw "Profile $ProfileName could not be uniquely resolved after provisioning."
    }

    if (-not $matches[0].Active) {
        Invoke-ProfileCommand -Arguments @('profile', 'select', $ProfileName) | Out-Null
    }

    Set-ProfileManagementUrl

    $verifiedRows = Invoke-ProfileCommand -Arguments @('profile', 'list')
    $verifiedMatches = @(Get-TargetProfileRows -Rows $verifiedRows)
    if ($verifiedMatches.Count -ne 1 -or -not $verifiedMatches[0].Active) {
        throw "Profile $ProfileName was not active after provisioning."
    }

    if (-not (Test-ProfileManagementUrl)) {
        throw "Profile $ProfileName does not contain management URL $ManagementUrl."
    }

    Write-ProfileLog -Message "Verified active profile $ProfileName with management URL $ManagementUrl for $env:USERDOMAIN\$env:USERNAME."
    exit 0
}
catch {
    Write-ProfileLog -Message "ERROR: $($_.Exception.Message)"
    exit 1
}
'@

    Set-Content -LiteralPath $ProfileProvisionerPath -Value $provisioner -Encoding UTF8
    Set-ProtectedDirectoryAcl -Path $SleekDataDirectory -AllowUsersRead

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $runCommand = '"{0}" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $windowsPowerShell, $ProfileProvisionerPath

    New-Item -Path $UiRunRegistryPath -Force | Out-Null
    New-ItemProperty -Path $UiRunRegistryPath -Name $ProfileRunValueName -PropertyType String -Value $runCommand -Force | Out-Null

    $configuredRunCommand = Get-ItemPropertyValue -LiteralPath $UiRunRegistryPath -Name $ProfileRunValueName
    if ($configuredRunCommand -ne $runCommand) {
        throw 'The per-user NetBird profile provisioner autostart entry could not be verified.'
    }

    Write-InstallerLog -Level INFO -Message "Installed the per-user $ProfileName profile provisioner. It runs at each user sign-in."
}

function Invoke-ProfileProvisionerForCurrentUser {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User.Value -eq 'S-1-5-18') {
        Write-InstallerLog -Level INFO -Message 'Installer is running as SYSTEM; profile provisioning will run for each user at their next sign-in.'
        return
    }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-InstallerLog -Level INFO -Message "Provisioning $ProfileName immediately for $($identity.Name)."
    $process = Start-Process -FilePath $windowsPowerShell -ArgumentList @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $ProfileProvisionerPath
    ) -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        throw "Per-user profile provisioning failed with exit code $($process.ExitCode). See $env:LOCALAPPDATA\Sleek\NetBird\profile-provision.log"
    }
}

function Test-EquivalentManagementUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Actual,

        [Parameter(Mandatory = $true)]
        [string]$Expected
    )

    try {
        $actualUri = [uri]$Actual
        $expectedUri = [uri]$Expected

        return (
            $actualUri.Scheme -eq $expectedUri.Scheme -and
            $actualUri.Host -eq $expectedUri.Host -and
            $actualUri.Port -eq $expectedUri.Port -and
            $actualUri.AbsolutePath.TrimEnd('/') -eq $expectedUri.AbsolutePath.TrimEnd('/')
        )
    }
    catch {
        return $false
    }
}

function Confirm-EffectiveConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CliPath
    )

    $debugConfigSupported = $false
    $debugHelp = & $CliPath debug config --help 2>&1
    if ($LASTEXITCODE -eq 0 -and ($debugHelp -join ' ') -match 'effective configuration') {
        $debugConfigSupported = $true
    }

    if (-not $debugConfigSupported) {
        $configuration = Get-Content -LiteralPath $DefaultProfilePath -Raw | ConvertFrom-Json
        if (-not (Test-EquivalentManagementUrl -Actual ([string]$configuration.ManagementURL) -Expected $ManagementUrl)) {
            throw 'The stable NetBird client default profile contains the wrong management URL.'
        }

        Write-InstallerLog -Level INFO -Message 'Verified the stable-client management URL in default.json.'
        return
    }

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $output = & $CliPath debug config 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            try {
                $configuration = (($output -join [Environment]::NewLine) | ConvertFrom-Json)
                $managedFields = @($configuration.mDMManagedFields)

                if (
                    (Test-EquivalentManagementUrl -Actual ([string]$configuration.managementUrl) -Expected $ManagementUrl) -and
                    $managedFields -contains 'managementURL'
                ) {
                    Write-InstallerLog -Level INFO -Message "Verified the daemon's effective and MDM-managed management URL."
                    return
                }
            }
            catch {
                # The service can emit incomplete data briefly while restarting.
            }
        }

        Start-Sleep -Seconds 2
    }

    throw 'NetBird is installed, but the daemon did not report the required managed management URL.'
}

function Remove-TemporaryFiles {
    if (-not [string]::IsNullOrWhiteSpace($script:TemporaryDirectory)) {
        Remove-Item -LiteralPath $script:TemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Main {
    Invoke-Preflight
    Initialize-InstallerLog

    $architecture = Get-WindowsArchitecture
    $paths = Get-NetBirdPaths

    Write-InstallerLog -Level INFO -Message 'Starting system-wide NetBird installation for Windows.'
    Write-InstallerLog -Level INFO -Message "Required management URL: $ManagementUrl"
    Write-InstallerLog -Level INFO -Message "Architecture: $($architecture.PackageSuffix)"

    if (Test-HealthyNetBirdInstallation -Paths $paths) {
        Write-InstallerLog -Level INFO -Message 'A healthy official NetBird installation is already present; skipping package installation.'
    }
    else {
        Install-NetBirdPackage -Architecture $architecture
    }

    Confirm-NetBirdInstallation -Paths $paths
    Set-NetBirdManagedPolicy
    Set-NetBirdDefaultProfile
    Set-NetBirdServiceConfiguration -CliPath $paths.Cli
    Install-UserProfileProvisioner
    Invoke-ProfileProvisionerForCurrentUser
    Confirm-EffectiveConfiguration -CliPath $paths.Cli

    Write-InstallerLog -Level INFO -Message 'NetBird installation and configuration completed successfully.'
    Write-InstallerLog -Level INFO -Message 'All Windows users can launch NetBird and complete SSO.'
    Write-InstallerLog -Level INFO -Message "$ProfileName is created and selected in each user's context at sign-in."
    Write-InstallerLog -Level INFO -Message 'No setup key was used and no authentication was completed by this script.'
    Write-InstallerLog -Level INFO -Message "Installation log: $InstallLog"
}

try {
    Main
    exit 0
}
catch {
    Write-InstallerLog -Level ERROR -Message $_.Exception.Message
    exit 1
}
finally {
    Remove-TemporaryFiles
}
