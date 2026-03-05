<#
.SYNOPSIS
    Checks the lock status of the background worker project.

.DESCRIPTION
    Displays information about any existing lock on the background worker.
    Can optionally force-remove a stale or orphaned lock.

.PARAMETER Suffix
    Suffix for the background project directory name. Default: "-BackgroundWorker"

.PARAMETER ForceRemove
    Force remove the lock file, even if the locking process still exists.
    Use with caution - only when you're sure the lock is orphaned.

.EXAMPLE
    ./CheckLock.ps1
    # Shows current lock status

.EXAMPLE
    ./CheckLock.ps1 -ForceRemove
    # Forcibly removes any existing lock
#>

param(
    [string]$Suffix = "-BackgroundWorker",
    [switch]$ForceRemove
)

# Dot-source common functions
. "$PSScriptRoot/BackgroundProjectCommon.ps1"

try {
    $projectRoot = Get-BackgroundProjectRoot
    $destinationPath = Get-BackgroundProjectPath -ProjectRoot $projectRoot -Suffix $Suffix
    $lockPath = Get-BackgroundProjectLockPath -DestinationPath $destinationPath

    Write-BackgroundProjectLog "=== Background Worker Lock Status ===" "INFO"
    Write-BackgroundProjectLog "Background Project: $destinationPath" "INFO"
    Write-BackgroundProjectLog "Lock File: $lockPath" "INFO"
    Write-BackgroundProjectLog ""

    if (-not (Test-Path $lockPath)) {
        Write-BackgroundProjectLog "Status: UNLOCKED (no lock file exists)" "SUCCESS"
        exit 0
    }

    $lockInfo = Get-BackgroundProjectLockInfo -LockPath $lockPath

    if (-not $lockInfo) {
        Write-BackgroundProjectLog "Status: INVALID LOCK (lock file exists but is corrupted)" "WARN"

        if ($ForceRemove) {
            Write-BackgroundProjectLog "Removing invalid lock file..." "WARN"
            Remove-Item $lockPath -Force
            Write-BackgroundProjectLog "Lock file removed" "SUCCESS"
        } else {
            Write-BackgroundProjectLog "Use -ForceRemove to delete the invalid lock file" "INFO"
        }
        exit 0
    }

    # Display lock info
    $elapsed = (Get-Date) - $lockInfo.StartTime
    $elapsedStr = "{0:hh\:mm\:ss}" -f $elapsed

    Write-BackgroundProjectLog "Status: LOCKED" "WARN"
    Write-BackgroundProjectLog ""
    Write-BackgroundProjectLog "Lock Details:" "INFO"
    Write-BackgroundProjectLog "  Operation: $($lockInfo.Operation)" "INFO"
    Write-BackgroundProjectLog "  PID: $($lockInfo.PID)" "INFO"
    Write-BackgroundProjectLog "  Machine: $($lockInfo.MachineName)" "INFO"
    Write-BackgroundProjectLog "  Started: $($lockInfo.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))" "INFO"
    Write-BackgroundProjectLog "  Running for: $elapsedStr" "INFO"
    Write-BackgroundProjectLog ""

    # Check if process exists
    $isStale = Test-BackgroundProjectLockStale -LockInfo $lockInfo

    if ($isStale) {
        Write-BackgroundProjectLog "Lock appears to be STALE (process no longer exists or timed out)" "WARN"
    } else {
        Write-BackgroundProjectLog "Lock is ACTIVE (process is still running)" "INFO"
    }

    Write-BackgroundProjectLog ""

    if ($ForceRemove) {
        if (-not $isStale) {
            Write-BackgroundProjectLog "WARNING: Forcing removal of an active lock!" "WARN"
            Write-BackgroundProjectLog "The locking process (PID: $($lockInfo.PID)) may still be running." "WARN"
            Write-BackgroundProjectLog ""
        }

        Remove-Item $lockPath -Force
        Write-BackgroundProjectLog "Lock file forcibly removed" "SUCCESS"
    } else {
        if ($isStale) {
            Write-BackgroundProjectLog "The lock will be automatically cleaned up on next operation." "INFO"
            Write-BackgroundProjectLog "Or use -ForceRemove to remove it now." "INFO"
        } else {
            Write-BackgroundProjectLog "Wait for the operation to complete, or:" "INFO"
            Write-BackgroundProjectLog "  1. Kill the process: Stop-Process -Id $($lockInfo.PID)" "INFO"
            Write-BackgroundProjectLog "  2. Force remove: ./CheckLock.ps1 -ForceRemove" "INFO"
        }
    }

    exit 0
} catch {
    Write-BackgroundProjectLog "ERROR: $($_.Exception.Message)" "ERROR"
    exit 1
}
