# e29-tools

Public helper scripts for E29 staff.

## e29-setup.ps1

Sets up a staff Windows computer: apps, Claude Code with the E29 plugins (signed in to the E29
claude.ai organisation), GitHub sign-in and git name and email. Senior members who can read the
project-management plugin repo also get `e29-pm`. Safe to run again: it checks first, changes only
what is missing, then verifies. It also installs what the E29 Claude skills need (Node.js, Python,
`keyring`) and sets the folder variables they read. Full log: `%TEMP%\e29-setup.log`; every run
also posts it to the healthchecks.io check `e29-setup`, which keeps only logs from E29 Microsoft 365
domains.

Open PowerShell (not as administrator), then run:

```powershell
irm https://raw.githubusercontent.com/E29eu/e29-tools/main/e29-setup.ps1 | iex
```

Windows asks once for admin rights, for the apps that install for all users. Browsers open for the
Claude and GitHub sign-ins.

Check only, changes nothing:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/E29eu/e29-tools/main/e29-setup.ps1))) -Check
```

The app list is the `$Apps` table at the top of the script.
