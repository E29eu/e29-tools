# e29-tools

Public helper scripts for E29 staff.

## e29-cleanup.ps1

One-time cleanup of the E29 Claude plugins: removes the old GitHub-marketplace install of
`e29-core` once the copy from the E29 claude.ai organisation is present, updates `e29-pm`, runs
the e29-core setup check and verifies both plugins are version 2 or higher. Safe to run again.

Quit Claude Desktop and Claude Code, open PowerShell, then run:

```powershell
irm https://raw.githubusercontent.com/E29eu/e29-tools/main/e29-cleanup.ps1 | iex
```
