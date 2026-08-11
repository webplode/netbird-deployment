#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [AllowEmptyString()]
    [string]$ManagementUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Exit categories: 0 success; 2 URL/invocation; 3 platform/privilege;
# 4 matching-install prerequisite; 5 persistence/service; 6 runtime/effective.

$PolicyRegistryPath = 'HKLM:\Software\Policies\NetBird'
$ServiceRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Netbird'
$UiRunRegistryPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
$ProfileRunValueName = 'SleekNetBirdProfileProvisioner'
$ServiceName = 'Netbird'
$ProfileProvisionerPath = Join-Path $env:ProgramData 'Sleek\NetBird\provision-netbird-profile.ps1'
$DefaultProfilePath = Join-Path $env:ProgramData 'Netbird\default.json'
Set-Variable -Name ProvisionerAssignmentPattern -Scope Script -Option ReadOnly -Value '(?m)^(?<Prefix>[ \t]*\$ManagementUrl[ \t]*=[ \t]*)(?:(?<Single>'')(?<SingleValue>(?:''''|[^''\r\n])*)''|(?<Double>")(?<DoubleValue>(?:""|[^"\r\n])*)")(?<Suffix>[ \t]*(?:#.*)?)$'
$script:RuntimeCommitted = $false
$script:PersistenceTouched = $false
$script:Snapshots = $null

if (-not ('Sleek.NetBirdNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Sleek
{
    public sealed class CommandLineTokenSpan
    {
        public string Value { get; set; }
        public int Start { get; set; }
        public int Length { get; set; }
    }

    public static class NetBirdNative
    {
        private const uint SC_MANAGER_CONNECT = 0x0001;
        private const uint SERVICE_CHANGE_CONFIG = 0x0002;
        private const uint SERVICE_NO_CHANGE = 0xFFFFFFFF;

        [DllImport("shell32.dll", ExactSpelling = true, SetLastError = true)]
        private static extern IntPtr CommandLineToArgvW(
            [MarshalAs(UnmanagedType.LPWStr)] string commandLine,
            out int argumentCount);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern IntPtr OpenSCManagerW(
            string machineName,
            string databaseName,
            uint desiredAccess);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern IntPtr OpenServiceW(
            IntPtr serviceControlManager,
            string serviceName,
            uint desiredAccess);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ChangeServiceConfigW(
            IntPtr service,
            uint serviceType,
            uint startType,
            uint errorControl,
            string binaryPathName,
            string loadOrderGroup,
            IntPtr tagIdentifier,
            string dependencies,
            string serviceStartName,
            string password,
            string displayName);

        [DllImport("advapi32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseServiceHandle(IntPtr handle);

        public static string[] SplitCommandLine(string commandLine)
        {
            int count;
            IntPtr arguments = CommandLineToArgvW(commandLine, out count);
            if (arguments == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CommandLineToArgvW failed.");
            }

            try
            {
                string[] result = new string[count];
                for (int index = 0; index < count; index++)
                {
                    IntPtr item = Marshal.ReadIntPtr(arguments, index * IntPtr.Size);
                    result[index] = Marshal.PtrToStringUni(item);
                }
                return result;
            }
            finally
            {
                LocalFree(arguments);
            }
        }

        public static CommandLineTokenSpan[] ParseTokenSpans(string commandLine)
        {
            List<CommandLineTokenSpan> result = new List<CommandLineTokenSpan>();
            int position = 0;

            while (position < commandLine.Length)
            {
                while (position < commandLine.Length &&
                       (commandLine[position] == ' ' || commandLine[position] == '\t'))
                {
                    position++;
                }
                if (position >= commandLine.Length)
                {
                    break;
                }

                int start = position;
                bool inQuotes = false;
                StringBuilder value = new StringBuilder();

                while (position < commandLine.Length)
                {
                    if (!inQuotes &&
                        (commandLine[position] == ' ' || commandLine[position] == '\t'))
                    {
                        break;
                    }

                    int backslashCount = 0;
                    while (position < commandLine.Length && commandLine[position] == '\\')
                    {
                        backslashCount++;
                        position++;
                    }

                    if (position < commandLine.Length && commandLine[position] == '"')
                    {
                        value.Append('\\', backslashCount / 2);
                        if ((backslashCount % 2) == 1)
                        {
                            value.Append('"');
                            position++;
                        }
                        else if (inQuotes && position + 1 < commandLine.Length &&
                                 commandLine[position + 1] == '"')
                        {
                            value.Append('"');
                            position += 2;
                        }
                        else
                        {
                            inQuotes = !inQuotes;
                            position++;
                        }
                        continue;
                    }

                    value.Append('\\', backslashCount);
                    if (position < commandLine.Length)
                    {
                        value.Append(commandLine[position]);
                        position++;
                    }
                }

                if (inQuotes)
                {
                    throw new FormatException("The command line contains an unterminated quoted token.");
                }

                result.Add(new CommandLineTokenSpan
                {
                    Value = value.ToString(),
                    Start = start,
                    Length = position - start
                });
            }

            return result.ToArray();
        }

        public static void SetServiceBinaryPath(string serviceName, string binaryPath)
        {
            IntPtr manager = OpenSCManagerW(null, null, SC_MANAGER_CONNECT);
            if (manager == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenSCManagerW failed.");
            }

            try
            {
                IntPtr service = OpenServiceW(manager, serviceName, SERVICE_CHANGE_CONFIG);
                if (service == IntPtr.Zero)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenServiceW failed.");
                }

                try
                {
                    bool changed = ChangeServiceConfigW(
                        service,
                        SERVICE_NO_CHANGE,
                        SERVICE_NO_CHANGE,
                        SERVICE_NO_CHANGE,
                        binaryPath,
                        null,
                        IntPtr.Zero,
                        null,
                        null,
                        null,
                        null);
                    if (!changed)
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "ChangeServiceConfigW failed.");
                    }
                }
                finally
                {
                    CloseServiceHandle(service);
                }
            }
            finally
            {
                CloseServiceHandle(manager);
            }
        }
    }
}
'@
}

function Write-Status {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Throw-StageError {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(2, 6)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $exception = New-Object System.InvalidOperationException("${Stage}: $Message")
    $exception.Data['ExitCode'] = $ExitCode
    throw $exception
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
    }
}

function ConvertTo-NormalizedManagementUrl {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -ne $Value.Trim() -or $Value -match '\s' -or $Value -match '%(?![0-9A-Fa-f]{2})') {
        Throw-StageError -ExitCode 2 -Stage 'invocation/URL' -Message 'Provide one absolute HTTPS management URL without surrounding or embedded whitespace.'
    }

    $uri = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or
        [string]::IsNullOrWhiteSpace($uri.Host) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or
        -not (Test-WellFormedBracketedIpv6 -Value $Value)) {
        Throw-StageError -ExitCode 2 -Stage 'invocation/URL' -Message "The management URL must be an absolute HTTPS URL with a host: $Value"
    }

    try { $null = $uri.Port }
    catch { Throw-StageError -ExitCode 2 -Stage 'invocation/URL' -Message "The management URL contains an invalid port: $Value" }

    $builder = New-Object UriBuilder($uri)
    $builder.Scheme = 'https'
    $builder.Host = $uri.Host.ToLowerInvariant()
    if ($builder.Path.Length -gt 1) {
        $builder.Path = $builder.Path.TrimEnd('/')
    }

    $normalized = $builder.Uri.AbsoluteUri
    if ($builder.Uri.AbsolutePath -ceq '/') {
        $queryIndex = $normalized.IndexOf('?')
        $rootSlashIndex = if ($queryIndex -ge 0) { $queryIndex - 1 } else { $normalized.Length - 1 }
        if ($rootSlashIndex -ge 0 -and $normalized[$rootSlashIndex] -eq '/') {
            $normalized = $normalized.Remove($rootSlashIndex, 1)
        }
    }
    return $normalized
}

function Test-WellFormedBracketedIpv6 {
    param([Parameter(Mandatory = $true)][string]$Value)

    $authorityMatch = [regex]::Match($Value, '(?i)^https://(?<Authority>[^/?#]+)')
    if (-not $authorityMatch.Success) { return $false }
    $authority = $authorityMatch.Groups['Authority'].Value
    if ($authority.IndexOf('[') -lt 0 -and $authority.IndexOf(']') -lt 0) { return $true }

    $bracketMatch = [regex]::Match($authority, '^\[(?<Address>[^\]]+)\](?::[0-9]+)?$')
    if (-not $bracketMatch.Success) { return $false }
    $address = $null
    if (-not [Net.IPAddress]::TryParse($bracketMatch.Groups['Address'].Value, [ref]$address)) { return $false }
    return $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6
}

function Test-ComparableManagementUri {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -ne $Value.Trim() -or $Value -match '\s' -or $Value -match '%(?![0-9A-Fa-f]{2})') { return $false }
    $uri = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -ine 'https' -or [string]::IsNullOrWhiteSpace($uri.Host) -or -not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Fragment)) { return $false }
    if (-not (Test-WellFormedBracketedIpv6 -Value $Value)) { return $false }
    try { $null = $uri.Port }
    catch { return $false }
    return $true
}

function Test-EquivalentManagementUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    try {
        if (-not (Test-ComparableManagementUri -Value $Actual) -or -not (Test-ComparableManagementUri -Value $Expected)) { return $false }
        $actualUri = [uri]$Actual
        $expectedUri = [uri]$Expected
        $actualPath = $actualUri.AbsolutePath.TrimEnd('/')
        $expectedPath = $expectedUri.AbsolutePath.TrimEnd('/')
        $actualQuery = $actualUri.Query
        $expectedQuery = $expectedUri.Query
        return (
            $actualUri.IsAbsoluteUri -and
            $expectedUri.IsAbsoluteUri -and
            $actualUri.Scheme -ieq $expectedUri.Scheme -and
            $actualUri.Host -ieq $expectedUri.Host -and
            $actualUri.Port -eq $expectedUri.Port -and
            $actualPath -ceq $expectedPath -and
            $actualQuery -ceq $expectedQuery
        )
    }
    catch {
        return $false
    }
}

function Get-AclSddl {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-Acl -LiteralPath $Path).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
}

function Get-TextFileState {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = 0
    $encoding = $null
    $preamble = [byte[]]@()

    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        $encoding = New-Object Text.UTF32Encoding($true, $false, $true)
        $offset = 4
    }
    elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
        $encoding = New-Object Text.UTF32Encoding($false, $false, $true)
        $offset = 4
    }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object Text.UTF8Encoding($false, $true)
        $offset = 3
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object Text.UnicodeEncoding($true, $false, $true)
        $offset = 2
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object Text.UnicodeEncoding($false, $false, $true)
        $offset = 2
    }
    else {
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        try {
            $null = $utf8.GetString($bytes)
            $encoding = $utf8
        }
        catch {
            $encoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
        }
    }

    if ($offset -gt 0) {
        $preamble = New-Object byte[] $offset
        [Array]::Copy($bytes, 0, $preamble, 0, $offset)
    }

    $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    $newlineMatches = [regex]::Matches($text, '\r\n|\r|\n')
    $newlineKinds = @($newlineMatches | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($newlineKinds.Count -gt 1) {
        Throw-StageError -ExitCode 4 -Stage 'prerequisite' -Message "Text file uses mixed newline conventions and cannot be changed safely: $Path"
    }

    $newline = [Environment]::NewLine
    if ($newlineKinds.Count -eq 1) {
        $newline = $newlineKinds[0]
    }

    return [PSCustomObject]@{
        Path = $Path
        Bytes = $bytes
        Text = $text
        Encoding = $encoding
        CodePage = $encoding.CodePage
        Preamble = $preamble
        HasBom = ($offset -gt 0)
        Newline = $newline
        Sddl = Get-AclSddl -Path $Path
        Acl = Get-Acl -LiteralPath $Path
    }
}

function Convert-TextToBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][PSCustomObject]$State
    )

    $body = $State.Encoding.GetBytes($Text)
    if (-not $State.HasBom) {
        return $body
    }

    $result = New-Object byte[] ($State.Preamble.Length + $body.Length)
    [Array]::Copy($State.Preamble, 0, $result, 0, $State.Preamble.Length)
    [Array]::Copy($body, 0, $result, $State.Preamble.Length, $body.Length)
    return $result
}

function Write-AtomicTextFile {
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$State,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $directory = Split-Path -Parent $State.Path
    $temporary = Join-Path $directory ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($State.Path)), [guid]::NewGuid().ToString('N'))
    $backup = Join-Path $directory ('.{0}.{1}.bak' -f ([IO.Path]::GetFileName($State.Path)), [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllBytes($temporary, (Convert-TextToBytes -Text $Text -State $State))
        Set-Acl -LiteralPath $temporary -AclObject $State.Acl
        if ((Get-AclSddl -Path $temporary) -ne $State.Sddl) {
            throw "Could not preserve the ACL on staged file '$($State.Path)'."
        }
        [IO.File]::Replace($temporary, $State.Path, $backup, $true)
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }

    $verified = Get-TextFileState -Path $State.Path
    if ($verified.CodePage -ne $State.CodePage -or $verified.HasBom -ne $State.HasBom -or $verified.Newline -ne $State.Newline -or $verified.Sddl -ne $State.Sddl) {
        throw "Encoding, BOM, newline, or ACL preservation failed for '$($State.Path)'."
    }
}

function Restore-TextFileState {
    param([Parameter(Mandatory = $true)][PSCustomObject]$State)

    $directory = Split-Path -Parent $State.Path
    $temporary = Join-Path $directory ('.{0}.{1}.restore' -f ([IO.Path]::GetFileName($State.Path)), [guid]::NewGuid().ToString('N'))
    $backup = "$temporary.bak"
    try {
        [IO.File]::WriteAllBytes($temporary, $State.Bytes)
        Set-Acl -LiteralPath $temporary -AclObject $State.Acl
        [IO.File]::Replace($temporary, $State.Path, $backup, $true)
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }

    $actual = [IO.File]::ReadAllBytes($State.Path)
    if (-not (Test-ByteArrayEqual -Left $actual -Right $State.Bytes) -or (Get-AclSddl -Path $State.Path) -ne $State.Sddl) {
        throw "Rollback verification failed for '$($State.Path)'."
    }
}

function Test-ByteArrayEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Get-ServiceSnapshot {
    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
    $registryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services\Netbird')
    if ($null -eq $registryKey) { throw 'The NetBird service registry key is unavailable.' }
    try {
        $values = @()
        foreach ($name in $registryKey.GetValueNames()) {
            $values += [PSCustomObject]@{
                Name = $name
                Kind = [string]$registryKey.GetValueKind($name)
                Value = $registryKey.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        }
    }
    finally {
        $registryKey.Dispose()
    }

    $sddlOutput = & "$env:SystemRoot\System32\sc.exe" sdshow $ServiceName 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not capture the service security descriptor: $($sddlOutput -join ' ')" }
    $sddl = @($sddlOutput | Where-Object { ([string]$_).Trim() -match '^[DOGS]:' } | ForEach-Object { ([string]$_).Trim() })
    if ($sddl.Count -ne 1) { throw 'Could not uniquely capture the NetBird service security descriptor.' }

    return [PSCustomObject]@{
        ImagePath = [string](Get-ItemPropertyValue -LiteralPath $ServiceRegistryPath -Name ImagePath)
        Status = [string]$service.Status
        StartMode = [string]$cim.StartMode
        StartName = [string]$cim.StartName
        Description = [string]$cim.Description
        Dependencies = @($service.ServicesDependedOn | ForEach-Object { $_.Name } | Sort-Object)
        Dependents = @($service.DependentServices | ForEach-Object { $_.Name } | Sort-Object)
        RegistryValues = $values
        Sddl = $sddl[0]
    }
}

function Test-ObjectValueEqual {
    param($Left, $Right)
    if ($Left -is [byte[]] -and $Right -is [byte[]]) { return Test-ByteArrayEqual -Left $Left -Right $Right }
    if ($Left -is [array] -or $Right -is [array]) {
        $leftArray = @($Left); $rightArray = @($Right)
        if ($leftArray.Count -ne $rightArray.Count) { return $false }
        for ($i = 0; $i -lt $leftArray.Count; $i++) {
            if ([string]$leftArray[$i] -cne [string]$rightArray[$i]) { return $false }
        }
        return $true
    }
    return [string]$Left -ceq [string]$Right
}

function Get-PolicySnapshot {
    $registryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('Software\Policies\NetBird')
    if ($null -eq $registryKey) { throw 'The NetBird policy registry key is unavailable.' }
    try {
        $managementValue = $registryKey.GetValue('ManagementURL', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $managementKind = [string]$registryKey.GetValueKind('ManagementURL')
        $siblingValues = @()
        foreach ($name in @($registryKey.GetValueNames() | Where-Object { $_ -cne 'ManagementURL' } | Sort-Object)) {
            $siblingValues += [PSCustomObject]@{
                Name = $name
                Kind = [string]$registryKey.GetValueKind($name)
                Value = $registryKey.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        }
        $subkeyNames = @($registryKey.GetSubKeyNames() | Sort-Object)
    }
    finally {
        $registryKey.Dispose()
    }

    return [PSCustomObject]@{
        ManagementValue = $managementValue
        ManagementKind = $managementKind
        SiblingValues = $siblingValues
        SubkeyNames = $subkeyNames
    }
}

function Confirm-PolicySurfacePreserved {
    param([Parameter(Mandatory = $true)][PSCustomObject]$PolicySnapshot)

    $current = Get-PolicySnapshot
    if (-not (Test-ObjectValueEqual -Left $PolicySnapshot.SubkeyNames -Right $current.SubkeyNames)) {
        throw 'NetBird policy immediate subkey names changed unexpectedly.'
    }
    if ($PolicySnapshot.SiblingValues.Count -ne $current.SiblingValues.Count) {
        throw 'NetBird policy sibling value count changed unexpectedly.'
    }
    foreach ($beforeValue in $PolicySnapshot.SiblingValues) {
        $afterValue = @($current.SiblingValues | Where-Object { $_.Name -ceq $beforeValue.Name })
        if ($afterValue.Count -ne 1 -or $afterValue[0].Kind -cne $beforeValue.Kind -or -not (Test-ObjectValueEqual -Left $beforeValue.Value -Right $afterValue[0].Value)) {
            throw "NetBird policy sibling value changed unexpectedly: $($beforeValue.Name)"
        }
    }
}

function Get-RunRegistrySnapshot {
    $registryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    if ($null -eq $registryKey) { throw 'The machine Run registry key is unavailable.' }
    try {
        $values = @()
        foreach ($name in @($registryKey.GetValueNames() | Sort-Object)) {
            $values += [PSCustomObject]@{
                Name = $name
                Kind = [string]$registryKey.GetValueKind($name)
                Value = $registryKey.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        }
    }
    finally {
        $registryKey.Dispose()
    }
    return [PSCustomObject]@{ Values = $values }
}

function Confirm-RunRegistryPreserved {
    param([Parameter(Mandatory = $true)][PSCustomObject]$Snapshot)

    $current = Get-RunRegistrySnapshot
    if ($Snapshot.Values.Count -ne $current.Values.Count) { throw 'The machine Run registry value count changed unexpectedly.' }
    foreach ($beforeValue in $Snapshot.Values) {
        $afterValue = @($current.Values | Where-Object { $_.Name -ceq $beforeValue.Name })
        if ($afterValue.Count -ne 1 -or $afterValue[0].Kind -cne $beforeValue.Kind -or -not (Test-ObjectValueEqual -Left $beforeValue.Value -Right $afterValue[0].Value)) {
            throw "The machine Run registry value changed unexpectedly: $($beforeValue.Name)"
        }
    }
}

function Confirm-ServiceMetadataPreserved {
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$Before,
        [switch]$AllowImagePathChange
    )

    $after = Get-ServiceSnapshot
    foreach ($property in @('StartMode', 'StartName', 'Description', 'Dependencies', 'Dependents', 'Sddl')) {
        if (-not (Test-ObjectValueEqual -Left $Before.$property -Right $after.$property)) {
            throw "NetBird service metadata changed unexpectedly: $property"
        }
    }

    $beforeValues = @($Before.RegistryValues | Where-Object { -not ($AllowImagePathChange -and $_.Name -eq 'ImagePath') })
    $afterValues = @($after.RegistryValues | Where-Object { -not ($AllowImagePathChange -and $_.Name -eq 'ImagePath') })
    if ($beforeValues.Count -ne $afterValues.Count) { throw 'NetBird service registry metadata value count changed unexpectedly.' }
    foreach ($beforeValue in $beforeValues) {
        $afterValue = @($afterValues | Where-Object { $_.Name -ceq $beforeValue.Name })
        if ($afterValue.Count -ne 1 -or $afterValue[0].Kind -cne $beforeValue.Kind -or -not (Test-ObjectValueEqual -Left $beforeValue.Value -Right $afterValue[0].Value)) {
            throw "NetBird service registry metadata changed unexpectedly: $($beforeValue.Name)"
        }
    }
}

function Restore-ServiceSnapshot {
    param([Parameter(Mandatory = $true)][PSCustomObject]$Snapshot)

    Set-ServiceImagePathExact -ImagePath $Snapshot.ImagePath
    $registryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services\Netbird', $true)
    if ($null -eq $registryKey) { throw 'The NetBird service registry key is unavailable during rollback.' }
    try {
        $snapshotNames = @($Snapshot.RegistryValues | ForEach-Object { $_.Name })
        foreach ($currentName in $registryKey.GetValueNames()) {
            if ($snapshotNames -cnotcontains $currentName) { $registryKey.DeleteValue($currentName, $false) }
        }
        foreach ($value in $Snapshot.RegistryValues) {
            if ($value.Name -ceq 'ImagePath') { continue }
            $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind], $value.Kind)
            $registryKey.SetValue($value.Name, $value.Value, $kind)
        }
    }
    finally {
        $registryKey.Dispose()
    }

    $sddlOutput = & "$env:SystemRoot\System32\sc.exe" sdset $ServiceName $Snapshot.Sddl 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not restore the service security descriptor: $($sddlOutput -join ' ')" }
    Confirm-ServiceMetadataPreserved -Before $Snapshot
}

function Get-WindowsCommandLineState {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine
    )

    if ([string]::IsNullOrEmpty($CommandLine) -or $CommandLine -match '^\s' -or $CommandLine.IndexOf([char]0) -ge 0) {
        throw 'The service ImagePath is empty, begins with whitespace, or contains NUL.'
    }

    $arguments = @([Sleek.NetBirdNative]::SplitCommandLine($CommandLine))
    $spans = @([Sleek.NetBirdNative]::ParseTokenSpans($CommandLine))
    if ($arguments.Count -ne $spans.Count -or $arguments.Count -eq 0) {
        throw 'Native argv and token-span parsing produced different argument counts.'
    }
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        if ([string]$arguments[$index] -cne [string]$spans[$index].Value) {
            throw "Native argv and token-span parsing disagree at argument $index."
        }
    }

    return [PSCustomObject]@{
        CommandLine = $CommandLine
        Arguments = $arguments
        Spans = $spans
    }
}

function Get-CanonicalServiceCommandState {
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [Parameter(Mandatory = $true)][string]$CliPath
    )

    $state = Get-WindowsCommandLineState -CommandLine $ImagePath
    if ($state.Arguments.Count -lt 5 -or
        -not [string]::Equals([string]$state.Arguments[0], $CliPath, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$state.Arguments[1] -cne 'service' -or
        [string]$state.Arguments[2] -cne 'run') {
        throw 'The NetBird service ImagePath is not the canonical installed CLI service run command.'
    }

    $managementFlags = @()
    for ($index = 0; $index -lt $state.Arguments.Count; $index++) {
        $argument = [string]$state.Arguments[$index]
        if ($argument -ceq '--management-url') {
            $managementFlags += $index
        }
        elseif ($argument.StartsWith('--management-url=', [StringComparison]::Ordinal)) {
            throw 'The canonical service command must use the separate management URL flag/value form.'
        }
    }
    if ($managementFlags.Count -ne 1 -or $managementFlags[0] + 1 -ge $state.Arguments.Count) {
        throw 'The canonical service command must contain exactly one management URL flag with one value.'
    }

    $urlIndex = $managementFlags[0] + 1
    if (-not (Test-ComparableManagementUri -Value ([string]$state.Arguments[$urlIndex]))) {
        throw 'The service management URL argument is malformed.'
    }

    return [PSCustomObject]@{
        CommandLine = $state.CommandLine
        Arguments = $state.Arguments
        Spans = $state.Spans
        UrlIndex = $urlIndex
        UrlSpan = $state.Spans[$urlIndex]
        CliPath = $CliPath
    }
}

function New-TargetServiceImagePath {
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$SnapshotCommand,
        [Parameter(Mandatory = $true)][string]$TargetUrl,
        [Parameter(Mandatory = $true)][string]$CliPath
    )

    $span = $SnapshotCommand.UrlSpan
    $oldValue = [string]$SnapshotCommand.Arguments[$SnapshotCommand.UrlIndex]
    $rawToken = $SnapshotCommand.CommandLine.Substring($span.Start, $span.Length)
    if ($rawToken -ceq $oldValue) {
        $replacementToken = $TargetUrl
    }
    elseif ($rawToken -ceq ('"' + $oldValue + '"')) {
        $replacementToken = '"' + $TargetUrl + '"'
    }
    else {
        throw 'The management URL token uses an unprovable quoting form; exact-span fallback is unsafe.'
    }

    $targetImagePath = $SnapshotCommand.CommandLine.Remove($span.Start, $span.Length).Insert($span.Start, $replacementToken)
    $targetCommand = Get-CanonicalServiceCommandState -ImagePath $targetImagePath -CliPath $CliPath
    if ($targetCommand.Arguments.Count -ne $SnapshotCommand.Arguments.Count -or $targetCommand.UrlIndex -ne $SnapshotCommand.UrlIndex) {
        throw 'The exact-span service command did not round-trip to the original argv shape.'
    }
    for ($index = 0; $index -lt $SnapshotCommand.Arguments.Count; $index++) {
        if ($index -eq $SnapshotCommand.UrlIndex) {
            if ([string]$targetCommand.Arguments[$index] -cne $TargetUrl) { throw 'The target URL token did not round-trip exactly.' }
        }
        elseif ([string]$targetCommand.Arguments[$index] -cne [string]$SnapshotCommand.Arguments[$index]) {
            throw "The exact-span service command changed argument $index unexpectedly."
        }
    }
    return $targetImagePath
}

function Test-ServiceCommandDiffersOnlyAtManagementUrl {
    param(
        [Parameter(Mandatory = $true)][string]$ActualImagePath,
        [Parameter(Mandatory = $true)][PSCustomObject]$SnapshotCommand,
        [Parameter(Mandatory = $true)][string]$TargetUrl
    )

    try { $actual = Get-CanonicalServiceCommandState -ImagePath $ActualImagePath -CliPath $SnapshotCommand.CliPath }
    catch { return $false }
    if ($actual.Arguments.Count -ne $SnapshotCommand.Arguments.Count -or $actual.UrlIndex -ne $SnapshotCommand.UrlIndex) { return $false }
    for ($index = 0; $index -lt $SnapshotCommand.Arguments.Count; $index++) {
        if ($index -eq $SnapshotCommand.UrlIndex) {
            if (-not (Test-EquivalentManagementUrl -Actual ([string]$actual.Arguments[$index]) -Expected $TargetUrl)) { return $false }
        }
        elseif ([string]$actual.Arguments[$index] -cne [string]$SnapshotCommand.Arguments[$index]) { return $false }
    }
    return $true
}

function Invoke-NetBirdCommand {
    param(
        [Parameter(Mandatory = $true)][string]$CliPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$IgnoreFailure
    )

    Write-Status $Description
    $hadEnvironmentValue = Test-Path Env:NB_MANAGEMENT_URL
    $savedEnvironmentValue = $env:NB_MANAGEMENT_URL
    try {
        Remove-Item Env:NB_MANAGEMENT_URL -ErrorAction SilentlyContinue
        $output = & $CliPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($hadEnvironmentValue) { $env:NB_MANAGEMENT_URL = $savedEnvironmentValue }
        else { Remove-Item Env:NB_MANAGEMENT_URL -ErrorAction SilentlyContinue }
    }

    if ($exitCode -ne 0 -and -not $IgnoreFailure) {
        throw "$Description failed with exit code ${exitCode}: $($output -join ' ')"
    }
    return [PSCustomObject]@{ ExitCode = $exitCode; Output = @($output) }
}

function Get-DebugCapability {
    param([Parameter(Mandatory = $true)][string]$CliPath)

    $configHelp = Invoke-NetBirdCommand -CliPath $CliPath -Arguments @('debug', 'config', '--help') -Description 'Classifying effective-configuration capability' -IgnoreFailure
    if ($configHelp.ExitCode -eq 0) { return 'Managed' }

    $configText = $configHelp.Output -join ' '
    if ($configText -match '(?i)unknown (?:command|subcommand)|command not found|no such command') { return 'Legacy' }

    $debugHelp = Invoke-NetBirdCommand -CliPath $CliPath -Arguments @('debug', '--help') -Description 'Confirming legacy debug help shape' -IgnoreFailure
    if ($debugHelp.ExitCode -eq 0 -and ($debugHelp.Output -join "`n") -notmatch '(?im)^\s*config(?:\s|$)') { return 'Legacy' }
    return 'Ambiguous'
}

function Get-ManagedEvidence {
    param([string]$CliPath, [string]$TargetUrl, [int]$Attempts = 35)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $result = Invoke-NetBirdCommand -CliPath $CliPath -Arguments @('debug', 'config') -Description "Polling managed configuration ($attempt/$Attempts)" -IgnoreFailure
        if ($result.ExitCode -eq 0) {
            try {
                $configuration = ($result.Output -join [Environment]::NewLine) | ConvertFrom-Json
                $managedFields = @($configuration.mDMManagedFields)
                if ((Test-EquivalentManagementUrl -Actual ([string]$configuration.managementUrl) -Expected $TargetUrl) -and $managedFields -contains 'managementURL') {
                    return $configuration
                }
            }
            catch {
                $configuration = $null
            }
        }
        if ($attempt -lt $Attempts) { Start-Sleep -Seconds 2 }
    }
    return $null
}

function Set-DefaultProfile {
    param([PSCustomObject]$State, [string]$TargetUrl)
    try {
        $original = $State.Text | ConvertFrom-Json
        $updated = $State.Text | ConvertFrom-Json
    }
    catch { throw "The existing NetBird default profile is not valid JSON: $($State.Path)" }

    $property = $updated.PSObject.Properties['ManagementURL']
    if ($null -eq $property) { throw 'The installer-owned default.json is missing ManagementURL.' }
    $original.PSObject.Properties['ManagementURL'].Value = '__SLEEK_MANAGEMENT_URL__'
    $updated.PSObject.Properties['ManagementURL'].Value = '__SLEEK_MANAGEMENT_URL__'
    $originalSemantic = $original | ConvertTo-Json -Depth 100 -Compress
    $updatedSemantic = $updated | ConvertTo-Json -Depth 100 -Compress
    if ($originalSemantic -cne $updatedSemantic) { throw 'Unexpected semantic change while preparing default.json.' }

    $updated.PSObject.Properties['ManagementURL'].Value = $TargetUrl
    $json = $updated | ConvertTo-Json -Depth 100
    $json = [regex]::Replace($json, '\r\n|\r|\n', $State.Newline)
    if ($State.Text.EndsWith($State.Newline) -and -not $json.EndsWith($State.Newline)) { $json += $State.Newline }
    Write-AtomicTextFile -State $State -Text $json

    $verifyState = Get-TextFileState -Path $State.Path
    $verifyObject = $verifyState.Text | ConvertFrom-Json
    if (-not (Test-EquivalentManagementUrl -Actual ([string]$verifyObject.ManagementURL) -Expected $TargetUrl)) { throw 'default.json did not retain the target ManagementURL.' }
    $verifyObject.PSObject.Properties['ManagementURL'].Value = '__SLEEK_MANAGEMENT_URL__'
    if (($verifyObject | ConvertTo-Json -Depth 100 -Compress) -cne $originalSemantic) { throw 'default.json unrelated content changed.' }
}

function Set-ProfileProvisioner {
    param([PSCustomObject]$State, [string]$TargetUrl)
    $matches = @([regex]::Matches($State.Text, $script:ProvisionerAssignmentPattern))
    if ($matches.Count -ne 1) { throw "Expected exactly one generated `$ManagementUrl assignment in '$($State.Path)'; found $($matches.Count)." }
    $match = $matches[0]
    $quote = if ($match.Groups['Single'].Success) { "'" } else { '"' }
    $escapedUrl = if ($quote -eq "'") { $TargetUrl.Replace("'", "''") } else { $TargetUrl.Replace('"', '""') }
    $replacement = $match.Groups['Prefix'].Value + $quote + $escapedUrl + $quote + $match.Groups['Suffix'].Value
    $updated = $State.Text.Remove($match.Index, $match.Length).Insert($match.Index, $replacement)
    Write-AtomicTextFile -State $State -Text $updated

    $verified = Get-TextFileState -Path $State.Path
    $verifiedMatches = @([regex]::Matches($verified.Text, $script:ProvisionerAssignmentPattern))
    if ($verifiedMatches.Count -ne 1) { throw 'Provisioner assignment was not uniquely preserved.' }
    $normalizedOriginal = $State.Text.Remove($match.Index, $match.Length).Insert($match.Index, '__MANAGED_ASSIGNMENT__')
    $verifiedMatch = $verifiedMatches[0]
    $normalizedVerified = $verified.Text.Remove($verifiedMatch.Index, $verifiedMatch.Length).Insert($verifiedMatch.Index, '__MANAGED_ASSIGNMENT__')
    if ($normalizedOriginal -cne $normalizedVerified) { throw 'Unrelated provisioner content changed.' }
}

function Restore-PolicyValue {
    param([PSCustomObject]$PolicySnapshot)
    New-ItemProperty -LiteralPath $PolicyRegistryPath -Name ManagementURL -PropertyType $PolicySnapshot.ManagementKind -Value $PolicySnapshot.ManagementValue -Force | Out-Null
    if ([string](Get-ItemPropertyValue -LiteralPath $PolicyRegistryPath -Name ManagementURL) -cne [string]$PolicySnapshot.ManagementValue) {
        throw 'Policy rollback verification failed.'
    }
    Confirm-PolicySurfacePreserved -PolicySnapshot $PolicySnapshot
}

function Set-ServiceImagePathExact {
    param([string]$ImagePath)
    [Sleek.NetBirdNative]::SetServiceBinaryPath($ServiceName, $ImagePath)
    if ([string](Get-ItemPropertyValue -LiteralPath $ServiceRegistryPath -Name ImagePath) -cne $ImagePath) { throw 'Service ImagePath read-back mismatch.' }
}

function Restore-PreRuntimeSnapshots {
    Write-Status 'Restoring pre-runtime snapshots.'
    $service = Get-Service -Name $ServiceName
    if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $ServiceName -Force
        (Get-Service -Name $ServiceName).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [timespan]::FromSeconds(30))
    }
    Restore-ServiceSnapshot -Snapshot $script:Snapshots.Service
    Restore-TextFileState -State $script:Snapshots.Provisioner
    Restore-TextFileState -State $script:Snapshots.DefaultProfile
    Restore-PolicyValue -PolicySnapshot $script:Snapshots.Policy
    Confirm-RunRegistryPreserved -Snapshot $script:Snapshots.RunRegistry
    $service = Get-Service -Name $ServiceName
    if ($script:Snapshots.Service.Status -eq 'Running' -and $service.Status -ne 'Running') {
        Start-Service -Name $ServiceName
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [timespan]::FromSeconds(30))
    }
}

function Confirm-Persistence {
    param([string]$TargetUrl, [PSCustomObject]$SnapshotCommand, [PSCustomObject]$OriginalProvisioner)
    $policy = [string](Get-ItemPropertyValue -LiteralPath $PolicyRegistryPath -Name ManagementURL)
    if (-not (Test-EquivalentManagementUrl -Actual $policy -Expected $TargetUrl)) { throw 'HKLM policy ManagementURL mismatch.' }
    Confirm-PolicySurfacePreserved -PolicySnapshot $script:Snapshots.Policy
    $defaultState = Get-TextFileState -Path $DefaultProfilePath
    if ($defaultState.CodePage -ne $script:Snapshots.DefaultProfile.CodePage -or $defaultState.HasBom -ne $script:Snapshots.DefaultProfile.HasBom -or $defaultState.Newline -ne $script:Snapshots.DefaultProfile.Newline -or $defaultState.Sddl -ne $script:Snapshots.DefaultProfile.Sddl) { throw 'default.json encoding/BOM/newline/ACL mismatch.' }
    $default = $defaultState.Text | ConvertFrom-Json
    if (-not (Test-EquivalentManagementUrl -Actual ([string]$default.ManagementURL) -Expected $TargetUrl)) { throw 'default.json ManagementURL mismatch.' }
    $provisioner = Get-TextFileState -Path $ProfileProvisionerPath
    if ($provisioner.CodePage -ne $OriginalProvisioner.CodePage -or $provisioner.HasBom -ne $OriginalProvisioner.HasBom -or $provisioner.Newline -ne $OriginalProvisioner.Newline -or $provisioner.Sddl -ne $OriginalProvisioner.Sddl) { throw 'Provisioner encoding/BOM/newline/ACL mismatch.' }
    $matches = @([regex]::Matches($provisioner.Text, $script:ProvisionerAssignmentPattern))
    if ($matches.Count -ne 1) { throw 'Provisioner ManagementUrl assignment is not unique.' }
    $provisionerUrl = if ($matches[0].Groups['Single'].Success) { $matches[0].Groups['SingleValue'].Value.Replace("''", "'") } else { $matches[0].Groups['DoubleValue'].Value.Replace('""', '"') }
    if (-not (Test-EquivalentManagementUrl -Actual $provisionerUrl -Expected $TargetUrl)) { throw 'Provisioner ManagementUrl assignment mismatch.' }
    Confirm-RunRegistryPreserved -Snapshot $script:Snapshots.RunRegistry
    $imagePath = [string](Get-ItemPropertyValue -LiteralPath $ServiceRegistryPath -Name ImagePath)
    if (-not (Test-ServiceCommandDiffersOnlyAtManagementUrl -ActualImagePath $imagePath -SnapshotCommand $SnapshotCommand -TargetUrl $TargetUrl)) {
        throw 'NetBird service argv differs from the installer snapshot beyond the management URL.'
    }
}

function Wait-ServiceRunning {
    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Running) {
        Start-Service -Name $ServiceName
    }
    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [timespan]::FromSeconds(30))
}

function Invoke-ForwardRepair {
    param([string]$CliPath, [string]$TargetUrl, [string]$TargetImagePath, [PSCustomObject]$SnapshotCommand, [string]$Capability)
    Write-Status 'Runtime transition failed after down; attempting bounded target-directed repair.'

    $failures = New-Object 'System.Collections.Generic.List[string]'
    $serviceRunning = $false
    $upSucceeded = $false
    $startupHealthy = $false
    $policyVerified = $false
    $servicePersistenceVerified = $false
    $allPersistenceVerified = $false
    $effectiveVerified = $false
    $managedEvidenceBeforeUp = $false

    try {
        New-ItemProperty -LiteralPath $PolicyRegistryPath -Name ManagementURL -PropertyType String -Value $TargetUrl -Force | Out-Null
    }
    catch { $null = $failures.Add("policy target reapply failed: $($_.Exception.Message)") }
    try {
        Set-DefaultProfile -State $script:Snapshots.DefaultProfile -TargetUrl $TargetUrl
    }
    catch { $null = $failures.Add("default.json target reapply failed: $($_.Exception.Message)") }
    try {
        Set-ProfileProvisioner -State $script:Snapshots.Provisioner -TargetUrl $TargetUrl
    }
    catch { $null = $failures.Add("provisioner target reapply failed: $($_.Exception.Message)") }
    try {
        Set-ServiceImagePathExact -ImagePath $TargetImagePath
    }
    catch { $null = $failures.Add("service target reapply failed: $($_.Exception.Message)") }
    try {
        Wait-ServiceRunning
        $serviceRunning = $true
    }
    catch {
        $null = $failures.Add("service did not reach Running before target up: $($_.Exception.Message)")
    }

    try {
        $policy = [string](Get-ItemPropertyValue -LiteralPath $PolicyRegistryPath -Name ManagementURL)
        if (-not (Test-EquivalentManagementUrl -Actual $policy -Expected $TargetUrl)) { throw 'HKLM policy ManagementURL mismatch.' }
        Confirm-PolicySurfacePreserved -PolicySnapshot $script:Snapshots.Policy
        $policyVerified = $true
    }
    catch {
        $null = $failures.Add("policy persistence verification failed: $($_.Exception.Message)")
    }

    try {
        $imagePath = [string](Get-ItemPropertyValue -LiteralPath $ServiceRegistryPath -Name ImagePath)
        if (-not (Test-ServiceCommandDiffersOnlyAtManagementUrl -ActualImagePath $imagePath -SnapshotCommand $SnapshotCommand -TargetUrl $TargetUrl)) { throw 'Service argv differs beyond the management URL.' }
        Confirm-ServiceMetadataPreserved -Before $script:Snapshots.Service -AllowImagePathChange
        $servicePersistenceVerified = $true
    }
    catch {
        $null = $failures.Add("service persistence verification failed: $($_.Exception.Message)")
    }

    try {
        Confirm-Persistence -TargetUrl $TargetUrl -SnapshotCommand $SnapshotCommand -OriginalProvisioner $script:Snapshots.Provisioner
        $allPersistenceVerified = $true
    }
    catch {
        $null = $failures.Add("complete persistence verification failed: $($_.Exception.Message)")
    }

    $preUpPersistenceVerified = $serviceRunning -and $policyVerified -and $servicePersistenceVerified -and $allPersistenceVerified
    if ($Capability -eq 'Managed' -and $preUpPersistenceVerified) {
        try {
            if ($null -ne (Get-ManagedEvidence -CliPath $CliPath -TargetUrl $TargetUrl -Attempts 15)) {
                $managedEvidenceBeforeUp = $true
            }
            else {
                $null = $failures.Add('managed target evidence did not converge before bare up')
            }
        }
        catch {
            $null = $failures.Add("managed target evidence could not be checked before bare up: $($_.Exception.Message)")
        }
    }
    elseif ($Capability -eq 'Managed') {
        $null = $failures.Add('managed bare up was blocked because target persistence/service verification failed')
    }

    $readyForUp = $preUpPersistenceVerified -and ($Capability -ne 'Managed' -or $managedEvidenceBeforeUp)
    if ($readyForUp) {
        try {
            if ($Capability -eq 'Managed') {
                $upResult = Invoke-NetBirdCommand -CliPath $CliPath -Arguments @('up') -Description 'Forward-repairing managed NetBird runtime after target evidence' -IgnoreFailure
            }
            else {
                $upResult = Invoke-NetBirdCommand -CliPath $CliPath -Arguments @('up', '--management-url', $TargetUrl) -Description 'Forward-repairing legacy NetBird runtime' -IgnoreFailure
            }
            $upSucceeded = $upResult.ExitCode -eq 0
            if (-not $upSucceeded) { $null = $failures.Add("target up failed with exit code $($upResult.ExitCode)") }
        }
        catch { $null = $failures.Add("target up could not be executed: $($_.Exception.Message)") }
    }

    if ($upSucceeded) {
        try {
            $startupResult = Invoke-NetBirdCommand -CliPath $CliPath -Arguments @('status', '--check', 'startup') -Description 'Checking startup health after forward repair' -IgnoreFailure
            $startupHealthy = $startupResult.ExitCode -eq 0
            if (-not $startupHealthy) { $null = $failures.Add("startup health check failed with exit code $($startupResult.ExitCode)") }
        }
        catch { $null = $failures.Add("startup health check could not be executed: $($_.Exception.Message)") }
    }

    try {
        Wait-ServiceRunning
        $serviceRunning = $true
    }
    catch {
        $serviceRunning = $false
        $null = $failures.Add("service did not remain Running: $($_.Exception.Message)")
    }

    try {
        Confirm-Persistence -TargetUrl $TargetUrl -SnapshotCommand $SnapshotCommand -OriginalProvisioner $script:Snapshots.Provisioner
        Confirm-ServiceMetadataPreserved -Before $script:Snapshots.Service -AllowImagePathChange
        $policyVerified = $true
        $servicePersistenceVerified = $true
        $allPersistenceVerified = $true
    }
    catch { $null = $failures.Add("final target persistence verification failed: $($_.Exception.Message)") }

    if ($Capability -eq 'Managed') {
        try {
            if ($null -ne (Get-ManagedEvidence -CliPath $CliPath -TargetUrl $TargetUrl -Attempts 15)) { $effectiveVerified = $true }
            else { $null = $failures.Add('final managed effective evidence did not converge') }
        }
        catch { $null = $failures.Add("final managed effective evidence could not be checked: $($_.Exception.Message)") }
    }
    else {
        try {
            $legacyDefault = (Get-TextFileState -Path $DefaultProfilePath).Text | ConvertFrom-Json
            if (-not (Test-EquivalentManagementUrl -Actual ([string]$legacyDefault.ManagementURL) -Expected $TargetUrl)) { throw 'default.json ManagementURL mismatch.' }
            $effectiveVerified = $true
        }
        catch { $null = $failures.Add("legacy reduced-assurance effective verification failed: $($_.Exception.Message)") }
    }

    $verified = $serviceRunning -and $upSucceeded -and $startupHealthy -and $policyVerified -and $servicePersistenceVerified -and $allPersistenceVerified -and $effectiveVerified
    return [PSCustomObject]@{
        Verified = $verified
        ServiceRunning = $serviceRunning
        UpSucceeded = $upSucceeded
        StartupHealthy = $startupHealthy
        PolicyVerified = $policyVerified
        ServicePersistenceVerified = $servicePersistenceVerified
        AllPersistenceVerified = $allPersistenceVerified
        ManagedEvidenceBeforeUp = $managedEvidenceBeforeUp
        EffectiveVerified = $effectiveVerified
        Failures = @($failures)
    }
}

function Invoke-Preflight {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Throw-StageError -ExitCode 3 -Stage 'platform/privilege' -Message 'This script supports Windows only.' }
    if (-not (Test-IsAdministrator)) { Throw-StageError -ExitCode 3 -Stage 'platform/privilege' -Message 'Run this script from elevated Windows PowerShell 5.1 or as SYSTEM.' }
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -lt 1) { Throw-StageError -ExitCode 3 -Stage 'platform/privilege' -Message 'Windows PowerShell 5.1 is required.' }

    $paths = Get-NetBirdPaths
    if (-not (Test-Path -LiteralPath $paths.Cli -PathType Leaf)) { Throw-StageError -ExitCode 4 -Stage 'prerequisite' -Message "Existing NetBird CLI is missing: $($paths.Cli)" }
    if ($null -eq (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { Throw-StageError -ExitCode 4 -Stage 'prerequisite' -Message 'The existing Netbird service is missing.' }
    foreach ($path in @($PolicyRegistryPath, $ServiceRegistryPath, $UiRunRegistryPath)) {
        if (-not (Test-Path -LiteralPath $path)) { Throw-StageError -ExitCode 4 -Stage 'prerequisite' -Message "Installer-owned registry path is missing: $path" }
    }
    foreach ($path in @($DefaultProfilePath, $ProfileProvisionerPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Throw-StageError -ExitCode 4 -Stage 'prerequisite' -Message "Installer-owned file is missing: $path" }
    }
    try { $null = Get-ItemPropertyValue -LiteralPath $PolicyRegistryPath -Name ManagementURL }
    catch { Throw-StageError -ExitCode 4 -Stage 'prerequisite' -Message 'Installer-owned HKLM policy ManagementURL is missing.' }
    try { $profileRunCommand = [string](Get-ItemPropertyValue -LiteralPath $UiRunRegistryPath -Name $ProfileRunValueName) }
    catch { Throw-StageError -ExitCode 4 -Stage 'prerequisite' -Message 'Installer-owned profile provisioner Run entry is missing.' }
    if ($profileRunCommand.IndexOf($ProfileProvisionerPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Throw-StageError -ExitCode 4 -Stage 'prerequisite' -Message 'The profile provisioner Run entry does not reference the installer-owned provisioner path.'
    }
    $uiAutostartPresent = $false
    foreach ($runValue in (Get-RunRegistrySnapshot).Values) {
        if ([string]$runValue.Value -match '(?i)netbird-ui\.exe') { $uiAutostartPresent = $true; break }
    }
    if (-not $uiAutostartPresent) {
        Throw-StageError -ExitCode 4 -Stage 'prerequisite' -Message 'The existing NetBird UI machine Run entry is missing.'
    }

    return $paths
}

function Main {
    $script:ManagementUrl = ConvertTo-NormalizedManagementUrl -Value $ManagementUrl
    $paths = Invoke-Preflight
    Write-Status "Changing the existing NetBird management URL to $script:ManagementUrl"

    try {
        $policySnapshot = Get-PolicySnapshot
        if ($policySnapshot.ManagementKind -ne 'String') { throw "Installer-owned policy ManagementURL has unexpected registry type '$($policySnapshot.ManagementKind)'." }
        $serviceSnapshot = Get-ServiceSnapshot
        $serviceCommand = Get-CanonicalServiceCommandState -ImagePath $serviceSnapshot.ImagePath -CliPath $paths.Cli
        $script:Snapshots = [PSCustomObject]@{
            Policy = $policySnapshot
            DefaultProfile = Get-TextFileState -Path $DefaultProfilePath
            Provisioner = Get-TextFileState -Path $ProfileProvisionerPath
            Service = $serviceSnapshot
            ServiceCommand = $serviceCommand
            RunRegistry = Get-RunRegistrySnapshot
        }

        if ($script:Snapshots.Service.StartMode -ne 'Auto') { throw 'The installer-owned NetBird service is not configured for automatic startup; refusing to alter its start mode.' }
        $targetImagePath = New-TargetServiceImagePath -SnapshotCommand $script:Snapshots.ServiceCommand -TargetUrl $script:ManagementUrl -CliPath $paths.Cli

        $parsedDefault = $script:Snapshots.DefaultProfile.Text | ConvertFrom-Json
        if ($null -eq $parsedDefault.PSObject.Properties['ManagementURL']) { throw 'The installer-owned default.json is missing ManagementURL.' }
        if (@([regex]::Matches($script:Snapshots.Provisioner.Text, $script:ProvisionerAssignmentPattern)).Count -ne 1) { throw 'The generated provisioner does not contain exactly one recognized ManagementUrl literal assignment.' }

        $script:PersistenceTouched = $true
        New-ItemProperty -LiteralPath $PolicyRegistryPath -Name ManagementURL -PropertyType String -Value $script:ManagementUrl -Force | Out-Null
        Confirm-PolicySurfacePreserved -PolicySnapshot $script:Snapshots.Policy
        Set-DefaultProfile -State $script:Snapshots.DefaultProfile -TargetUrl $script:ManagementUrl
        Set-ProfileProvisioner -State $script:Snapshots.Provisioner -TargetUrl $script:ManagementUrl

        $reconfigure = Invoke-NetBirdCommand -CliPath $paths.Cli -Arguments @('service', 'reconfigure', '--management-url', $script:ManagementUrl) -Description 'Reconfiguring the NetBird service management URL' -IgnoreFailure
        $configuredImagePath = [string](Get-ItemPropertyValue -LiteralPath $ServiceRegistryPath -Name ImagePath)
        if ($reconfigure.ExitCode -ne 0 -or -not (Test-ServiceCommandDiffersOnlyAtManagementUrl -ActualImagePath $configuredImagePath -SnapshotCommand $script:Snapshots.ServiceCommand -TargetUrl $script:ManagementUrl)) {
            Write-Status 'Service reconfigure did not preserve the snapshot argv shape; using proven exact-token-span replay.'
            Set-ServiceImagePathExact -ImagePath $targetImagePath
            $configuredImagePath = [string](Get-ItemPropertyValue -LiteralPath $ServiceRegistryPath -Name ImagePath)
            if ($configuredImagePath -cne $targetImagePath) { throw 'Exact-token-span service fallback read-back failed.' }
        }
        if (-not (Test-ServiceCommandDiffersOnlyAtManagementUrl -ActualImagePath $configuredImagePath -SnapshotCommand $script:Snapshots.ServiceCommand -TargetUrl $script:ManagementUrl)) { throw 'NetBird service argv differs from the snapshot beyond the management URL.' }
        Confirm-ServiceMetadataPreserved -Before $script:Snapshots.Service -AllowImagePathChange
        Wait-ServiceRunning
        Confirm-Persistence -TargetUrl $script:ManagementUrl -SnapshotCommand $script:Snapshots.ServiceCommand -OriginalProvisioner $script:Snapshots.Provisioner

        $capability = Get-DebugCapability -CliPath $paths.Cli
        if ($capability -eq 'Ambiguous') { throw 'NetBird debug-config capability could not be structurally classified; refusing runtime mutation.' }
        if ($capability -eq 'Managed') {
            $managedEvidence = Get-ManagedEvidence -CliPath $paths.Cli -TargetUrl $script:ManagementUrl
            if ($null -eq $managedEvidence) { throw 'Managed-capable NetBird did not converge to the target managementURL/mDMManagedFields before runtime. Update upstream GPO/MDM policy and retry.' }
        }

        $script:RuntimeCommitted = $true
        Invoke-NetBirdCommand -CliPath $paths.Cli -Arguments @('down') -Description 'Stopping the current NetBird runtime session' | Out-Null
        if ($capability -eq 'Managed') {
            Invoke-NetBirdCommand -CliPath $paths.Cli -Arguments @('up') -Description 'Starting NetBird with managed policy' | Out-Null
        }
        else {
            Invoke-NetBirdCommand -CliPath $paths.Cli -Arguments @('up', '--management-url', $script:ManagementUrl) -Description 'Starting legacy NetBird with the target management URL' | Out-Null
        }
        Invoke-NetBirdCommand -CliPath $paths.Cli -Arguments @('status', '--check', 'startup') -Description 'Verifying NetBird startup health' | Out-Null
        Wait-ServiceRunning
        Confirm-Persistence -TargetUrl $script:ManagementUrl -SnapshotCommand $script:Snapshots.ServiceCommand -OriginalProvisioner $script:Snapshots.Provisioner
        Confirm-ServiceMetadataPreserved -Before $script:Snapshots.Service -AllowImagePathChange
        if ($capability -eq 'Managed') {
            if ($null -eq (Get-ManagedEvidence -CliPath $paths.Cli -TargetUrl $script:ManagementUrl -Attempts 15)) { throw 'Final daemon effective/managed configuration verification failed.' }
        }
        else {
            $legacyDefault = (Get-TextFileState -Path $DefaultProfilePath).Text | ConvertFrom-Json
            if (-not (Test-EquivalentManagementUrl -Actual ([string]$legacyDefault.ManagementURL) -Expected $script:ManagementUrl)) { throw 'Reduced-assurance legacy default.json verification failed.' }
            Write-Status 'Legacy client has no effective configuration introspection; final URL evidence is reduced-assurance default.json plus startup health.'
        }

        Write-Status "SUCCESS: verified policy, default.json, profile provisioner and Run entry, service management URL, automatic/running service, startup health, and effective configuration for $script:ManagementUrl"
        Write-Warning 'A different control plane can require user re-enrollment or SSO. This script changes endpoint configuration only and does not migrate identity.'
    }
    catch {
        $failureMessage = $_.Exception.Message
        if ($null -ne $script:Snapshots) {
            if (-not $script:RuntimeCommitted) {
                if ($script:PersistenceTouched) {
                    try { Restore-PreRuntimeSnapshots }
                    catch { Write-Error "Pre-runtime rollback also failed: $($_.Exception.Message)" -ErrorAction Continue }
                }
            }
            else {
                try {
                    $repairOutcome = Invoke-ForwardRepair -CliPath $paths.Cli -TargetUrl $script:ManagementUrl -TargetImagePath $targetImagePath -SnapshotCommand $script:Snapshots.ServiceCommand -Capability $capability
                    if ($repairOutcome.Verified) {
                        $failureMessage += ' Target-directed repair was verified: the requested target is running and all target persistence/effective checks converged. The original operation still exits 6 because it failed after the runtime commit boundary.'
                    }
                    else {
                        $repairFailures = $repairOutcome.Failures -join '; '
                        $failureMessage += " Target state remains unresolved after target-directed repair: $repairFailures. Do not restore the old URL; remediate the reported target checks and rerun this script for the same target."
                    }
                }
                catch {
                    $failureMessage += " Target state remains unresolved because target-directed repair could not complete: $($_.Exception.Message). Do not restore the old URL; remediate the target state and rerun this script for the same target."
                }
            }
        }
        $failureExitCode = if ($script:RuntimeCommitted) { 6 } elseif ($script:PersistenceTouched) { 5 } else { 4 }
        $failureStage = if ($script:RuntimeCommitted) { 'runtime/effective verification' } elseif ($script:PersistenceTouched) { 'persistence/service staging' } else { 'prerequisite/malformed state' }
        Throw-StageError -ExitCode $failureExitCode -Stage $failureStage -Message $failureMessage
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Main
        exit 0
    }
    catch {
        $exitCode = 1
        if ($_.Exception.Data.Contains('ExitCode')) { $exitCode = [int]$_.Exception.Data['ExitCode'] }
        [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
        exit $exitCode
    }
}
