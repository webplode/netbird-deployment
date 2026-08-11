#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dependency-free Windows VM harness. The production invocation guard makes
# dot-sourcing inert, so tests exercise the real helper functions without
# invoking preflight, registry, service, or NetBird mutations.
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$ChangerPath = Join-Path $RepositoryRoot 'change_management_url.ps1'
. $ChangerPath -ManagementUrl 'https://target.example/path?Key=Value'

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ([string]$Expected -cne [string]$Actual) {
        throw "$Message Expected '$Expected'; observed '$Actual'."
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action }
    catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

function Write-HarnessTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][Text.Encoding]$Encoding,
        [byte[]]$Preamble = [byte[]]@()
    )

    $body = $Encoding.GetBytes($Text)
    $bytes = New-Object byte[] ($Preamble.Length + $body.Length)
    if ($Preamble.Length -gt 0) { [Array]::Copy($Preamble, 0, $bytes, 0, $Preamble.Length) }
    [Array]::Copy($body, 0, $bytes, $Preamble.Length, $body.Length)
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS: $Name"
    }
    catch {
        $script:Failed++
        [Console]::Error.WriteLine("FAIL: ${Name}: $($_.Exception.Message)")
    }
}

Invoke-Test 'URL path comparison is case-sensitive' {
    Assert-False `
        (Test-EquivalentManagementUrl -Actual 'https://target.example/Team' -Expected 'https://target.example/team') `
        'Paths differing only by case must not be equivalent.'
}

Invoke-Test 'URL query comparison is case-sensitive' {
    Assert-False `
        (Test-EquivalentManagementUrl -Actual 'https://target.example/path?Key=Value' -Expected 'https://target.example/path?key=Value') `
        'Queries differing only by case must not be equivalent.'
}

Invoke-Test 'URL fragments are rejected' {
    Assert-Throws `
        { ConvertTo-NormalizedManagementUrl -Value 'https://target.example/path#fragment' | Out-Null } `
        'A management URL containing a fragment must be rejected.'
}

Invoke-Test 'service command accepts exactly one management URL argument' {
    $cli = 'C:\Program Files\NetBird\netbird.exe'
    $imagePath = '"C:\Program Files\NetBird\netbird.exe" service run --management-url "https://old.example/path?Key=Value" --log-file "C:\ProgramData\NetBird logs\service.log" --custom "value with spaces"'
    $shape = Get-CanonicalServiceCommandState -ImagePath $imagePath -CliPath $cli
    Assert-Equal 1 @($shape.Arguments | Where-Object { $_ -ceq '--management-url' }).Count 'Exactly one management flag is required.'
    Assert-Equal 0 @($shape.Arguments | Where-Object { $_ -ceq '--admin-url' }).Count 'An admin URL flag must not be invented.'
}

Invoke-Test 'service URL rewrite preserves every non-management argv value' {
    $cli = 'C:\Program Files\NetBird\netbird.exe'
    $imagePath = '"C:\Program Files\NetBird\netbird.exe" service run --management-url "https://old.example" --log-file "C:\ProgramData\NetBird logs\service.log" --custom "a\\\"b c"'
    $before = Get-CanonicalServiceCommandState -ImagePath $imagePath -CliPath $cli
    $updatedImagePath = New-TargetServiceImagePath -SnapshotCommand $before -TargetUrl 'https://new.example' -CliPath $cli
    $after = Get-CanonicalServiceCommandState -ImagePath $updatedImagePath -CliPath $cli
    Assert-Equal $before.Arguments.Count $after.Arguments.Count 'Argument count must remain unchanged.'
    for ($index = 0; $index -lt $before.Arguments.Count; $index++) {
        if ($index -ne $before.UrlIndex) {
            Assert-Equal $before.Arguments[$index] $after.Arguments[$index] "Argument $index changed unexpectedly."
        }
    }
    Assert-Equal 'https://new.example' $after.Arguments[$after.UrlIndex] 'The paired management URL was not updated.'
}

Invoke-Test 'T12 policy preservation detects a sibling-value mismatch' {
    $snapshot = [PSCustomObject]@{
        ManagementValue = 'https://old.example'
        ManagementKind = 'String'
        SiblingValues = @([PSCustomObject]@{ Name = 'Sentinel'; Kind = 'DWord'; Value = 7 })
        SubkeyNames = @('Enrollment')
    }
    $script:HarnessPolicyCurrent = [PSCustomObject]@{
        ManagementValue = 'https://target.example'
        ManagementKind = 'String'
        SiblingValues = @([PSCustomObject]@{ Name = 'Sentinel'; Kind = 'DWord'; Value = 7 })
        SubkeyNames = @('Enrollment')
    }
    function Get-PolicySnapshot { return $script:HarnessPolicyCurrent }

    Confirm-PolicySurfacePreserved -PolicySnapshot $snapshot
    $script:HarnessPolicyCurrent.SiblingValues[0].Value = 8
    Assert-Throws {
        Confirm-PolicySurfacePreserved -PolicySnapshot $snapshot
    } 'A policy sibling-value mismatch must fail verification.'
}

Invoke-Test 'T13 T14 T19 default profile preserves semantics encoding BOM newline ACL and idempotence' {
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('sleek-netbird-default-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $directory
    try {
        $path = Join-Path $directory 'default.json'
        $text = "{`r`n  `"ManagementURL`": `"https://old.example`",`r`n  `"Nested`": { `"Sentinel`": 42 },`r`n  `"Enabled`": true`r`n}`r`n"
        Write-HarnessTextFile -Path $path -Text $text -Encoding (New-Object Text.UTF8Encoding($false, $true)) -Preamble ([byte[]]@(0xEF, 0xBB, 0xBF))
        $before = Get-TextFileState -Path $path

        Set-DefaultProfile -State $before -TargetUrl 'https://target.example/path?Key=Value'
        $after = Get-TextFileState -Path $path
        $parsed = $after.Text | ConvertFrom-Json
        Assert-True (Test-EquivalentManagementUrl -Actual ([string]$parsed.ManagementURL) -Expected 'https://target.example/path?Key=Value') 'default.json target URL was not preserved.'
        Assert-Equal 42 $parsed.Nested.Sentinel 'default.json nested content changed.'
        Assert-True ([bool]$parsed.Enabled) 'default.json unrelated content changed.'
        Assert-Equal $before.CodePage $after.CodePage 'default.json code page changed.'
        Assert-Equal $before.HasBom $after.HasBom 'default.json BOM state changed.'
        Assert-Equal $before.Newline $after.Newline 'default.json newline convention changed.'
        Assert-Equal $before.Sddl $after.Sddl 'default.json ACL SDDL changed.'

        $firstPassBytes = [IO.File]::ReadAllBytes($path)
        Set-DefaultProfile -State $after -TargetUrl 'https://target.example/path?Key=Value'
        $secondPassBytes = [IO.File]::ReadAllBytes($path)
        Assert-True (Test-ByteArrayEqual -Left $firstPassBytes -Right $secondPassBytes) 'The second default.json update was not byte-idempotent.'
    }
    finally {
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'T13 malformed default profile fails without changing bytes' {
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('sleek-netbird-malformed-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $directory
    try {
        $path = Join-Path $directory 'default.json'
        [IO.File]::WriteAllBytes($path, [Text.Encoding]::UTF8.GetBytes('{ malformed json'))
        $state = Get-TextFileState -Path $path
        $before = [IO.File]::ReadAllBytes($path)
        Assert-Throws {
            Set-DefaultProfile -State $state -TargetUrl 'https://target.example'
        } 'Malformed default.json must be rejected.'
        Assert-True (Test-ByteArrayEqual -Left $before -Right ([IO.File]::ReadAllBytes($path))) 'Malformed default.json bytes changed.'
    }
    finally {
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'T14 T15 T19 provisioner preserves non-assignment text UTF16 BOM newline ACL and idempotence' {
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('sleek-netbird-provisioner-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $directory
    try {
        $path = Join-Path $directory 'provision-netbird-profile.ps1'
        $text = "# generated sentinel`n`$ManagementUrl = 'https://old.example' # managed`nWrite-Host `"unchanged`"`n"
        Write-HarnessTextFile -Path $path -Text $text -Encoding (New-Object Text.UnicodeEncoding($false, $false, $true)) -Preamble ([byte[]]@(0xFF, 0xFE))
        $before = Get-TextFileState -Path $path

        Set-ProfileProvisioner -State $before -TargetUrl 'https://target.example/path?Key=Value'
        $after = Get-TextFileState -Path $path
        Assert-True ($after.Text.Contains("# generated sentinel`n")) 'Provisioner prefix content changed.'
        Assert-True ($after.Text.Contains("Write-Host `"unchanged`"`n")) 'Provisioner suffix content changed.'
        Assert-True ($after.Text.Contains("`$ManagementUrl = 'https://target.example/path?Key=Value' # managed")) 'Provisioner target assignment was not written.'
        Assert-Equal $before.CodePage $after.CodePage 'Provisioner code page changed.'
        Assert-Equal $before.HasBom $after.HasBom 'Provisioner BOM state changed.'
        Assert-Equal $before.Newline $after.Newline 'Provisioner newline convention changed.'
        Assert-Equal $before.Sddl $after.Sddl 'Provisioner ACL SDDL changed.'

        $firstPassBytes = [IO.File]::ReadAllBytes($path)
        Set-ProfileProvisioner -State $after -TargetUrl 'https://target.example/path?Key=Value'
        $secondPassBytes = [IO.File]::ReadAllBytes($path)
        Assert-True (Test-ByteArrayEqual -Left $firstPassBytes -Right $secondPassBytes) 'The second provisioner update was not byte-idempotent.'

        foreach ($ambiguousText in @("Write-Host 'none'`n", "`$ManagementUrl = 'one'`n`$ManagementUrl = 'two'`n")) {
            Write-HarnessTextFile -Path $path -Text $ambiguousText -Encoding (New-Object Text.UTF8Encoding($false, $true))
            $ambiguous = Get-TextFileState -Path $path
            $ambiguousBytes = [IO.File]::ReadAllBytes($path)
            Assert-Throws {
                Set-ProfileProvisioner -State $ambiguous -TargetUrl 'https://target.example'
            } 'A provisioner with zero or multiple assignments must be rejected.'
            Assert-True (Test-ByteArrayEqual -Left $ambiguousBytes -Right ([IO.File]::ReadAllBytes($path))) 'An ambiguous provisioner changed before rejection.'
        }
    }
    finally {
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'T16 service parser rejects custom and ambiguous command shapes' {
    $cli = 'C:\Program Files\NetBird\netbird.exe'
    foreach ($imagePath in @(
        '"C:\Program Files\NetBird\netbird.exe" service run --management-url=https://old.example',
        '"C:\Program Files\NetBird\netbird.exe" service run --management-url https://one.example --management-url https://two.example',
        '"C:\Program Files\NetBird\netbird.exe" custom run --management-url https://old.example'
    )) {
        Assert-Throws {
            Get-CanonicalServiceCommandState -ImagePath $imagePath -CliPath $cli | Out-Null
        } "A noncanonical service command must be rejected: $imagePath"
    }
}

Invoke-Test 'T17 capability classification distinguishes managed legacy and ambiguous evidence' {
    function Invoke-NetBirdCommand {
        param([string]$CliPath, [string[]]$Arguments, [string]$Description, [switch]$IgnoreFailure)
        if ($script:HarnessCapabilityScenario -eq 'Managed') {
            return [PSCustomObject]@{ ExitCode = 0; Output = @('usage') }
        }
        if ($script:HarnessCapabilityScenario -eq 'Legacy' -and $Arguments.Count -eq 3) {
            return [PSCustomObject]@{ ExitCode = 1; Output = @('unknown command config') }
        }
        return [PSCustomObject]@{ ExitCode = 1; Output = @('transient timeout') }
    }

    foreach ($scenario in @('Managed', 'Legacy', 'Ambiguous')) {
        $script:HarnessCapabilityScenario = $scenario
        Assert-Equal $scenario (Get-DebugCapability -CliPath 'mock-netbird.exe') "Capability scenario $scenario was misclassified."
    }
}

Invoke-Test 'T20 final persistence rejects unrelated default profile semantic drift' {
    $script:Snapshots = [PSCustomObject]@{
        Policy = [PSCustomObject]@{}
        RunRegistry = [PSCustomObject]@{}
        DefaultProfile = [PSCustomObject]@{ Text = '{"ManagementURL":"https://old.example","Sentinel":1}'; CodePage = 65001; HasBom = $false; Newline = "`n"; Sddl = 'mock' }
    }
    $originalProvisioner = [PSCustomObject]@{ Text = "`$ManagementUrl = 'https://old.example'`nWrite-Host 'same'`n"; CodePage = 65001; HasBom = $false; Newline = "`n"; Sddl = 'mock' }
    function Get-ItemPropertyValue { return 'https://target.example' }
    function Confirm-PolicySurfacePreserved { }
    function Confirm-RunRegistryPreserved { }
    function Test-ServiceCommandDiffersOnlyAtManagementUrl { return $true }
    function Get-TextFileState {
        param([string]$Path)
        if ($Path -eq $DefaultProfilePath) {
            return [PSCustomObject]@{ Text = '{"ManagementURL":"https://target.example","Sentinel":2}'; CodePage = 65001; HasBom = $false; Newline = "`n"; Sddl = 'mock' }
        }
        return [PSCustomObject]@{ Text = "`$ManagementUrl = 'https://target.example'`nWrite-Host 'same'`n"; CodePage = 65001; HasBom = $false; Newline = "`n"; Sddl = 'mock' }
    }

    Assert-Throws {
        Confirm-Persistence -TargetUrl 'https://target.example' -SnapshotCommand ([PSCustomObject]@{}) -OriginalProvisioner $originalProvisioner
    } 'Final persistence must reject unrelated default.json semantic drift.'
}

Invoke-Test 'T20 final persistence rejects unrelated provisioner drift' {
    $script:Snapshots = [PSCustomObject]@{
        Policy = [PSCustomObject]@{}
        RunRegistry = [PSCustomObject]@{}
        DefaultProfile = [PSCustomObject]@{ Text = '{"ManagementURL":"https://old.example","Sentinel":1}'; CodePage = 65001; HasBom = $false; Newline = "`n"; Sddl = 'mock' }
    }
    $originalProvisioner = [PSCustomObject]@{ Text = "`$ManagementUrl = 'https://old.example'`nWrite-Host 'same'`n"; CodePage = 65001; HasBom = $false; Newline = "`n"; Sddl = 'mock' }
    function Get-ItemPropertyValue { return 'https://target.example' }
    function Confirm-PolicySurfacePreserved { }
    function Confirm-RunRegistryPreserved { }
    function Test-ServiceCommandDiffersOnlyAtManagementUrl { return $true }
    function Get-TextFileState {
        param([string]$Path)
        if ($Path -eq $DefaultProfilePath) {
            return [PSCustomObject]@{ Text = '{"ManagementURL":"https://target.example","Sentinel":1}'; CodePage = 65001; HasBom = $false; Newline = "`n"; Sddl = 'mock' }
        }
        return [PSCustomObject]@{ Text = "`$ManagementUrl = 'https://target.example'`nWrite-Host 'changed'`n"; CodePage = 65001; HasBom = $false; Newline = "`n"; Sddl = 'mock' }
    }

    Assert-Throws {
        Confirm-Persistence -TargetUrl 'https://target.example' -SnapshotCommand ([PSCustomObject]@{}) -OriginalProvisioner $originalProvisioner
    } 'Final persistence must reject unrelated provisioner drift.'
}

Invoke-Test 'T23 pre-runtime rollback restores every snapshot surface before restart' {
    $script:Trace = New-Object 'System.Collections.Generic.List[string]'
    $script:Snapshots = [PSCustomObject]@{
        Service = [PSCustomObject]@{ Status = 'Stopped' }
        Provisioner = [PSCustomObject]@{ Path = 'provisioner' }
        DefaultProfile = [PSCustomObject]@{ Path = 'default' }
        Policy = [PSCustomObject]@{}
        RunRegistry = [PSCustomObject]@{}
    }
    function Get-Service { return [PSCustomObject]@{ Status = [ServiceProcess.ServiceControllerStatus]::Stopped } }
    function Restore-ServiceSnapshot { $null = $script:Trace.Add('service') }
    function Restore-TextFileState { param([PSCustomObject]$State); $null = $script:Trace.Add([string]$State.Path) }
    function Restore-PolicyValue { $null = $script:Trace.Add('policy') }
    function Confirm-RunRegistryPreserved { $null = $script:Trace.Add('run') }

    Restore-PreRuntimeSnapshots
    Assert-Equal 'service,provisioner,default,policy,run' ($script:Trace -join ',') 'Pre-runtime rollback did not restore all snapshot surfaces in order.'
}

Invoke-Test 'managed forward repair proves persistence and managed evidence before bare up' {
    $script:Trace = New-Object 'System.Collections.Generic.List[string]'
    $script:Snapshots = [PSCustomObject]@{
        Policy = [PSCustomObject]@{}
        DefaultProfile = [PSCustomObject]@{}
        Provisioner = [PSCustomObject]@{}
        Service = [PSCustomObject]@{}
    }
    function Wait-ServiceRunning { $null = $script:Trace.Add('service-running') }
    function New-ItemProperty { $null = $script:Trace.Add('policy-write') }
    function Set-DefaultProfile { $null = $script:Trace.Add('default-write') }
    function Set-ProfileProvisioner { $null = $script:Trace.Add('provisioner-write') }
    function Set-ServiceImagePathExact { $null = $script:Trace.Add('service-write') }
    function Repair-TargetPersistence { $null = $script:Trace.Add('persistence-reapplied') }
    function Set-TargetPersistence { $null = $script:Trace.Add('persistence-reapplied') }
    function Confirm-Persistence { $null = $script:Trace.Add('persistence-verified') }
    function Confirm-PolicySurfacePreserved { }
    function Confirm-ServiceMetadataPreserved { }
    function Test-ServiceCommandDiffersOnlyAtManagementUrl { return $true }
    function Get-PolicySnapshot { return [PSCustomObject]@{} }
    function Get-ServiceSnapshot { return [PSCustomObject]@{} }
    function Get-TextFileState { return [PSCustomObject]@{ Text = '{"ManagementURL":"https://target.example"}' } }
    function Get-ItemPropertyValue {
        param([string]$LiteralPath, [string]$Name)
        if ($Name -eq 'ImagePath') { return 'target-image-path' }
        return 'https://target.example'
    }
    function Get-ManagedEvidence {
        $null = $script:Trace.Add('managed-evidence')
        return [PSCustomObject]@{ managementUrl = 'https://target.example' }
    }
    function Invoke-NetBirdCommand {
        param([string]$CliPath, [string[]]$Arguments, [string]$Description, [switch]$IgnoreFailure)
        if ($Arguments[0] -eq 'up') { $null = $script:Trace.Add('up-bare') }
        if ($Arguments[0] -eq 'status') { $null = $script:Trace.Add('startup') }
        return [PSCustomObject]@{ ExitCode = 0; Output = @() }
    }

    $snapshotCommand = [PSCustomObject]@{ CliPath = 'netbird.exe'; Arguments = @('netbird.exe', 'service', 'run', '--management-url', 'https://old.example'); UrlIndex = 4 }
    $outcome = Invoke-ForwardRepair -CliPath 'netbird.exe' -TargetUrl 'https://target.example' -TargetImagePath 'target-image-path' -SnapshotCommand $snapshotCommand -Capability Managed
    Assert-True $outcome.Verified 'The fully mocked target repair should verify.'
    $upIndex = $script:Trace.IndexOf('up-bare')
    Assert-True ($upIndex -ge 0) 'Managed forward repair must issue bare up.'
    $aggregateReapply = $script:Trace.IndexOf('persistence-reapplied')
    if ($aggregateReapply -ge 0) {
        Assert-True ($aggregateReapply -lt $upIndex) 'Target persistence reapplication must precede managed bare up.'
    }
    else {
        foreach ($event in @('policy-write', 'default-write', 'provisioner-write', 'service-write')) {
            $eventIndex = $script:Trace.IndexOf($event)
            Assert-True ($eventIndex -ge 0) "Missing repair event: $event"
            Assert-True ($eventIndex -lt $upIndex) "$event must precede managed bare up."
        }
    }
    foreach ($event in @('persistence-verified', 'managed-evidence')) {
        $eventIndex = $script:Trace.IndexOf($event)
        Assert-True ($eventIndex -ge 0) "Missing repair event: $event"
        Assert-True ($eventIndex -lt $upIndex) "$event must precede managed bare up."
    }
}

Write-Host "PowerShell helper tests: $script:Passed passed, $script:Failed failed"
if ($script:Failed -ne 0) { exit 1 }
