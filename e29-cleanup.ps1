& {
    # E29 plugin one-time cleanup. Safe to run again. Run in PowerShell:
    #   irm https://raw.githubusercontent.com/E29eu/e29-tools/main/e29-cleanup.ps1 | iex
    $ErrorActionPreference = 'Continue'
    $state = @{ Fail = 0; Todo = 0 }
    # Claude Code resolves ~ to %USERPROFILE%; 5.1's $HOME differs on a redirected profile.
    $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $cfg = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { "$userHome\.claude" }
    # The E29 claude.ai organisation; synced folder names start with it.
    $e29OrgId = '1119948f-586d-43b6-88e5-a2431fa8ae84'
    $e29Marketplace = 'E29eu/claude-e29-core-plugin'
    $syncWaitSeconds = 120

    function Say($tag, $msg) {
        $color = @{ OK = 'Green'; FIXED = 'Green'; SKIP = 'Gray'; TODO = 'Yellow'; FAIL = 'Red' }[$tag]
        if ($tag -eq 'FAIL') { $state.Fail++ }
        if ($tag -eq 'TODO') { $state.Todo++ }
        Write-Host ('[{0}] {1}' -f $tag, $msg) -ForegroundColor $color
    }
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
    function Get-Major($version) { $major = 0; [void][int]::TryParse("$version".Split('.')[0], [ref]$major); $major }
    # Claude Code skips the claude.ai plugin sync when the sign-in lacks the user:plugins scope
    # (sign-ins from older versions). Reads only the scope list, never a token. $null = unknown.
    function Get-PluginScope {
        try { $text = [IO.File]::ReadAllText("$cfg\.credentials.json") } catch { return $null }
        $match = [regex]::Match($text, '"claudeAiOauth"\s*:\s*\{[^{}]*?"scopes"\s*:\s*\[([^\]]*)\]')
        if (-not $match.Success) { return $null }
        $match.Groups[1].Value.Contains('"user:plugins"')
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
        Write-Host '       Details for Attila:' -ForegroundColor Gray
        $lines | ForEach-Object { Write-Host "         $_" -ForegroundColor Gray }
    }

    Write-Host "`nE29 plugin cleanup`n" -ForegroundColor White

    # Claude Code CLI on PATH, else the copy Claude Desktop or VS Code ships.
    $claude = @(Get-Command claude -CommandType Application -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.exe', '.cmd' } | ForEach-Object { $_.Source })
    $claude += @("$userHome\.local\bin\claude.exe") | Where-Object { Test-Path $_ }
    $claude += @(Get-ChildItem "$env:APPDATA\Claude\claude-code", "$env:LOCALAPPDATA\Packages\Claude_*\LocalCache\Roaming\Claude\claude-code", "$userHome\.vscode\extensions\anthropic.claude-code-*\resources\native-binary" -Recurse -Filter claude.exe -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName })
    $claude = $claude | Select-Object -First 1
    if (-not $claude) {
        Say FAIL 'Claude is not installed on this computer. Install Claude Desktop or Claude Code, sign in with your E29 claude.ai account, then paste this again.'
        return
    }
    # Claude knows its own config folder best (CLAUDE_CONFIG_DIR set elsewhere, redirected profile).
    if (($auth = Get-Auth).configDirectory) { $cfg = $auth.configDirectory }

    while (@(Get-Process -Name claude -ErrorAction SilentlyContinue).Count) {
        Write-Host 'Claude is still running. Quit Claude Desktop (also right-click its tray icon next to the clock and choose Quit) and close every Claude Code window, including inside VS Code.' -ForegroundColor Yellow
        if ((Read-Host 'Press Enter to check again, or type C and Enter to continue anyway') -eq 'C') { break }
    }

    $plugins = Get-ClaudeJson plugin list --json
    if ($null -eq $plugins) {
        Say FAIL "Could not read the plugin list. Run this to see why:  & '$claude' plugin list"
        return
    }

    # 1. The new e29-core comes from the claude.ai organisation. Nothing is removed until it is here.
    $core = $plugins | Where-Object { $_.id -eq 'e29-core@synced' } | Select-Object -First 1
    # Missing or old: an old Claude Code does not sync claude.ai plugins at all, so update it first
    # and check the sign-in; a headless run then syncs. A cut-short download leaves .staging behind,
    # so that goes next, then the whole synced folder (a cache of claude.ai).
    $oldVersion = if ($core) { $core.version } else { 'missing' }
    foreach ($reset in 'update', '.staging', 'all') {
        # No reset helps against an own upload: claude.ai sends it again.
        if ((Get-Major $core.version) -ge 2 -or (Get-UploadedCore)) { break }
        if ($reset -eq 'update') {
            Write-Host "       e29-core is $(if ($core) { "old ($($core.version))" } else { 'missing' }); getting the current version from claude.ai..." -ForegroundColor Yellow
            $before = (& $claude --version 2>$null) -join ' '
            [void](Invoke-Claude update)
            $after = (& $claude --version 2>$null) -join ' '
            if ($after -ne $before) { Say FIXED "Updated Claude Code: $before -> $after" }
            # Sync needs the E29 organisation and the user:plugins scope (missing from older sign-ins).
            $auth = Get-Auth
            if ((Get-PluginScope) -eq $false -or ($auth -and (-not $auth.loggedIn -or ($auth.orgId -and $auth.orgId -ne $e29OrgId)))) {
                Write-Host "       Claude is $(if ($auth.loggedIn) { "signed in as $($auth.email) ($($auth.orgName))" } else { 'not signed in' }) and cannot download E29 plugins. A browser opens now:" -ForegroundColor Yellow
                Write-Host '       sign in with your E29 claude.ai account, then come back to this window.' -ForegroundColor Yellow
                & $claude auth login --claudeai
                $auth = Get-Auth
                if ($auth.loggedIn -and $auth.orgId -eq $e29OrgId -and (Get-PluginScope) -ne $false) { Say FIXED "Signed in to Claude as $($auth.email) (E29)." }
                else { Say FAIL "Claude is still not signed in with an E29 account that can download plugins ($($auth.email), $($auth.orgName))."; break }
            }
        }
        elseif (@(Get-Process -Name claude -ErrorAction SilentlyContinue).Count) {
            Say TODO 'Claude is still running, so its download folder was not reset. Quit Claude everywhere, then paste this again.'
            break
        }
        else {
            # Every bucket, not the one installPath names: a half-synced e29-core lists no installPath.
            $dirs = if ($reset -eq 'all') { "$cfg\plugins\synced" } else { @(Get-ChildItem "$cfg\plugins\synced\*\.staging" -Directory -Force -ErrorAction SilentlyContinue).FullName }
            foreach ($dir in $dirs) { if (-not (Remove-Dir $dir)) { Say TODO "Could not delete $dir (a file is in use). Restart Windows, then paste this again." } }
        }
        Write-Host "       Waiting for the download from claude.ai (up to $syncWaitSeconds seconds)..."
        $core = Wait-Sync
    }
    $plugins = Get-ClaudeJson plugin list --json
    $core = $plugins | Where-Object { $_.id -eq 'e29-core@synced' } | Select-Object -First 1
    if ((Get-Major $core.version) -lt 2 -and ($uploaded = @(Get-UploadedCore)[0])) {
        Say TODO "Your claude.ai account has its own old copy of e29-core (in My Uploads, from $($uploaded.updatedAt)). It hides the E29 one."
        Write-Host '       In claude.ai open Customize > Plugins, delete e29-core under My Uploads, then paste this again.' -ForegroundColor Yellow
    }
    if (-not $core) {
        Say FAIL 'The new e29-core is not on this computer yet. Nothing was changed.'
        Write-Host '       Getting it from claude.ai did not work. Not signed in? Type  claude , then /login with your E29 claude.ai account.'
        Show-SyncInfo $null
        return
    }
    if ($uploaded) { }
    elseif ((Get-Major $core.version) -lt 2) { Say TODO "New e29-core is old ($($core.version)); it must be 2 or higher - see the end." }
    elseif ($core.version -ne $oldVersion) { Say FIXED "Downloaded e29-core $($core.version) (was $oldVersion)." }
    else { Say OK "New e29-core $($core.version) is installed." }

    # 2. Old e29-core from the GitHub marketplace, at every scope. Kept while the new one is below 2:
    # it may be the only working copy.
    $ready = (Get-Major $core.version) -ge 2
    foreach ($old in @($plugins | Where-Object { $ready -and $_.id -eq 'e29-core@e29-core' })) {
        $folder = if ($old.scope -eq 'user') { $userHome } else { $old.projectPath }
        if (-not $folder -or -not (Test-Path $folder)) { Say SKIP "Old e29-core entry for a folder that no longer exists: $($old.projectPath)"; continue }
        Push-Location $folder
        $run = Invoke-Claude plugin uninstall e29-core@e29-core --scope $old.scope
        Pop-Location
        if (-not $run.Ok) { Say FAIL "Could not remove old e29-core ($($old.scope) scope): $($run.Out)"; continue }
        Say FIXED "Removed old e29-core $($old.version) ($($old.scope) scope)."
        if ($old.scope -eq 'project') { Write-Host "       This changed $folder\.claude\settings.json: commit that change." }
    }

    $markets = Get-ClaudeJson plugin marketplace list --json
    if ($ready -and @($markets | Where-Object { $_.name -eq 'e29-core' }).Count) {
        $run = Invoke-Claude plugin marketplace remove e29-core
        if ($run.Ok) { Say FIXED 'Removed the old e29-core marketplace.' } else { Say FAIL "Could not remove the old e29-core marketplace: $($run.Out)" }
    }

    # 3. e29-pm stays a GitHub marketplace plugin: update it and make sure it is on.
    $pm = @($plugins | Where-Object { $_.id -eq 'e29-pm@e29-pm' })
    if (-not $pm.Count) {
        Say SKIP 'e29-pm is not installed (only the project-management team needs it).'
    }
    else {
        [void](Invoke-Claude plugin marketplace update e29-pm)
        $run = Invoke-Claude plugin update e29-pm@e29-pm
        if (-not $run.Ok) {
            Say FAIL "Could not update e29-pm: $($run.Out)"
            Write-Host '       Usually GitHub sign-in: run  gh auth login --web  then paste this again.'
        }
        # ponytail: only user-scope e29-pm is re-enabled; project-scope installs are the repo owner's choice.
        if (@($pm | Where-Object { $_.scope -eq 'user' -and -not $_.enabled }).Count) {
            $run = Invoke-Claude plugin enable e29-pm@e29-pm --scope user
            if ($run.Ok) { Say FIXED 'Turned e29-pm back on.' } else { Say FAIL "Could not turn e29-pm on: $($run.Out)" }
        }
    }

    # 4. The setup check: Claude Desktop config, dependencies, Dataverse connection.
    $setup = if ($core.installPath) { Join-Path $core.installPath 'skills\setup-e29-plugin\scripts\setup_e29_plugin.ps1' }
    if ($setup -and (Test-Path $setup)) {
        Write-Host "`n--- E29 setup check ---" -ForegroundColor White
        # Transcript keeps setup's colours on screen and lets us count its "still to do" lines.
        $env:E29_SETUP = $setup
        $env:E29_LOG = Join-Path $env:TEMP 'e29-setup-check.log'
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command 'Start-Transcript -LiteralPath $env:E29_LOG -Force | Out-Null; & $env:E29_SETUP; $code = $LASTEXITCODE; Stop-Transcript | Out-Null; exit $code'
        if ($LASTEXITCODE) { Say FAIL 'The setup check above found a problem: read the red lines.' }
        $state.Todo += @(Get-Content -LiteralPath $env:E29_LOG -Encoding UTF8 -ErrorAction SilentlyContinue |
                Where-Object { $_.StartsWith([string][char]0x23F3) -or $_.StartsWith('[TODO]') }).Count
        Write-Host "--- end of setup check ---`n" -ForegroundColor White
    }
    else { Say TODO "Setup check not found in the new e29-core; in Claude Code run /e29-core:setup-e29-plugin" }

    # 5. Final check, read back from Claude itself.
    $plugins = Get-ClaudeJson plugin list --json
    $core = $plugins | Where-Object { $_.id -eq 'e29-core@synced' } | Select-Object -First 1
    if ($core -and $core.enabled -and (Get-Major $core.version) -ge 2) { Say OK "e29-core $($core.version) from claude.ai is installed and on." }
    elseif ($uploaded) { Write-Host '       e29-core stays old until the My Uploads copy is deleted (see above).' -ForegroundColor Yellow }
    elseif ($core -and -not $core.enabled) { Say FAIL 'e29-core from claude.ai is turned off. In Claude Code type /plugin, turn e29-core on, then run this again.' }
    else {
        Say FAIL "e29-core from claude.ai is $(if ($core) { "version $($core.version)" } else { 'missing' }); it must be 2 or higher."
        Write-Host '       Downloading it from claude.ai did not work on this computer.'
        Show-SyncInfo $core
    }

    $left = @($plugins | Where-Object { $_.id -eq 'e29-core@e29-core' -and ($_.scope -eq 'user' -or ($_.projectPath -and (Test-Path $_.projectPath))) })
    $markets = Get-ClaudeJson plugin marketplace list --json
    # Unreadable lists say nothing about the old copy: never delete its folders on that.
    if ($null -eq $plugins -or $null -eq $markets) { Say FAIL "Could not read the plugin list. Run this to see why:  & '$claude' plugin list" }
    elseif ($left.Count -or @($markets | Where-Object { $_.name -eq 'e29-core' }).Count) {
        if ($ready) { Say FAIL 'The old e29-core is still installed (see the red lines above).' }
        else { Say SKIP 'The old e29-core stays until the new one is version 2 or higher.' }
    }
    else {
        Say OK 'The old e29-core is gone.'
        foreach ($dir in "$cfg\plugins\cache\e29-core", "$cfg\plugins\marketplaces\e29-core") {
            if (-not (Test-Path $dir)) { continue }
            if (-not (Remove-Dir $dir)) { Say TODO "Could not delete leftover folder $dir (a file is in use). Restart Windows and paste this again." }
            else { Say FIXED "Deleted leftover folder $dir" }
        }
    }

    foreach ($p in @($plugins | Where-Object { $_.id -eq 'e29-pm@e29-pm' -and $_.scope -eq 'user' })) {
        if ($p.enabled -and (Get-Major $p.version) -ge 2) { Say OK "e29-pm $($p.version) is installed and on." }
        else { Say FAIL "e29-pm is version $($p.version), on=$($p.enabled); expected version 2 or higher and on." }
    }

    if ($state.Fail) { Write-Host "`n$($state.Fail) problem(s) above. Send a screenshot of this window to Attila." -ForegroundColor Red }
    elseif ($state.Todo) { Write-Host "`nAlmost done: $($state.Todo) thing(s) still to do - read the yellow lines above, then start Claude again." -ForegroundColor Yellow }
    else { Write-Host "`nAll done. Start Claude again." -ForegroundColor Green }
}
