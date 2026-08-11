#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Complete system-wide NetBird removal for Windows 10 and later.
#
# Intended execution:
#   - Run from an elevated Windows PowerShell 5.1 session.
#   - In JumpCloud, use a Windows PowerShell command and Run As: SYSTEM.
#   - Safe to run repeatedly when NetBird is already absent.
#
# WARNING:
#   This permanently deletes every NetBird profile and device identity stored
#   on this PC. Reinstalling NetBird will require a new SSO login or setup key.

$ServiceName = 'Netbird'
$PolicyRegistryPath = 'HKLM:\Software\Policies\NetBird'
$MachineRunRegistryPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
$ProfileRunValueName = 'SleekNetBirdProfileProvisioner'

$ProgramDataNetBird = Join-Path $env:ProgramData 'Netbird'
$SleekNetBirdDirectory = Join-Path $env:ProgramData 'Sleek\NetBird'
$LogDirectory = Join-Path $env:ProgramData 'Sleek\Logs'
$InstallLog = Join-Path $LogDirectory 'netbird-jumpcloud-install.log'
$MsiLog = Join-Path $LogDirectory 'netbird-msi-install.log'
$UninstallLog = Join-Path $LogDirectory 'netbird-jumpcloud-uninstall.log'
$MsiUninstallLog = Join-Path $LogDirectory 'netbird-msi-uninstall.log'
$CachedMsiPath = Join-Path $SleekNetBirdDirectory 'netbird-installer.msi'

$script:LogReady = $false
$script:FailureCount = 0
$script:RestartRequired = $false

function Write-UninstallLog {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = '[{0}] {1}: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogReady) {
        Add-Content -LiteralPath $UninstallLog -Value $line -Encoding UTF8
    }

    if ($Level -eq 'ERROR') {
        [Console]::Error.WriteLine($line)
    }
    else {
        Write-Host $line
    }
}

function Add-UninstallFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:FailureCount++
    Write-UninstallLog -Level ERROR -Message $Message
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Preflight {
    if ($env:OS -ne 'Windows_NT') {
        throw 'This uninstaller supports Windows only.'
    }

    if (-not (Test-IsAdministrator)) {
        throw 'Run this uninstaller as Administrator. In JumpCloud, set Run As to SYSTEM.'
    }

    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
    if ([version]$operatingSystem.Version -lt [version]'10.0') {
        throw "Windows 10 or later is required. Detected version: $($operatingSystem.Version)"
    }

    Get-Command msiexec.exe -ErrorAction Stop | Out-Null
    Get-Command sc.exe -ErrorAction Stop | Out-Null
}

function Initialize-UninstallLog {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    New-Item -Path $UninstallLog -ItemType File -Force | Out-Null

    $aclOutput = & "$env:SystemRoot\System32\icacls.exe" $UninstallLog '/inheritance:r' '/grant:r' '*S-1-5-18:F' '*S-1-5-32-544:F' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not secure the uninstall log. icacls output: $($aclOutput -join ' ')"
    }

    $script:LogReady = $true
}

function Remove-PathSafely {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-UninstallLog -Level INFO -Message "$Description is already absent: $Path"
        return
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force
        Write-UninstallLog -Level INFO -Message "Removed $Description`: $Path"
    }
    catch {
        Add-UninstallFailure -Message "Failed to remove $Description at '$Path': $($_.Exception.Message)"
    }
}

function Stop-NetBirdComponents {
    foreach ($processName in @('netbird-ui', 'netbird')) {
        $processes = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
        if ($processes.Count -eq 0) {
            Write-UninstallLog -Level INFO -Message "Process $processName is not running."
            continue
        }

        try {
            $processes | Stop-Process -Force
            Write-UninstallLog -Level INFO -Message "Stopped all $processName processes."
        }
        catch {
            Write-UninstallLog -Level WARN -Message "Could not stop every $processName process: $($_.Exception.Message)"
        }
    }

    $cliCandidates = @(
        (Join-Path $env:ProgramFiles 'NetBird\netbird.exe')
    )
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $cliCandidates += Join-Path ${env:ProgramFiles(x86)} 'NetBird\netbird.exe'
    }

    $cliPath = $cliCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($null -ne $cliPath) {
        foreach ($arguments in @(
            @('down'),
            @('service', 'stop'),
            @('service', 'uninstall')
        )) {
            $output = & $cliPath @arguments 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-UninstallLog -Level INFO -Message "Executed netbird $($arguments -join ' ')."
            }
            else {
                Write-UninstallLog -Level WARN -Message "netbird $($arguments -join ' ') returned exit code $LASTEXITCODE`: $($output -join ' ')"
            }
        }
    }
    else {
        Write-UninstallLog -Level INFO -Message 'NetBird CLI is absent; service fallback cleanup will be used.'
    }

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $service) {
        try {
            if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                Stop-Service -Name $ServiceName -Force
                $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [timespan]::FromSeconds(30))
            }
        }
        catch {
            Write-UninstallLog -Level WARN -Message "Could not stop the NetBird service cleanly: $($_.Exception.Message)"
        }

        $output = & "$env:SystemRoot\System32\sc.exe" delete $ServiceName 2>&1
        if ($LASTEXITCODE -notin @(0, 1060)) {
            Write-UninstallLog -Level WARN -Message "sc.exe delete returned exit code $LASTEXITCODE`: $($output -join ' ')"
        }
    }
}

function Get-NetBirdMsiProducts {
    $registryRoots = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $products = foreach ($registryRoot in $registryRoots) {
        Get-ItemProperty -Path $registryRoot -ErrorAction SilentlyContinue |
            Where-Object {
                [string]$_.DisplayName -match '(?i)^NetBird(?:\s|$)'
            } |
            ForEach-Object {
                [PSCustomObject]@{
                    DisplayName = [string]$_.DisplayName
                    ProductCode = [string]$_.PSChildName
                }
            }
    }

    return @($products | Sort-Object ProductCode -Unique)
}

function Uninstall-NetBirdMsi {
    if (Test-Path -LiteralPath $CachedMsiPath -PathType Leaf) {
        $signature = Get-AuthenticodeSignature -LiteralPath $CachedMsiPath
        if (
            $signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid -and
            $null -ne $signature.SignerCertificate -and
            $signature.SignerCertificate.Subject -match '(?i)NetBird'
        ) {
            Write-UninstallLog -Level INFO -Message "Uninstalling NetBird with the signed MSI retained during installation: $CachedMsiPath"
            $arguments = @(
                '/x', $CachedMsiPath,
                '/quiet',
                '/norestart',
                '/L*v', $MsiUninstallLog
            )
            & "$env:SystemRoot\System32\msiexec.exe" @arguments
            $exitCode = $LASTEXITCODE
            Write-UninstallLog -Level INFO -Message "Windows Installer MSI-file uninstall exited with code $exitCode."

            if ($exitCode -eq 3010) {
                $script:RestartRequired = $true
            }
            elseif ($exitCode -notin @(0, 1605, 1614)) {
                Write-UninstallLog -Level WARN -Message "MSI-file uninstall failed with exit code $exitCode; falling back to the registered product code."
            }
        }
        else {
            Write-UninstallLog -Level WARN -Message 'The retained NetBird MSI signature is invalid; it will not be executed. Falling back to the registered product code.'
        }
    }
    else {
        Write-UninstallLog -Level INFO -Message 'The retained NetBird MSI is absent; using the registered MSI product code.'
    }

    $products = @(Get-NetBirdMsiProducts)
    if ($products.Count -eq 0) {
        Write-UninstallLog -Level INFO -Message 'No NetBird MSI registration was found.'
        return
    }

    foreach ($product in $products) {
        if ($product.ProductCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
            Add-UninstallFailure -Message "NetBird uninstall entry has an unexpected product code: $($product.ProductCode)"
            continue
        }

        Write-UninstallLog -Level INFO -Message "Uninstalling $($product.DisplayName) ($($product.ProductCode))."
        $arguments = @(
            '/x', $product.ProductCode,
            '/quiet',
            '/norestart',
            '/L*v', $MsiUninstallLog
        )
        & "$env:SystemRoot\System32\msiexec.exe" @arguments
        $exitCode = $LASTEXITCODE

        if ($exitCode -notin @(0, 1605, 1614, 3010)) {
            Add-UninstallFailure -Message "NetBird MSI uninstall failed with exit code $exitCode. See $MsiUninstallLog"
        }
        elseif ($exitCode -eq 3010) {
            $script:RestartRequired = $true
            Write-UninstallLog -Level WARN -Message 'Windows Installer reported that a restart is required.'
        }
    }
}

function Remove-RegistryArtifacts {
    try {
        if (Test-Path -LiteralPath $PolicyRegistryPath) {
            Remove-Item -LiteralPath $PolicyRegistryPath -Recurse -Force
            Write-UninstallLog -Level INFO -Message "Removed NetBird machine policy: $PolicyRegistryPath"
        }
    }
    catch {
        Add-UninstallFailure -Message "Failed to remove NetBird machine policy: $($_.Exception.Message)"
    }

    if (Test-Path -LiteralPath $MachineRunRegistryPath) {
        try {
            Remove-ItemProperty -LiteralPath $MachineRunRegistryPath -Name $ProfileRunValueName -Force -ErrorAction SilentlyContinue

            $runValues = Get-ItemProperty -LiteralPath $MachineRunRegistryPath
            foreach ($property in $runValues.PSObject.Properties) {
                if ([string]$property.Value -match '(?i)netbird-ui\.exe') {
                    Remove-ItemProperty -LiteralPath $MachineRunRegistryPath -Name $property.Name -Force
                    Write-UninstallLog -Level INFO -Message "Removed NetBird machine autostart value: $($property.Name)"
                }
            }
        }
        catch {
            Add-UninstallFailure -Message "Failed to remove a NetBird machine autostart value: $($_.Exception.Message)"
        }
    }
}

function Get-LocalUserProfiles {
    return @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
        Where-Object {
            -not $_.Special -and
            -not [string]::IsNullOrWhiteSpace([string]$_.LocalPath) -and
            [string]$_.LocalPath -ne [string]$env:SystemRoot
        })
}

function Remove-NetBirdFromUserRegistryHive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HiveName
    )

    $hiveRoot = "Registry::HKEY_USERS\$HiveName"
    foreach ($keyPath in @(
        "$hiveRoot\Software\NetBird",
        "$hiveRoot\Software\io.netbird.client"
    )) {
        if (Test-Path -LiteralPath $keyPath) {
            Remove-Item -LiteralPath $keyPath -Recurse -Force
            Write-UninstallLog -Level INFO -Message "Removed user NetBird registry key: $keyPath"
        }
    }

    $runPath = "$hiveRoot\Software\Microsoft\Windows\CurrentVersion\Run"
    if (Test-Path -LiteralPath $runPath) {
        $runValues = Get-ItemProperty -LiteralPath $runPath
        foreach ($property in $runValues.PSObject.Properties) {
            if ([string]$property.Value -match '(?i)netbird(?:-ui)?\.exe') {
                Remove-ItemProperty -LiteralPath $runPath -Name $property.Name -Force
                Write-UninstallLog -Level INFO -Message "Removed user NetBird autostart value $($property.Name) from $HiveName."
            }
        }
    }
}

function Remove-NetBirdUserRegistryData {
    param(
        [Parameter(Mandatory = $true)]
        [object]$UserProfile
    )

    $sid = [string]$UserProfile.SID
    if ([string]::IsNullOrWhiteSpace($sid)) {
        return
    }

    $loadedHivePath = "Registry::HKEY_USERS\$sid"
    if (Test-Path -LiteralPath $loadedHivePath) {
        try {
            Remove-NetBirdFromUserRegistryHive -HiveName $sid
        }
        catch {
            Add-UninstallFailure -Message "Failed to clean NetBird registry data for SID $sid`: $($_.Exception.Message)"
        }
        return
    }

    $ntUserPath = Join-Path ([string]$UserProfile.LocalPath) 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $ntUserPath -PathType Leaf)) {
        Write-UninstallLog -Level INFO -Message "No offline registry hive exists for SID $sid."
        return
    }

    $temporaryHiveName = 'SleekNetBirdCleanup_{0}' -f [guid]::NewGuid().ToString('N')
    $loadOutput = & "$env:SystemRoot\System32\reg.exe" load "HKU\$temporaryHiveName" $ntUserPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        Add-UninstallFailure -Message "Could not load the registry hive for SID $sid`: $($loadOutput -join ' ')"
        return
    }

    try {
        Remove-NetBirdFromUserRegistryHive -HiveName $temporaryHiveName
    }
    catch {
        Add-UninstallFailure -Message "Failed to clean the offline NetBird registry data for SID $sid`: $($_.Exception.Message)"
    }
    finally {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        $unloadOutput = & "$env:SystemRoot\System32\reg.exe" unload "HKU\$temporaryHiveName" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Add-UninstallFailure -Message "Could not unload the temporary registry hive for SID $sid`: $($unloadOutput -join ' ')"
        }
    }
}

function Remove-AllUserData {
    try {
        $userProfiles = @(Get-LocalUserProfiles)
    }
    catch {
        Add-UninstallFailure -Message "Could not enumerate Windows user profiles: $($_.Exception.Message)"
        return
    }

    foreach ($userProfile in $userProfiles) {
        $home = [string]$userProfile.LocalPath
        if ([string]::IsNullOrWhiteSpace($home) -or $home -eq '\' -or $home -eq '/') {
            Write-UninstallLog -Level WARN -Message "Skipped unsafe user profile path for SID $($userProfile.SID)."
            continue
        }

        Remove-NetBirdUserRegistryData -UserProfile $userProfile

        foreach ($relativePath in @(
            'AppData\Local\NetBird',
            'AppData\Local\netbird',
            'AppData\Roaming\NetBird',
            'AppData\Roaming\netbird',
            'AppData\Local\Sleek\NetBird',
            '.config\netbird'
        )) {
            Remove-PathSafely -Path (Join-Path $home $relativePath) -Description "NetBird user data for SID $($userProfile.SID)"
        }
    }
}

function Remove-NetBirdArtifacts {
    Remove-RegistryArtifacts
    Remove-AllUserData

    Remove-PathSafely -Path $ProgramDataNetBird -Description 'NetBird profiles and device state'
    Remove-PathSafely -Path $SleekNetBirdDirectory -Description 'Sleek NetBird provisioning data'
    Remove-PathSafely -Path $InstallLog -Description 'NetBird installation log'
    Remove-PathSafely -Path $MsiLog -Description 'NetBird MSI installation log'

    foreach ($programDirectory in @(
        (Join-Path $env:ProgramFiles 'NetBird'),
        $(if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) { Join-Path ${env:ProgramFiles(x86)} 'NetBird' })
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$programDirectory)) {
            Remove-PathSafely -Path $programDirectory -Description 'NetBird application directory'
        }
    }

    if (Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName") {
        try {
            Remove-Item -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -Recurse -Force
            Write-UninstallLog -Level INFO -Message 'Removed the remaining NetBird service registry key.'
        }
        catch {
            Add-UninstallFailure -Message "Failed to remove the remaining NetBird service registry key: $($_.Exception.Message)"
        }
    }
}

function Confirm-NetBirdRemoved {
    foreach ($processName in @('netbird-ui', 'netbird')) {
        if ($null -ne (Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
            Add-UninstallFailure -Message "A $processName process remains after cleanup."
        }
    }

    if ($null -ne (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
        Add-UninstallFailure -Message 'The NetBird Windows service remains after cleanup.'
    }

    if (@(Get-NetBirdMsiProducts).Count -ne 0) {
        Add-UninstallFailure -Message 'A NetBird MSI registration remains after cleanup.'
    }

    foreach ($path in @($ProgramDataNetBird, $SleekNetBirdDirectory, (Join-Path $env:ProgramFiles 'NetBird'))) {
        if (Test-Path -LiteralPath $path) {
            Add-UninstallFailure -Message "A NetBird artifact remains after cleanup: $path"
        }
    }

    if (Test-Path -LiteralPath $PolicyRegistryPath) {
        Add-UninstallFailure -Message "The NetBird machine policy remains after cleanup: $PolicyRegistryPath"
    }
}

function Main {
    Invoke-Preflight
    Initialize-UninstallLog

    Write-UninstallLog -Level INFO -Message 'Starting complete NetBird uninstallation for Windows.'
    Write-UninstallLog -Level WARN -Message 'All NetBird profiles, enrollment state, and user UI data will be deleted.'

    Stop-NetBirdComponents
    Uninstall-NetBirdMsi
    Stop-NetBirdComponents
    Remove-NetBirdArtifacts
    Confirm-NetBirdRemoved

    if ($script:FailureCount -ne 0) {
        Write-UninstallLog -Level ERROR -Message "NetBird uninstallation completed with $($script:FailureCount) unresolved issue(s)."
        Write-UninstallLog -Level ERROR -Message "Review the log: $UninstallLog"
        exit 1
    }

    Write-UninstallLog -Level INFO -Message 'NetBird was completely removed from this Windows PC.'
    if ($script:RestartRequired) {
        Write-UninstallLog -Level WARN -Message 'Restart Windows to complete removal of files held by the installer.'
    }
    Write-UninstallLog -Level INFO -Message "Uninstallation log: $UninstallLog"
}

try {
    Main
    exit 0
}
catch {
    Write-UninstallLog -Level ERROR -Message $_.Exception.Message
    exit 1
}
