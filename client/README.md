# NetBird client tooling

These scripts manage Sleek's macOS and Windows NetBird clients. They are
administrator-operated and target `https://nbvpn.sleek.com`.

## Scripts

| Script | Platform | Purpose |
| --- | --- | --- |
| `install_netbird.sh` | macOS | Install and configure the client without a setup key |
| `install_netbird.ps1` | Windows | Install and configure the client without a setup key |
| `change_management_url.sh` | macOS | Change the installer-owned management URL surfaces |
| `change_management_url.ps1` | Windows | Change the installer-owned management URL surfaces |
| `uninstall_netbird.sh` | macOS | Remove the managed client installation |
| `uninstall_netbird.ps1` | Windows | Remove the managed client installation |

Read each script's header and run it only on the matching operating system.
The install scripts persist the management endpoint but do not complete SSO or
store a setup key. The management-URL changers preserve client identity and do
not perform logout or re-enrollment.

## Safe local verification

From the repository root:

```sh
bash -n client/install_netbird.sh
bash -n client/change_management_url.sh
bash -n client/uninstall_netbird.sh
python3 client/tests/run_change_management_url_tests.py
```

The Python suite does not execute privileged product entry points. Windows
PowerShell 5.1 verification must run on a disposable Windows VM:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\client\tests\change_management_url.Tests.ps1
```

The remaining disposable-VM matrix is tracked in
[`../plans/client-management-url-validation.md`](../plans/client-management-url-validation.md).
