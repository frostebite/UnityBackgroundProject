<#
.SYNOPSIS
    Syncs project and runs a compile check on the background project.

.DESCRIPTION
    Syncs the current project to a background copy, then runs Unity in batch mode
    to verify compilation succeeds.

.PARAMETER Suffix
    Suffix for the background project directory name. Default: "-BackgroundWorker"

.PARAMETER Path
    Custom path for the background project. If not specified, uses sibling directory.

.PARAMETER SkipSync
    Skip the sync step (use if project is already synced).

.PARAMETER Verbose
    Show detailed output during execution.

.EXAMPLE
    ./CompileCheck.ps1
    # Syncs and runs compile check

.EXAMPLE
    ./CompileCheck.ps1 -SkipSync
    # Runs compile check without syncing first
#>

param(
    [string]$Suffix = "-BackgroundWorker",
    [string]$Path = "",
    [switch]$SkipSync,
    [switch]$Verbose
)

# Dot-source common functions
. "$PSScriptRoot/BackgroundProjectCommon.ps1"

# Determine paths first (needed for lock)
$projectRoot = Get-BackgroundProjectRoot
$destinationPath = Get-BackgroundProjectPath -ProjectRoot $projectRoot -Suffix $Suffix -Path $Path

# Acquire lock before any operations
if (-not (New-BackgroundProjectLock -DestinationPath $destinationPath -Operation "CompileCheck")) {
    exit 1
}

try {
    Write-BackgroundProjectLog "=== Compile Check Background Project ===" "INFO"
    Write-BackgroundProjectLog "Source: $projectRoot" "INFO"
    Write-BackgroundProjectLog "Background: $destinationPath" "INFO"
    Write-BackgroundProjectLog ""

    # Step 1: Sync (unless skipped)
    if (-not $SkipSync) {
        Write-BackgroundProjectLog "Step 1: Syncing project..." "INFO"
        Sync-BackgroundProject -ProjectRoot $projectRoot -DestinationPath $destinationPath -Verbose:$Verbose
        Write-BackgroundProjectLog ""
    } else {
        Write-BackgroundProjectLog "Step 1: Skipping sync (SkipSync flag set)" "INFO"
        Write-BackgroundProjectLog ""
    }

    # Step 2: Run compile check
    Write-BackgroundProjectLog "Step 2: Running compile check..." "INFO"

    $unityExe = Get-UnityExecutablePath -ProjectPath $destinationPath
    Write-BackgroundProjectLog "Using Unity: $unityExe" "INFO"

    $unityArgs = @(
        "-batchmode",
        "-nographics",
        "-quit",
        "-projectPath",
        "`"$destinationPath`"",
        "-logFile",
        "-"
    )

    Write-BackgroundProjectLog "Running: $unityExe $($unityArgs -join ' ')" "INFO"
    Write-BackgroundProjectLog ""

    $result = Invoke-UnityProcess -UnityExe $unityExe -Arguments $unityArgs -WorkingDirectory $destinationPath -TimeoutSeconds 600 -ShowOutput:$Verbose

    Write-BackgroundProjectLog ""

    if ($result.ExitCode -eq 0) {
        Write-BackgroundProjectLog "=== COMPILE CHECK PASSED ===" "SUCCESS"
        $script:exitCode = 0
    } else {
        Write-BackgroundProjectLog "=== COMPILE CHECK FAILED ===" "ERROR"
        Write-BackgroundProjectLog "Exit code: $($result.ExitCode)" "ERROR"

        if ($result.Stdout) {
            $lines = $result.Stdout -split "`n"
            $displayLines = if ($lines.Count -gt 100) { $lines[-100..-1] } else { $lines }
            Write-Host ($displayLines -join "`n") -ForegroundColor Red
        }

        $script:exitCode = $result.ExitCode
    }
} catch {
    Write-BackgroundProjectLog "ERROR: $($_.Exception.Message)" "ERROR"
    $script:exitCode = 1
} finally {
    # Copy logs from background project to main workspace
    Copy-BackgroundProjectLogs -ProjectRoot $projectRoot -BackgroundProjectPath $destinationPath -OperationName "CompileCheck"

    # Always release the lock
    Remove-BackgroundProjectLock -DestinationPath $destinationPath
}

exit $script:exitCode
