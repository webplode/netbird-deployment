# Management URL changer verification

Run the safe local suite from the repository root:

```sh
python3 client/tests/run_change_management_url_tests.py
```

On a disposable Windows VM with Windows PowerShell 5.1, run the native helper
harness from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\client\tests\change_management_url.Tests.ps1
```

The suite uses only the Python standard library and does not execute either
privileged changer. It checks Bash syntax, both implementations' source
contracts, isolated plist/JSON/argument preservation fixtures, paired
management-URL argument handling, Windows policy sibling/subkey preservation,
and snapshot-derived exact service command acceptance.

For macOS, the source contracts require success to depend only on the managed
preference and LaunchDaemon URL, allow the daemon to begin loaded or unloaded,
and preserve that initial loaded state. Debug configuration, status, down/up,
and network convergence are deliberately not success requirements. The Python
suite also sources the production Bash helpers behind their entry guard and
exercises URL validation. The PowerShell harness similarly removes only the
entry point, dot-sources the real helper definitions, and supplies local mocks;
it must be run on Windows PowerShell 5.1 before rollout.

It deliberately does not simulate `/Library`, launchd, `HKLM`, Windows services,
ACL/SDDL behavior, or NetBird. Those checks require the disposable macOS and
Windows VM smoke matrix in
`plans/client-management-url-validation.md`; passing this local suite
does not waive that rollout gate.
