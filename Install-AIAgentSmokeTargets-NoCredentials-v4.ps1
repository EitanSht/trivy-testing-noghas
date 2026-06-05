<#
.SYNOPSIS
    Installs and launches a curated list of AI agent and AI desktop variations on a Windows VM without requiring API keys, tokens, or browser-auth automation.

.DESCRIPTION
    This no-credentials version is designed for VM smoke testing and Defender discovery validation.

    It intentionally removes:
      - API key and token parameters.
      - Cloud prompt tests that require API keys, OAuth tokens, GitHub tokens, Google credentials, or cached auth.
      - Conditional prompt attempts for Cursor CLI and Antigravity CLI.
      - OpenCode, Codex CLI, Claude Code, Gemini CLI, and GitHub Copilot CLI prompt execution.

    It keeps:
      - Install via PowerShell where available.
      - Run-once smoke checks such as --help, --version, doctor, or app launch.
      - Local Ollama prompt testing, because it can run without cloud login after pulling a local model.
      - CSV, JSON, stdout, stderr, and transcript logging.

    Important:
      - Run in a normal signed-in user context for desktop apps, Store apps, VS Code extensions, and WinGet.
      - Some installs may require admin depending on VM policy.
      - This script avoids unsafe auto-approve flags.
      - Desktop apps and VS Code extensions are install/run smoke targets, not headless prompt targets.

.PARAMETER Install
    Install supported targets. Default: $true

.PARAMETER RunOnce
    Run each supported target once. Default: $true

.PARAMETER InstallPrerequisites
    Install Node.js, Git, VS Code, and Python with WinGet where possible. Default: $true

.PARAMETER IncludeDesktopApps
    Include desktop app targets. Default: $true

.PARAMETER IncludeVSCodeExtensions
    Include VS Code extension targets. Default: $true

.PARAMETER IncludeConditionalTargets
    Include Cursor and Antigravity CLI install/run checks. Default: $true

.PARAMETER IncludeExperimentalTargets
    Include Nanobot install/run check. Default: $true

.PARAMETER IncludeDeprecatedRooCode
    Include Roo Code VS Code extension. Default: $false

.PARAMETER SkipLocalOllamaPrompt
    Skip the local Ollama model pull and prompt test. By default, the script runs the local Ollama prompt because it does not require API keys, tokens, or login.

.PARAMETER PullOllamaModel
    Pull the Ollama model before running the Ollama prompt. Default: $true

.PARAMETER OllamaModel
    Ollama model used for local prompt test. Default: llama3.2:1b

.PARAMETER KeepAppsOpen
    Leave launched GUI apps open after smoke launch. Default: $false

.EXAMPLE
    .\Install-AIAgentSmokeTargets-NoCredentials.ps1

.EXAMPLE
    .\Install-AIAgentSmokeTargets-NoCredentials.ps1 -RunLocalOllamaPrompt $false

.EXAMPLE
    .\Install-AIAgentSmokeTargets-NoCredentials.ps1 -IncludeDesktopApps $false -IncludeVSCodeExtensions $false
#>

[CmdletBinding()]
param(
    [bool]$Install = $true,
    [bool]$RunOnce = $true,
    [bool]$InstallPrerequisites = $true,
    [bool]$IncludeDesktopApps = $true,
    [bool]$IncludeVSCodeExtensions = $true,
    [bool]$IncludeConditionalTargets = $true,
    [bool]$IncludeExperimentalTargets = $true,
    [bool]$IncludeDeprecatedRooCode = $false,
    [switch]$SkipLocalOllamaPrompt,
    [bool]$PullOllamaModel = $true,
    [bool]$KeepAppsOpen = $false,
    [string]$OllamaModel = "llama3.2:1b",
    [string]$OllamaPromptText = "Reply with exactly AGENT-SMOKE-OK and nothing else.",
    [int]$LaunchSeconds = 7,
    [int]$CommandTimeoutSeconds = 240,
    [string]$WorkRoot = "$env:ProgramData\AIAgentSmokeTest"
)

$ErrorActionPreference = "Continue"

if ($env:OS -ne "Windows_NT") {
    throw "This script is intended for Windows."
}

$StartTime = Get-Date
$OutputRoot = Join-Path $WorkRoot "output"
$WorkspaceRoot = Join-Path $WorkRoot "workspace"
$LogsRoot = Join-Path $WorkRoot "logs"
New-Item -ItemType Directory -Path $WorkRoot, $OutputRoot, $WorkspaceRoot, $LogsRoot -Force | Out-Null

$TranscriptPath = Join-Path $LogsRoot ("transcript-nocreds-v3-{0}.txt" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
try {
    Start-Transcript -Path $TranscriptPath -Force | Out-Null
}
catch {
    Write-Warning "Could not start transcript: $($_.Exception.Message)"
}

$Results = New-Object System.Collections.Generic.List[object]

function New-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '[^a-zA-Z0-9_.-]', '_')
}

function Add-SmokeResult {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Details = "",
        [Nullable[int]]$ExitCode = $null,
        [string]$Stdout = "",
        [string]$Stderr = ""
    )

    $Results.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToString("o")
        Target = $Target
        Phase = $Phase
        Status = $Status
        ExitCode = $ExitCode
        Details = $Details
        Stdout = $Stdout
        Stderr = $Stderr
    }) | Out-Null

    $prefix = switch ($Status) {
        "OK" { "[OK]" }
        "Skipped" { "[SKIPPED]" }
        "TimedOut" { "[TIMEOUT]" }
        "Failed" { "[FAILED]" }
        "Warning" { "[WARN]" }
        default { "[$Status]" }
    }

    Write-Host "$prefix $Target / $Phase - $Details"
}

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host ""
    Write-Host "================================================================"
    Write-Host $Text
    Write-Host "================================================================"
}

function Test-CommandAvailable {
    param([Parameter(Mandatory = $true)][string]$CommandName)
    return [bool](Get-Command $CommandName -ErrorAction SilentlyContinue)
}

function Refresh-SessionPath {
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $extra = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin",
        "$env:LOCALAPPDATA\Programs\Cursor\resources\app\bin",
        "$env:LOCALAPPDATA\Programs\Ollama",
        "$env:LOCALAPPDATA\Programs\Claude",
        "$env:LOCALAPPDATA\Programs\Antigravity IDE\bin",
        "$env:LOCALAPPDATA\Programs\Antigravity\bin",
        "$env:LOCALAPPDATA\agy\bin",
        "$env:APPDATA\npm",
        "$env:USERPROFILE\.codex\bin",
        "$env:USERPROFILE\.antigravity\bin",
        "$env:USERPROFILE\.cursor\bin",
        "$env:USERPROFILE\.local\bin"
    ) | Where-Object { $_ -and (Test-Path $_) }

    $env:Path = (($machinePath, $userPath) + $extra | Where-Object { $_ }) -join ";"
}


function Add-NpmGlobalBinToPath {
    if (-not (Test-CommandAvailable "npm")) {
        return
    }

    try {
        $prefix = (& npm prefix -g 2>$null).Trim()
        if (-not [string]::IsNullOrWhiteSpace($prefix)) {
            $candidates = @($prefix, (Join-Path $prefix "bin")) | Where-Object { $_ -and (Test-Path $_) }
            foreach ($candidate in $candidates) {
                if ($env:Path -notlike "*$candidate*") {
                    $env:Path = "$candidate;$env:Path"
                }
            }
        }
    }
    catch {
        Write-Warning "Could not add npm global bin path: $($_.Exception.Message)"
    }
}

function Get-PowerShellHostPath {
    if (Test-CommandAvailable "pwsh") {
        return (Get-Command "pwsh").Source
    }

    if (Test-CommandAvailable "powershell.exe") {
        return (Get-Command "powershell.exe").Source
    }

    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

function Join-NativeArgumentList {
    param([string[]]$Arguments = @())

    $quoted = foreach ($arg in $Arguments) {
        if ($null -eq $arg) {
            '""'
            continue
        }

        $s = [string]$arg
        if ($s.Length -eq 0) {
            '""'
            continue
        }

        if ($s -notmatch '[\s"]') {
            $s
            continue
        }

        '"' + ($s -replace '"', '\"') + '"'
    }

    return ($quoted -join " ")
}

function Resolve-NativeCommandPath {
    param([Parameter(Mandatory = $true)][string]$CommandName)

    if (Test-Path $CommandName) {
        return (Resolve-Path $CommandName).Path
    }

    $commands = @(Get-Command $CommandName -All -ErrorAction SilentlyContinue)
    if (-not $commands -or $commands.Count -eq 0) {
        return $null
    }

    # Prefer native executables and .cmd launchers over PowerShell shims.
    # This avoids PowerShell converting normal native stderr into NativeCommandError noise.
    $preferred = $commands |
        Where-Object {
            $_.Source -and
            ([System.IO.Path]::GetExtension($_.Source).ToLowerInvariant() -in @(".exe", ".cmd", ".bat", ".com"))
        } |
        Select-Object -First 1

    if ($preferred) {
        return $preferred.Source
    }

    return $commands[0].Source
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = $CommandTimeoutSeconds,
        [string]$WorkingDirectory = $WorkspaceRoot,
        [bool]$TreatNonZeroAsWarning = $false,
        [int[]]$SuccessExitCodes = @(0)
    )

    Refresh-SessionPath

    if (-not (Test-Path $WorkingDirectory)) {
        New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
    }

    $safe = New-SafeFileName "$Target-$Phase"
    $stdoutPath = Join-Path $OutputRoot "$safe.stdout.txt"
    $stderrPath = Join-Path $OutputRoot "$safe.stderr.txt"

    $resolvedFilePath = Resolve-NativeCommandPath -CommandName $FilePath
    if (-not $resolvedFilePath) {
        Add-SmokeResult -Target $Target -Phase $Phase -Status "Skipped" -Details "Command not found: $FilePath" -Stdout $stdoutPath -Stderr $stderrPath
        return $false
    }

    $argumentString = Join-NativeArgumentList -Arguments $Arguments
    Write-Host "Running: $resolvedFilePath $argumentString"

    try {
        if (Test-Path $stdoutPath) { Remove-Item $stdoutPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $stderrPath) { Remove-Item $stderrPath -Force -ErrorAction SilentlyContinue }

        $process = Start-Process `
            -FilePath $resolvedFilePath `
            -ArgumentList $argumentString `
            -WorkingDirectory $WorkingDirectory `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru `
            -WindowStyle Hidden

        $completed = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $completed) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
            catch {
                # Ignore kill failure. Result is still timeout.
            }

            Add-SmokeResult -Target $Target -Phase $Phase -Status "TimedOut" -Details "Timed out after $TimeoutSeconds seconds" -Stdout $stdoutPath -Stderr $stderrPath
            return $false
        }

        $exitCode = [int]$process.ExitCode

        if ($SuccessExitCodes -contains $exitCode) {
            $detail = "Completed"
            if ($exitCode -ne 0) {
                $detail = "Completed with expected non-zero exit code: $exitCode"
            }
            Add-SmokeResult -Target $Target -Phase $Phase -Status "OK" -Details $detail -ExitCode $exitCode -Stdout $stdoutPath -Stderr $stderrPath
            return $true
        }

        if ($TreatNonZeroAsWarning) {
            Add-SmokeResult -Target $Target -Phase $Phase -Status "Warning" -Details "Non-zero exit code: $exitCode" -ExitCode $exitCode -Stdout $stdoutPath -Stderr $stderrPath
            return $false
        }

        Add-SmokeResult -Target $Target -Phase $Phase -Status "Failed" -Details "Non-zero exit code: $exitCode" -ExitCode $exitCode -Stdout $stdoutPath -Stderr $stderrPath
        return $false
    }
    catch {
        $_.Exception.Message | Out-File -FilePath $stderrPath -Append -Encoding UTF8
        Add-SmokeResult -Target $Target -Phase $Phase -Status "Failed" -Details $_.Exception.Message -Stdout $stdoutPath -Stderr $stderrPath
        return $false
    }
}

function Invoke-LoggedPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Command,
        [int]$TimeoutSeconds = $CommandTimeoutSeconds,
        [string]$WorkingDirectory = $WorkspaceRoot,
        [bool]$TreatNonZeroAsWarning = $false
    )

    $psHost = Get-PowerShellHostPath
    return Invoke-LoggedCommand -Target $Target -Phase $Phase -FilePath $psHost -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        $Command
    ) -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $WorkingDirectory -TreatNonZeroAsWarning $TreatNonZeroAsWarning
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [string]$Source = "",
        [bool]$Silent = $true
    )

    if (-not (Test-CommandAvailable "winget")) {
        Add-SmokeResult -Target $Target -Phase "Install" -Status "Skipped" -Details "WinGet not found. Install App Installer or run after user logon."
        return $false
    }

    $args = @(
        "install",
        "--id", $PackageId,
        "--exact",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )

    if ($Source) {
        $args += @("--source", $Source)
    }

    if ($Silent) {
        $args += "--silent"
    }

    # Treat common non-fatal WinGet states as success:
    # -1978335189 / 0x8A15002B = update not applicable
    # -1978335135 / 0x8A150061 = package already installed
    # -1978334963 / 0x8A15010D = install already installed
    $ok = Invoke-LoggedCommand -Target $Target -Phase "Install-WinGet-$PackageId" -FilePath "winget" -Arguments $args -TimeoutSeconds 900 -TreatNonZeroAsWarning $true -SuccessExitCodes @(0, -1978335189, -1978335135, -1978334963)
    Refresh-SessionPath
    return $ok
}

function Install-NpmGlobalPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    if (-not (Test-CommandAvailable "npm")) {
        Add-SmokeResult -Target $Target -Phase "Install" -Status "Skipped" -Details "npm not found. Install Node.js first."
        return $false
    }

    $previousScriptShell = $env:NPM_CONFIG_SCRIPT_SHELL
    $previousFund = $env:NPM_CONFIG_FUND
    $previousAudit = $env:NPM_CONFIG_AUDIT
    $env:NPM_CONFIG_SCRIPT_SHELL = "cmd.exe"
    $env:NPM_CONFIG_FUND = "false"
    $env:NPM_CONFIG_AUDIT = "false"

    try {
        $ok = Invoke-LoggedCommand -Target $Target -Phase "Install-npm-$PackageName" -FilePath "npm" -Arguments @("install", "-g", $PackageName) -TimeoutSeconds 900 -TreatNonZeroAsWarning $true
    }
    finally {
        $env:NPM_CONFIG_SCRIPT_SHELL = $previousScriptShell
        $env:NPM_CONFIG_FUND = $previousFund
        $env:NPM_CONFIG_AUDIT = $previousAudit
    }

    Refresh-SessionPath
    Add-NpmGlobalBinToPath
    return $ok
}

function Install-PythonPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    $pythonCommand = $null
    $args = @()

    if (Test-CommandAvailable "py") {
        $pythonCommand = "py"
        $args = @("-3.12", "-m", "pip", "install", "--upgrade", $PackageName)
    }
    elseif (Test-CommandAvailable "python") {
        $pythonCommand = "python"
        $args = @("-m", "pip", "install", "--upgrade", $PackageName)
    }

    if (-not $pythonCommand) {
        Add-SmokeResult -Target $Target -Phase "Install" -Status "Skipped" -Details "Python not found."
        return $false
    }

    $ok = Invoke-LoggedCommand -Target $Target -Phase "Install-pip-$PackageName" -FilePath $pythonCommand -Arguments $args -TimeoutSeconds 900 -TreatNonZeroAsWarning $true
    Refresh-SessionPath
    return $ok
}

function Start-ProcessOnce {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string[]]$ProcessNameLike = @()
    )

    Refresh-SessionPath

    if (-not (Test-CommandAvailable $FilePath) -and -not (Test-Path $FilePath)) {
        Add-SmokeResult -Target $Target -Phase $Phase -Status "Skipped" -Details "Command not found: $FilePath"
        return $false
    }

    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -ErrorAction Stop
        Start-Sleep -Seconds $LaunchSeconds

        if (-not $KeepAppsOpen) {
            if ($process -and -not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }

            foreach ($name in $ProcessNameLike) {
                Get-Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProcessName -like "*$name*" } |
                    Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }

        Add-SmokeResult -Target $Target -Phase $Phase -Status "OK" -Details "Launched for $LaunchSeconds seconds"
        return $true
    }
    catch {
        Add-SmokeResult -Target $Target -Phase $Phase -Status "Failed" -Details $_.Exception.Message
        return $false
    }
}

function Start-StartMenuAppOnce {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string[]]$NameLike,
        [string[]]$ProcessNameLike = @()
    )

    try {
        $allApps = Get-StartApps
        $app = $null

        foreach ($candidate in $NameLike) {
            $app = $allApps |
                Where-Object { $_.Name -like "*$candidate*" -or $_.AppID -like "*$candidate*" } |
                Select-Object -First 1

            if ($app) { break }
        }

        if (-not $app) {
            Add-SmokeResult -Target $Target -Phase "RunOnce" -Status "Skipped" -Details "No Start Menu app found matching any of: $($NameLike -join ', ')"
            return $false
        }

        Start-Process "shell:AppsFolder\$($app.AppID)" -ErrorAction Stop
        Start-Sleep -Seconds $LaunchSeconds

        if (-not $KeepAppsOpen) {
            foreach ($name in $ProcessNameLike) {
                Get-Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProcessName -like "*$name*" } |
                    Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }

        Add-SmokeResult -Target $Target -Phase "RunOnce" -Status "OK" -Details "Launched Start Menu app: $($app.Name)"
        return $true
    }
    catch {
        Add-SmokeResult -Target $Target -Phase "RunOnce" -Status "Failed" -Details $_.Exception.Message
        return $false
    }
}

function Start-ExecutableCandidateOnce {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string[]]$PathCandidates,
        [string[]]$ProcessNameLike = @()
    )

    foreach ($candidate in $PathCandidates) {
        $matches = @(Get-ChildItem -Path $candidate -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($matches.Count -gt 0) {
            return Start-ProcessOnce -Target $Target -Phase "RunOnce-exe" -FilePath $matches[0].FullName -Arguments @() -ProcessNameLike $ProcessNameLike
        }

        if (Test-Path $candidate) {
            return Start-ProcessOnce -Target $Target -Phase "RunOnce-exe" -FilePath $candidate -Arguments @() -ProcessNameLike $ProcessNameLike
        }
    }

    Add-SmokeResult -Target $Target -Phase "RunOnce-exe" -Status "Skipped" -Details "No executable candidate found."
    return $false
}

function Initialize-Workspace {
    New-Item -ItemType Directory -Path $WorkspaceRoot -Force | Out-Null
    $readme = Join-Path $WorkspaceRoot "README.md"
    if (-not (Test-Path $readme)) {
        @"
# AI agent smoke test workspace

This directory is intentionally simple.
No API keys, tokens, or cloud prompt credentials are used by this script.
"@ | Out-File -FilePath $readme -Encoding UTF8
    }

    if ((Test-CommandAvailable "git") -and -not (Test-Path (Join-Path $WorkspaceRoot ".git"))) {
        Invoke-LoggedCommand -Target "Workspace" -Phase "git-init" -FilePath "git" -Arguments @("init") -WorkingDirectory $WorkspaceRoot -TimeoutSeconds 60 -TreatNonZeroAsWarning $true | Out-Null
    }
}


function Install-VSCodeExtensionAndVerify {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ExtensionId
    )

    if (-not (Test-CommandAvailable "code")) {
        Add-SmokeResult -Target $Target -Phase "Install-extension" -Status "Skipped" -Details "VS Code CLI 'code' not found."
        return $false
    }

    # Newer VS Code builds include GitHub Copilot Chat as a built-in extension.
    # Installing the marketplace package can fail because it tries to downgrade the built-in version.
    if ($ExtensionId -ieq "GitHub.copilot-chat") {
        Add-SmokeResult -Target $Target -Phase "Install-extension" -Status "Skipped" -Details "Skipped explicit install. Copilot Chat may be built into the current VS Code build and cannot be downgraded."
        return $true
    }

    $ok = Invoke-LoggedCommand -Target $Target -Phase "Install-extension" -FilePath "code" -Arguments @("--install-extension", $ExtensionId, "--force") -TimeoutSeconds 300 -TreatNonZeroAsWarning $true

    $safe = New-SafeFileName "$Target-Install-extension"
    $stderrPath = Join-Path $OutputRoot "$safe.stderr.txt"
    $stderrText = ""
    if (Test-Path $stderrPath) {
        $stderrText = Get-Content $stderrPath -Raw -ErrorAction SilentlyContinue
    }

    $installed = $false
    try {
        $installedExtensions = & code --list-extensions 2>$null
        $installed = [bool]($installedExtensions | Where-Object { $_ -ieq $ExtensionId })
    }
    catch {
        $installed = $false
    }

    if ($installed) {
        Add-SmokeResult -Target $Target -Phase "Verify-extension" -Status "OK" -Details "Extension is installed: $ExtensionId"
        return $true
    }

    if ($stderrText -match "built-in extension" -and $stderrText -match "cannot be downgraded") {
        Add-SmokeResult -Target $Target -Phase "Verify-extension" -Status "Warning" -Details "VS Code blocked install because a newer built-in Copilot Chat extension exists. This is not a script failure, but the requested marketplace extension was not installed as a separate extension."
        return $ok
    }

    Add-SmokeResult -Target $Target -Phase "Verify-extension" -Status "Warning" -Details "Extension not present after install attempt: $ExtensionId. Check stderr in output folder."
    return $ok
}

function Add-NoCredentialPromptSkip {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$UseInstead = ""
    )

    $details = "Removed from this no-credentials script because prompt execution requires API key, token, OAuth, cached auth, or interactive login."
    if ($UseInstead) {
        $details += " $UseInstead"
    }

    Add-SmokeResult -Target $Target -Phase "Prompt" -Status "Skipped" -Details $details
}

Write-Section "AI agent smoke test started - no credentials mode v3"
Write-Host "WorkRoot: $WorkRoot"
Write-Host "Transcript: $TranscriptPath"
Write-Host "Install: $Install"
Write-Host "RunOnce: $RunOnce"
Write-Host "SkipLocalOllamaPrompt: $SkipLocalOllamaPrompt"
Write-Host "Effective RunLocalOllamaPrompt: $(-not $SkipLocalOllamaPrompt)"

Refresh-SessionPath
Initialize-Workspace

if ($Install -and $InstallPrerequisites) {
    Write-Section "Prerequisites"
    Install-WingetPackage -Target "Node.js LTS" -PackageId "OpenJS.NodeJS.LTS" | Out-Null
    Install-WingetPackage -Target "Git" -PackageId "Git.Git" | Out-Null
    Install-WingetPackage -Target "Visual Studio Code" -PackageId "Microsoft.VisualStudioCode" | Out-Null
    Install-WingetPackage -Target "Python 3.12" -PackageId "Python.Python.3.12" | Out-Null
    Refresh-SessionPath
    Add-NpmGlobalBinToPath

    if (Test-CommandAvailable "node") {
        Invoke-LoggedCommand -Target "Node.js" -Phase "RunOnce-version" -FilePath "node" -Arguments @("--version") -TimeoutSeconds 60 -TreatNonZeroAsWarning $true | Out-Null
    }
    else {
        Add-SmokeResult -Target "Node.js" -Phase "RunOnce-version" -Status "Warning" -Details "node command not found after prerequisite install."
    }

    if (Test-CommandAvailable "npm") {
        Invoke-LoggedCommand -Target "npm" -Phase "RunOnce-version" -FilePath "npm" -Arguments @("--version") -TimeoutSeconds 60 -TreatNonZeroAsWarning $true | Out-Null
    }
    else {
        Add-SmokeResult -Target "npm" -Phase "RunOnce-version" -Status "Warning" -Details "npm command not found after prerequisite install."
    }
}

# 1. GitHub Copilot CLI
Write-Section "1. GitHub Copilot CLI"
if ($Install) {
    Install-WingetPackage -Target "GitHub Copilot CLI" -PackageId "GitHub.Copilot" | Out-Null
    if (-not (Test-CommandAvailable "copilot")) {
        Install-NpmGlobalPackage -Target "GitHub Copilot CLI" -PackageName "@github/copilot" | Out-Null
    }
}
if ($RunOnce) {
    Invoke-LoggedCommand -Target "GitHub Copilot CLI" -Phase "RunOnce-help" -FilePath "copilot" -Arguments @("--help") -TimeoutSeconds 120 -TreatNonZeroAsWarning $true | Out-Null
}
Add-NoCredentialPromptSkip -Target "GitHub Copilot CLI"

# 2. Claude Code
Write-Section "2. Claude Code"
if ($Install) {
    Invoke-LoggedPowerShell -Target "Claude Code" -Phase "Install-native" -Command "irm https://claude.ai/install.ps1 | iex" -TimeoutSeconds 900 -TreatNonZeroAsWarning $true | Out-Null
    Refresh-SessionPath
    if (-not (Test-CommandAvailable "claude")) {
        Install-WingetPackage -Target "Claude Code" -PackageId "Anthropic.ClaudeCode" | Out-Null
    }
}
if ($RunOnce) {
    Invoke-LoggedCommand -Target "Claude Code" -Phase "RunOnce-version" -FilePath "claude" -Arguments @("--version") -TimeoutSeconds 120 -TreatNonZeroAsWarning $true | Out-Null
    Invoke-LoggedCommand -Target "Claude Code" -Phase "RunOnce-help" -FilePath "claude" -Arguments @("--help") -TimeoutSeconds 120 -TreatNonZeroAsWarning $true | Out-Null
    Add-SmokeResult -Target "Claude Code" -Phase "RunOnce-doctor" -Status "Skipped" -Details "Skipped in no-credentials mode because doctor can wait on auth or environment checks."
}
Add-NoCredentialPromptSkip -Target "Claude Code"

# 3. Gemini CLI
Write-Section "3. Gemini CLI"
if ($Install) {
    Install-NpmGlobalPackage -Target "Gemini CLI" -PackageName "@google/gemini-cli" | Out-Null
}
if ($RunOnce) {
    Invoke-LoggedCommand -Target "Gemini CLI" -Phase "RunOnce-help" -FilePath "gemini" -Arguments @("--help") -TimeoutSeconds 120 -TreatNonZeroAsWarning $true | Out-Null
}
Add-NoCredentialPromptSkip -Target "Gemini CLI"

# 4. Ollama Desktop / Ollama
Write-Section "4. Ollama Desktop / Ollama"
if ($Install) {
    Install-WingetPackage -Target "Ollama" -PackageId "Ollama.Ollama" | Out-Null
}
if ($RunOnce) {
    Invoke-LoggedCommand -Target "Ollama" -Phase "RunOnce-version" -FilePath "ollama" -Arguments @("--version") -TimeoutSeconds 120 -TreatNonZeroAsWarning $true | Out-Null
}
if (-not $SkipLocalOllamaPrompt) {
    if ($PullOllamaModel) {
        Invoke-LoggedCommand -Target "Ollama" -Phase "Pull-$OllamaModel" -FilePath "ollama" -Arguments @("pull", $OllamaModel) -TimeoutSeconds 1800 -TreatNonZeroAsWarning $true | Out-Null
    }
    Invoke-LoggedCommand -Target "Ollama" -Phase "LocalPrompt" -FilePath "ollama" -Arguments @("run", $OllamaModel, $OllamaPromptText) -TimeoutSeconds 900 -TreatNonZeroAsWarning $true | Out-Null
}
else {
    Add-SmokeResult -Target "Ollama" -Phase "LocalPrompt" -Status "Skipped" -Details "SkipLocalOllamaPrompt was set."
}

# 5. OpenClaw
Write-Section "5. OpenClaw"
if ($Install) {
    $openClawInstall = '$s = (iwr -useb https://openclaw.ai/install.ps1).Content; & ([scriptblock]::Create($s)) -NoOnboard'
    Invoke-LoggedPowerShell -Target "OpenClaw" -Phase "Install-NoOnboard" -Command $openClawInstall -TimeoutSeconds 900 -TreatNonZeroAsWarning $true | Out-Null
    Refresh-SessionPath
    Add-NpmGlobalBinToPath

    if (-not (Test-CommandAvailable "openclaw")) {
        Add-SmokeResult -Target "OpenClaw" -Phase "Install-fallback" -Status "Warning" -Details "Installer did not put openclaw on PATH. Trying npm fallback: npm install -g openclaw@latest"
        Install-NpmGlobalPackage -Target "OpenClaw" -PackageName "openclaw@latest" | Out-Null
        Refresh-SessionPath
        Add-NpmGlobalBinToPath
    }
}
if ($RunOnce) {
    Invoke-LoggedCommand -Target "OpenClaw" -Phase "RunOnce-version" -FilePath "openclaw" -Arguments @("--version") -TimeoutSeconds 120 -TreatNonZeroAsWarning $true | Out-Null
    Invoke-LoggedCommand -Target "OpenClaw" -Phase "RunOnce-doctor" -FilePath "openclaw" -Arguments @("doctor") -TimeoutSeconds 180 -TreatNonZeroAsWarning $true | Out-Null
}
Add-NoCredentialPromptSkip -Target "OpenClaw" -UseInstead "Use only install/run artifacts unless a local provider is explicitly configured."

# 6. Codex CLI
Write-Section "6. Codex CLI"
if ($Install) {
    Invoke-LoggedPowerShell -Target "Codex CLI" -Phase "Install-native" -Command "irm https://chatgpt.com/codex/install.ps1 | iex" -TimeoutSeconds 900 -TreatNonZeroAsWarning $true | Out-Null
    Refresh-SessionPath
    if (-not (Test-CommandAvailable "codex")) {
        Install-NpmGlobalPackage -Target "Codex CLI" -PackageName "@openai/codex" | Out-Null
    }
}
if ($RunOnce) {
    Invoke-LoggedCommand -Target "Codex CLI" -Phase "RunOnce-help" -FilePath "codex" -Arguments @("--help") -TimeoutSeconds 120 -TreatNonZeroAsWarning $true | Out-Null
}
Add-NoCredentialPromptSkip -Target "Codex CLI"

# 7. Codex Desktop
if ($IncludeDesktopApps) {
    Write-Section "7. Codex Desktop"
    if ($Install) {
        if (-not [string]::IsNullOrWhiteSpace($env:CODEX_DESKTOP_PACKAGE_ID)) {
            Install-WingetPackage -Target "Codex Desktop" -PackageId $env:CODEX_DESKTOP_PACKAGE_ID -Source "msstore" | Out-Null
        }
        else {
            Add-SmokeResult -Target "Codex Desktop" -Phase "Install" -Status "Skipped" -Details "No stable Microsoft Store package id configured. Set CODEX_DESKTOP_PACKAGE_ID if you have the exact Store package id."
        }
    }
    if ($RunOnce) {
        if (Test-CommandAvailable "codex") {
            Start-ProcessOnce -Target "Codex Desktop" -Phase "RunOnce-codex-app" -FilePath "codex" -Arguments @("app") -ProcessNameLike @("Codex") | Out-Null
        }
        else {
            Start-StartMenuAppOnce -Target "Codex Desktop" -NameLike "Codex" -ProcessNameLike @("Codex") | Out-Null
        }
    }
    Add-SmokeResult -Target "Codex Desktop" -Phase "Prompt" -Status "Skipped" -Details "Desktop app is not a headless no-credentials prompt target."
}

# 8. OpenCode
Write-Section "8. OpenCode"
if ($Install) {
    Install-NpmGlobalPackage -Target "OpenCode" -PackageName "opencode-ai" | Out-Null
}
if ($RunOnce) {
    Invoke-LoggedCommand -Target "OpenCode" -Phase "RunOnce-version" -FilePath "opencode" -Arguments @("--version") -TimeoutSeconds 120 -TreatNonZeroAsWarning $true | Out-Null
}
Add-NoCredentialPromptSkip -Target "OpenCode"

# 9. Claude Desktop
if ($IncludeDesktopApps) {
    Write-Section "9. Claude Desktop"
    if ($Install) {
        if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_DESKTOP_MSIX_URL)) {
            $claudeMsix = Join-Path $WorkRoot "ClaudeDesktop.msix"
            Invoke-LoggedPowerShell -Target "Claude Desktop" -Phase "Download-MSIX" -Command "Invoke-WebRequest -Uri '$env:CLAUDE_DESKTOP_MSIX_URL' -OutFile '$claudeMsix'" -TimeoutSeconds 900 -TreatNonZeroAsWarning $true | Out-Null
            Invoke-LoggedPowerShell -Target "Claude Desktop" -Phase "Install-MSIX" -Command "Add-AppxPackage -Path '$claudeMsix'" -TimeoutSeconds 900 -TreatNonZeroAsWarning $true | Out-Null
        }
        else {
            Install-WingetPackage -Target "Claude Desktop" -PackageId "Anthropic.Claude" | Out-Null
        }
    }
    if ($RunOnce) {
        $launched = Start-StartMenuAppOnce -Target "Claude Desktop" -NameLike @("Claude Desktop", "Claude", "Anthropic") -ProcessNameLike @("Claude")
        if (-not $launched) {
            Start-ExecutableCandidateOnce -Target "Claude Desktop" -PathCandidates @(
                "$env:LOCALAPPDATA\Programs\Claude\Claude.exe",
                "$env:LOCALAPPDATA\Programs\Anthropic\Claude\Claude.exe",
                "$env:LOCALAPPDATA\AnthropicClaude\Claude.exe",
                "$env:ProgramFiles\Claude\Claude.exe",
                "$env:ProgramFiles\Anthropic\Claude\Claude.exe",
                "$env:ProgramFiles\WindowsApps\*Claude*\*.exe"
            ) -ProcessNameLike @("Claude") | Out-Null
        }
    }
    Add-SmokeResult -Target "Claude Desktop" -Phase "Prompt" -Status "Skipped" -Details "Desktop app is not a headless no-credentials prompt target."
}

# 10. ChatGPT Desktop
if ($IncludeDesktopApps) {
    Write-Section "10. ChatGPT Desktop"
    if ($Install) {
        Install-WingetPackage -Target "ChatGPT Desktop" -PackageId "9NT1R1C2HH7J" -Source "msstore" | Out-Null
    }
    if ($RunOnce) {
        Start-StartMenuAppOnce -Target "ChatGPT Desktop" -NameLike "ChatGPT" -ProcessNameLike @("ChatGPT") | Out-Null
    }
    Add-SmokeResult -Target "ChatGPT Desktop" -Phase "Prompt" -Status "Skipped" -Details "Desktop app is not a headless no-credentials prompt target."
}

# 11-16. VS Code extensions
if ($IncludeVSCodeExtensions) {
    Write-Section "11-16. VS Code AI extensions"

    if ($Install) {
        $extensions = @(
            @{ Target = "VS Code GitHub Copilot Extension"; Id = "GitHub.copilot" },
            @{ Target = "VS Code GitHub Copilot Chat Extension"; Id = "GitHub.copilot-chat" },
            @{ Target = "VS Code Claude Code Extension"; Id = "anthropic.claude-code" },
            @{ Target = "VS Code Codex Extension"; Id = "openai.chatgpt" },
            @{ Target = "VS Code Gemini Code Assist Extension"; Id = "Google.geminicodeassist" },
            @{ Target = "VS Code Cline Extension"; Id = "saoudrizwan.claude-dev" }
        )

        if ($IncludeDeprecatedRooCode) {
            $extensions += @{ Target = "VS Code Roo Code Extension"; Id = "RooVeterinaryInc.roo-cline" }
        }

        foreach ($ext in $extensions) {
            Install-VSCodeExtensionAndVerify -Target $ext.Target -ExtensionId $ext.Id | Out-Null
        }
    }

    if ($RunOnce) {
        if (Test-CommandAvailable "code") {
            Invoke-LoggedCommand -Target "VS Code" -Phase "RunOnce-list-extensions" -FilePath "code" -Arguments @("--list-extensions") -TimeoutSeconds 120 -TreatNonZeroAsWarning $true | Out-Null
            Start-ProcessOnce -Target "VS Code" -Phase "RunOnce-launch" -FilePath "code" -Arguments @($WorkspaceRoot) -ProcessNameLike @("Code") | Out-Null
        }
        else {
            Add-SmokeResult -Target "VS Code" -Phase "RunOnce" -Status "Skipped" -Details "VS Code CLI 'code' not found."
        }
    }

    Add-SmokeResult -Target "VS Code AI extensions" -Phase "Prompt" -Status "Skipped" -Details "Extensions are not headless no-credentials prompt targets."
}

# 17. Cursor
if ($IncludeConditionalTargets) {
    Write-Section "17. Cursor"
    if ($Install) {
        Install-WingetPackage -Target "Cursor Desktop" -PackageId "Anysphere.Cursor" | Out-Null
        Invoke-LoggedPowerShell -Target "Cursor CLI" -Phase "Install-native-win32" -Command "irm 'https://cursor.com/install?win32=true' | iex" -TimeoutSeconds 900 -TreatNonZeroAsWarning $true | Out-Null
        Refresh-SessionPath
    }

    if ($RunOnce) {
        if (Test-CommandAvailable "cursor-agent") {
            Invoke-LoggedCommand -Target "Cursor CLI" -Phase "RunOnce-help" -FilePath "cursor-agent" -Arguments @("--help") -TimeoutSeconds 120 -TreatNonZeroAsWarning $true | Out-Null
        }
        elseif (Test-CommandAvailable "cursor") {
            Invoke-LoggedCommand -Target "Cursor" -Phase "RunOnce-version" -FilePath "cursor" -Arguments @("--version") -TimeoutSeconds 120 -TreatNonZeroAsWarning $true | Out-Null
            Start-ProcessOnce -Target "Cursor Desktop" -Phase "RunOnce-launch" -FilePath "cursor" -Arguments @($WorkspaceRoot) -ProcessNameLike @("Cursor") | Out-Null
        }
        else {
            Start-StartMenuAppOnce -Target "Cursor Desktop" -NameLike "Cursor" -ProcessNameLike @("Cursor") | Out-Null
        }
    }

    Add-NoCredentialPromptSkip -Target "Cursor CLI"
}

# 18. Poe Desktop
if ($IncludeDesktopApps) {
    Write-Section "18. Poe Desktop"
    if ($Install) {
        Install-WingetPackage -Target "Poe Desktop" -PackageId "Quora.Poe" | Out-Null
    }
    if ($RunOnce) {
        try {
            Start-Process "poe-app:" -ErrorAction Stop
            Start-Sleep -Seconds $LaunchSeconds
            if (-not $KeepAppsOpen) {
                Get-Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProcessName -like "*Poe*" } |
                    Stop-Process -Force -ErrorAction SilentlyContinue
            }
            Add-SmokeResult -Target "Poe Desktop" -Phase "RunOnce-protocol" -Status "OK" -Details "Launched poe-app protocol."
        }
        catch {
            Add-SmokeResult -Target "Poe Desktop" -Phase "RunOnce-protocol" -Status "Warning" -Details $_.Exception.Message
            Start-StartMenuAppOnce -Target "Poe Desktop" -NameLike "Poe" -ProcessNameLike @("Poe") | Out-Null
        }
    }
    Add-SmokeResult -Target "Poe Desktop" -Phase "Prompt" -Status "Skipped" -Details "Desktop app is not a headless no-credentials prompt target."
}

# 19. Nanobot
if ($IncludeExperimentalTargets) {
    Write-Section "19. Nanobot"
    if ($Install) {
        Install-PythonPackage -Target "Nanobot" -PackageName "nanobot-ai" | Out-Null
    }
    if ($RunOnce) {
        Invoke-LoggedCommand -Target "Nanobot" -Phase "RunOnce-help" -FilePath "nanobot" -Arguments @("--help") -TimeoutSeconds 120 -TreatNonZeroAsWarning $true | Out-Null
    }
    Add-SmokeResult -Target "Nanobot" -Phase "Prompt" -Status "Skipped" -Details "Experimental target. No verified no-credentials one-shot prompt command is used."
}

# 20. Antigravity IDE
if ($IncludeDesktopApps) {
    Write-Section "20. Antigravity IDE"
    if ($Install) {
        if (-not [string]::IsNullOrWhiteSpace($env:ANTIGRAVITY_IDE_INSTALLER_URL)) {
            $agInstaller = Join-Path $WorkRoot "AntigravityIDE.exe"
            Invoke-LoggedPowerShell -Target "Antigravity IDE" -Phase "Download-installer" -Command "Invoke-WebRequest -Uri '$env:ANTIGRAVITY_IDE_INSTALLER_URL' -OutFile '$agInstaller'" -TimeoutSeconds 900 -TreatNonZeroAsWarning $true | Out-Null
            Invoke-LoggedCommand -Target "Antigravity IDE" -Phase "Install-installer" -FilePath $agInstaller -Arguments @("/S") -TimeoutSeconds 900 -TreatNonZeroAsWarning $true | Out-Null
        }
        else {
            Install-WingetPackage -Target "Antigravity IDE" -PackageId "Google.Antigravity" | Out-Null
        }
    }
    if ($RunOnce) {
        $launched = Start-StartMenuAppOnce -Target "Antigravity IDE" -NameLike @("Antigravity IDE", "Antigravity") -ProcessNameLike @("Antigravity")
        if (-not $launched) {
            Start-ExecutableCandidateOnce -Target "Antigravity IDE" -PathCandidates @(
                "$env:LOCALAPPDATA\Programs\Antigravity\Antigravity.exe",
                "$env:LOCALAPPDATA\Programs\Antigravity IDE\Antigravity.exe",
                "$env:ProgramFiles\Google\Antigravity\Antigravity.exe",
                "$env:ProgramFiles\Antigravity\Antigravity.exe",
                "$env:ProgramFiles\WindowsApps\*Antigravity*\*.exe"
            ) -ProcessNameLike @("Antigravity") | Out-Null
        }
    }
    Add-SmokeResult -Target "Antigravity IDE" -Phase "Prompt" -Status "Skipped" -Details "IDE is not a headless no-credentials prompt target."
}

# 21. Antigravity CLI
if ($IncludeConditionalTargets) {
    Write-Section "21. Antigravity CLI"
    if ($Install) {
        Invoke-LoggedPowerShell -Target "Antigravity CLI" -Phase "Install-native" -Command "irm https://antigravity.google/cli/install.ps1 | iex" -TimeoutSeconds 900 -TreatNonZeroAsWarning $true | Out-Null
        Refresh-SessionPath
    }
    if ($RunOnce) {
        Invoke-LoggedCommand -Target "Antigravity CLI" -Phase "RunOnce-help" -FilePath "agy" -Arguments @("help") -TimeoutSeconds 120 -TreatNonZeroAsWarning $true | Out-Null
    }
    Add-NoCredentialPromptSkip -Target "Antigravity CLI"
}

Write-Section "Summary"

$ResultsCsv = Join-Path $WorkRoot "ai-agent-smoke-results-nocreds-v3.csv"
$ResultsJson = Join-Path $WorkRoot "ai-agent-smoke-results-nocreds-v3.json"

$Results | Export-Csv -Path $ResultsCsv -NoTypeInformation -Encoding UTF8
$Results | ConvertTo-Json -Depth 6 | Out-File -FilePath $ResultsJson -Encoding UTF8

$summary = $Results |
    Group-Object Status |
    Sort-Object Name |
    Select-Object Name, Count

$summary | Format-Table -AutoSize

Write-Host ""
Write-Host "Results CSV:  $ResultsCsv"
Write-Host "Results JSON: $ResultsJson"
Write-Host "Output root:  $OutputRoot"
Write-Host "Transcript:   $TranscriptPath"
Write-Host "Started:      $($StartTime.ToString('o'))"
Write-Host "Finished:     $((Get-Date).ToString('o'))"

try {
    Stop-Transcript | Out-Null
}
catch {
    Write-Warning "Could not stop transcript: $($_.Exception.Message)"
}
