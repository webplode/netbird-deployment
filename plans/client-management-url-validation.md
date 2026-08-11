# Test specification: Change NetBird management URL

## Test objective

Prove that `client/change_management_url.sh` and
`client/change_management_url.ps1` converge an existing matching installation
to one HTTPS management URL without reinstalling NetBird, losing unrelated
configuration, inheriting `NB_MANAGEMENT_URL`, invoking `logout`, or reporting
success on partial/mismatched state.

## Safety model

Automated tests must not write real `/Library`, `HKLM`, `%ProgramData%`, LaunchDaemon, Windows service, or NetBird profile state.

- The implementation should keep platform paths/constants and external command invocation centralized so a test harness can substitute a temporary root and fake executables without adding a production dependency.
- macOS harness: run from a temporary directory with fixture plist files and a fake command directory for `netbird`, `launchctl`, and any privileged/system mutation boundary. Where absolute native utilities are retained, split pure validation/parsing helpers from mutation orchestration and exercise the latter in a disposable macOS VM; never shadow or alter host `/usr/bin` or `/Library`.
- Windows harness: run in an isolated Windows Sandbox/VM or Pester-compatible PowerShell 5.1 session using function mocks for registry/service/process cmdlets and a temporary `$env:ProgramData`. If Pester is not already available, do not add it as a repository dependency; use a temporary native PowerShell harness that dot-sources a testable/no-main form or invokes the script with mocked wrapper functions.
- Fake `netbird` records argv, `NB_MANAGEMENT_URL` presence, and command order. Scenarios control exit codes, delayed MDM application, managed-field availability, and `debug config` JSON. It never contacts a network.
- Before/after fixture snapshots exclude only the intended field/argument so preservation claims are mechanically checked.
- Real platform validation is limited to disposable test VMs enrolled in a non-production management environment.

No permanent test dependency is required. If testability requires a hidden override (for example a test root or injected command path), it must be gated explicitly for tests and must not weaken normal fixed-path/privilege checks.

## Required fixtures

### macOS fixtures

- Valid managed-preferences plist containing `managementURL` plus at least three unrelated scalar/array/dictionary keys.
- Malformed plist.
- Valid LaunchDaemon plist with `ProgramArguments`, `--management-url`, old URL, and unrelated service flags.
- Fake loaded/unloaded `launchctl` states.
- Fake outputs for successful reconfigure, failed reconfigure with safe local plist replay, noncanonical safe refusal, startup failure, delayed managed-field convergence, and legacy unmanaged behavior.

### Windows fixtures

- Policy registry object with `ManagementURL` plus unrelated values/subkey sentinel.
- `default.json` with nested/unrelated properties across UTF-8 BOM/no-BOM and CRLF/LF variants; malformed variant.
- Service object/registry `ImagePath` with quoted executable, `--management-url`, old URL, and unrelated arguments.
- Generated provisioner based on `client/install_netbird.ps1`, plus
  zero/duplicate assignment, quoted URL, UTF-8/UTF-16 BOM, CRLF/LF, distinct
  SDDL, and unrelated-code variants.
- Fake service states `Stopped`, `StartPending`, `Running`, and timeout.
- Fake NetBird command outputs paralleling the macOS scenarios, including `debug config --help` unsupported.

## Test cases

| ID | Scenario and action | Required result |
| --- | --- | --- |
| T01 | Empty, relative, `http`, hostless, malformed, or whitespace URL | Exit invocation/URL category before any write or NetBird call; actionable URL error. |
| T02 | URL with uppercase scheme/host, explicit/default port, path, and optional trailing slash | Accept valid HTTPS; equivalence ignores host/scheme case and trailing slash but detects port/path changes. |
| T03 | Shell receives zero/two arguments; PowerShell parameter omitted | Exit before mutation with canonical usage. |
| T04 | Non-root macOS and non-admin Windows identities | Exit privilege category before mutation. SYSTEM is accepted on Windows. |
| T05 | CLI missing/non-executable or service missing | Exit matching-install prerequisite category; no file/registry writes and no install/download command. |
| T06 | Required installer-owned policy/default/provisioner missing | Fail closed as non-matching/incomplete installation; do not synthesize replacement state. |
| T07 | macOS happy path from old URL to new URL | Only `managementURL` changes; service arg changes; loaded service remains healthy; runtime/effective checks pass. |
| T08 | macOS malformed policy plist | Non-zero; original bytes/hash unchanged; service/runtime untouched. |
| T09 | macOS LaunchDaemon contains similar URL as unrelated arg | Verify the value paired with `--management-url`, not a substring elsewhere; mismatch blocks success. |
| T10 | macOS reconfigure fails with canonical vs custom LaunchDaemon | Canonical case permits atomic local URL edit/re-bootstrap with all other args/metadata identical; custom case restores staged state and refuses. Trace never uninstalls/reinstalls service. |
| T11 | macOS effective URL delayed, mismatched, or timeout | Retry within bound; succeed on eventual equivalent value; mismatch/timeout exits effective-verification category. |
| T12 | Windows registry policy update | Only `ManagementURL` changes; sibling values and subkey sentinel remain identical. |
| T13 | Windows valid/malformed `default.json` | Valid case changes only property semantically and preserves nested data; malformed case leaves original bytes/hash unchanged and exits non-zero. |
| T14 | Windows encoding/BOM/newline/SDDL matrix; one provisioner assignment and quoted URL | Replace correctly; encoding/code page, BOM, newline sequence, and exact ACL SDDL match; provisioner differs only in assignment span. |
| T15 | Windows provisioner has zero or multiple recognized assignments | Fail before replacement and before runtime transition; original bytes/hash unchanged. |
| T16 | Windows reconfigure failure with canonical exact-replay vs custom service | Exact-replay changes only paired URL and preserves every captured argument/metadata/SDDL; unprovable case restores and refuses without uninstall/install. |
| T17 | Structural capability classification | Explicit unknown command/subcommand or verified help absence positively classifies legacy and permits reduced-assurance `default.json` verification; supported help/command classifies managed-capable. Empty fields, malformed output, timeout, and target mismatch never classify legacy. |
| T18a | Structurally unsupported legacy client with conflicting environment | Variable is absent/restored; trace is positive unsupported-capability evidence -> persistence evidence -> `down` -> `up --management-url` -> startup check. |
| T18b | Managed-capable client with delayed target field | Poll waits within bound, then trace is managed evidence -> `down` -> bare `up` -> startup/debug; flagged `up` never occurs. |
| T18c | Managed-capable client persistently missing/empty, malformed, timed out, or mismatched | Fail before first `down`, restore snapshots, report upstream policy/MDM remediation, and never execute flagged `up`. |
| T19 | Run each changer twice with the same target | Both runs exit `0`; second is idempotent; no duplicate keys/properties/arguments/assignments; unrelated snapshots remain equal. |
| T20 | Inject mismatch in each required surface one at a time | Every mismatch blocks success and names that surface; no false-positive final message. |
| T21 | Static source inspection | No `curl`, package install/download/upgrade, setup key, OAuth/SSO automation, server mutation, or `logout`; expected persistence paths and runtime commands are present. |
| T22 | URL points to a different test control plane where existing identity is rejected | Script does not delete identity or logout; it reports configuration success only if its defined startup/effective checks pass and emits re-enrollment/SSO warning. Authentication migration remains out of scope. |
| T23 | Inject failure before and after first runtime `down` | Pre-boundary failure restores raw/semantic/metadata snapshots and old running service; post-boundary failure never rolls back URL, performs bounded forward repair, and emits target-state recovery guidance if unresolved. |
| T24 | External MDM/GPO reasserts old URL after local write | Effective mismatch blocks success and directs operator to update upstream policy; script never claims it can defeat controller sync. |

## Command-trace assertions

For every NetBird invocation, assert:

1. The executable is the matching installed CLI path.
2. `NB_MANAGEMENT_URL` is absent from the child environment.
3. No argument contains setup keys, auth tokens, or `logout`.
4. Persistence/service verification precedes runtime; first `down` is the commit boundary.
5. Managed order is `down` -> bare `up` -> startup check; legacy flagged order is reachable only after positive structural unsupported-capability evidence.
6. A capable client requires bounded positive managed evidence; missing/empty fields, malformed output, timeout, or mismatch trigger pre-runtime rollback and never flagged `up`. Final debug verification follows startup health.
7. Service-local fallback requires reconfigure failure plus canonical-shape/exact-replay proof; noncanonical traces contain no uninstall/install and safely refuse.
8. Pre-boundary failures restore snapshots; post-boundary failures invoke only target-directed forward repair.

## Preservation assertions

- macOS: compare parsed plist trees with only `managementURL` normalized away; compare LaunchDaemon argument arrays with only the value paired to `--management-url` normalized away; require root:wheel and mode `0644` in VM validation.
- Windows: compare registry excluding only `ManagementURL`; compare JSON semantically excluding that property; assert encoding/code page, BOM, newlines, and exact ACL SDDL for both files; compare provisioner text excluding one assignment span; compare service arguments excluding paired URL plus exact service metadata/SDDL.
- Malformed/ambiguous fixtures: compare raw byte hash before and after; it must be identical.

## Exit and messaging assertions

- `0`: every persistence, service, startup, and effective/fallback check passed, including idempotent already-configured runs.
- Invocation/URL, privilege/platform, prerequisite/malformed state, persistence/service, and effective-verification failures use distinct documented non-zero categories or a stable equivalent.
- stderr/error stream identifies the stage and safe recovery action without exposing tokens or credentials.
- Final success output includes the target URL, surfaces verified, and a warning that a different control plane can require re-enrollment/SSO; it must not state that identity migrated.

## Static and syntax checks

Run after each edit and again from the integrated workspace:

```text
bash -n client/change_management_url.sh
shellcheck client/change_management_url.sh          # when installed; absence is a documented gap, not a reason to add a dependency
powershell.exe -NoProfile -Command "[void][scriptblock]::Create((Get-Content -Raw .\client\change_management_url.ps1))"
rg -n "logout|setup-key|curl|Invoke-WebRequest|msiexec|Install-NetBirdPackage" client/change_management_url.sh client/change_management_url.ps1
```

Review the `rg` matches contextually: usage/error text may mention prohibited actions, but no executable forbidden path may exist. On non-Windows development hosts, use `pwsh` only as a parser supplement; final compatibility evidence must come from Windows PowerShell 5.1.

## Disposable VM smoke matrix

| Platform | Required smoke evidence |
| --- | --- |
| Managed macOS VM | Old URL fixture installed by `install_netbird.sh`; successful change; plist/LaunchDaemon snapshots; `launchctl print system/netbird`; `status --check startup`; `debug config`; reboot persistence; second-run idempotence. |
| Windows 10/11 VM, Windows PowerShell 5.1 | Old URL fixture installed by `install_netbird.ps1`; registry/default/provisioner/service snapshots; successful change; service automatic/running; startup/debug output; user sign-in confirms provisioner cannot restore old URL; reboot persistence; second-run idempotence. |
| Failure VM scenario per OS | Conflicting `NB_MANAGEMENT_URL`, forced reconfigure failure, and unreachable/different test control plane; confirm bounded non-zero behavior and no logout/identity deletion. |

Do not use production management endpoints or real user credentials for failure scenarios. Redact peer IDs, tokens, and identity material from captured evidence.

## Acceptance closure checklist

- [ ] T01-T03 prove input contract.
- [ ] T04-T06 prove privilege and existing-install gates before mutation.
- [ ] T07-T11 prove macOS persistence, fallback, runtime, and effective verification.
- [ ] T12-T17 prove all Windows persistence surfaces, service behavior, and compatibility fallback.
- [ ] T18 proves environment precedence defense and runtime order; command trace contains no `logout`.
- [ ] T19 proves idempotence.
- [ ] T20 proves no partial/mismatched success.
- [ ] T21 proves non-goals and absence of package/auth/server logic.
- [ ] T22 and success messaging preserve the endpoint-versus-identity distinction.
- [ ] T23 proves rollback-before-runtime and forward-repair-after-runtime.
- [ ] T24 proves the upstream MDM/GPO caveat is enforced.
- [ ] Code reviewer reports no critical/high findings.
- [ ] Verifier records fresh integrated evidence against all 14 acceptance criteria in the PRD.

## Stop rule and verification ownership

The `test-engineer` owns the temporary/mock harness and evidence, but does not edit product scripts without handing findings to their owning executor. A `code-reviewer` reviews the integrated scripts after tests. A separate `verifier` reruns syntax, static, mock, and available VM checks and signs off the acceptance mapping. Stop only when all automated cases pass and any unavailable disposable-VM evidence is explicitly recorded as a rollout blocker/gap rather than silently waived.
