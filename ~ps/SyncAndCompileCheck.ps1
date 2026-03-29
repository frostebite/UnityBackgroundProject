<#
.SYNOPSIS
    Syncs project to background worker and runs compile check.

.DESCRIPTION
    Uses rclone to mirror the current project to a sibling directory,
    then runs Unity in batch mode to verify compilation succeeds.

.PARAMETER Suffix
    Suffix for the background project directory name. Default: "-BackgroundWorker"

.PARAMETER InstanceName
    Named instance from background-project-config.json. When omitted, uses the
    primary instance for backward compatibility.

.PARAMETER SkipSync
    Skip the sync step (use if project is already synced).

.PARAMETER Verbose
    Show detailed output during execution.

.PARAMETER TimeoutSeconds
    Maximum time in seconds to wait for Unity to complete. Default: 1800 (30 minutes).

.EXAMPLE
    ./SyncAndCompileCheck.ps1
    # Syncs and runs compile check

.EXAMPLE
    ./SyncAndCompileCheck.ps1 -SkipSync
    # Runs compile check without syncing first
#>

param(
    [string]$Suffix = "-BackgroundWorker",
    [string]$InstanceName = "",
    [switch]$SkipSync,
    [switch]$Verbose,
    [int]$TimeoutSeconds = 1800
)

$ErrorActionPreference = "Stop"

# Dot-source common functions (same folder)
. "$PSScriptRoot/BackgroundProjectCommon.ps1"

# Determine paths first (needed for lock)
$projectRoot = Get-BackgroundProjectRoot -ScriptRoot $PSScriptRoot -WorkingDirectory $PWD.Path
$destinationPath = Get-BackgroundProjectPath -ProjectRoot $projectRoot -Suffix $Suffix -InstanceName $InstanceName

# Acquire lock before any operations
if (-not (New-BackgroundProjectLock -DestinationPath $destinationPath -Operation "SyncAndCompileCheck")) {
    exit 1
}

try {
    Write-BackgroundProjectLog "=== Sync and Compile Check ===" "INFO"
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

    $result = Invoke-UnityProcess -UnityExe $unityExe -Arguments $unityArgs -WorkingDirectory $destinationPath -TimeoutSeconds $TimeoutSeconds -ShowOutput:$Verbose

    Write-BackgroundProjectLog ""

    if ($result.ExitCode -eq 0) {
        Write-BackgroundProjectLog "=== COMPILE CHECK PASSED ===" "SUCCESS"
        $script:exitCode = 0
    } else {
        Write-BackgroundProjectLog "=== COMPILE CHECK FAILED ===" "ERROR"
        Write-BackgroundProjectLog "Exit code: $($result.ExitCode)" "ERROR"

        if ($result.Stdout) {
            # Show last 100 lines of output for debugging
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
    Copy-BackgroundProjectLogs -ProjectRoot $projectRoot -BackgroundProjectPath $destinationPath -OperationName "SyncAndCompileCheck" -InstanceName $InstanceName

    # Always release the lock
    Remove-BackgroundProjectLock -DestinationPath $destinationPath
}

exit $script:exitCode
