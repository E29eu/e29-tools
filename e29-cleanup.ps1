& {
    # E29 plugin one-time cleanup. Safe to run again. Run in PowerShell:
    #   irm https://raw.githubusercontent.com/E29eu/e29-tools/main/e29-cleanup.ps1 | iex
    $ErrorActionPreference = 'Continue'
    $state = @{ Fail = 0; Todo = 0 }
    # Claude Code resolves ~ to %USERPROFILE%; 5.1's $HOME differs on a redirected profile.
    $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $cfg = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { "$userHome\.claude" }

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
        $match = [regex]::Match("$text", '(?s)\[.*\]')
        if (-not $match.Success) { return $null }
        $parsed = $match.Value | ConvertFrom-Json
        return , @($parsed)
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
        $lines = @("claude $((& $claude --version 2>$null) -join ' ')")
        $auth = (& $claude auth status 2>$null) -join "`n"
        try { $a = $auth | ConvertFrom-Json; $lines += "signed in: $($a.loggedIn) via $($a.authMethod) as $($a.email), org $($a.orgName) $($a.orgId)" }
        catch { $lines += "auth status: $auth" }
        $lines += "sign-in allows plugin sync (user:plugins): $(if ($null -eq ($scope = Get-PluginScope)) { 'unknown' } else { $scope })"
        if ($core) { $lines += "loaded from: $($core.installPath)" }
        $buckets = @(Get-ChildItem "$cfg\plugins\synced" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.*' })
        if (-not $buckets.Count) { $lines += "no synced folder in $cfg\plugins\synced - this Claude Code never synced from claude.ai" }
        foreach ($bucket in $buckets) {
            $lines += "folder $($bucket.Name)"
            try {
                $m = Get-Content -LiteralPath "$($bucket.FullName)\manifest.json" -Raw -ErrorAction Stop | ConvertFrom-Json
                $lines += "  last sync $(if ($m.lastUpdated) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$m.lastUpdated).LocalDateTime } else { 'never' })"
                foreach ($p in @($m.plugins | Where-Object { $_.name -eq 'e29-core' })) { $lines += "  claude.ai says e29-core generation $($p.generation), updated $($p.updatedAt)" }
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

    while ($running = @(Get-Process -Name claude -ErrorAction SilentlyContinue)) {
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
    # Missing or old: an old Claude Code does not sync claude.ai plugins at all, so update it first;
    # a headless run then triggers a sync. A failed download can leave .staging behind and stall
    # every later sync, so that goes next, then the whole synced folder (a cache of claude.ai).
    $oldVersion = if ($core) { $core.version } else { 'missing' }
    foreach ($reset in 'update', '.staging', 'all') {
        if ((Get-Major $core.version) -ge 2) { break }
        if ($reset -eq 'update') {
            Write-Host "       e29-core is $(if ($core) { "old ($($core.version))" } else { 'missing' }); getting the current version from claude.ai..." -ForegroundColor Yellow
            $before = (& $claude --version 2>$null) -join ' '
            [void](Invoke-Claude update)
            $after = (& $claude --version 2>$null) -join ' '
            if ($after -ne $before) { Say FIXED "Updated Claude Code: $before -> $after" }
            if ((Get-PluginScope) -eq $false) {
                Write-Host '       Your Claude sign-in is too old to download plugins. A browser opens now:' -ForegroundColor Yellow
                Write-Host '       sign in with your E29 claude.ai account, then come back to this window.' -ForegroundColor Yellow
                & $claude auth login --claudeai
                if (Get-PluginScope) { Say FIXED 'Signed in to Claude again; plugin download allowed.' }
                else { Say FAIL 'The new Claude sign-in still does not allow plugin download.' }
            }
        }
        elseif ($core -and (Split-Path (Split-Path "$($core.installPath)")) -eq "$cfg\plugins\synced") {
            $bucket = Split-Path "$($core.installPath)"
            Remove-Item -LiteralPath $(if ($reset -eq 'all') { $bucket } else { Join-Path $bucket '.staging' }) -Recurse -Force -ErrorAction SilentlyContinue
        }
        Push-Location $userHome
        [void](Invoke-Claude -p 'Reply with OK.' --max-turns 1)
        Pop-Location
        $plugins = Get-ClaudeJson plugin list --json
        $core = $plugins | Where-Object { $_.id -eq 'e29-core@synced' } | Select-Object -First 1
    }
    if (-not $core) {
        Say FAIL 'The new e29-core is not on this computer yet. Nothing was changed.'
        Write-Host '       Getting it from claude.ai did not work. Not signed in? Type  claude , then /login with your E29 claude.ai account.'
        Show-SyncInfo $null
        return
    }
    if ((Get-Major $core.version) -lt 2) { Say TODO "New e29-core is old ($($core.version)); it must be 2 or higher - see the end." }
    elseif ($core.version -ne $oldVersion) { Say FIXED "Downloaded e29-core $($core.version) (was $oldVersion)." }
    else { Say OK "New e29-core $($core.version) is installed." }

    # 2. Old e29-core from the GitHub marketplace, at every scope.
    foreach ($old in @($plugins | Where-Object { $_.id -eq 'e29-core@e29-core' })) {
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
    if (@($markets | Where-Object { $_.name -eq 'e29-core' }).Count) {
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
    $setup = Join-Path "$($core.installPath)" 'skills\setup-e29-plugin\scripts\setup_e29_plugin.ps1'
    if (Test-Path $setup) {
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
    elseif ($core -and -not $core.enabled) { Say FAIL 'e29-core from claude.ai is turned off. In Claude Code type /plugin, turn e29-core on, then run this again.' }
    else {
        Say FAIL "e29-core from claude.ai is $(if ($core) { "version $($core.version)" } else { 'missing' }); it must be 2 or higher."
        Write-Host '       Downloading it from claude.ai did not work on this computer.'
        Show-SyncInfo $core
    }

    $left = @($plugins | Where-Object { $_.id -eq 'e29-core@e29-core' -and ($_.scope -eq 'user' -or ($_.projectPath -and (Test-Path $_.projectPath))) })
    $markets = Get-ClaudeJson plugin marketplace list --json
    if ($left.Count -or @($markets | Where-Object { $_.name -eq 'e29-core' }).Count) { Say FAIL 'The old e29-core is still installed (see the red lines above).' }
    else {
        Say OK 'The old e29-core is gone.'
        foreach ($dir in "$cfg\plugins\cache\e29-core", "$cfg\plugins\marketplaces\e29-core") {
            if (-not (Test-Path $dir)) { continue }
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $dir) { Say TODO "Could not delete leftover folder $dir (a file is in use). Restart Windows and paste this again." }
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
