# BackgroundProjectCommon.ps1
# Shared functions for background project scripts
#
# This script can be located in:
#   - Assets/_Game/Submodules/UnityBackgroundProject/~ps/ (submodule in Assets)
#   - Packages/com.company.backgroundproject/~ps/ (UPM package)
#   - Any other location as a git submodule
#
# Project root detection is location-agnostic.

function Write-BackgroundProjectLog {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Test-UnityProjectRoot {
    param (
        [string]$Path
    )

    if (-not $Path -or -not (Test-Path $Path)) {
        return $false
    }

    # A Unity project has both Assets and ProjectSettings folders
    $hasAssets = Test-Path (Join-Path $Path "Assets")
    $hasProjectSettings = Test-Path (Join-Path $Path "ProjectSettings")

    # ProjectVersion.txt is the most reliable indicator
    $hasVersionFile = Test-Path (Join-Path $Path "ProjectSettings\ProjectVersion.txt")

    return $hasAssets -and $hasProjectSettings -and $hasVersionFile
}

function Get-BackgroundProjectRoot {
    param (
        [string]$ScriptRoot = $PSScriptRoot,
        [string]$WorkingDirectory = $PWD.Path
    )

    # Method 1: Check current working directory first
    # This is the most reliable when called from git hooks (which run from project root)
    if (Test-UnityProjectRoot $WorkingDirectory) {
        return $WorkingDirectory
    }

    # Method 2: Walk up from script location
    # Works regardless of where the script is located (Assets, Packages, external submodule)
    $current = $ScriptRoot
    $maxDepth = 15  # Increased depth to handle deep nesting

    for ($i = 0; $i -lt $maxDepth; $i++) {
        if (-not $current) { break }

        if (Test-UnityProjectRoot $current) {
            return $current
        }

        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }  # Reached root
        $current = $parent
    }

    # Method 3: Check if we're in a Packages folder (UPM package)
    # The project root would be the parent of Packages
    if ($ScriptRoot -match "[\\/]Packages[\\/]") {
        $packagesIndex = $ScriptRoot.IndexOf("Packages")
        if ($packagesIndex -gt 0) {
            $candidateRoot = $ScriptRoot.Substring(0, $packagesIndex - 1)
            if (Test-UnityProjectRoot $candidateRoot) {
                return $candidateRoot
            }
        }
    }

    # Method 4: Walk up from working directory
    $current = $WorkingDirectory
    for ($i = 0; $i -lt $maxDepth; $i++) {
        if (-not $current) { break }

        if (Test-UnityProjectRoot $current) {
            return $current
        }

        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }

    # Method 5: Check common environment variables
    if ($env:UNITY_PROJECT_ROOT -and (Test-UnityProjectRoot $env:UNITY_PROJECT_ROOT)) {
        return $env:UNITY_PROJECT_ROOT
    }

    Write-BackgroundProjectLog "ERROR: Could not find Unity project root" "ERROR"
    Write-BackgroundProjectLog "  Script location: $ScriptRoot" "ERROR"
    Write-BackgroundProjectLog "  Working directory: $WorkingDirectory" "ERROR"
    Write-BackgroundProjectLog "  Tip: Set UNITY_PROJECT_ROOT environment variable or run from project root" "ERROR"
    throw "Unity project root not found"
}

function Get-BackgroundProjectPath {
    param (
        [string]$ProjectRoot,
        [string]$Suffix = "-BackgroundWorker",
        [string]$Path = ""
    )

    if ($Path) {
        # Use explicitly provided path
        return $Path
    }

    # Check environment variable override
    if ($env:BACKGROUND_PROJECT_PATH) {
        return $env:BACKGROUND_PROJECT_PATH
    }

    # Use sibling folder approach
    $projectName = Split-Path $ProjectRoot -Leaf
    $parentDir = Split-Path $ProjectRoot -Parent

    if (-not $parentDir) {
        Write-BackgroundProjectLog "ERROR: Unable to determine parent directory for: $ProjectRoot" "ERROR"
        throw "Unable to determine parent directory"
    }

    return Join-Path $parentDir "$projectName$Suffix"
}

function Sync-BackgroundProject {
    param (
        [string]$ProjectRoot,
        [string]$DestinationPath,
        [switch]$Verbose
    )

    Write-BackgroundProjectLog "Syncing project to background copy..." "INFO"
    Write-BackgroundProjectLog "  Source: $ProjectRoot" "INFO"
    Write-BackgroundProjectLog "  Destination: $DestinationPath" "INFO"

    # Check if rclone is available
    $rcloneCmd = Get-Command rclone -ErrorAction SilentlyContinue
    if (-not $rcloneCmd) {
        Write-BackgroundProjectLog "ERROR: rclone not found on PATH. Please install rclone from https://rclone.org/install/" "ERROR"
        throw "rclone not found"
    }

    # Ensure destination directory exists
    if (-not (Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        Write-BackgroundProjectLog "Created destination directory: $DestinationPath" "INFO"
    }

    # Use rclone sync with exclude patterns anchored to root
    $rcloneArgs = @(
        "sync",
        "`"$ProjectRoot`"",
        "`"$DestinationPath`"",
        "--exclude", "/Library/**",
        "--exclude", "/Temp/**",
        "--exclude", "/Logs/**",
        "--exclude", "/obj/**",
        "--exclude", "/Obj/**",
        "--exclude", "/Builds/**",
        "--exclude", "/Build/**",
        "--exclude", "/UserSettings/**",
        "--exclude", "/MemoryCaptures/**",
        "--exclude", "/bin/**",
        "--exclude", "*.csproj",
        "--exclude", "*.sln",
        "--exclude", "*.csproj.user",
        "--exclude", "/.vs/**",
        "--exclude", "/.vscode/**",
        "--exclude", "/.idea/**",
        "--exclude", "/.gradle/**",
        "--exclude", "/DerivedData/**",
        "--exclude", "/.git/**",
        "--exclude", ".DS_Store",
        "--exclude", "Thumbs.db",
        "--progress"
    )

    if (-not $Verbose) {
        $rcloneArgs += "--stats=0"
    }

    Write-BackgroundProjectLog "Running rclone sync..." "INFO"
    $rcloneResult = & rclone $rcloneArgs 2>&1
    $rcloneExitCode = $LASTEXITCODE

    if ($rcloneExitCode -ne 0) {
        Write-BackgroundProjectLog "ERROR: Sync failed with exit code: $rcloneExitCode" "ERROR"
        if ($Verbose) {
            Write-Host $rcloneResult
        }
        throw "Sync failed with exit code: $rcloneExitCode"
    }

    Write-BackgroundProjectLog "Sync completed successfully" "SUCCESS"
}

function Get-UnityExecutablePath {
    param (
        [string]$ProjectPath
    )

    $unityExe = $null

    # Method 1: Check environment variable
    if ($env:UNITY_EDITOR_PATH -and (Test-Path $env:UNITY_EDITOR_PATH)) {
        return $env:UNITY_EDITOR_PATH
    }

    # Method 2: Try to find Unity version from project and match in Hub
    $projectRoot = if ($ProjectPath) { $ProjectPath } else { Get-BackgroundProjectRoot }
    $versionFile = Join-Path $projectRoot "ProjectSettings\ProjectVersion.txt"
    $unityVersion = $null

    if (Test-Path $versionFile) {
        try {
            $versionContent = Get-Content $versionFile -ErrorAction SilentlyContinue
            $match = $versionContent | Select-String "m_EditorVersion:\s*(.+)"
            if ($match) {
                $unityVersion = $match.Matches.Groups[1].Value.Trim()
            }
        } catch {
            Write-BackgroundProjectLog "WARNING: Could not read Unity version from project" "WARN"
        }
    }

    # Method 3: Try registry lookup using project version (Windows)
    if ($unityVersion -and $IsWindows -ne $false) {
        try {
            $regPath = "HKLM:\SOFTWARE\Unity Technologies\Installer\$unityVersion"
            $unityLocation = (Get-ItemProperty -Path $regPath -Name "Location x64" -ErrorAction SilentlyContinue).'Location x64'

            if ($unityLocation) {
                $candidatePath = Join-Path $unityLocation "Editor\Unity.exe"
                if (Test-Path $candidatePath) {
                    $unityExe = $candidatePath
                    Write-BackgroundProjectLog "Found Unity $unityVersion from registry" "INFO"
                }
            }
        } catch {
            # Registry lookup failed, continue to other methods
        }
    }

    # Method 4: Try Unity Hub locations
    if (-not $unityExe) {
        $hubPaths = @()

        if ($IsWindows -ne $false) {
            $hubPaths += @(
                "C:\Program Files\Unity\Hub\Editor",
                "$env:ProgramFiles\Unity\Hub\Editor"
            )
        }
        if ($IsMacOS) {
            $hubPaths += "/Applications/Unity/Hub/Editor"
        }
        if ($IsLinux) {
            $hubPaths += @(
                "$env:HOME/Unity/Hub/Editor",
                "/opt/Unity/Hub/Editor"
            )
        }

        foreach ($hubPath in $hubPaths) {
            if (-not (Test-Path $hubPath)) { continue }

            # If we have a specific version, look for it
            if ($unityVersion) {
                $versionPath = Join-Path $hubPath $unityVersion
                if ($IsWindows -ne $false) {
                    $candidatePath = Join-Path $versionPath "Editor\Unity.exe"
                } else {
                    $candidatePath = Join-Path $versionPath "Unity.app/Contents/MacOS/Unity"
                }

                if (Test-Path $candidatePath) {
                    $unityExe = $candidatePath
                    Write-BackgroundProjectLog "Found Unity $unityVersion in Hub" "INFO"
                    break
                }
            }

            # Fallback: use most recent version
            $versions = Get-ChildItem $hubPath -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
            foreach ($ver in $versions) {
                if ($IsWindows -ne $false) {
                    $candidatePath = Join-Path $ver.FullName "Editor\Unity.exe"
                } else {
                    $candidatePath = Join-Path $ver.FullName "Unity.app/Contents/MacOS/Unity"
                }

                if (Test-Path $candidatePath) {
                    $unityExe = $candidatePath
                    Write-BackgroundProjectLog "Found Unity $($ver.Name) in Hub (fallback)" "WARN"
                    break
                }
            }

            if ($unityExe) { break }
        }
    }

    if (-not $unityExe -or -not (Test-Path $unityExe)) {
        Write-BackgroundProjectLog "ERROR: Unity executable not found" "ERROR"
        Write-BackgroundProjectLog "  Project version: $unityVersion" "ERROR"
        Write-BackgroundProjectLog "  Tip: Set UNITY_EDITOR_PATH environment variable" "ERROR"
        throw "Unity executable not found"
    }

    return $unityExe
}

# ============================================================================
# Lock File System
# ============================================================================
# Prevents multiple operations from running simultaneously on the background worker.
# Lock file is stored in the background worker directory.

function Get-BackgroundProjectLockPath {
    param (
        [string]$DestinationPath
    )
    return Join-Path $DestinationPath ".background-worker.lock"
}

function Get-BackgroundProjectLockInfo {
    <#
    .SYNOPSIS
        Gets information about an existing lock file.
    .DESCRIPTION
        Reads and parses the lock file to get information about the locking process.
    .RETURNS
        Hashtable with lock info, or $null if no lock exists or lock is invalid.
    #>
    param (
        [string]$LockPath
    )

    if (-not (Test-Path $LockPath)) {
        return $null
    }

    try {
        $content = Get-Content $LockPath -Raw -ErrorAction Stop
        $lockInfo = $content | ConvertFrom-Json -ErrorAction Stop

        return @{
            PID = $lockInfo.PID
            Operation = $lockInfo.Operation
            StartTime = [DateTime]::Parse($lockInfo.StartTime)
            MachineName = $lockInfo.MachineName
            ScriptPath = $lockInfo.ScriptPath
        }
    } catch {
        Write-BackgroundProjectLog "WARNING: Could not parse lock file: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Test-BackgroundProjectLockStale {
    <#
    .SYNOPSIS
        Checks if a lock is stale (locking process no longer exists).
    .DESCRIPTION
        A lock is considered stale if:
        - The PID no longer exists on this machine
        - The lock is from a different machine (we can't verify, so assume not stale)
        - The lock is older than the stale timeout (default: 2 hours)
    #>
    param (
        [hashtable]$LockInfo,
        [int]$StaleTimeoutMinutes = 120
    )

    if (-not $LockInfo) {
        return $true
    }

    # Check if from a different machine - we can't verify if process exists
    if ($LockInfo.MachineName -ne $env:COMPUTERNAME) {
        # Check timeout for remote locks
        $elapsed = (Get-Date) - $LockInfo.StartTime
        if ($elapsed.TotalMinutes -gt $StaleTimeoutMinutes) {
            Write-BackgroundProjectLog "Lock from different machine ($($LockInfo.MachineName)) is older than $StaleTimeoutMinutes minutes - considering stale" "WARN"
            return $true
        }
        return $false
    }

    # Check if the process still exists
    try {
        $process = Get-Process -Id $LockInfo.PID -ErrorAction SilentlyContinue
        if (-not $process) {
            Write-BackgroundProjectLog "Lock process (PID: $($LockInfo.PID)) no longer exists - lock is stale" "WARN"
            return $true
        }
    } catch {
        # Process doesn't exist
        Write-BackgroundProjectLog "Lock process (PID: $($LockInfo.PID)) no longer exists - lock is stale" "WARN"
        return $true
    }

    # Check timeout
    $elapsed = (Get-Date) - $LockInfo.StartTime
    if ($elapsed.TotalMinutes -gt $StaleTimeoutMinutes) {
        Write-BackgroundProjectLog "Lock is older than $StaleTimeoutMinutes minutes - considering stale" "WARN"
        return $true
    }

    return $false
}

function Test-BackgroundProjectLock {
    <#
    .SYNOPSIS
        Checks if the background project is currently locked.
    .DESCRIPTION
        Returns $true if locked by another process, $false if not locked or lock is stale.
    #>
    param (
        [string]$DestinationPath,
        [int]$StaleTimeoutMinutes = 120
    )

    $lockPath = Get-BackgroundProjectLockPath -DestinationPath $DestinationPath
    $lockInfo = Get-BackgroundProjectLockInfo -LockPath $lockPath

    if (-not $lockInfo) {
        return $false
    }

    # Check if it's our own lock (same PID)
    if ($lockInfo.PID -eq $PID -and $lockInfo.MachineName -eq $env:COMPUTERNAME) {
        return $false
    }

    # Check if lock is stale
    if (Test-BackgroundProjectLockStale -LockInfo $lockInfo -StaleTimeoutMinutes $StaleTimeoutMinutes) {
        # Remove stale lock
        Write-BackgroundProjectLog "Removing stale lock file" "WARN"
        Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    return $true
}

function New-BackgroundProjectLock {
    <#
    .SYNOPSIS
        Acquires a lock on the background project.
    .DESCRIPTION
        Creates a lock file with information about the locking process.
        Fails if another process holds the lock.
    .RETURNS
        $true if lock acquired, $false if already locked.
    #>
    param (
        [string]$DestinationPath,
        [string]$Operation,
        [int]$StaleTimeoutMinutes = 120
    )

    # Ensure destination directory exists
    if (-not (Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    $lockPath = Get-BackgroundProjectLockPath -DestinationPath $DestinationPath

    # Check for existing lock
    if (Test-BackgroundProjectLock -DestinationPath $DestinationPath -StaleTimeoutMinutes $StaleTimeoutMinutes) {
        $lockInfo = Get-BackgroundProjectLockInfo -LockPath $lockPath
        $elapsed = (Get-Date) - $lockInfo.StartTime
        $elapsedStr = "{0:hh\:mm\:ss}" -f $elapsed

        Write-BackgroundProjectLog "=== BACKGROUND WORKER LOCKED ===" "ERROR"
        Write-BackgroundProjectLog "Another operation is running on the background worker:" "ERROR"
        Write-BackgroundProjectLog "  Operation: $($lockInfo.Operation)" "ERROR"
        Write-BackgroundProjectLog "  PID: $($lockInfo.PID)" "ERROR"
        Write-BackgroundProjectLog "  Machine: $($lockInfo.MachineName)" "ERROR"
        Write-BackgroundProjectLog "  Started: $($lockInfo.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))" "ERROR"
        Write-BackgroundProjectLog "  Running for: $elapsedStr" "ERROR"
        Write-BackgroundProjectLog "" "ERROR"
        Write-BackgroundProjectLog "Wait for the other operation to complete, or:" "ERROR"
        Write-BackgroundProjectLog "  - Kill the process (PID: $($lockInfo.PID))" "ERROR"
        Write-BackgroundProjectLog "  - Delete the lock file: $lockPath" "ERROR"

        return $false
    }

    # Create lock file
    $lockData = @{
        PID = $PID
        Operation = $Operation
        StartTime = (Get-Date).ToString("o")
        MachineName = $env:COMPUTERNAME
        ScriptPath = $MyInvocation.ScriptName
    }

    try {
        $lockData | ConvertTo-Json | Set-Content $lockPath -Force -ErrorAction Stop
        Write-BackgroundProjectLog "Acquired lock for operation: $Operation (PID: $PID)" "INFO"
        return $true
    } catch {
        Write-BackgroundProjectLog "ERROR: Failed to create lock file: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Remove-BackgroundProjectLock {
    <#
    .SYNOPSIS
        Releases the lock on the background project.
    .DESCRIPTION
        Removes the lock file. Only removes if we own the lock (same PID).
    #>
    param (
        [string]$DestinationPath,
        [switch]$Force
    )

    $lockPath = Get-BackgroundProjectLockPath -DestinationPath $DestinationPath

    if (-not (Test-Path $lockPath)) {
        return
    }

    $lockInfo = Get-BackgroundProjectLockInfo -LockPath $lockPath

    # Only remove if we own the lock (or Force is specified)
    if (-not $Force -and $lockInfo -and ($lockInfo.PID -ne $PID -or $lockInfo.MachineName -ne $env:COMPUTERNAME)) {
        Write-BackgroundProjectLog "WARNING: Lock owned by different process (PID: $($lockInfo.PID)) - not removing" "WARN"
        return
    }

    try {
        Remove-Item $lockPath -Force -ErrorAction Stop
        Write-BackgroundProjectLog "Released lock" "INFO"
    } catch {
        Write-BackgroundProjectLog "WARNING: Failed to remove lock file: $($_.Exception.Message)" "WARN"
    }
}

function Invoke-WithBackgroundProjectLock {
    <#
    .SYNOPSIS
        Executes a script block while holding the background project lock.
    .DESCRIPTION
        Acquires the lock, executes the script block, then releases the lock.
        Ensures lock is released even if an error occurs.
    .EXAMPLE
        Invoke-WithBackgroundProjectLock -DestinationPath $dest -Operation "RunTests" -ScriptBlock {
            # Your code here
        }
    #>
    param (
        [string]$DestinationPath,
        [string]$Operation,
        [scriptblock]$ScriptBlock,
        [int]$StaleTimeoutMinutes = 120
    )

    $lockAcquired = $false

    try {
        # Acquire lock
        $lockAcquired = New-BackgroundProjectLock -DestinationPath $DestinationPath -Operation $Operation -StaleTimeoutMinutes $StaleTimeoutMinutes

        if (-not $lockAcquired) {
            throw "Failed to acquire lock on background worker"
        }

        # Execute the script block
        & $ScriptBlock
    } finally {
        # Always release lock if we acquired it
        if ($lockAcquired) {
            Remove-BackgroundProjectLock -DestinationPath $DestinationPath
        }
    }
}

# ============================================================================
# Log Copying
# ============================================================================
# Copies logs from the background project to the main workspace after operations.

function Copy-BackgroundProjectLogs {
    <#
    .SYNOPSIS
        Copies logs and test artifacts from the background project to the main workspace.
    .DESCRIPTION
        After background project operations complete, copies the UnityFileLogger
        folder contents to a BackgroundWorker subfolder in the main workspace's
        UnityFileLogger folder. Also copies test results and other artifacts.
    .PARAMETER ProjectRoot
        The main workspace project root.
    .PARAMETER BackgroundProjectPath
        The background worker project path.
    .PARAMETER OperationName
        Optional name for the operation (used in log messages).
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory=$true)]
        [string]$BackgroundProjectPath,

        [string]$OperationName = "BackgroundWorker"
    )

    $backgroundLogsPath = Join-Path $BackgroundProjectPath "UnityFileLogger"
    $mainLogsPath = Join-Path $ProjectRoot "UnityFileLogger"
    $destinationPath = Join-Path $mainLogsPath "BackgroundWorker"

    # Check if background project has logs
    if (-not (Test-Path $backgroundLogsPath)) {
        Write-BackgroundProjectLog "No logs found in background project: $backgroundLogsPath" "INFO"
        return
    }

    # Check if there are any log files
    $logFiles = Get-ChildItem $backgroundLogsPath -Filter "*.log" -Recurse -ErrorAction SilentlyContinue
    if (-not $logFiles -or $logFiles.Count -eq 0) {
        Write-BackgroundProjectLog "No log files found in background project logs folder" "INFO"
        return
    }

    Write-BackgroundProjectLog "Copying $($logFiles.Count) log files from background project..." "INFO"

    # Ensure main logs directory exists
    if (-not (Test-Path $mainLogsPath)) {
        New-Item -ItemType Directory -Path $mainLogsPath -Force | Out-Null
        Write-BackgroundProjectLog "Created main logs directory: $mainLogsPath" "INFO"
    }

    # Ensure BackgroundWorker subfolder exists
    if (-not (Test-Path $destinationPath)) {
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
    }

    try {
        # Copy all contents preserving structure
        # Use robocopy for efficiency if available, otherwise fall back to Copy-Item
        $robocopy = Get-Command robocopy -ErrorAction SilentlyContinue
        if ($robocopy) {
            $robocopyArgs = @(
                "`"$backgroundLogsPath`"",
                "`"$destinationPath`"",
                "/E",           # Copy subdirectories including empty ones
                "/NP",          # No progress
                "/NDL",         # No directory list
                "/NJH",         # No job header
                "/NJS",         # No job summary
                "/MT:4"         # Multi-threaded
            )

            $result = & robocopy $robocopyArgs 2>&1
            # Robocopy exit codes 0-7 are success
            if ($LASTEXITCODE -le 7) {
                Write-BackgroundProjectLog "Logs copied successfully to: $destinationPath" "SUCCESS"
            } else {
                Write-BackgroundProjectLog "WARNING: robocopy returned code $LASTEXITCODE" "WARN"
            }
        } else {
            # Fallback to Copy-Item
            Copy-Item -Path "$backgroundLogsPath\*" -Destination $destinationPath -Recurse -Force -ErrorAction Stop
            Write-BackgroundProjectLog "Logs copied successfully to: $destinationPath" "SUCCESS"
        }

        # Log the copied files count
        $copiedFiles = Get-ChildItem $destinationPath -Filter "*.log" -Recurse -ErrorAction SilentlyContinue
        Write-BackgroundProjectLog "Copied $($copiedFiles.Count) log files to main workspace" "INFO"

    } catch {
        Write-BackgroundProjectLog "WARNING: Failed to copy logs: $($_.Exception.Message)" "WARN"
        # Don't throw - log copying failure shouldn't fail the whole operation
    }

    # Copy additional test artifacts
    Copy-BackgroundProjectTestArtifacts -ProjectRoot $ProjectRoot -BackgroundProjectPath $BackgroundProjectPath -DestinationPath $destinationPath
}

function Copy-BackgroundProjectTestArtifacts {
    <#
    .SYNOPSIS
        Copies test artifacts (TestResults.xml, etc.) from the background project.
    .DESCRIPTION
        Copies test result files and other artifacts that Unity generates during test runs.
        These are typically stored in AppData or the project folder.
    .PARAMETER ProjectRoot
        The main workspace project root.
    .PARAMETER BackgroundProjectPath
        The background worker project path.
    .PARAMETER DestinationPath
        The destination path for artifacts (typically UnityFileLogger/BackgroundWorker).
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory=$true)]
        [string]$BackgroundProjectPath,

        [Parameter(Mandatory=$true)]
        [string]$DestinationPath
    )

    # Create TestArtifacts subfolder
    $artifactsDestination = Join-Path $DestinationPath "TestArtifacts"
    if (-not (Test-Path $artifactsDestination)) {
        New-Item -ItemType Directory -Path $artifactsDestination -Force | Out-Null
    }

    $artifactsCopied = 0

    # Known locations for TestResults.xml
    $testResultsLocations = @(
        # Unity's default location in AppData
        "$env:LOCALAPPDATA\Unity\Editor\TestResults.xml",
        "$env:APPDATA\Unity\Editor\TestResults.xml",
        # Project-specific locations (common Unity patterns)
        (Join-Path $BackgroundProjectPath "TestResults.xml"),
        (Join-Path $BackgroundProjectPath "Logs\TestResults.xml")
    )

    # Add custom artifact path from environment variable if set.
    # Set BACKGROUND_PROJECT_ARTIFACT_SUBPATH to the company/product subfolder
    # under LocalLow (e.g., "My Company\My Game") to search for test results there.
    if ($env:BACKGROUND_PROJECT_ARTIFACT_SUBPATH) {
        $testResultsLocations += "$env:LOCALAPPDATA\..\LocalLow\$($env:BACKGROUND_PROJECT_ARTIFACT_SUBPATH)\TestResults.xml"
    }

    # Also load additional artifact paths from config file if present
    $configPath = Join-Path $PSScriptRoot "background-project-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($config.artifactSubpath) {
                $testResultsLocations += "$env:LOCALAPPDATA\..\LocalLow\$($config.artifactSubpath)\TestResults.xml"
            }
        } catch {
            Write-BackgroundProjectLog "WARNING: Could not parse config file: $($_.Exception.Message)" "WARN"
        }
    }

    foreach ($location in $testResultsLocations) {
        if (Test-Path $location) {
            try {
                $fileName = Split-Path $location -Leaf
                $destFile = Join-Path $artifactsDestination $fileName

                # Add timestamp to avoid overwriting if multiple locations exist
                if (Test-Path $destFile) {
                    $timestamp = Get-Date -Format "HHmmss"
                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                    $extension = [System.IO.Path]::GetExtension($fileName)
                    $destFile = Join-Path $artifactsDestination "$baseName`_$timestamp$extension"
                }

                Copy-Item -Path $location -Destination $destFile -Force -ErrorAction Stop
                Write-BackgroundProjectLog "Copied test artifact: $location -> $destFile" "INFO"
                $artifactsCopied++
            } catch {
                Write-BackgroundProjectLog "WARNING: Failed to copy test artifact from $location`: $($_.Exception.Message)" "WARN"
            }
        }
    }

    # Copy any .xml files from the background project's Logs folder (test reports, etc.)
    $logsFolder = Join-Path $BackgroundProjectPath "Logs"
    if (Test-Path $logsFolder) {
        $xmlFiles = Get-ChildItem $logsFolder -Filter "*.xml" -ErrorAction SilentlyContinue
        foreach ($xmlFile in $xmlFiles) {
            try {
                $destFile = Join-Path $artifactsDestination $xmlFile.Name
                Copy-Item -Path $xmlFile.FullName -Destination $destFile -Force -ErrorAction Stop
                Write-BackgroundProjectLog "Copied test artifact: $($xmlFile.FullName)" "INFO"
                $artifactsCopied++
            } catch {
                Write-BackgroundProjectLog "WARNING: Failed to copy $($xmlFile.Name): $($_.Exception.Message)" "WARN"
            }
        }
    }

    # Copy Unity Editor.log for additional debugging context
    $editorLogLocations = @(
        "$env:LOCALAPPDATA\Unity\Editor\Editor.log",
        "$env:APPDATA\Unity\Editor\Editor.log"
    )

    foreach ($editorLog in $editorLogLocations) {
        if (Test-Path $editorLog) {
            try {
                $destFile = Join-Path $artifactsDestination "Editor.log"
                Copy-Item -Path $editorLog -Destination $destFile -Force -ErrorAction Stop
                Write-BackgroundProjectLog "Copied Unity Editor.log for debugging" "INFO"
                $artifactsCopied++
                break  # Only copy one Editor.log
            } catch {
                Write-BackgroundProjectLog "WARNING: Failed to copy Editor.log: $($_.Exception.Message)" "WARN"
            }
        }
    }

    if ($artifactsCopied -gt 0) {
        Write-BackgroundProjectLog "Copied $artifactsCopied test artifact(s) to: $artifactsDestination" "SUCCESS"
    } else {
        Write-BackgroundProjectLog "No test artifacts found to copy" "INFO"
    }
}

# ============================================================================
# Unity Process Management
# ============================================================================

function Invoke-UnityProcess {
    param (
        [string]$UnityExe,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 600,
        [switch]$ShowOutput
    )

    $stdoutFile = Join-Path $env:TEMP "unity_stdout_$PID.txt"
    $stderrFile = Join-Path $env:TEMP "unity_stderr_$PID.txt"

    # Clean up any existing temp files
    Remove-Item $stdoutFile -ErrorAction SilentlyContinue
    Remove-Item $stderrFile -ErrorAction SilentlyContinue

    $proc = $null
    [int]$exitCode = 1
    $stdout = ""
    $stderr = ""

    try {
        # Use System.Diagnostics.Process directly for reliable exit code capture.
        # Start-Process with -RedirectStandardOutput can lose the ExitCode in Windows PowerShell.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $UnityExe
        $psi.Arguments = $Arguments -join ' '
        $psi.WorkingDirectory = $WorkingDirectory
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)

        if (-not $proc) {
            throw "Failed to start Unity process"
        }

        # Read stdout/stderr to files asynchronously to avoid deadlocks.
        # We kick off background jobs to drain the streams.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        # Wait for process with timeout
        $completed = $proc.WaitForExit($TimeoutSeconds * 1000)

        if (-not $completed) {
            Write-BackgroundProjectLog "ERROR: Unity process timed out after $TimeoutSeconds seconds" "ERROR"
            $proc.Kill()
            $proc.WaitForExit()
            $exitCode = -1
        } else {
            # Parameterless WaitForExit ensures async stream readers are flushed
            $proc.WaitForExit()
            $exitCode = [int]$proc.ExitCode
        }

        # Wait for async reads to complete
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        # Save to files for potential debugging
        if ($stdout) { [System.IO.File]::WriteAllText($stdoutFile, $stdout) }
        if ($stderr) { [System.IO.File]::WriteAllText($stderrFile, $stderr) }

    } catch {
        Write-BackgroundProjectLog "ERROR: Exception during Unity process: $($_.Exception.Message)" "ERROR"
        if ($proc -and -not $proc.HasExited) {
            $proc.Kill()
        }
        throw
    } finally {
        if ($proc) { $proc.Dispose() }

        # Clean up temp files
        Remove-Item $stdoutFile -ErrorAction SilentlyContinue
        Remove-Item $stderrFile -ErrorAction SilentlyContinue
    }

    if ($ShowOutput -and $stdout) {
        Write-Host $stdout
    }

    Write-BackgroundProjectLog "Unity process exited with code: $exitCode" "INFO"

    return @{
        ExitCode = [int]$exitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}
