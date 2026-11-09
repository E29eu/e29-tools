param([switch] $Check, [switch] $MachineOnly, [string] $UserSid, [switch] $Grant)
& {
    # E29 staff computer setup: apps, Claude with the E29 plugins, GitHub sign-in and git identity,
    # plus a device inventory and posture lines in the log.
    # Safe to run again: it checks first, changes only what is missing, then verifies. In PowerShell:
    #   irm https://raw.githubusercontent.com/E29eu/e29-tools/main/e29-setup.ps1 | iex
    # Check only, changes nothing:
    #   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/E29eu/e29-tools/main/e29-setup.ps1))) -Check
    # Runs on Windows PowerShell 5.1 and pwsh 7. Never `exit`: under `irm | iex` it closes the window.

    # Install only what is missing; the apps update themselves. user = no admin rights needed;
    # machine = one elevated step for all of them. Command: how to see a copy winget does not list.
    $Apps = @(
        @{ Name = 'Teams'; Id = 'Microsoft.Teams'; Scope = 'user' }
        @{ Name = 'Bitwarden'; Id = 'Bitwarden.Bitwarden'; Scope = 'user' }
        @{ Name = 'Claude Desktop'; Id = 'Anthropic.Claude'; Scope = 'user' }
        @{ Name = 'Obsidian'; Id = 'Obsidian.Obsidian'; Scope = 'user' }
        @{ Name = 'FFmpeg'; Id = 'Gyan.FFmpeg'; Scope = 'user'; Command = 'ffmpeg' }
        @{ Name = 'PowerShell 7'; Id = 'Microsoft.PowerShell'; Scope = 'user'; Command = 'pwsh' }
        @{ Name = 'ExifTool'; Id = 'OliverBetz.ExifTool'; Scope = 'user'; Command = 'exiftool' }
        @{ Name = 'VS Code'; Id = 'Microsoft.VisualStudioCode'; Scope = 'user'; Command = 'code' }
        @{ Name = 'Visual C++ Redistributable'; Id = 'Microsoft.VCRedist.2015+.x64'; Scope = 'machine' }
        @{ Name = 'Synology Drive Client'; Id = 'Synology.DriveClient'; Scope = 'machine' }
        @{ Name = 'Git'; Id = 'Git.Git'; Scope = 'machine'; Command = 'git' }
        @{ Name = 'GitHub CLI'; Id = 'GitHub.cli'; Scope = 'machine'; Command = 'gh' }
        @{ Name = 'Google Chrome'; Id = 'Google.Chrome'; Scope = 'machine' }
        # The E29 Dataverse connection runs through npx.
        @{ Name = 'Node.js'; Id = 'OpenJS.NodeJS.LTS'; Scope = 'machine'; Command = 'node' }
        # py, not python: Windows ships a python.exe that only opens the Store. PrependPath puts the
        # real one before it.
        @{ Name = 'Python'; Id = 'Python.Python.3.13'; Scope = 'user'; Command = 'py'; Custom = 'PrependPath=1' }
    )

    # SharePoint libraries OneDrive syncs by itself (AutoMountTeamSites policy). IDs from the
    # library's Sync > Copy library ID. Pm = only for whoever can read the PM plugin repo.
    # Microsoft supports the policy only for libraries under 5,000 files and folders.
    $tenantId = '49d5cd76-822a-4768-a27e-56c9ad7b2e3f'
    $Libraries = @(
        @{ Name = 'Project - Documents'; Url = 'https://e29eu.sharepoint.com/sites/project'; Site = '7e3c26de-33a6-4d93-b9cf-2e5b9264367a'; Web = '351d6e06-e5ff-4dec-9be0-bf40723a275c'; List = '6d415ab9-831c-4edc-885d-e224fd336ef2' }
        @{ Name = 'Grant - Documents'; Url = 'https://e29eu.sharepoint.com/sites/grant'; Site = 'e67617b3-3948-4e3d-b82b-721ce3e8f00d'; Web = 'c66f90f0-cebb-42f7-ad3e-b1540c65d63e'; List = '174496ff-101e-4ba0-9e95-61e06c839fd4'; Pm = $true }
    )

    $ErrorActionPreference = 'Continue'
    $state = @{ OK = 0; FIXED = 0; SKIP = 0; TODO = 0; FAIL = 0 }
    # TODO and FAIL lines, repeated under the summary so nothing scrolls out of sight.
    $openItems = [Collections.Generic.List[object]]::new()
    $logPath = Join-Path $env:TEMP 'e29-setup.log'
    # Claude Code resolves ~ to %USERPROFILE%; 5.1's $HOME differs on a redirected profile.
    $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $cfg = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { "$userHome\.claude" }
    # The E29 claude.ai organisation; synced folder names start with it.
    $e29OrgId = '1119948f-586d-43b6-88e5-a2431fa8ae84'
    $e29Marketplace = 'E29eu/claude-e29-core-plugin'
    $syncWaitSeconds = 120
    $pmRepo = 'E29eu/claude-e29-pm-plugin'
    $claudeInstallerUrl = 'https://claude.ai/install.ps1'
    $kb = 'https://kb.e29.eu'
    # healthchecks.io check e29-setup (project E29) receives every log. It keeps only a log whose
    # first line names an E29 Microsoft 365 domain with users (HTTP body keyword filter); anything
    # else is ignored. A new staff domain goes into the check's success and failure keywords.
    $logUrl = 'https://hc-ping.com/a9cddf4c-a6a4-4e63-9ce3-20f1bec8e5d0'

    # The whole script text, for the elevated copy: `irm | iex` leaves no file to start again.
    $root = $MyInvocation.MyCommand.ScriptBlock.Ast
    while ($root.Parent) { $root = $root.Parent }
    $selfText = $root.Extent.Text

    function Log($text) { try { Add-Content -LiteralPath $logPath -Value $text -Encoding UTF8 } catch { } }
    function Say($tag, $msg) {
        $state[$tag]++
        $color = @{ OK = 'Green'; FIXED = 'Green'; SKIP = 'Gray'; TODO = 'Yellow'; FAIL = 'Red' }[$tag]
        if ($tag -in 'TODO', 'FAIL') { $openItems.Add(@{ Text = ('[{0}] {1}' -f $tag, $msg); Color = $color }) }
        Write-Host ('[{0}] {1}' -f $tag, $msg) -ForegroundColor $color
        Log "[$tag] $msg"
    }
    function Note($msg, $color = 'Gray') { Write-Host "       $msg" -ForegroundColor $color; Log "       $msg" }
    function Section($title) { Write-Host "`n$title" -ForegroundColor Cyan; Log "`n== $title" }
    # Installers write PATH to the registry, which this session never re-reads.
    # Each entry once: repeated calls must not grow PATH towards its 32767-character limit.
    function Update-Path {
        $env:Path = @(@([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User'), $env:Path) -join ';' -split ';' |
                Where-Object { $_ } | Select-Object -Unique) -join ';'
    }
    # .exe or .cmd only: npm also puts an extensionless sh shim on PATH that Windows cannot start.
    function Find-Exe($name) { Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.cmd' } | Select-Object -First 1 -ExpandProperty Source }
    # major.minor from `<name> --version`; $null when missing or when it prints no version (the Store stub).
    function Get-ToolVersion($name) {
        if (-not ($exe = Find-Exe $name)) { return $null }
        $out = (& $exe --version 2>&1 | ForEach-Object { "$_" }) -join ' '
        if ($out -match '(\d+)\.(\d+)') { [version]"$($Matches[1]).$($Matches[2])" }
    }
    # Output of a command that may hang, or $null after $seconds. Ends the whole tree: a .cmd
    # launcher (npm install) runs Claude as a child.
    function Invoke-Timed($exe, $arguments, $seconds) {
        $psi = [Diagnostics.ProcessStartInfo]::new($exe, $arguments)
        $psi.UseShellExecute = $false
        $psi.WorkingDirectory = $userHome
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $null = $p.StandardError.ReadToEndAsync()
        if ($p.WaitForExit($seconds * 1000)) { return $out.Result }
        taskkill /PID $p.Id /T /F 2>&1 | Out-Null
    }
    # Set once, read back: Group Policy can silently discard a User environment write.
    function Set-UserVariable($name, $value) {
        if ($Check) { Say TODO "$name is not set; it would be $value."; return }
        [Environment]::SetEnvironmentVariable($name, $value, 'User')
        if ([Environment]::GetEnvironmentVariable($name, 'User') -ne $value) { Say FAIL "Could not set ${name}: Windows did not keep it."; return }
        Set-Item -Path "env:$name" -Value $value
        Say FIXED "Set $name to $value."
    }
    # Children of $roots holding one of $markers (relative folder paths).
    function Find-Root($roots, $markers) {
        @(foreach ($root in $roots) {
                if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
                foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
                    if (@($markers | Where-Object { Test-Path -LiteralPath (Join-Path $dir.FullName $_) -PathType Container }).Count) { $dir.FullName }
                }
            }) | Sort-Object -Unique
    }

    # Installed from any source counts: winget also lists Store and preinstalled copies. One list per
    # app: a single winget export misses some of them. A Store or vendor copy winget does not tie to
    # the id still lists under its name.
    function Test-App($app) {
        if ($app.Command -and (Find-Exe $app.Command)) { return $true }
        $null = winget list --id $app.Id --exact --accept-source-agreements 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
        $null = winget list --name $app.Name --accept-source-agreements 2>&1
        $LASTEXITCODE -eq 0
    }
    function Install-App($app) {
        Note "Installing $($app.Name)..."
        $custom = if ($app.Custom) { '--custom', $app.Custom }
        $out = winget install --id $app.Id --exact --scope $app.Scope --silent --accept-package-agreements --accept-source-agreements @custom 2>&1 |
            ForEach-Object { "$_".Trim() } | Where-Object { $_.Length -gt 1 -and $_ -notmatch '^[-\\|/ ]+$' }
        Log ($out -join "`n")
        $LASTEXITCODE
    }
    function Get-InstallHint($app) { "winget install --id $($app.Id) --exact --scope $($app.Scope)" }

    # --- Policies --- only an admin can write them, the user's own policy key too. The elevated copy
    # writes that key by the user's SID, so it lands on the right user whichever admin approves.
    $sid = if ($UserSid) { $UserSid } else { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    function Get-Library($grant) { $Libraries | Where-Object { $grant -or -not $_.Pm } }
    function Get-Policy($grant) {
        foreach ($lib in @(Get-Library $grant)) {
            $id = "tenantId=$tenantId&siteId=%7B$($lib.Site)%7D&webId=%7B$($lib.Web)%7D&listId=%7B$($lib.List)%7D&webUrl=$([uri]::EscapeDataString($lib.Url))&version=1"
            @{ Label = "OneDrive syncs $($lib.Name)"; Key = "Registry::HKEY_USERS\$sid\Software\Policies\Microsoft\OneDrive\TenantAutoMount"; Name = $lib.Name; Value = $id }
        }
        # Bitwarden replaces the browsers' own password managers. Its server URL stays a manual step.
        foreach ($b in @(
                @{ Name = 'Chrome'; Key = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome'; Ext = 'nngceckbapebfimnlniiiahkandclblb;https://clients2.google.com/service/update2/crx' },
                @{ Name = 'Edge'; Key = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge'; Ext = 'jbkfoedolllekgbhcbcoahefnbanhhlh;https://edge.microsoft.com/extensionwebstorebase/v1/crx' })) {
            @{ Label = "$($b.Name) password manager is off"; Key = $b.Key; Name = 'PasswordManagerEnabled'; Value = 0 }
            @{ Label = "$($b.Name) installs the Bitwarden extension"; Key = "$($b.Key)\ExtensionInstallForcelist"; List = $b.Ext }
        }
    }
    # List = one entry of a numbered list policy, added after any entries already there.
    function Test-Policy($p) {
        $item = Get-Item -LiteralPath $p.Key -ErrorAction SilentlyContinue
        if (-not $item) { return $false }
        if ($p.List) { return [bool]@($item.GetValueNames() | Where-Object { "$($item.GetValue($_))".Split(';')[0] -eq $p.List.Split(';')[0] }).Count }
        "$($item.GetValue($p.Name))" -eq "$($p.Value)"
    }
    function Set-Policy($p) {
        if (Test-Policy $p) { return }
        try {
            if (-not (Test-Path -LiteralPath $p.Key)) { $null = New-Item -Path $p.Key -Force -ErrorAction Stop }
            if ($p.List) {
                $names = @((Get-Item -LiteralPath $p.Key).GetValueNames())
                $n = 1; while ($names -contains "$n") { $n++ }
                $null = New-ItemProperty -LiteralPath $p.Key -Name "$n" -Value $p.List -PropertyType String -Force -ErrorAction Stop
            }
            else { $null = New-ItemProperty -LiteralPath $p.Key -Name $p.Name -Value $p.Value -PropertyType $(if ($p.Value -is [int]) { 'DWord' } else { 'String' }) -Force -ErrorAction Stop }
        }
        catch { Log "policy $($p.Label): $($_.Exception.Message)" }
    }

    # Elevated copy: machine-wide apps and policies only, then back to the first window.
    if ($MachineOnly) {
        Write-Host "`nE29 setup - apps and settings for all users`n" -ForegroundColor White
        foreach ($p in @(Get-Policy $Grant | Where-Object { -not (Test-Policy $_) })) {
            Set-Policy $p
            if (Test-Policy $p) { Write-Host "[FIXED] $($p.Label)." -ForegroundColor Green }
            else { Write-Host "[FAIL] Could not set: $($p.Label)." -ForegroundColor Red }
        }
        # winget is per user, and the admin who typed the password may never have had it. The
        # policies above need no winget.
        if (-not (Find-Exe winget)) {
            Write-Host '[FAIL] winget is not available for this admin account.' -ForegroundColor Red
            Start-Sleep -Seconds 10
            # Safe here: this copy runs from a file, never under irm | iex. 3 tells the first window why.
            exit 3
        }
        foreach ($app in @($Apps | Where-Object { $_.Scope -eq 'machine' })) {
            if (Test-App $app) { continue }
            $code = Install-App $app
            Update-Path
            if (Test-App $app) { Write-Host "[FIXED] Installed $($app.Name)." -ForegroundColor Green }
            else { Write-Host "[FAIL] Could not install $($app.Name) (winget exit $code)." -ForegroundColor Red }
        }
        Write-Host "`nDone. This window closes in 5 seconds; the first window carries on." -ForegroundColor White
        Start-Sleep -Seconds 5
        return
    }

    # --- Claude helpers ---
    function Invoke-Claude {
        $out = (& $claude @args 2>&1 | ForEach-Object { "$_" }) -join ' '
        @{ Ok = ($LASTEXITCODE -eq 0); Out = $out }
    }
    function Get-ClaudeJson {
        $text = (& $claude @args 2>$null) -join "`n"
        # From the first line that opens the array: a warning printed before it may hold brackets.
        $match = [regex]::Match("$text", '(?ms)^\[.*\]')
        if (-not $match.Success) { return $null }
        # Unreadable must not look like "e29-core missing": that answer deletes the synced folder.
        try { $parsed = $match.Value | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
        return , @($parsed)
    }
    function Get-Core { $list = Get-ClaudeJson plugin list --json; $list | Where-Object { $_.id -eq 'e29-core@synced' } | Select-Object -First 1 }
    function Get-Auth { try { (& $claude auth status 2>$null) -join "`n" | ConvertFrom-Json -ErrorAction Stop } catch { $null } }
    function Get-Major($version) { $major = 0; [void][int]::TryParse("$version".Split('.')[0], [ref]$major); $major }
    # Remove-Item gives up silently past 260 characters on Windows PowerShell 5.1, and synced plugin
    # paths run longer; rd with the \\?\ prefix does not. $true = gone.
    function Remove-Dir($path) {
        if (-not (Test-Path -LiteralPath $path)) { return $true }
        $full = [IO.Path]::GetFullPath($path)
        $long = if ($full.StartsWith('\\')) { '\\?\UNC\' + $full.Substring(2) } else { '\\?\' + $full }
        cmd /c rd /s /q $long 2>&1 | Out-Null
        -not (Test-Path -LiteralPath $path)
    }
    # A personal upload named e29-core (claude.ai "My Uploads") is synced in place of the E29 one.
    function Get-UploadedCore {
        foreach ($m in @(Get-ChildItem "$cfg\plugins\synced\*\manifest.json" -Force -ErrorAction SilentlyContinue)) {
            try { (Get-Content -LiteralPath $m.FullName -Raw | ConvertFrom-Json).plugins | Where-Object { $_.name -eq 'e29-core' -and $_.marketplaceName -ne $e29Marketplace } } catch { }
        }
    }
    # Changes each time a claude.ai sync round finishes.
    function Get-SyncRound { (Get-ChildItem "$cfg\plugins\synced\*\.last-complete-round" -Force -ErrorAction SilentlyContinue | Get-Content -Raw -ErrorAction SilentlyContinue) -join ',' }
    # A headless Claude syncs claude.ai plugins as it starts, but a -p run quits once it has replied,
    # which can cut the download short. Fed by stream-json it stays up until its input closes: keep
    # it open until e29-core is 2 or higher, a sync round ends, or time runs out.
    function Wait-Sync {
        $round = Get-SyncRound
        $psi = [Diagnostics.ProcessStartInfo]::new($claude, '-p --input-format stream-json --output-format stream-json --verbose')
        $psi.UseShellExecute = $false
        $psi.WorkingDirectory = $userHome
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi)
        $p.BeginOutputReadLine(); $p.BeginErrorReadLine()
        $deadline = (Get-Date).AddSeconds($syncWaitSeconds)
        do { Start-Sleep -Seconds 3; $core = Get-Core }
        until ((Get-Major $core.version) -ge 2 -or $p.HasExited -or (Get-Date) -gt $deadline -or (Get-SyncRound) -ne $round)
        $p.StandardInput.Close()
        # A .cmd launcher (npm install) runs Claude as a child: end the whole tree.
        if (-not $p.WaitForExit(20000)) { taskkill /PID $p.Id /T /F 2>&1 | Out-Null; [void]$p.WaitForExit(5000) }
        Get-Core
    }
    # Claude Code skips the claude.ai plugin sync when the sign-in lacks the user:plugins scope
    # (sign-ins from older versions). Reads only the scope list, never a token. $null = unknown.
    function Get-PluginScope {
        try { $text = [IO.File]::ReadAllText("$cfg\.credentials.json") } catch { return $null }
        $match = [regex]::Match($text, '"claudeAiOauth"\s*:\s*\{[^{}]*?"scopes"\s*:\s*\[([^\]]*)\]')
        if (-not $match.Success) { return $null }
        $match.Groups[1].Value.Contains('"user:plugins"')
    }
    # A sign-in that names no organisation is not sent to log in again; after a login it must be E29.
    function Test-E29SignIn($auth, [switch] $Strict) {
        $auth -and $auth.loggedIn -and ($auth.orgId -eq $e29OrgId -or (-not $Strict -and -not $auth.orgId)) -and (Get-PluginScope) -ne $false
    }
    function Update-Claude {
        $before = (& $claude --version 2>$null) -join ' '
        [void](Invoke-Claude update)
        $after = (& $claude --version 2>$null) -join ' '
        if ($after -ne $before) { Say FIXED "Updated Claude Code: $before to $after" }
    }
    # A running Claude holds its plugin folder open; Claude Desktop also starts itself after install.
    # $true = no Claude runs.
    function Wait-ClaudeQuit {
        while (@(Get-Process -Name claude -ErrorAction SilentlyContinue).Count) {
            Note 'Claude is running. Quit Claude Desktop (also right-click its tray icon next to the clock and choose Quit) and close every Claude Code window, including inside VS Code.' Yellow
            if ((Read-Host '       Press Enter to check again, or type S and Enter to skip') -eq 'S') { return $false }
        }
        $true
    }
    # Why the claude.ai copy on disk is old or missing: sign-in, and what the last sync wrote.
    function Show-SyncInfo($core) {
        $lines = @("claude $((& $claude --version 2>$null) -join ' ') at $claude, config $cfg")
        if ($a = Get-Auth) { $lines += "signed in: $($a.loggedIn) via $($a.authMethod) as $($a.email), org $($a.orgName) $($a.orgId)" }
        else { $lines += 'auth status: unreadable' }
        $lines += "sign-in allows plugin sync (user:plugins): $(if ($null -eq ($scope = Get-PluginScope)) { 'unknown' } else { $scope })"
        if ($core) { $lines += "loaded from: $($core.installPath)" }
        $buckets = @(Get-ChildItem "$cfg\plugins\synced" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.*' })
        if (-not $buckets.Count) { $lines += "no synced folder in $cfg\plugins\synced - this Claude Code never synced from claude.ai" }
        foreach ($bucket in $buckets) {
            $lines += "folder $($bucket.Name)"
            try {
                $m = Get-Content -LiteralPath "$($bucket.FullName)\manifest.json" -Raw -ErrorAction Stop | ConvertFrom-Json
                $lines += "  last sync $(if ($m.lastUpdated) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$m.lastUpdated).LocalDateTime } else { 'never' })"
                foreach ($p in @($m.plugins | Where-Object { $_.name -eq 'e29-core' })) { $lines += "  claude.ai sends e29-core $($p.pluginId) from $($p.marketplaceName) ($($p.installationPreference)), generation $($p.generation), updated $($p.updatedAt)" }
                foreach ($r in @((Get-Content -LiteralPath "$($bucket.FullName)\.marketplaces.json" -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).rows)) { if ($r) { $lines += "  marketplace $($r.name) ($($r.scope)), updated $($r.updated_at)" } }
            }
            catch { $lines += '  no readable manifest.json' }
            foreach ($dir in @(Get-ChildItem -LiteralPath $bucket.FullName -Directory -Force | Where-Object { $_.Name -like 'e29-core*' -or $_.Name -eq '.staging' })) {
                $version = try { (Get-Content -LiteralPath "$($dir.FullName)\.claude-plugin\plugin.json" -Raw -ErrorAction Stop | ConvertFrom-Json).version } catch { '-' }
                $lines += "  $($dir.Name)  v$version  $($dir.LastWriteTime)  ($(@(Get-ChildItem -LiteralPath $dir.FullName -Force).Count) items)"
            }
        }
        Note 'Details for Attila:'
        $lines | ForEach-Object { Note "  $_" }
    }

    try { Set-Content -LiteralPath $logPath -Value "E29 setup $(Get-Date -Format s) on $env:COMPUTERNAME as $env:USERNAME$(if ($Check) { ' (check only)' })" -Encoding UTF8 } catch { }
    Write-Host "`nE29 computer setup$(if ($Check) { ' - CHECK ONLY, nothing is changed' })" -ForegroundColor White

    # --- 1. Preflight ---
    Section '1. This computer'
    # Windows 11 still reports major version 10; its builds start at 22000.
    if ([Environment]::OSVersion.Version.Build -lt 22000) {
        Say FAIL "Windows $([Environment]::OSVersion.Version) is too old: this setup needs Windows 11."
        return
    }
    if (-not (Find-Exe winget)) {
        Say FAIL 'winget is missing. Install or update App Installer from the Microsoft Store, then paste this again:'
        Note 'https://apps.microsoft.com/detail/9NBLGGH4NNS1' Yellow
        return
    }
    Say OK "Windows $([Environment]::OSVersion.Version.Build), winget $((winget --version) -join '')."

    # Inventory, for the log Attila reconciles with the Assets table (serial number), Entra and
    # Intune (device name, device id, MAC addresses). Reads only, no admin rights needed.
    function Get-Safe($block) { try { & $block } catch { } }
    $cs = Get-Safe { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
    $bios = Get-Safe { Get-CimInstance Win32_BIOS -ErrorAction Stop }
    $cpu = Get-Safe { Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 }
    $os = Get-Safe { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $memory = (Get-Safe { Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop } | Measure-Object Capacity -Sum).Sum
    Note "Device: $env:COMPUTERNAME"
    Note "Model: $($cs.Manufacturer) $($cs.Model)"
    Note "Serial number: $("$($bios.SerialNumber)".Trim())"
    Note "BIOS: $($bios.SMBIOSBIOSVersion)$(if ($bios.ReleaseDate) { ", $($bios.ReleaseDate.ToString('yyyy-MM-dd'))" })"
    Note ('CPU: {0}, {1} cores' -f "$($cpu.Name)".Trim(), $cpu.NumberOfCores)
    Note ('Memory: {0:N0} GB' -f ($memory / 1GB))
    foreach ($disk in @(Get-Safe { Get-PhysicalDisk -ErrorAction Stop })) { Note ('Disk: {0}, {1:N0} GB {2} {3}, {4}' -f $disk.FriendlyName, ($disk.Size / 1GB), $disk.MediaType, $disk.BusType, $disk.HealthStatus) }
    # Design capacity needs admin rights in WMI; the battery report does not.
    if (Get-Safe { Get-CimInstance Win32_Battery -ErrorAction Stop }) {
        $report = Join-Path $env:TEMP "e29-battery-$PID.xml"
        $null = powercfg /batteryreport /xml /output $report 2>&1
        foreach ($b in @(Get-Safe { ([xml](Get-Content -LiteralPath $report -Raw -ErrorAction Stop)).BatteryReport.Batteries.Battery })) {
            if ([double]$b.DesignCapacity -gt 0) { Note ('Battery: {0:N0} of {1:N0} mWh design ({2:P0}), {3} cycles' -f [double]$b.FullChargeCapacity, [double]$b.DesignCapacity, ([double]$b.FullChargeCapacity / [double]$b.DesignCapacity), $b.CycleCount) }
        }
        Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue
    }
    Note "Windows: $($os.Caption) $($cv.DisplayVersion), build $($cv.CurrentBuild).$($cv.UBR), $($os.OSArchitecture)$(if ($os.InstallDate) { ", installed $($os.InstallDate.ToString('yyyy-MM-dd'))" })$(if ($os.LastBootUpTime) { ", started $($os.LastBootUpTime.ToString('yyyy-MM-dd'))" })"
    # Entra device id: joined, or registered to the E29 tenant (a work account added in Settings).
    $dsreg = (dsregcmd /status 2>$null) -join "`n"
    $registered = @([regex]::Matches($dsreg, 'WorkplaceDeviceId : (\S+)[\s\S]*?WorkplaceTenantId : (\S+)') | Where-Object { $_.Groups[2].Value -eq $tenantId })
    if ($dsreg -match 'AzureAdJoined : YES' -and $dsreg -match '\bDeviceId : (\S+)') { Note "Entra: joined, device id $($Matches[1])" }
    elseif ($registered.Count) { Note "Entra: registered, device id $($registered[0].Groups[1].Value)" }
    else { Note 'Entra: not joined or registered to E29' }
    $mdm = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue | Get-ItemProperty -ErrorAction SilentlyContinue | Where-Object { $_.ProviderID -eq 'MS DM Server' -and $_.UPN } | ForEach-Object { $_.UPN } | Sort-Object -Unique)
    Note "Intune: $(if ($mdm.Count) { "enrolled as $($mdm -join ', ')" } else { 'not enrolled' })"
    # Built-in adapters only: a USB dock's MAC moves between laptops.
    foreach ($nic in @(Get-Safe { Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.MacAddress -and $_.InterfaceDescription -notmatch 'USB' } })) { Note "Network: $($nic.InterfaceDescription), MAC $($nic.MacAddress)" }
    $secureBoot = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue).UEFISecureBootEnabled
    Note "Secure Boot: $(if ($secureBoot -eq 1) { 'on' } elseif ($null -ne $secureBoot) { 'off' } else { 'not supported' })"
    Note "TPM: $(@(Get-Safe { Get-CimInstance Win32_PnPEntity -Filter "PNPClass='SecurityDevices'" -ErrorAction Stop } | Where-Object { $_.Name -match 'Trusted Platform Module' } | ForEach-Object { $_.Name }) -join ', ')"

    # Posture: read only in both modes; each TODO says what the user fixes.
    # Shell values: 1 on, 2 off, 3 encrypting, 4 decrypting, 5 suspended, 6 on and locked, 8 waiting
    # for activation. Win32_EncryptableVolume needs admin rights; this does not.
    $bitlocker = Get-Safe { (New-Object -ComObject Shell.Application).NameSpace("$env:SystemDrive\").Self.ExtendedProperty('System.Volume.BitLockerProtection') }
    $bitlockerText = if ($null -ne $bitlocker) { @{ 0 = 'not supported'; 1 = 'on'; 2 = 'off'; 3 = 'encrypting'; 4 = 'decrypting'; 5 = 'suspended'; 6 = 'on'; 8 = 'waiting for activation' }[[int]$bitlocker] }
    if ($null -eq $bitlocker) { Note 'Could not read the disk encryption state.' }
    elseif ($bitlocker -in 1, 3, 6) { Say OK "Disk encryption (BitLocker) on $env:SystemDrive is $bitlockerText." }
    else { Say TODO "Disk encryption (BitLocker) on $env:SystemDrive is $(if ($bitlockerText) { $bitlockerText } else { "in state $bitlocker" }). Turn it on: Settings > Privacy & security > Device encryption; on Windows Pro search BitLocker and choose Turn on BitLocker. Save the recovery key in Bitwarden." }

    # Every product Windows Security knows: Bitdefender turns Microsoft Defender off.
    # productState: 0x1000 = on, 0x10 = definitions out of date.
    $av = @(Get-Safe { Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop })
    foreach ($a in $av) { Note ('Antivirus: {0}, {1}, {2}' -f $a.displayName, $(if ($a.productState -band 0x1000) { 'on' } else { 'off' }), $(if ($a.productState -band 0x10) { 'out of date' } else { 'up to date' })) }
    $avGood = @($av | Where-Object { ($_.productState -band 0x1000) -and -not ($_.productState -band 0x10) })
    if ($avGood.Count) { Say OK "Antivirus $(@($avGood | ForEach-Object { $_.displayName }) -join ', ') is on and up to date." }
    else { Say TODO "No antivirus is on and up to date$(if ($av.Count) { " ($(@($av | ForEach-Object { $_.displayName }) -join ', '))" }). Open Windows Security > Virus & threat protection, turn it on and choose Check for updates." }

    # Windows packages only: the update history also lists daily Defender definitions. Patch Tuesdays
    # can be 35 days apart, so an up-to-date laptop may show 34 days.
    $lastUpdate = Get-Safe { Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1 }
    if ($lastUpdate) {
        $days = [int]((Get-Date) - $lastUpdate.InstalledOn).TotalDays
        $text = "Last Windows update $($lastUpdate.HotFixID) on $($lastUpdate.InstalledOn.ToString('yyyy-MM-dd')), $days days ago."
        if ($days -le 40) { Say OK $text } else { Say TODO "$text Settings > Windows Update > Check for updates, install everything and restart." }
    }
    else { Note 'Could not read the last Windows update.' }

    $sysDrive = Get-Safe { [IO.DriveInfo]::new($env:SystemDrive) }
    if ($sysDrive.TotalSize) {
        $text = '{0} has {1:N0} GB free of {2:N0} GB ({3:P0}).' -f $env:SystemDrive, ($sysDrive.AvailableFreeSpace / 1GB), ($sysDrive.TotalSize / 1GB), ($sysDrive.AvailableFreeSpace / $sysDrive.TotalSize)
        if ($sysDrive.AvailableFreeSpace / $sysDrive.TotalSize -ge 0.1) { Say OK $text } else { Say TODO "$text Free up space: Settings > System > Storage > Cleanup recommendations." }
    }

    # --- 2. Apps ---
    Section '2. Apps and settings'
    # Grant - Documents follows the PM plugin repo access. gh is not signed in on a first run: the
    # next run adds it.
    $grantAccess = $false
    if ($ghExe = Find-Exe gh) { & $ghExe api "repos/$pmRepo" --silent 2>$null; $grantAccess = $LASTEXITCODE -eq 0 }
    $policies = @(Get-Policy $grantAccess)
    $missing = @($Apps | Where-Object { -not (Test-App $_) })
    $unset = @($policies | Where-Object { -not (Test-Policy $_) })
    foreach ($app in @($Apps | Where-Object { $missing -notcontains $_ })) { Say OK "$($app.Name) is installed." }
    foreach ($p in @($policies | Where-Object { $unset -notcontains $_ })) { Say OK "$($p.Label)." }
    if ($Check) {
        foreach ($app in $missing) { Say TODO "$($app.Name) is not installed." }
        foreach ($p in $unset) { Say TODO "Not set yet: $($p.Label)." }
    }
    else {
        $codes = @{}
        $elevated = $false
        foreach ($app in @($missing | Where-Object { $_.Scope -eq 'user' })) { $codes[$app.Id] = Install-App $app }
        $machine = @($missing | Where-Object { $_.Scope -eq 'machine' })
        if ($machine.Count -or $unset.Count) {
            $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if ($isAdmin) {
                foreach ($app in $machine) { $codes[$app.Id] = Install-App $app }
                foreach ($p in $unset) { Set-Policy $p }
                $elevated = $true
            }
            else {
                Note "Some apps and settings are for all users. Windows asks for admin rights once: choose Yes." Yellow
                $selfPath = Join-Path $env:TEMP 'e29-setup.ps1'
                try {
                    [IO.File]::WriteAllText($selfPath, $selfText, (New-Object Text.UTF8Encoding $true))
                    $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$selfPath`" -MachineOnly -UserSid $sid$(if ($grantAccess) { ' -Grant' })"
                    Log "elevated step exited $($p.ExitCode)"
                    if ($p.ExitCode -eq 3) { Note 'The admin account has no winget. The admin signs in to Windows once and updates App Installer from the Microsoft Store, then paste this again.' Yellow }
                    # Tried there; its window showed each winget result.
                    foreach ($app in $machine) { $codes[$app.Id] = $null }
                    $elevated = $true
                }
                catch { Note "No admin rights: $($_.Exception.Message)" }
            }
        }
        Update-Path
        foreach ($app in $missing) {
            if (Test-App $app) { Say FIXED "Installed $($app.Name)." }
            elseif (-not $codes.ContainsKey($app.Id)) {
                Say TODO "$($app.Name) is not installed: it needs admin rights. Ask someone with admin rights to run:  $(Get-InstallHint $app)"
            }
            else { Say FAIL "Could not install $($app.Name)$(if ($null -ne $codes[$app.Id]) { " (winget exit $($codes[$app.Id]))" }). Try:  $(Get-InstallHint $app)" }
        }
        foreach ($p in $unset) {
            if (Test-Policy $p) { Say FIXED "$($p.Label)." }
            elseif (-not $elevated) { Say TODO "Not set: $($p.Label). It needs admin rights: someone with admin rights pastes this again." }
            else { Say FAIL "Could not set: $($p.Label)." }
        }
    }

    # Shows .pdf and .docx, so nobody saves x.pdf.pdf.
    $explorer = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    if ((Get-ItemProperty -LiteralPath $explorer -Name HideFileExt -ErrorAction SilentlyContinue).HideFileExt -eq 0) { Say OK 'File Explorer shows file extensions.' }
    elseif ($Check) { Say TODO 'File Explorer hides file extensions.' }
    else {
        try {
            Set-ItemProperty -LiteralPath $explorer -Name HideFileExt -Value 0 -Type DWord -ErrorAction Stop
            Say FIXED 'File Explorer shows file extensions from the next sign-in.'
        }
        catch { Say FAIL "Could not make File Explorer show file extensions: $($_.Exception.Message)" }
    }

    # Claude Code in VS Code, for website editing. No VS Code: its app line above already says so.
    $vscode = Find-Exe code
    $extension = 'anthropic.claude-code'
    if ($vscode) {
        if (@(& $vscode --list-extensions 2>$null) -contains $extension) { Say OK 'Claude Code extension for VS Code is installed.' }
        elseif ($Check) { Say TODO 'Claude Code extension for VS Code is not installed.' }
        else {
            Log ((& $vscode --install-extension $extension 2>&1 | ForEach-Object { "$_" }) -join "`n")
            if (@(& $vscode --list-extensions 2>$null) -contains $extension) { Say FIXED 'Installed the Claude Code extension for VS Code.' }
            else { Say FAIL "Could not install the Claude Code extension for VS Code. Try:  code --install-extension $extension" }
        }
    }

    # Kept, never upgraded: other software may pin an old version. Missing: its app line says so.
    $nodeVersion = Get-ToolVersion node
    if ($nodeVersion -and $nodeVersion -lt [version]'18.0') { Say FAIL "Node.js $nodeVersion is too old: E29 Dataverse needs 18 or newer. Try:  winget install --id OpenJS.NodeJS.LTS --exact" }
    elseif ($nodeVersion -and $nodeVersion -lt [version]'24.0') { Say TODO "Node.js $nodeVersion is old: the E29 websites need 24. Run:  winget upgrade --id OpenJS.NodeJS.LTS --exact" }
    # The skills call python; fill-travel-distance needs 3.11 (enum.StrEnum).
    $pythonVersion = Get-ToolVersion python
    if (-not $pythonVersion) { if (Find-Exe py) { Say TODO 'python opens the Microsoft Store. Turn it off: Settings > Apps > Advanced app settings > App execution aliases > python.exe and python3.exe off. Then paste this again.' } }
    elseif ($pythonVersion -lt [version]'3.11') { Say TODO "Python $pythonVersion is too old: the E29 skills need 3.11 or newer. Run:  winget install --id Python.Python.3.13 --exact --scope user --custom PrependPath=1" }

    # --- 3. Claude ---
    Section '3. Claude'
    $claude = $null
    $userEmail = $null
    & {
        # Claude Code: PATH, the native install, or npm.
        $claude = @(Find-Exe claude) + @("$userHome\.local\bin\claude.exe", "$env:APPDATA\npm\claude.cmd" | Where-Object { Test-Path $_ }) | Where-Object { $_ } | Select-Object -First 1
        if (-not $claude -and -not $Check) {
            Note "Installing Claude Code with the official installer: $claudeInstallerUrl"
            $installer = Join-Path $env:TEMP "claude-install-$PID.ps1"
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $claudeInstallerUrl -OutFile $installer -UseBasicParsing
                # A child process: the installer's own strict mode or exit cannot end this run.
                $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer 2>&1 | ForEach-Object { "$_" }
                Log ($out -join "`n")
            }
            catch { Note "Download failed: $($_.Exception.Message)" }
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
            Update-Path
            if (Test-Path "$userHome\.local\bin\claude.exe") { $claude = "$userHome\.local\bin\claude.exe"; Say FIXED 'Installed Claude Code.' }
            else { Say FAIL "Could not install Claude Code. Try:  irm $claudeInstallerUrl | iex" }
        }
        elseif (-not $claude) {
            Say TODO 'Claude Code is not installed.'
            # Check only: Claude Desktop's or VS Code's copy can still answer the questions below.
            $claude = @(Get-ChildItem "$env:APPDATA\Claude\claude-code", "$env:LOCALAPPDATA\Packages\Claude_*\LocalCache\Roaming\Claude\claude-code", "$userHome\.vscode\extensions\anthropic.claude-code-*\resources\native-binary" -Recurse -Filter claude.exe -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName }) | Select-Object -First 1
        }
        else { Say OK "Claude Code is installed ($claude)." }
        if (-not $claude) { return }
        Set-Variable -Name claude -Value $claude -Scope 1

        # Found outside PATH: new terminals need it there. Written as REG_EXPAND_SZ, which keeps every
        # %TOKEN% (SetEnvironmentVariable would freeze them; setx cuts at 1024 characters).
        if (-not (Find-Exe claude) -and $claude -in "$userHome\.local\bin\claude.exe", "$env:APPDATA\npm\claude.cmd") {
            $claudeDir = Split-Path -Parent $claude
            if ($Check) { Say TODO "claude is not on PATH ($claudeDir)." }
            else {
                try {
                    $raw = "$((Get-Item -LiteralPath 'HKCU:\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames'))"
                    Set-ItemProperty -LiteralPath 'HKCU:\Environment' -Name Path -Value ((@($raw.Split(';') | Where-Object { $_ }) + $claudeDir) -join ';') -Type ExpandString
                    # Deleting a never-stored dummy makes .NET broadcast the change to new terminals.
                    [Environment]::SetEnvironmentVariable('E29_SETUP_BROADCAST', $null, 'User')
                    Update-Path
                    Say FIXED "Added $claudeDir to PATH. New terminals find claude."
                }
                catch { Say FAIL "Could not add $claudeDir to PATH: $($_.Exception.Message)" }
            }
        }

        # Sign-in: the E29 organisation, with the user:plugins scope the claude.ai plugin sync needs.
        # An old Claude Code gives no readable sign-in and does not sync claude.ai plugins: update it first.
        $auth = Get-Auth
        $updated = $false
        if (-not $auth -and -not $Check) { Update-Claude; $updated = $true; $auth = Get-Auth }
        if ($auth.configDirectory) { Set-Variable -Name cfg -Value $auth.configDirectory -Scope 1; $cfg = $auth.configDirectory }
        if (-not $auth) { Note "Could not read the Claude sign-in; carrying on. To see why:  & '$claude' auth status" Yellow }
        elseif (Test-E29SignIn $auth) { Say OK "Signed in to Claude as $($auth.email)$(if ($auth.orgName) { " ($($auth.orgName))" })." }
        elseif ($Check) { Say TODO "Claude is $(if ($auth.loggedIn) { "signed in as $($auth.email) ($($auth.orgName)), not with an E29 account that can download plugins" } else { 'not signed in' })." }
        else {
            Note "Claude is $(if ($auth.loggedIn) { "signed in as $($auth.email) ($($auth.orgName))" } else { 'not signed in' }). A browser opens now:" Yellow
            Note 'sign in with your E29 claude.ai account, then come back to this window.' Yellow
            & $claude auth login --claudeai
            $auth = Get-Auth
            if (Test-E29SignIn $auth -Strict) { Say FIXED "Signed in to Claude as $($auth.email) (E29)." }
            else { Say FAIL "Claude is still not signed in with an E29 account that can download plugins ($($auth.email), $($auth.orgName))."; return }
        }
        if (Test-E29SignIn $auth -Strict) { Set-Variable -Name userEmail -Value $auth.email -Scope 1 }

        $plugins = Get-ClaudeJson plugin list --json
        if ($null -eq $plugins) { Say FAIL "Could not read the Claude plugin list. Run this to see why:  & '$claude' plugin list"; return }

        # e29-core comes from the claude.ai organisation. Missing or old: update Claude Code first (an
        # old one does not sync claude.ai plugins); a headless run then syncs. A cut-short download
        # leaves .staging behind, so that goes next, then the whole synced folder (a cache of claude.ai).
        $core = $plugins | Where-Object { $_.id -eq 'e29-core@synced' } | Select-Object -First 1
        $oldVersion = if ($core) { $core.version } else { 'missing' }
        $uploaded = $null
        if (-not $Check) {
            foreach ($reset in 'update', '.staging', 'all') {
                # No reset helps against an own upload: claude.ai sends it again.
                if ((Get-Major $core.version) -ge 2 -or (Get-UploadedCore)) { break }
                if ($reset -eq 'update') {
                    Note "e29-core is $(if ($core) { "old ($($core.version))" } else { 'missing' }); getting the current version from claude.ai..." Yellow
                    if (-not $updated) { Update-Claude }
                }
                elseif (-not (Wait-ClaudeQuit)) {
                    Say TODO 'Claude is still running, so its plugin download folder was not reset. Quit Claude everywhere (also its tray icon), then paste this again.'
                    break
                }
                else {
                    # Every bucket, not the one installPath names: a half-synced e29-core lists no installPath.
                    $dirs = if ($reset -eq 'all') { "$cfg\plugins\synced" } else { @(Get-ChildItem "$cfg\plugins\synced\*\.staging" -Directory -Force -ErrorAction SilentlyContinue).FullName }
                    foreach ($dir in $dirs) { if (-not (Remove-Dir $dir)) { Say TODO "Could not delete $dir (a file is in use). Restart Windows, then paste this again." } }
                }
                Note "Waiting for the download from claude.ai (up to $syncWaitSeconds seconds)..."
                $core = Wait-Sync
            }
            $plugins = Get-ClaudeJson plugin list --json
            $core = $plugins | Where-Object { $_.id -eq 'e29-core@synced' } | Select-Object -First 1
            if ($core -and $core.version -ne $oldVersion -and (Get-Major $core.version) -ge 2) { Say FIXED "Downloaded e29-core $($core.version) (was $oldVersion)." }
        }
        if ((Get-Major $core.version) -lt 2 -and ($uploaded = @(Get-UploadedCore)[0])) {
            Say TODO "Your claude.ai account has its own old copy of e29-core (in My Uploads, from $($uploaded.updatedAt)). It hides the E29 one."
            Note 'In claude.ai open Customize > Plugins, delete e29-core under My Uploads, then paste this again.' Yellow
        }

        # Old e29-core from the GitHub marketplace, at every scope. Kept while the new one is below 2:
        # it may be the only working copy.
        $ready = (Get-Major $core.version) -ge 2
        foreach ($old in @($plugins | Where-Object { $ready -and $_.id -eq 'e29-core@e29-core' })) {
            $folder = if ($old.scope -eq 'user') { $userHome } else { $old.projectPath }
            if (-not $folder -or -not (Test-Path $folder)) { continue }
            if ($Check) { Say TODO "Old e29-core $($old.version) is still installed ($($old.scope) scope)."; continue }
            Push-Location $folder
            $run = Invoke-Claude plugin uninstall e29-core@e29-core --scope $old.scope
            Pop-Location
            if (-not $run.Ok) { Say FAIL "Could not remove old e29-core ($($old.scope) scope): $($run.Out)"; continue }
            Say FIXED "Removed old e29-core $($old.version) ($($old.scope) scope)."
            if ($old.scope -eq 'project') { Note "This changed $folder\.claude\settings.json: commit that change." }
        }
        $markets = Get-ClaudeJson plugin marketplace list --json
        if ($ready -and @($markets | Where-Object { $_.name -eq 'e29-core' }).Count) {
            if ($Check) { Say TODO 'The old e29-core marketplace is still added.' }
            else {
                $run = Invoke-Claude plugin marketplace remove e29-core
                if ($run.Ok) { Say FIXED 'Removed the old e29-core marketplace.' } else { Say FAIL "Could not remove the old e29-core marketplace: $($run.Out)" }
            }
        }
        # Folders go only once Claude itself no longer lists the old plugin or marketplace: a failed
        # remove or an unreadable list must not leave a registered plugin without its files.
        $leftover = @("$cfg\plugins\cache\e29-core", "$cfg\plugins\marketplaces\e29-core" | Where-Object { Test-Path $_ })
        if ($ready -and -not $Check -and $leftover.Count) {
            $plugins = Get-ClaudeJson plugin list --json
            $markets = Get-ClaudeJson plugin marketplace list --json
            if ($null -eq $plugins -or $null -eq $markets) { Say FAIL "Could not read the Claude plugin lists, so the old e29-core folders were kept. Run this to see why:  & '$claude' plugin list" }
            elseif (-not @($plugins | Where-Object { $_.id -eq 'e29-core@e29-core' -and ($_.scope -eq 'user' -or ($_.projectPath -and (Test-Path $_.projectPath))) }).Count -and
                -not @($markets | Where-Object { $_.name -eq 'e29-core' }).Count) {
                foreach ($dir in $leftover) {
                    if (Remove-Dir $dir) { Say FIXED "Deleted leftover folder $dir" }
                    else { Say TODO "Could not delete leftover folder $dir (a file is in use). Restart Windows and paste this again." }
                }
            }
        }

        # Final check, read back from Claude itself.
        $core = Get-Core
        if ($core -and $core.enabled -and (Get-Major $core.version) -ge 2) { Say OK "e29-core $($core.version) from claude.ai is installed and on." }
        elseif ($uploaded) { Note 'e29-core stays old until the My Uploads copy is deleted (see above).' Yellow }
        elseif ($core -and -not $core.enabled) { Say FAIL 'e29-core from claude.ai is turned off. In Claude Code type /plugin, turn e29-core on, then paste this again.' }
        elseif ($Check) { Say TODO "e29-core from claude.ai is $(if ($core) { "version $($core.version)" } else { 'missing' }); it must be 2 or higher." }
        else {
            Say FAIL "e29-core from claude.ai is $(if ($core) { "version $($core.version)" } else { 'missing' }); it must be 2 or higher."
            Show-SyncInfo $core
        }
        if (-not ($core -and $core.enabled -and (Get-Major $core.version) -ge 2)) { return }

        # keyring caches the Dataverse sign-in. The package list lives once, in the plugin.
        $requirements = Join-Path $core.installPath 'skills\e29-dataverse\scripts\requirements.txt'
        if ($pythonVersion -ge [version]'3.11' -and (Test-Path -LiteralPath $requirements)) {
            $python = Find-Exe python
            & $python -c 'import keyring' 2>$null
            if ($LASTEXITCODE -eq 0) { Say OK 'keyring (Dataverse sign-in cache) is installed.' }
            elseif ($Check) { Say TODO 'keyring (Dataverse sign-in cache) is not installed.' }
            else {
                Log ((& $python -m pip install --user -r $requirements 2>&1 | ForEach-Object { "$_" }) -join "`n")
                & $python -c 'import keyring' 2>$null
                if ($LASTEXITCODE -eq 0) { Say FIXED 'Installed keyring (Dataverse sign-in cache).' }
                else { Say FAIL "Could not install keyring. Try:  python -m pip install --user -r `"$requirements`"" }
            }
        }

        # Not connected is fine: the Microsoft sign-in happens on the first Dataverse question.
        Note 'Checking E29 Dataverse in Claude Code (this checks every connection, so it takes a moment)...'
        $server = 'plugin:e29-core:E29_Dataverse'
        $list = Invoke-Timed $claude 'mcp list' 180
        $line = @("$list" -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_.StartsWith("${server}:") })[0]
        if ($line -cmatch '\bConnected\b') { Say OK 'E29 Dataverse is connected in Claude Code.' }
        elseif ($line) { Note "E29 Dataverse is set up; Claude asks for your E29 Microsoft sign-in on first use. ($line)" }
        elseif ($null -eq $list) { Note 'claude mcp list took over 3 minutes and was stopped; in Claude Code, /mcp shows E29 Dataverse.' Yellow }
        else { Say TODO 'E29 Dataverse is missing from Claude Code. Restart Claude Code, then paste this again.' }
    }
    Update-Path

    # Claude Desktop gets E29 Dataverse from the synced plugin and hands every config server to its
    # Code tab, so the 'E29 Dataverse' entry old installers wrote doubles every Dataverse tool.
    # ceiling: pinned to Anthropic's MSIX package family name; a re-signed package needs it updated.
    $desktopConfigs = "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json", "$env:APPDATA\Claude\claude_desktop_config.json"
    foreach ($desktopConfig in @($desktopConfigs | Where-Object { Test-Path -LiteralPath $_ })) {
        try {
            $config = [IO.File]::ReadAllText($desktopConfig) | ConvertFrom-Json -ErrorAction Stop
            $servers = if ($config) { $config.mcpServers }
            $names = @(if ($servers) { $servers.PSObject.Properties.Name })
            $old = $names | Where-Object { $_ -eq 'E29 Dataverse' } | Select-Object -First 1
            $others = @($names | Where-Object { $_ -ne 'E29 Dataverse' -and ($servers.$_ | ConvertTo-Json -Depth 20 -Compress) -match '@microsoft/dataverse' })
            if (-not $old) { Say OK "No old E29 Dataverse entry in $desktopConfig." }
            elseif ($Check) { Say TODO "$desktopConfig still has the old E29 Dataverse entry; it doubles every Dataverse tool." }
            else {
                $servers.PSObject.Properties.Remove($old)
                $new = $config | ConvertTo-Json -Depth 100
                # Never write a file that lost anything but that one entry.
                $back = $new | ConvertFrom-Json -ErrorAction Stop
                if ((@($back.PSObject.Properties.Name) -join '|') -ne (@($config.PSObject.Properties.Name) -join '|') -or
                    (@($back.mcpServers.PSObject.Properties.Name) -join '|') -ne (@($names | Where-Object { $_ -ne $old }) -join '|')) { throw 'the rewritten file does not read back the same.' }
                $backup = "$desktopConfig.$(Get-Date -Format yyyyMMdd-HHmmss).bak"
                Copy-Item -LiteralPath $desktopConfig -Destination $backup
                [IO.File]::WriteAllText($desktopConfig, $new, (New-Object Text.UTF8Encoding $false))
                Say FIXED "Removed the old E29 Dataverse entry from $desktopConfig (backup: $backup). Restart Claude Desktop."
            }
            if ($others.Count) { Say TODO "$desktopConfig has other Dataverse entries: $($others -join ', '). One for e29.crm4.dynamics.com doubles every Dataverse tool; delete it by hand." }
        }
        catch { Say FAIL "Could not clean up $desktopConfig; nothing written: $($_.Exception.Message)" }
    }

    # --- 4. Folders --- where the Claude skills find SharePoint, the NAS and repo clones. Set only
    # when exactly one candidate is found; never guessed.
    Section '4. Folders'
    $var = 'E29_SHAREPOINT_ROOT'
    $have = [Environment]::GetEnvironmentVariable($var, 'User')
    if ($have -and (Test-Path -LiteralPath $have -PathType Container)) { Say OK "$var is $have." }
    else {
        $oneDriveParent = if ($env:OneDriveCommercial) { Split-Path -Parent $env:OneDriveCommercial }
        $found = @(Find-Root @($userHome, $oneDriveParent) @('Grant - Documents', 'Project - Documents', 'Project - Dissemination', 'Project - Output'))
        if ($found.Count -eq 1) { Set-UserVariable $var $found[0] }
        elseif ($found.Count) { Say TODO "$var is not set: several folders look like the E29 SharePoint folder ($($found -join '; ')). Run, with the right one:  [Environment]::SetEnvironmentVariable('$var', '<folder>', 'User')" }
        else { Say TODO "$var is not set: no E29 SharePoint library is on this computer yet. OneDrive adds Project - Documents within 8 hours of this setup: paste this again tomorrow." }
    }

    # OneDrive signed in to E29, and the libraries the policies mount kept on this computer
    # ("Always keep on this device"). The policy mounts them online-only.
    $oneDrive = @(Get-ItemProperty 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business*' -ErrorAction SilentlyContinue | Where-Object { $_.ConfiguredTenantId -eq $tenantId })
    if ($oneDrive.Count) {
        Say OK "OneDrive is signed in as $($oneDrive[0].UserEmail)."
        # Every synced SharePoint library: each Tenants\<name> value is a local folder; the user's own OneDrive left out.
        $synced = @(@(foreach ($account in $oneDrive) {
                    Get-ChildItem (Join-Path $account.PSPath 'Tenants') -ErrorAction SilentlyContinue |
                        ForEach-Object { $_.GetValueNames() } | Where-Object { $_ -and $_ -ne $account.UserFolder }
                }) | Sort-Object -Unique)
        if ($synced.Count) { foreach ($path in $synced) { Note "Synced library: $path" } }
        else { Note 'Synced library: none.' }
    }
    else { Say TODO 'OneDrive is not signed in with your E29 account. Open OneDrive from the Start menu and sign in with your @e29.eu address.' }
    $spRoot = [Environment]::GetEnvironmentVariable($var, 'User')
    foreach ($lib in @(Get-Library $grantAccess)) {
        $folder = if ($spRoot) { Join-Path $spRoot $lib.Name }
        if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) {
            if ($spRoot) { Say TODO "$($lib.Name) is not on this computer yet: OneDrive adds it within 8 hours of this setup. Paste this again tomorrow." }
            continue
        }
        # 0x80000 = pinned.
        $pinned = { [bool]((Get-Item -LiteralPath $folder -Force).Attributes -band 0x80000) }
        if (& $pinned) { Say OK "$($lib.Name) is kept on this computer."; continue }
        if ($Check) { Say TODO "$($lib.Name) is online-only, not kept on this computer."; continue }
        $size = (Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        $free = ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($folder))).AvailableFreeSpace
        # 5 GB left over for Windows and everything else.
        if ($size -gt $free - 5GB) { Say TODO ('{0} needs {1:N1} GB and the disk has {2:N1} GB free, so it stays online-only. Free up space, then paste this again.' -f $lib.Name, ($size / 1GB), ($free / 1GB)); continue }
        Log (@(attrib -U +P $folder 2>&1; attrib -U +P "$folder\*" /S /D 2>&1) -join "`n")
        if (& $pinned) { Say FIXED ('Keeping {0} on this computer; OneDrive downloads {1:N1} GB in the background.' -f $lib.Name, ($size / 1GB)) }
        else { Say FAIL "Could not keep $($lib.Name) on this computer. In File Explorer right-click it and choose Always keep on this device." }
    }

    # A ;-separated list of NAS roots, the folders holding photo\. Off the office network every one
    # can be down and the value still right.
    $var = 'E29_NAS_ROOT'
    $nasDefault = '\\E29HU'
    $have = [Environment]::GetEnvironmentVariable($var, 'User')
    $candidates = @("$have" -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Note "Looking for the office NAS $nasDefault (up to ~20 seconds when it is not reachable)..."
    # Test-Path on an unreachable UNC host throws instead of returning $false.
    $reachable = @($candidates) + @($nasDefault | Where-Object { $candidates -notcontains $_ }) |
        Where-Object { try { Test-Path -LiteralPath (Join-Path $_ 'photo') -PathType Container -ErrorAction Stop } catch { $false } } |
        Select-Object -First 1
    if ($reachable -and $candidates -contains $reachable) { Say OK "$var is $have." }
    elseif ($reachable) { Set-UserVariable $var ((@($nasDefault) + $candidates) -join ';') }
    elseif ($have) { Say SKIP "$var is $have; the NAS is not reachable from here now." }
    else { Say SKIP "$var is not set: the office NAS is not reachable from here. Only the NAS photo skills need it." }

    # The user's own clones; without it the skills work in a cache clone.
    $var = 'E29_GITHUB_REPOS_ROOT'
    $have = [Environment]::GetEnvironmentVariable($var, 'User')
    if ($have -and (Test-Path -LiteralPath $have -PathType Container)) { Say OK "$var is $have." }
    else {
        $found = @(Find-Root @($userHome, "$userHome\source", [Environment]::GetFolderPath('MyDocuments'), "$env:SystemDrive\") @('e29-websites\.git', 'knowledge-base\.git'))
        if ($found.Count -eq 1) { Set-UserVariable $var $found[0] }
        else { Say SKIP "$var is not set: $(if ($found.Count) { "several folders hold E29 repo clones ($($found -join '; '))" } else { 'no E29 repo clone on this computer' }). Optional." }
    }

    # --- 5. GitHub --- runs even when the Claude step failed: Git and GitHub CLI come from the app list.
    Section '5. GitHub'
    $gh = Find-Exe gh
    $git = Find-Exe git
    # gh prints the error body on stdout too: only an object with a login is a user.
    function Get-GhUser { try { $u = (& $gh api user 2>$null) -join "`n" | ConvertFrom-Json -ErrorAction Stop; if ($u.login) { $u } } catch { } }
    $ghUser = $null
    if (-not $gh) { Say FAIL 'GitHub CLI (gh) is missing - see the Apps lines above.' }
    else {
        & $gh auth status -h github.com *> $null
        if ($LASTEXITCODE -eq 0) { $ghUser = Get-GhUser }
        if ($ghUser) { Say OK "Signed in to GitHub as $($ghUser.login)." }
        elseif ($Check) { Say TODO 'Not signed in to GitHub.' }
        else {
            Note 'Sign in to GitHub: press Enter when asked, then paste the code shown here into the browser and approve.' Yellow
            & $gh auth login --web -h github.com -p https
            $ghUser = Get-GhUser
            if ($ghUser) { Say FIXED "Signed in to GitHub as $($ghUser.login)." }
            else { Say FAIL 'GitHub sign-in did not finish. Paste this again to retry.' }
        }
    }
    if ($ghUser -and $git) {
        # gh hands its sign-in to git, so clones and pushes of private repos work without a password.
        $helpers = @(& $git config --global --get-all credential.https://github.com.helper 2>$null)
        if (($helpers -join ' ') -match 'gh(\.exe)?[''"]?\s+auth git-credential') { Say OK 'git uses the GitHub sign-in.' }
        elseif ($Check) { Say TODO 'git does not use the GitHub sign-in yet.' }
        else {
            & $gh auth setup-git -h github.com
            if ($LASTEXITCODE -eq 0) { Say FIXED 'git now uses the GitHub sign-in.' } else { Say FAIL 'gh auth setup-git failed.' }
        }

        # Set only when empty; an existing value is the user's choice. The noreply address always
        # matches the account, so GitHub never refuses a commit for it.
        $noreply = "$($ghUser.id)+$($ghUser.login)@users.noreply.github.com"
        $name = if ($ghUser.name) { $ghUser.name } else { $ghUser.login }
        foreach ($setting in @(
                @{ Key = 'user.name'; Want = $name },
                @{ Key = 'user.email'; Want = $noreply },
                @{ Key = 'init.defaultBranch'; Want = 'main' })) {
            $have = "$(& $git config --global --get $setting.Key 2>$null)".Trim()
            if ($have) { Say OK "git $($setting.Key) is $have." }
            elseif ($Check) { Say TODO "git $($setting.Key) is not set." }
            else {
                & $git config --global $setting.Key $setting.Want
                if ($LASTEXITCODE -eq 0) { Say FIXED "Set git $($setting.Key) to $($setting.Want)." } else { Say FAIL "Could not set git $($setting.Key)." }
            }
        }

        $membership = try { & $gh api user/memberships/orgs/E29eu 2>$null | ConvertFrom-Json } catch { $null }
        if ($membership.state -eq 'active') { Say OK 'Member of the E29eu GitHub organisation.' }
        elseif ($membership.state -eq 'pending') { Say TODO 'Accept your E29eu invitation: https://github.com/orgs/E29eu/invitation' }
        else { Say TODO "Not in the E29eu GitHub organisation: ask Attila to add GitHub user $($ghUser.login)." }
    }
    elseif ($ghUser) { Say FAIL 'Git is missing - see the Apps lines above.' }

    # --- 6. PM plugin --- for whoever can read its private repo; the GitHub team decides who.
    $pm = $false
    if ($ghUser -and $claude) {
        & $gh api "repos/$pmRepo" --silent 2>$null
        $pm = $LASTEXITCODE -eq 0
    }
    if ($pm) {
        Section '6. Project management plugin'
        $markets = Get-ClaudeJson plugin marketplace list --json
        if ($null -eq $markets) { Say FAIL "Could not read the Claude marketplace list. Run this to see why:  & '$claude' plugin marketplace list" }
        elseif (@($markets | Where-Object { $_.name -eq 'e29-pm' }).Count) { Say OK 'e29-pm marketplace is added.' }
        elseif ($Check) { Say TODO 'e29-pm marketplace is not added.' }
        else {
            # The git URL, not owner/repo: the private repo needs the git source form.
            $run = Invoke-Claude plugin marketplace add "https://github.com/$pmRepo.git"
            if ($run.Ok) { Say FIXED 'Added the e29-pm marketplace.' } else { Say FAIL "Could not add the e29-pm marketplace: $($run.Out)" }
        }

        function Get-Pm { $list = Get-ClaudeJson plugin list --json; $list | Where-Object { $_.id -eq 'e29-pm@e29-pm' -and $_.scope -eq 'user' } | Select-Object -First 1 }
        $installed = Get-Pm
        if ($Check) { }
        elseif (-not $installed) {
            $run = Invoke-Claude plugin install e29-pm@e29-pm --scope user
            $installed = Get-Pm
            if ($installed) { Say FIXED "Installed e29-pm $($installed.version)." } else { Say FAIL "Could not install e29-pm: $($run.Out)" }
        }
        else {
            # Installed: bring it up to date and turn it back on if it was turned off.
            [void](Invoke-Claude plugin marketplace update e29-pm)
            $run = Invoke-Claude plugin update e29-pm@e29-pm
            if (-not $run.Ok) { Say FAIL "Could not update e29-pm: $($run.Out)" }
            if (-not $installed.enabled) {
                $run = Invoke-Claude plugin enable e29-pm@e29-pm --scope user
                if ($run.Ok) { Say FIXED 'Turned e29-pm back on.' } else { Say FAIL "Could not turn e29-pm on: $($run.Out)" }
            }
            $installed = Get-Pm
        }
        if (-not $installed) { if ($Check) { Say TODO 'e29-pm is not installed.' } }
        elseif ($installed.enabled -and (Get-Major $installed.version) -ge 2) { Say OK "e29-pm $($installed.version) is installed and on." }
        else { Say $(if ($Check) { 'TODO' } else { 'FAIL' }) "e29-pm is version $($installed.version), on=$($installed.enabled); it must be 2 or higher and on." }

        # No CLI flag turns on auto-update: change only that leaf in settings.json, keep the rest
        # byte for byte, and never write a file that does not parse.
        $settingsPath = "$cfg\settings.json"
        try {
            $text = [IO.File]::ReadAllText($settingsPath)
            $entry = ($text | ConvertFrom-Json -ErrorAction Stop).extraKnownMarketplaces.'e29-pm'
            # SKIP, not TODO: nothing for the user to do, and this script updates e29-pm on each run.
            if (-not $entry) { Say SKIP "e29-pm auto-update: no e29-pm marketplace in $settingsPath to turn it on in." }
            elseif ($entry.autoUpdate -eq $true) { Say OK 'e29-pm updates itself.' }
            elseif ($null -ne $entry.autoUpdate) { Say SKIP "e29-pm auto-update is turned off in $settingsPath; left as is." }
            elseif ($Check) { Say TODO 'e29-pm auto-update is not on.' }
            else {
                # Inserted first in the object, with the indentation of the line it goes before.
                $hits = [regex]::Matches($text, '"e29-pm"\s*:\s*\{(\s*)')
                $new = if ($hits.Count -eq 1) { $text.Insert($hits[0].Index + $hits[0].Length, '"autoUpdate": true,' + $hits[0].Groups[1].Value) }
                if ($new -and ($new | ConvertFrom-Json -ErrorAction Stop).extraKnownMarketplaces.'e29-pm'.autoUpdate -eq $true) {
                    $backup = "$settingsPath.$(Get-Date -Format yyyyMMdd-HHmmss).bak"
                    Copy-Item -LiteralPath $settingsPath -Destination $backup
                    [IO.File]::WriteAllText($settingsPath, $new, (New-Object Text.UTF8Encoding $false))
                    Say FIXED "Turned on e29-pm auto-update (backup: $backup)."
                }
                else { Say FAIL "Could not place autoUpdate in $settingsPath; nothing written. Set extraKnownMarketplaces.e29-pm.autoUpdate to true by hand." }
            }
        }
        catch { Say FAIL "$settingsPath is missing or does not parse; nothing written: $($_.Exception.Message)" }
    }
    elseif ($ghUser -and $claude) { Say SKIP 'No extra Claude plugins for your GitHub account.' }

    # --- 6. Summary --- the manual steps after this live in the knowledge base, not here.
    Section 'Summary'
    $summary = 'OK {0}  FIXED {1}  SKIP {2}  TODO {3}  FAIL {4}' -f $state.OK, $state.FIXED, $state.SKIP, $state.TODO, $state.FAIL
    Write-Host "  $summary"; Log "  $summary"
    # Indented: the telemetry parser counts only [TODO]/[FAIL] at line start, so these are not doubled.
    foreach ($item in $openItems) { Write-Host "  $($item.Text)" -ForegroundColor $item.Color; Log "  $($item.Text)" }

    # The log goes to Attila. The first line is what the check's keyword filter reads: result and
    # E29 Microsoft 365 domain, from the E29 Claude sign-in or the Windows work account.
    $reported = $false
    if (-not $userEmail) { $userEmail = "$(whoami /upn 2>$null)".Trim() }
    if ($logUrl -and $userEmail -match '@([\w.-]+)$') {
        $marker = "[e29-setup $(if ($state.FAIL) { 'FAIL' } else { 'OK' })@$($Matches[1].ToLower())]"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $body = [Text.Encoding]::UTF8.GetBytes("$marker`n$([IO.File]::ReadAllText($logPath))")
            $null = Invoke-WebRequest -Uri $logUrl -Method Post -Body $body -ContentType 'text/plain; charset=utf-8' -UseBasicParsing -TimeoutSec 20
            $reported = $true
        }
        catch { }
    }
    if ($state.FAIL -and $reported) {
        Write-Host "`n$($state.FAIL) problem(s) above. Attila has the log and will follow up." -ForegroundColor Red
        return
    }
    if ($state.FAIL) {
        Write-Host "`n$($state.FAIL) problem(s) above. Send Attila a screenshot of this window and this file:" -ForegroundColor Red
        Write-Host "  $logPath  " -ForegroundColor White -BackgroundColor DarkRed
        return
    }
    Write-Host "  Full log: $logPath" -ForegroundColor Gray
    if ($state.TODO) { Write-Host "`nAlmost done: do the yellow [TODO] lines, then paste this again." -ForegroundColor Yellow }
    elseif ($Check) { Write-Host "`nAll set: nothing to change." -ForegroundColor Green }
    else { Write-Host "`nAll done. Go back to the guide: $kb/getting-started/set-up-your-computer/#connect-to-systems" -ForegroundColor Green }
}
