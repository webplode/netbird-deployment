#!/usr/bin/env python3
"""Safe, dependency-free contract tests for the NetBird URL changers.

These tests never execute either changer.  The changers intentionally address
privileged, fixed operating-system paths, so exercising them on a developer Mac
would be destructive.  This harness instead checks source contracts and uses
isolated fixtures to make the preservation and command-order rules executable.
Platform service behavior remains a disposable-VM verification responsibility.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
SHELL_CHANGER = ROOT / "change_management_url.sh"
POWERSHELL_CHANGER = ROOT / "change_management_url.ps1"


def source(path: Path) -> str:
    if not path.is_file():
        raise AssertionError(f"required implementation is missing: {path.name}")
    return path.read_text(encoding="utf-8")


def bash_function(implementation: str, name: str) -> str:
    """Return one top-level Bash function whose closing brace is unindented."""

    start = implementation.index(f"{name}() {{")
    end = implementation.index("\n}", start) + 2
    return implementation[start:end]


def paired_value(arguments: list[str], flag: str) -> str:
    positions = [index for index, value in enumerate(arguments) if value == flag]
    if len(positions) != 1 or positions[0] + 1 >= len(arguments):
        raise ValueError(f"expected exactly one value paired with {flag}")
    return arguments[positions[0] + 1]


def normalized_url(value: str) -> tuple[str, str, int, str, str]:
    parsed = urlsplit(value)
    if parsed.scheme.lower() != "https" or not parsed.hostname:
        raise ValueError("management URL must be absolute HTTPS")
    if parsed.username or parsed.password or parsed.fragment:
        raise ValueError("management URL contains unsupported components")
    try:
        port = parsed.port or 443
    except ValueError as error:
        raise ValueError("management URL has an invalid port") from error
    path = parsed.path.rstrip("/") or "/"
    return parsed.scheme.lower(), parsed.hostname.lower(), port, path, parsed.query


def urls_equivalent(left: str, right: str) -> bool:
    return normalized_url(left) == normalized_url(right)


def normalize_paired_url(arguments: list[str]) -> list[str]:
    result = list(arguments)
    index = result.index("--management-url")
    result[index + 1] = "<management-url>"
    return result


def policy_surface_without_management_url(policy: dict) -> tuple[dict, tuple[str, ...]]:
    sibling_values = {
        name: value
        for name, value in policy["values"].items()
        if name != "ManagementURL"
    }
    return sibling_values, tuple(sorted(policy["subkeys"]))


def snapshot_derived_service_arguments(
    arguments: list[str], target_url: str
) -> list[str]:
    result = list(arguments)
    flag = "--management-url"
    positions = [index for index, value in enumerate(result) if value == flag]
    if len(positions) != 1 or positions[0] + 1 >= len(result):
        raise ValueError(f"expected exactly one value paired with {flag}")
    result[positions[0] + 1] = target_url
    return result


def bash_library_source() -> str:
    implementation = source(SHELL_CHANGER)
    if 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' in implementation:
        return implementation + "\ntrap - EXIT\n"
    entry_point = '\nmain "$@"'
    position = implementation.rfind(entry_point)
    if position < 0:
        raise AssertionError("could not isolate Bash helpers from main entry point")
    return implementation[:position] + "\ntrap - EXIT\n"


def run_sourced_bash(commands: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    with TemporaryDirectory() as directory:
        library = Path(directory) / "change_management_url.library.sh"
        library.write_text(bash_library_source(), encoding="utf-8")
        process_env = dict(os.environ)
        if env:
            process_env.update(env)
        return subprocess.run(
            ["/bin/bash", "-c", 'source "$1"\n' + commands, "bash-test", str(library)],
            capture_output=True,
            text=True,
            env=process_env,
        )


class UrlContractTests(unittest.TestCase):
    def test_accepts_equivalent_https_urls(self) -> None:
        self.assertTrue(
            urls_equivalent(
                "HTTPS://NETBIRD.Example:443/team/", "https://netbird.example/team"
            )
        )

    def test_detects_port_or_path_changes(self) -> None:
        self.assertFalse(urls_equivalent("https://a.example", "https://a.example:444"))
        self.assertFalse(urls_equivalent("https://a.example/a", "https://a.example/b"))

    def test_detects_query_case_changes(self) -> None:
        self.assertFalse(
            urls_equivalent("https://a.example/path?Key=Value", "https://a.example/path?key=Value")
        )

    def test_rejects_non_https_or_hostless_urls(self) -> None:
        for value in ("", "relative", "http://a.example", "https:///missing", "https://a.example/#fragment"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                normalized_url(value)


class SourcedBashHelperTests(unittest.TestCase):
    def test_actual_normalizer_rejects_malformed_bracketed_ipv6(self) -> None:
        for value in (
            "https://[::::]",
            "https://[1:2:3:4:5:6:7:8:9]",
            "https://[2001:db8::1",
        ):
            with self.subTest(value=value):
                result = run_sourced_bash(
                    'set +e\nnormalize_management_url "$TEST_URL" >/dev/null 2>&1\nexit $?\n',
                    {"TEST_URL": value},
                )
                self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_actual_normalizer_rejects_invalid_percent_escapes(self) -> None:
        for value in (
            "https://example.com/%",
            "https://example.com/%2",
            "https://example.com/%ZZ",
            "https://example.com/path?key=%GG",
        ):
            with self.subTest(value=value):
                result = run_sourced_bash(
                    'set +e\nnormalize_management_url "$TEST_URL" >/dev/null 2>&1\nexit $?\n',
                    {"TEST_URL": value},
                )
                self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_actual_normalizer_rejects_oversized_decimal_ports(self) -> None:
        for value in (
            "https://example.com:18446744073709551617",
            "https://example.com:99999999999999999999999999999999999999999999999999",
        ):
            with self.subTest(value=value):
                result = run_sourced_bash(
                    'set +e\nnormalize_management_url "$TEST_URL" >/dev/null 2>&1\nexit $?\n',
                    {"TEST_URL": value},
                )
                self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_actual_main_succeeds_without_runtime_connection_evidence(self) -> None:
        result = run_sourced_bash(
            r'''
TRACE=""
record() { TRACE="${TRACE}$1\n"; }
log() { :; }
warn() { :; }
preflight() { record preflight; TARGET_URL="$1"; }
take_snapshots() { record snapshots; }
write_managed_policy() { record write_policy; }
verify_policy() { record verify_policy; }
configure_service() { record configure_service; }
verify_service() { record verify_service; }
run_netbird_capture() { record forbidden_runtime_probe; return 1; }
runtime_transition() { record forbidden_runtime_transition; return 1; }
startup_is_healthy() { record forbidden_startup_check; return 1; }
managed_evidence_is_target() { record forbidden_managed_evidence; return 1; }
set +e
main https://new.example
status=$?
set -e
printf 'status=%s\n%b' "$status" "$TRACE"
'''
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "status=0",
                "preflight",
                "snapshots",
                "write_policy",
                "verify_policy",
                "configure_service",
                "verify_policy",
                "verify_service",
            ],
        )

class FixturePreservationTests(unittest.TestCase):
    def test_macos_policy_changes_only_management_url(self) -> None:
        original = {
            "managementURL": "https://old.example",
            "autoConnect": True,
            "labels": ["finance", "managed"],
            "nested": {"sentinel": 42},
        }
        with TemporaryDirectory() as directory:
            fixture = Path(directory) / "io.netbird.client.plist"
            fixture.write_bytes(plistlib.dumps(original, fmt=plistlib.FMT_BINARY))
            changed = plistlib.loads(fixture.read_bytes())
            changed["managementURL"] = "https://new.example"
            fixture.write_bytes(plistlib.dumps(changed, fmt=plistlib.FMT_BINARY))
            observed = plistlib.loads(fixture.read_bytes())
        self.assertEqual(observed.pop("managementURL"), "https://new.example")
        original_without_url = dict(original)
        original_without_url.pop("managementURL")
        self.assertEqual(observed, original_without_url)

    def test_malformed_macos_policy_is_not_rewritten(self) -> None:
        with TemporaryDirectory() as directory:
            fixture = Path(directory) / "broken.plist"
            fixture.write_bytes(b"not a plist\x00")
            before = fixture.read_bytes()
            with self.assertRaises(Exception):
                plistlib.loads(before)
            self.assertEqual(fixture.read_bytes(), before)

    def test_launchdaemon_checks_paired_url_not_similar_argument(self) -> None:
        arguments = [
            "/usr/local/bin/netbird",
            "service",
            "run",
            "--management-url",
            "https://old.example",
            "--log-file",
            "/tmp/https://new.example.log",
        ]
        self.assertEqual(paired_value(arguments, "--management-url"), "https://old.example")

    def test_launchdaemon_preserves_all_arguments_except_paired_url(self) -> None:
        before = ["netbird", "service", "run", "--management-url", "https://old", "--log-level", "info"]
        after = ["netbird", "service", "run", "--management-url", "https://new", "--log-level", "info"]
        self.assertEqual(normalize_paired_url(before), normalize_paired_url(after))

    def test_windows_json_changes_only_management_url_semantically(self) -> None:
        original = {
            "ManagementURL": "https://old.example",
            "Nested": {"List": [1, 2, 3]},
            "Sentinel": True,
        }
        original_text = json.dumps(original, indent=2).replace("\n", "\r\n") + "\r\n"
        encoded = ("\ufeff" + original_text).encode("utf-8")
        bom = encoded.startswith(b"\xef\xbb\xbf")
        newline = "\r\n" if b"\r\n" in encoded else "\n"
        parsed = json.loads(encoded.decode("utf-8-sig"))
        parsed["ManagementURL"] = "https://new.example"
        rewritten_text = json.dumps(parsed, indent=2).replace("\n", newline) + newline
        rewritten = (("\ufeff" if bom else "") + rewritten_text).encode("utf-8")
        observed = json.loads(rewritten.decode("utf-8-sig"))
        self.assertTrue(rewritten.startswith(b"\xef\xbb\xbf"))
        self.assertIn(b"\r\n", rewritten)
        self.assertEqual(observed["ManagementURL"], "https://new.example")
        for key in ("Nested", "Sentinel"):
            self.assertEqual(observed[key], original[key])

    def test_windows_service_changes_exactly_one_management_url(self) -> None:
        before = ["netbird.exe", "service", "run", "--management-url", "https://old", "--log-level", "info"]
        after = snapshot_derived_service_arguments(before, "https://new")
        self.assertEqual(paired_value(after, "--management-url"), "https://new")
        self.assertEqual(after.count("--management-url"), 1)
        self.assertNotIn("--admin-url", after)

    def test_windows_policy_url_change_preserves_sibling_values(self) -> None:
        before = {
            "values": {
                "ManagementURL": ("String", "https://old.example"),
                "AutoConnect": ("DWord", 1),
                "OpaqueSentinel": ("Binary", b"\x00\xff"),
            },
            "subkeys": ["Enrollment", "Overrides"],
        }
        after = {
            "values": dict(before["values"]),
            "subkeys": list(before["subkeys"]),
        }
        after["values"]["ManagementURL"] = ("String", "https://new.example")
        self.assertEqual(
            policy_surface_without_management_url(after),
            policy_surface_without_management_url(before),
        )

    def test_windows_policy_verification_detects_sibling_value_change(self) -> None:
        before = {
            "values": {"ManagementURL": ("String", "https://old"), "Sentinel": ("DWord", 7)},
            "subkeys": ["Enrollment"],
        }
        after = {
            "values": {"ManagementURL": ("String", "https://new"), "Sentinel": ("DWord", 8)},
            "subkeys": ["Enrollment"],
        }
        self.assertNotEqual(
            policy_surface_without_management_url(after),
            policy_surface_without_management_url(before),
        )

    def test_windows_policy_verification_detects_immediate_subkey_change(self) -> None:
        before = {
            "values": {"ManagementURL": ("String", "https://old")},
            "subkeys": ["Enrollment"],
        }
        after = {
            "values": {"ManagementURL": ("String", "https://new")},
            "subkeys": ["Enrollment", "Unexpected"],
        }
        self.assertNotEqual(
            policy_surface_without_management_url(after),
            policy_surface_without_management_url(before),
        )

    def test_windows_service_acceptance_rejects_unrelated_argument_change(self) -> None:
        snapshot = ["netbird.exe", "service", "run", "--management-url", "https://old", "--log-level", "info"]
        expected = snapshot_derived_service_arguments(snapshot, "https://new")
        reconfigured = snapshot_derived_service_arguments(snapshot, "https://new")
        reconfigured[-1] = "debug"
        self.assertNotEqual(reconfigured, expected)

    def test_ambiguous_provisioner_assignment_is_rejected(self) -> None:
        assignment = re.compile(r"(?m)^\s*\$ManagementUrl\s*=\s*(['\"]).*?\1\s*$")
        for fixture in ("Write-Host 'none'\n", "$ManagementUrl='a'\n$ManagementUrl='b'\n"):
            with self.subTest(fixture=fixture):
                self.assertNotEqual(len(assignment.findall(fixture)), 1)


class ImplementationSourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.shell = source(SHELL_CHANGER)
        cls.powershell = source(POWERSHELL_CHANGER)

    def test_shell_has_valid_bash_syntax(self) -> None:
        result = subprocess.run(
            ["/bin/bash", "-n", str(SHELL_CHANGER)], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_shellcheck_when_available(self) -> None:
        shellcheck = shutil.which("shellcheck")
        if shellcheck is None:
            self.skipTest("shellcheck is not installed")
        result = subprocess.run(
            [shellcheck, str(SHELL_CHANGER)], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_powershell_parser_when_available(self) -> None:
        powershell = shutil.which("powershell.exe") or shutil.which("pwsh")
        if powershell is None:
            self.skipTest("PowerShell is not installed; Windows PowerShell 5.1 remains required")
        command = (
            "$errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("
            f"'{str(POWERSHELL_CHANGER).replace("'", "''")}', [ref]$null, [ref]$errors); "
            "if ($errors.Count) { $errors | ForEach-Object { [Console]::Error.WriteLine($_) }; exit 1 }"
        )
        result = subprocess.run(
            [powershell, "-NoProfile", "-Command", command], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_all_installer_owned_persistence_surfaces_are_named(self) -> None:
        for token in ("/Library/Managed Preferences/io.netbird.client.plist", "/Library/LaunchDaemons/netbird.plist", "managementURL", "--management-url"):
            with self.subTest(platform="macOS", token=token):
                self.assertIn(token, self.shell)
        for token in ("Software\\Policies\\NetBird", "default.json", "provision-netbird-profile.ps1", "ManagementURL", "--management-url"):
            with self.subTest(platform="Windows", token=token):
                self.assertIn(token.lower(), self.powershell.lower())

    def test_macos_preflight_accepts_an_unloaded_launchdaemon(self) -> None:
        preflight = bash_function(self.shell, "preflight")
        self.assertRegex(
            preflight,
            r'if\s+loaded_service="\$\(/bin/launchctl print[^\n]+";\s+then',
        )
        self.assertRegex(preflight, r"(?s)else.*not loaded.*persistent")
        self.assertNotRegex(
            preflight,
            r'loaded_service="\$\(/bin/launchctl print[^\n]+"\s*\|\|\s*die',
        )

    def test_macos_preflight_records_when_launchdaemon_was_loaded(self) -> None:
        preflight = bash_function(self.shell, "preflight")
        self.assertRegex(preflight, r"SERVICE_WAS_LOADED\s*=\s*1")
        self.assertRegex(self.shell, r"(?m)^SERVICE_WAS_LOADED\s*=\s*0$")

    def test_macos_service_write_preserves_initial_loaded_state(self) -> None:
        service_write = bash_function(self.shell, "write_service_plist")
        self.assertRegex(
            service_write,
            r'(?s)if \[\[ "\$SERVICE_WAS_LOADED" -eq 1 \]\].*launchctl bootout',
        )
        self.assertRegex(
            service_write,
            r'(?s)if \[\[ "\$SERVICE_WAS_LOADED" -eq 1 \]\]; then.*bootstrap_with_retry',
        )

    def test_macos_verifies_loaded_or_unloaded_state_matches_initial_state(self) -> None:
        verification = bash_function(self.shell, "verify_service")
        self.assertRegex(
            verification,
            r'(?s)if \[\[ "\$SERVICE_WAS_LOADED" -eq 1 \]\]; then.*launchctl print.*elif /bin/launchctl print.*return 1',
        )

    def test_macos_success_path_requires_only_persistent_surfaces(self) -> None:
        main = bash_function(self.shell, "main")
        for required in ("write_managed_policy", "verify_policy", "configure_service", "verify_service"):
            with self.subTest(required=required):
                self.assertIn(required, main)
        for runtime_dependency in (
            "classify_capability",
            "debug config",
            "runtime_transition",
            "managed_evidence",
            "startup_is_healthy",
            "run_target_up",
            " status ",
            " down",
            " up",
        ):
            with self.subTest(runtime_dependency=runtime_dependency):
                self.assertNotIn(runtime_dependency, main)

    def test_macos_persistence_helpers_do_not_require_netbird_connection_commands(self) -> None:
        persistence_path = "\n".join(
            bash_function(self.shell, name)
            for name in (
                "preflight",
                "write_managed_policy",
                "verify_policy",
                "write_service_plist",
                "verify_service",
                "configure_service",
                "main",
            )
        )
        self.assertNotRegex(
            persistence_path,
            r"(?m)^\s*(?:run_netbird(?:_capture)?\s+)?(?:debug\s+config|status\b|down\b|up\b)",
        )

    def test_windows_managed_and_positive_unsupported_branches_are_present(self) -> None:
        lowered = self.powershell.lower()
        self.assertIn("debug", lowered)
        self.assertIn("config", lowered)
        self.assertIn("help", lowered)
        self.assertRegex(lowered, r"unsupported|unknown")
        self.assertRegex(lowered, r"command|subcommand")
        self.assertIn("mdmmanagedfields", lowered)
        self.assertIn("managementurl", lowered)

    def test_windows_runtime_and_environment_safety_contracts_are_present(self) -> None:
        lowered = self.powershell.lower()
        self.assertIn("nb_management_url", lowered)
        self.assertRegex(lowered, r"\bdown\b")
        self.assertRegex(lowered, r"\bup\b")
        self.assertIn("status", lowered)
        self.assertIn("startup", lowered)

    def test_environment_is_removed_for_each_cli_wrapper(self) -> None:
        self.assertRegex(
            self.powershell,
            r"(?i)Remove-Item\s+Env:NB_MANAGEMENT_URL",
        )
        self.assertRegex(
            self.powershell,
            r"(?i)\$env:NB_MANAGEMENT_URL\s*=\s*\$savedEnvironmentValue",
        )

    def test_windows_runtime_branch_command_shapes_are_explicit(self) -> None:
        self.assertRegex(
            self.powershell,
            r"(?i)-Arguments\s+@\('up'\)"
        )
        self.assertRegex(
            self.powershell,
            r"(?i)-Arguments\s+@\('up',\s*'--management-url',\s*\$script:ManagementUrl\)"
        )

    def test_windows_service_reconfigure_sets_only_management_url(self) -> None:
        lowered = self.powershell.lower()
        self.assertRegex(
            lowered,
            r"service'\s*,\s*'reconfigure'\s*,\s*'--management-url'",
        )
        self.assertNotIn("--admin-url", lowered)

    def test_windows_policy_snapshot_excludes_only_management_url(self) -> None:
        self.assertRegex(
            self.powershell,
            r"(?is)GetValueNames\(\).*?Where-Object\s*\{\s*\$_\s+-cne\s+'ManagementURL'\s*\}",
        )
        self.assertRegex(self.powershell, r"(?i)GetSubKeyNames\(\)")
        self.assertIn("SiblingValues", self.powershell)
        self.assertIn("SubkeyNames", self.powershell)

    def test_windows_policy_preservation_is_checked_after_update(self) -> None:
        update = self.powershell.index(
            "New-ItemProperty -LiteralPath $PolicyRegistryPath -Name ManagementURL"
        )
        verification = self.powershell.index(
            "Confirm-PolicySurfacePreserved -PolicySnapshot $script:Snapshots.Policy",
            update,
        )
        self.assertGreater(verification, update)

    def test_windows_service_acceptance_requires_snapshot_derived_exact_imagepath(self) -> None:
        self.assertRegex(
            self.powershell,
            r"(?i)\$targetImagePath\s*=\s*(?:New-TargetServiceImagePath\s+-SnapshotCommand\s+\$script:Snapshots\.ServiceCommand|Set-(?:PairedServiceUrls|ServiceManagementUrl)\s+-ImagePath\s+\$script:Snapshots\.Service\.ImagePath)",
        )
        self.assertRegex(
            self.powershell,
            r"(?i)(?:\$configuredImagePath\s+-cne\s+\$targetImagePath|Test-ServiceCommandDiffersOnlyAtManagementUrl\s+-ActualImagePath\s+\$configuredImagePath)",
        )

    def test_powershell_managed_forward_repair_proves_persistence_and_evidence_before_up(self) -> None:
        start = self.powershell.index("function Invoke-ForwardRepair")
        end = self.powershell.index("\nfunction Invoke-Preflight", start)
        repair = self.powershell[start:end]
        up = repair.index("-Arguments @('up')")
        persistence = repair.index("Confirm-Persistence")
        evidence = repair.index("Get-ManagedEvidence")
        self.assertLess(persistence, up)
        self.assertLess(evidence, up)

    def test_powershell_forward_repair_reapplies_target_persistence_before_up(self) -> None:
        start = self.powershell.index("function Invoke-ForwardRepair")
        end = self.powershell.index("\nfunction Invoke-Preflight", start)
        repair = self.powershell[start:end]
        up = repair.index("-Arguments @('up')")
        aggregate_reapply = re.search(
            r"(?i)(?:Repair|Set|Write|Update)-[A-Za-z]*(?:Target|Persistence)[A-Za-z]*",
            repair,
        )
        concrete_reapply = (
            "New-ItemProperty",
            "Set-DefaultProfile",
            "Set-ProfileProvisioner",
            "Set-ServiceImagePathExact",
        )
        if aggregate_reapply is not None:
            self.assertLess(aggregate_reapply.start(), up)
        else:
            for mutation in concrete_reapply:
                with self.subTest(mutation=mutation):
                    self.assertLess(repair.index(mutation), up)

    def test_windows_service_shape_uses_windows_argv_semantics(self) -> None:
        start = self.powershell.index("function Get-WindowsCommandLineState")
        end = self.powershell.index("\nfunction Invoke-NetBirdCommand", start)
        service_helpers = self.powershell[start:end]
        self.assertIn("CommandLineToArgvW", self.powershell)
        self.assertRegex(service_helpers, r"(?i)SplitCommandLine|CommandLineToArgvW")
        self.assertNotRegex(
            service_helpers,
            r"(?i)\[regex\]::Matches\(\$ImagePath",
        )

    def test_windows_service_shape_requires_one_management_url_and_no_admin_url(self) -> None:
        start = self.powershell.index("function Get-CanonicalServiceCommandState")
        end = self.powershell.index("\nfunction Invoke-NetBirdCommand", start)
        service_helpers = self.powershell[start:end]
        self.assertIn("--management-url", service_helpers.lower())
        self.assertNotIn("--admin-url", service_helpers.lower())
        self.assertRegex(
            service_helpers,
            r"(?i)(?:management\w*\.Count\s+-(?:eq|ne)\s+1|count\s*\(.*management)",
        )

    def test_windows_service_rewrite_preserves_non_management_argv(self) -> None:
        start = self.powershell.index("function Get-CanonicalServiceCommandState")
        end = self.powershell.index("\nfunction Invoke-NetBirdCommand", start)
        service_helpers = self.powershell[start:end]
        self.assertRegex(service_helpers, r"(?i)Arguments|Argv")
        self.assertRegex(service_helpers, r"(?i)(?:management.*index|index.*management|UrlIndex)")
        self.assertRegex(
            service_helpers,
            r"(?is)for\s*\([^)]*\).*?elseif\s*\([^)]*Arguments\[\$index\][^)]*-cne[^)]*Arguments\[\$index\]",
        )

    def test_powershell_url_equivalence_is_case_sensitive_for_path_and_query(self) -> None:
        start = self.powershell.index("function Test-EquivalentManagementUrl")
        end = self.powershell.index("\nfunction Get-AclSddl", start)
        equivalence = self.powershell[start:end]
        self.assertRegex(
            equivalence,
            r"(?i)(?:AbsolutePath|actualPath)[^\n]*-ceq|-ceq[^\n]*(?:AbsolutePath|expectedPath)",
        )
        self.assertRegex(
            equivalence,
            r"(?i)(?:actualQuery|Query|PathAndQuery)[^\n]*-ceq|-ceq[^\n]*(?:expectedQuery|Query)",
        )

    def test_powershell_url_validation_rejects_fragments(self) -> None:
        start = self.powershell.index("function ConvertTo-NormalizedManagementUrl")
        end = self.powershell.index("\nfunction Test-EquivalentManagementUrl", start)
        validation = self.powershell[start:end]
        self.assertIn("Fragment", validation)
        self.assertRegex(validation, r"(?i)IsNullOrEmpty\([^\n]*Fragment|Fragment[^\n]*(?:-ne|Length)")

    def test_restore_pre_runtime_snapshots_has_no_unused_cli_parameter(self) -> None:
        start = self.powershell.index("function Restore-PreRuntimeSnapshots")
        end = self.powershell.index("\nfunction Confirm-Persistence", start)
        restore = self.powershell[start:end]
        self.assertNotRegex(restore, r"(?i)param\([^)]*CliPath")
        self.assertNotRegex(self.powershell, r"(?i)Restore-PreRuntimeSnapshots\s+-CliPath")

    def test_powershell_forward_repair_returns_verification_outcome(self) -> None:
        start = self.powershell.index("function Invoke-ForwardRepair")
        end = self.powershell.index("\nfunction Invoke-Preflight", start)
        repair = self.powershell[start:end]
        self.assertRegex(repair, r"(?i)return\s+\$(?:true|false)|\[PSCustomObject\]")
        self.assertNotRegex(repair, r"(?i)catch\s*\{\s*\}")

    def test_powershell_forward_outcome_depends_on_service_up_and_startup(self) -> None:
        start = self.powershell.index("function Invoke-ForwardRepair")
        end = self.powershell.index("\nfunction Invoke-Preflight", start)
        repair = self.powershell[start:end]
        for evidence in ("Wait-ServiceRunning", "'up'", "'startup'"):
            with self.subTest(evidence=evidence):
                self.assertIn(evidence, repair)
        self.assertRegex(repair, r"(?i)ExitCode|return\s+\$false|catch")

    def test_powershell_main_catch_uses_forward_repair_outcome(self) -> None:
        committed = self.powershell.rindex("if (-not $script:RuntimeCommitted)")
        end = self.powershell.index("\n        Throw-StageError", committed)
        handler = self.powershell[committed:end]
        self.assertRegex(
            handler,
            r"(?i)\$\w*(?:repair|outcome)\w*\s*=\s*Invoke-ForwardRepair",
        )
        self.assertRegex(handler, r"(?i)if\s*\(\s*\$\w*(?:repair|outcome)\w*")

    def test_powershell_main_catch_has_distinct_repaired_and_unresolved_guidance(self) -> None:
        committed = self.powershell.rindex("if (-not $script:RuntimeCommitted)")
        end = self.powershell.index("\n        Throw-StageError", committed)
        handler = self.powershell[committed:end]
        self.assertRegex(handler, r"(?i)verified|converged|repaired")
        self.assertRegex(handler, r"(?i)unresolved|remains|did not converge")

    def test_forbidden_executable_operations_are_absent(self) -> None:
        forbidden = (
            r"\bcurl\b",
            r"invoke-webrequest",
            r"\bmsiexec(?:\.exe)?\b",
            r"install-netbirdpackage",
            r"\bsetup-key\b",
            r"\blogout\b",
            r"service\s+uninstall",
            r"service\s+install",
        )
        for name, implementation in (("shell", self.shell), ("PowerShell", self.powershell)):
            code_lines = []
            for line in implementation.splitlines():
                stripped = line.lstrip()
                if stripped.startswith("#"):
                    continue
                code_lines.append(line)
            code = "\n".join(code_lines).lower()
            for pattern in forbidden:
                with self.subTest(platform=name, pattern=pattern):
                    self.assertIsNone(re.search(pattern, code), f"forbidden executable token {pattern!r} in {name} changer")

    def test_success_messaging_preserves_identity_boundary(self) -> None:
        for implementation in (self.shell, self.powershell):
            lowered = implementation.lower()
            self.assertRegex(lowered, r"re-enroll|reenroll")
            self.assertIn("sso", lowered)


if __name__ == "__main__":
    unittest.main(verbosity=2)
