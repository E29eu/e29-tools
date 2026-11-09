# e29-tools

Public helper scripts for E29 staff.

## e29-setup.ps1

Sets up an E29 staff Windows computer: the work apps, Claude Code, the GitHub sign-in and a few
Windows, OneDrive and browser settings. Safe to run again: it checks first and changes only what is
missing.

Open PowerShell (not as administrator), then run:

```powershell
irm https://raw.githubusercontent.com/E29eu/e29-tools/main/e29-setup.ps1 | iex
```

Windows asks once for admin rights. Browsers open for the sign-ins.

Check only, changes nothing:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/E29eu/e29-tools/main/e29-setup.ps1))) -Check
```

The log is saved to `%TEMP%\e29-setup.log` and sent to E29 IT. The setup also adds a weekly
scheduled task, `E29 setup check`, that runs the check only. To remove it:
`Unregister-ScheduledTask -TaskName 'E29 setup check'`.
