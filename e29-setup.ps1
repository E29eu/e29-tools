param([switch] $Check, [switch] $MachineOnly)
& {
    # E29 staff computer setup: apps, Claude with the E29 plugins, GitHub sign-in and git identity.
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
    )

    $ErrorActionPreference = 'Continue'
    $state = @{ OK = 0; FIXED = 0; SKIP = 0; TODO = 0; FAIL = 0 }
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

    # The whole script text, for the elevated copy: `irm | iex` leaves no file to start again.
    $root = $MyInvocation.MyCommand.ScriptBlock.Ast
    while ($root.Parent) { $root = $root.Parent }
    $selfText = $root.Extent.Text

    function Log($text) { try { Add-Content -LiteralPath $logPath -Value $text -Encoding UTF8 } catch { } }
    function Say($tag, $msg) {
        $state[$tag]++
        $color = @{ OK = 'Green'; FIXED = 'Green'; SKIP = 'Gray'; TODO = 'Yellow'; FAIL = 'Red' }[$tag]
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

    # Installed from any source counts: winget also lists Store and preinstalled copies. One list per
    # app: a single winget export misses some of them.
    function Test-App($app) {
        if ($app.Command -and (Find-Exe $app.Command)) { return $true }
        $null = winget list --id $app.Id --exact --accept-source-agreements 2>&1
        $LASTEXITCODE -eq 0
    }
    function Install-App($app) {
        Note "Installing $($app.Name)..."
        $out = winget install --id $app.Id --exact --scope $app.Scope --silent --accept-package-agreements --accept-source-agreements 2>&1 |
            ForEach-Object { "$_".Trim() } | Where-Object { $_.Length -gt 1 -and $_ -notmatch '^[-\\|/ ]+$' }
        Log ($out -join "`n")
        $LASTEXITCODE
    }
    function Get-InstallHint($app) { "winget install --id $($app.Id) --exact --scope $($app.Scope)" }

    # Elevated copy: machine-wide apps only, then back to the first window.
    if ($MachineOnly) {
        Write-Host "`nE29 setup - apps for all users`n" -ForegroundColor White
        # winget is per user, and the admin who typed the password may never have had it.
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

    # --- 2. Apps ---
    Section '2. Apps'
    $missing = @($Apps | Where-Object { -not (Test-App $_) })
    foreach ($app in @($Apps | Where-Object { $missing -notcontains $_ })) { Say OK "$($app.Name) is installed." }
    if ($Check) {
        foreach ($app in $missing) { Say TODO "$($app.Name) is not installed." }
    }
    else {
        $codes = @{}
        foreach ($app in @($missing | Where-Object { $_.Scope -eq 'user' })) { $codes[$app.Id] = Install-App $app }
        $machine = @($missing | Where-Object { $_.Scope -eq 'machine' })
        if ($machine.Count) {
            $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if ($isAdmin) { foreach ($app in $machine) { $codes[$app.Id] = Install-App $app } }
            else {
                Note "$($machine.Count) app(s) install for all users. Windows asks for admin rights once: choose Yes." Yellow
                $selfPath = Join-Path $env:TEMP 'e29-setup.ps1'
                try {
                    [IO.File]::WriteAllText($selfPath, $selfText, (New-Object Text.UTF8Encoding $true))
                    $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$selfPath`" -MachineOnly"
                    Log "elevated step exited $($p.ExitCode)"
                    if ($p.ExitCode -eq 3) { Note 'The admin account has no winget. The admin signs in to Windows once and updates App Installer from the Microsoft Store, then paste this again.' Yellow }
                    # Tried there; its window showed each winget result.
                    foreach ($app in $machine) { $codes[$app.Id] = $null }
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

    # --- 3. Claude ---
    Section '3. Claude'
    $claude = $null
    & {
        # Claude Code: PATH, the native install, or npm - the places setup_e29_plugin.ps1 looks.
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

        # The e29-core setup check owns the Claude dependencies: Node.js, Python, keyring, NAS
        # variable, Desktop config, Dataverse connection. Called, never copied.
        $setup = if ($core.installPath) { Join-Path $core.installPath 'skills\setup-e29-plugin\scripts\setup_e29_plugin.ps1' }
        if ($setup -and (Test-Path $setup)) {
            Write-Host "`n--- e29-core setup check ---" -ForegroundColor White
            # Transcript keeps its colours on screen and lets us count its "still to do" lines.
            $env:E29_SETUP = $setup
            $env:E29_LOG = Join-Path $env:TEMP 'e29-setup-check.log'
            $run = 'Start-Transcript -LiteralPath $env:E29_LOG -Force | Out-Null; & $env:E29_SETUP' + $(if ($Check) { ' -DryRun' }) + '; $code = $LASTEXITCODE; Stop-Transcript | Out-Null; exit $code'
            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command $run
            $code = $LASTEXITCODE
            $checkLog = @(Get-Content -LiteralPath $env:E29_LOG -Encoding UTF8 -ErrorAction SilentlyContinue)
            Log ($checkLog -join "`n")
            Write-Host "--- end of e29-core setup check ---`n" -ForegroundColor White
            if ($code) { Say FAIL 'The e29-core setup check above found a problem: read its red lines.' }
            $todo = @($checkLog | Where-Object { $_.StartsWith([string][char]0x23F3) -or $_.StartsWith('[TODO]') }).Count
            if ($todo) { $state.TODO += $todo }
        }
        elseif ($core) { Say TODO 'The e29-core setup check is missing. In Claude Code run /e29-core:setup-e29-plugin' }

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
    }
    Update-Path

    # --- 4. GitHub --- runs even when the Claude step failed: Git and GitHub CLI come from the app list.
    Section '4. GitHub'
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

    # --- 5. PM plugin --- for whoever can read its private repo; the GitHub team decides who.
    $pm = $false
    if ($ghUser -and $claude) {
        & $gh api "repos/$pmRepo" --silent 2>$null
        $pm = $LASTEXITCODE -eq 0
    }
    if ($pm) {
        Section '5. Project management plugin'
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

    # --- 6. What is left ---
    Section 'Still to do by hand (once per computer)'
    $left = @(
        "Claude Desktop: Settings > Connectors > Microsoft 365 > Connect, sign in with your E29 Microsoft account. Guide: $kb/getting-started/set-up-your-computer/#connect-microsoft-365",
        "Synology Drive Client: connect to the E29 NAS and sign in. Guide: $kb/getting-started/systems-and-accounts/",
        "Bitwarden app and browser extension: server https://vault.e29.eu/ then sign in. Guide: $kb/getting-started/set-up-your-computer/#set-up-bitwarden"
    )
    if ($pm) { $left += "Project management keys (Odoo, Fio, EU Login) into keyring: https://github.com/$pmRepo#readme" }
    $n = 0
    foreach ($line in $left) { $n++; Write-Host "  $n. $line"; Log "  $n. $line" }

    # --- 7. Summary ---
    Section 'Summary'
    $summary = 'OK {0}  FIXED {1}  SKIP {2}  TODO {3}  FAIL {4}' -f $state.OK, $state.FIXED, $state.SKIP, $state.TODO, $state.FAIL
    Write-Host "  $summary"; Log "  $summary"
    Write-Host "  Full log: $logPath" -ForegroundColor Gray
    if ($state.FAIL) { Write-Host "`n$($state.FAIL) problem(s) above. Send a screenshot of this window and the log file to Attila." -ForegroundColor Red }
    elseif ($state.TODO) { Write-Host "`nAlmost done: do the yellow [TODO] lines, then paste this again." -ForegroundColor Yellow }
    elseif ($Check) { Write-Host "`nAll set: nothing to change." -ForegroundColor Green }
    else { Write-Host "`nAll done. Do the steps under 'Still to do by hand', then start Claude." -ForegroundColor Green }
}
