# The PC's half of scripts/dev/windows-pc.sh: builds and tests with only the useful lines of output,
# and starts or closes the debug build on the desktop of the person who is logged on. An SSH session
# has no desktop of its own, so a scheduled task ("SubieScope dev run", made here) does the starting.
param([Parameter(Position = 0)][string]$Command = '', [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @())
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
$task = 'SubieScope dev run'
$runner = Join-Path $env:TEMP 'subiescope-dev-run.cmd'

function Clean([object[]]$lines) {
    $lines | ForEach-Object { "$_" -replace "$([char]27)\[[0-9;]*m", '' -replace "$([char]27)\]8;;[^\\]*\\", '' }
}

function OnDesktop([string]$line) {
    Set-Content -Path $runner -Encoding ASCII -Value "@echo off`r`n$line`r`n"
    schtasks /Create /TN $task /TR $runner /SC ONCE /ST 23:59 /IT /F | Out-Null
    schtasks /Run /TN $task | Out-Null
}

function Stop-App {
    if (-not (Get-Process SubieScope -ErrorAction SilentlyContinue)) { return }
    # The message a click on the X sends. It only arrives from the desktop the window is on.
    OnDesktop 'taskkill /IM SubieScope.exe'
    Get-Process SubieScope -ErrorAction SilentlyContinue | Wait-Process -Timeout 6 -ErrorAction SilentlyContinue
    $left = Get-Process SubieScope -ErrorAction SilentlyContinue
    if ($left) {
        'It did not close by itself: stopped.'
        $left | Stop-Process -Force
        # A stopped run leaves a marker behind, and the next start would ask about a crash.
        Start-Sleep -Milliseconds 300
        Remove-Item "$env:LOCALAPPDATA\SubieScope\Logs\running-*.marker" -ErrorAction SilentlyContinue
    }
}

switch ($Command) {
    'build' {
        $what = if ($Rest.Count) { $Rest -join ' ' } else { '--build-tests' }
        & (Join-Path $root 'scripts\fetch-webview2.ps1') | Out-Null
        $out = Clean (& cmd /c "swift build $what 2>&1")
        $errors = $out | Where-Object { $_ -match '(: error: |^error: (?!SwiftCompile|Build failed|CompileC))|fatal error|lld-link|undefined symbol|unresolved external' } | Select-Object -Unique
        $errors | Select-Object -First 60 | ForEach-Object { if ($_.Length -gt 330) { $_.Substring(0, 330) } else { $_ } }
        '--- {0} error lines; last line: {1}' -f @($errors).Count, ($out | Select-Object -Last 1)
    }
    'test' {
        # The whole suite runs one test at a time here. Side by side it stops for good on this PC since the suite
        # passed about 270 tests (each group passes by itself, and a Mac runs them all side by side): the tests
        # that wait for a simulated cable or adapter leave no thread free for it. Costs about two minutes.
        $arguments = if ($Rest.Count) { "test --filter `"$($Rest[0])`"" } else { 'test --no-parallel' }
        $out = Clean (& cmd /c "swift $arguments 2>&1")
        $out | Where-Object { $_ -match '(: error: |recorded an issue|failed after|Test run with|crashed|Fatal error|^error:)' } | Select-Object -Unique -First 60 |
            ForEach-Object { if ($_.Length -gt 420) { $_.Substring(0, 420) } else { $_ } }
    }
    'start' {
        Stop-App
        $bin = (& swift build --show-bin-path | Select-Object -Last 1).Trim()
        Copy-Item (Join-Path $root '.webview2\x64\WebView2Loader.dll') $bin -Force
        $scratch = Join-Path $env:TEMP 'subiescope-dev-logs'
        New-Item -ItemType Directory -Force $scratch | Out-Null
        $appArguments = if ($Rest.Count) { $Rest -join ' ' } else { '-setupWizardDone YES -selectedPort demo -autoConnect YES' }
        # In the background, the page from the source tree (a reload shows a change), recordings in a scratch folder.
        OnDesktop "start `"`" `"$bin\SubieScope.exe`" -debugPort 9339 -background YES -autoUpdateCheck NO -webRoot `"$root\Sources\SubieScope\Windows\Web`" -logsFolder `"$scratch`" $appArguments"
        Start-Sleep -Seconds 4
        $running = Get-Process SubieScope -ErrorAction SilentlyContinue
        if ($running) { 'Running (pid {0}). Its page answers on debug port 9339.' -f $running.Id } else { 'It did not start. See %LOCALAPPDATA%\SubieScope\Logs\subiescope.log' }
    }
    'stop' {
        Stop-App
        schtasks /Delete /TN $task /F 2>$null | Out-Null
        Remove-Item $runner -ErrorAction SilentlyContinue
        'Closed.'
    }
    default { 'usage: windows-pc.ps1 build|test|start|stop (see scripts/dev/windows-pc.sh)' }
}
