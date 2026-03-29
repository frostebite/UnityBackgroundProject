<#
.SYNOPSIS
    Syncs the Unity project to a background project copy.

.DESCRIPTION
    Uses rclone to mirror the current project to a sibling directory.
    Excludes Unity-generated folders (Library, Temp, etc.) and build artifacts.

.PARAMETER Suffix
    Suffix for the background project directory name. Default: "-BackgroundWorker"

.PARAMETER Path
    Custom path for the background project. If not specified, uses sibling directory.

.PARAMETER InstanceName
    Named instance from background-project-config.json. When omitted, uses the
    primary instance for backward compatibility.

.PARAMETER Verbose
    Show detailed output during sync.

.EXAMPLE
    ./SyncProject.ps1
    # Syncs to ../ProjectName-BackgroundWorker

.EXAMPLE
    ./SyncProject.ps1 -Suffix "-Test"
    # Syncs to ../ProjectName-Test

.EXAMPLE
    ./SyncProject.ps1 -Path "D:\BackgroundProjects\MyProject"
    # Syncs to specified path
#>

param(
    [string]$Suffix = "-BackgroundWorker",
    [string]$Path = "",
    [string]$InstanceName = "",
    [switch]$Verbose
)

# Dot-source common functions
. "$PSScriptRoot/BackgroundProjectCommon.ps1"

# Determine paths first (needed for lock)
$projectRoot = Get-BackgroundProjectRoot
$destinationPath = Get-BackgroundProjectPath -ProjectRoot $projectRoot -Suffix $Suffix -Path $Path -InstanceName $InstanceName

# Acquire lock before any operations
if (-not (New-BackgroundProjectLock -DestinationPath $destinationPath -Operation "SyncProject")) {
    exit 1
}

try {
    Write-BackgroundProjectLog "=== Sync Background Project ===" "INFO"

    Sync-BackgroundProject -ProjectRoot $projectRoot -DestinationPath $destinationPath -Verbose:$Verbose

    $script:exitCode = 0
} catch {
    Write-BackgroundProjectLog "ERROR: $($_.Exception.Message)" "ERROR"
    $script:exitCode = 1
} finally {
    # Copy logs from background project to main workspace (if any exist)
    Copy-BackgroundProjectLogs -ProjectRoot $projectRoot -BackgroundProjectPath $destinationPath -OperationName "SyncProject" -InstanceName $InstanceName

    # Always release the lock
    Remove-BackgroundProjectLock -DestinationPath $destinationPath
}

exit $script:exitCode
