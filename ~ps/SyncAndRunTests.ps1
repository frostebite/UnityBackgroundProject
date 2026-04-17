<#
.SYNOPSIS
    Syncs project to background worker, compiles, and runs tests.

.DESCRIPTION
    Uses rclone to mirror the current project to a sibling directory,
    runs a compile check to verify compilation succeeds,
    then runs Unity in batch mode to execute tests.

.PARAMETER Suffix
    Suffix for the background project directory name. Default: "-BackgroundWorker"

.PARAMETER InstanceName
    Named instance from background-project-config.json. When omitted, uses the
    primary instance for backward compatibility.

.PARAMETER TestPlatform
    Test platform to run. Default: "EditMode". Options: EditMode, PlayMode

.PARAMETER TestCategory
    Optional test category filter (e.g., "Maturity:trusted")

.PARAMETER TestFilter
    Optional test name filter (e.g., "Coast_SubPatch_4x4With2x2InMiddle")

.PARAMETER SkipSync
    Skip the sync step (use if project is already synced).

.PARAMETER SkipCompile
    Skip the compile check step.

.PARAMETER Verbose
    Show detailed output during execution.

.EXAMPLE
    ./SyncAndRunTests.ps1
    # Syncs, compiles, and runs EditMode tests

.EXAMPLE
    ./SyncAndRunTests.ps1 -TestPlatform PlayMode
    # Syncs, compiles, and runs PlayMode tests

.EXAMPLE
    ./SyncAndRunTests.ps1 -TestCategory "Maturity:trusted" -SkipSync
    # Runs trusted tests without syncing

.EXAMPLE
    ./SyncAndRunTests.ps1 -TestFilter "Coast_SubPatch_4x4With2x2InMiddle"
    # Runs a specific test by name
#>

param(
    [string]$Suffix = "-BackgroundWorker",
    [string]$InstanceName = "",
    [string]$TestPlatform = "EditMode",
    [string]$TestCategory = "",
    [string]$TestFilter = "",
    [switch]$SkipSync,
    [switch]$SkipCompile,
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

# Dot-source common functions (same folder)
. "$PSScriptRoot/BackgroundProjectCommon.ps1"

# Determine paths first (needed for lock)
$projectRoot = Get-BackgroundProjectRoot -ScriptRoot $PSScriptRoot -WorkingDirectory $PWD.Path
$destinationPath = Get-BackgroundProjectPath -ProjectRoot $projectRoot -Suffix $Suffix -InstanceName $InstanceName

# Build operation description for lock
$operationDesc = "SyncAndRunTests"
if ($TestFilter) {
    $operationDesc += " -TestFilter '$TestFilter'"
} elseif ($TestCategory) {
    $operationDesc += " -TestCategory '$TestCategory'"
}

# Acquire lock before any operations
if (-not (New-BackgroundProjectLock -DestinationPath $destinationPath -Operation $operationDesc)) {
    exit 1
}

try {
    Write-BackgroundProjectLog "=== Sync, Compile, and Run Tests ===" "INFO"
    Write-BackgroundProjectLog "Source: $projectRoot" "INFO"
    Write-BackgroundProjectLog "Background: $destinationPath" "INFO"
    Write-BackgroundProjectLog "Test Platform: $TestPlatform" "INFO"
    if ($TestCategory) {
        Write-BackgroundProjectLog "Test Category: $TestCategory" "INFO"
    }
    if ($TestFilter) {
        Write-BackgroundProjectLog "Test Filter: $TestFilter" "INFO"
    }
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

    # Step 2: Compile check (unless skipped)
    $unityExe = Get-UnityExecutablePath -ProjectPath $destinationPath
    Write-BackgroundProjectLog "Using Unity: $unityExe" "INFO"

    if (-not $SkipCompile) {
        Write-BackgroundProjectLog "Step 2: Running compile check..." "INFO"

        $compileArgs = @(
            "-batchmode",
            "-nographics",
            "-quit",
            "-projectPath",
            "`"$destinationPath`"",
            "-logFile",
            "-"
        )

        Write-BackgroundProjectLog "Running: $unityExe $($compileArgs -join ' ')" "INFO"
        $compileResult = Invoke-UnityProcess -UnityExe $unityExe -Arguments $compileArgs -WorkingDirectory $destinationPath -TimeoutSeconds 600 -ShowOutput:$Verbose

        if ($compileResult.ExitCode -ne 0) {
            Write-BackgroundProjectLog "=== COMPILE CHECK FAILED ===" "ERROR"
            Write-BackgroundProjectLog "Exit code: $($compileResult.ExitCode)" "ERROR"

            if ($compileResult.Stdout) {
                $lines = $compileResult.Stdout -split "`n"
                $displayLines = if ($lines.Count -gt 100) { $lines[-100..-1] } else { $lines }
                Write-Host ($displayLines -join "`n") -ForegroundColor Red
            }

            exit $compileResult.ExitCode
        }

        Write-BackgroundProjectLog "Compile check passed" "SUCCESS"
        Write-BackgroundProjectLog ""
    } else {
        Write-BackgroundProjectLog "Step 2: Skipping compile check (SkipCompile flag set)" "INFO"
        Write-BackgroundProjectLog ""
    }

    # Step 3: Run tests
    Write-BackgroundProjectLog "Step 3: Running tests..." "INFO"

    $unityArgs = @(
        "-batchmode",
        "-nographics",
        "-projectPath",
        "`"$destinationPath`"",
        "-runTests",
        "-testPlatform",
        $TestPlatform,
        "-logFile",
        "-"
    )

    # Add test category filter if specified
    if ($TestCategory) {
        $unityArgs += "-testFilter"
        $unityArgs += "`"category=$TestCategory`""
    }

    # Add test name filter if specified (can be combined with category)
    if ($TestFilter) {
        $unityArgs += "-testFilter"
        $unityArgs += "`"$TestFilter`""
    }

    Write-BackgroundProjectLog "Running: $unityExe $($unityArgs -join ' ')" "INFO"
    Write-BackgroundProjectLog ""

    # Tests can take longer, allow 30 minutes
    $result = Invoke-UnityProcess -UnityExe $unityExe -Arguments $unityArgs -WorkingDirectory $destinationPath -TimeoutSeconds 1800 -ShowOutput:$Verbose

    Write-BackgroundProjectLog ""

    if ($result.ExitCode -eq 0) {
        Write-BackgroundProjectLog "=== TESTS PASSED ===" "SUCCESS"
        $script:exitCode = 0
    } else {
        Write-BackgroundProjectLog "=== TESTS FAILED ===" "ERROR"
        Write-BackgroundProjectLog "Exit code: $($result.ExitCode)" "ERROR"

        if ($result.Stdout) {
            # Show last 150 lines of output for test debugging
            $lines = $result.Stdout -split "`n"
            $displayLines = if ($lines.Count -gt 150) { $lines[-150..-1] } else { $lines }
            Write-Host ($displayLines -join "`n") -ForegroundColor Red
        }

        $script:exitCode = $result.ExitCode
    }
} catch {
    Write-BackgroundProjectLog "ERROR: $($_.Exception.Message)" "ERROR"
    $script:exitCode = 1
} finally {
    # Copy logs from background project to main workspace
    Copy-BackgroundProjectLogs -ProjectRoot $projectRoot -BackgroundProjectPath $destinationPath -OperationName "SyncAndRunTests" -InstanceName $InstanceName

    # Always release the lock
    Remove-BackgroundProjectLock -DestinationPath $destinationPath
}

exit $script:exitCode
