# e29-tools

Public helper scripts for E29 staff.

## e29-setup.ps1

Sets up a staff Windows computer: apps, Claude Code with the E29 plugins (signed in to the E29
claude.ai organisation), GitHub sign-in and git name and email. Senior members who can read the
project-management plugin repo also get `e29-pm`. Safe to run again: it checks first, changes only
what is missing, then verifies. It also installs what the E29 Claude skills need (Node.js, Python,
`keyring`), sets the folder variables they read, and removes the old `E29 Dataverse` entry from
Claude Desktop's config, which doubled every Dataverse tool.

In the same admin step it sets policies: OneDrive syncs `Project - Documents` (and `Grant - Documents`
for whoever can read the PM plugin repo) by itself, Chrome and Edge install the Bitwarden extension
and turn off their own password managers. Once OneDrive has added a library (up to 8 hours after
the setup), the next run keeps it on the computer. It also makes File Explorer show file
extensions. The library list is the `$Libraries` table at the top of the script. Full log: `%TEMP%\e29-setup.log`; every run
also posts it to the healthchecks.io check `e29-setup`, which keeps only logs from E29 Microsoft 365
domains.

It also registers the scheduled task `E29 setup check`, in the user's own context: every Monday at
10:00 (or at the next logon after a missed run) it runs the latest script with `-Check`, hidden,
and posts that log too. To stop it: `Unregister-ScheduledTask -TaskName 'E29 setup check'`.

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
