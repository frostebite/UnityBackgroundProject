<#
.SYNOPSIS
    Syncs project to background worker and runs a Unity build.

.DESCRIPTION
    Uses rclone to mirror the current project to a sibling directory,
    then runs Unity in batch mode to execute a player build.

    Integrates with the submodule profile system (config/frameworks.yml)
    when available, but works without it by accepting explicit parameters.

.PARAMETER BuildMethod
    The C# method to invoke via -executeMethod.
    If not specified, attempts to resolve from the Framework parameter
    using config/frameworks.yml. Falls back to BuildMethodEditor.BuildStandaloneWindows64.

.PARAMETER Framework
    Framework name or id (e.g., "Shell", "tow", "aoo").
    Used to resolve BuildMethod and environment variables from config/frameworks.yml.
    If config/frameworks.yml is not found, this is passed as the FRAMEWORK env var only.

.PARAMETER Steam
    Enable Steam integration in the build (adds STEAM scripting define).
    When used with Framework, selects the Steam build variant (e.g., ShellBuild instead of ShellBuildValidation).

.PARAMETER Suffix
    Suffix for the background project directory name. Default: "-BackgroundWorker"

.PARAMETER InstanceName
    Named instance from background-project-config.json. When omitted, uses the
    primary instance for backward compatibility.

.PARAMETER SkipSync
    Skip the sync step (use if project is already synced).

.PARAMETER SkipCompile
    Skip the compile check step before building.

.PARAMETER Verbose
    Show detailed Unity output during execution.

.PARAMETER TimeoutSeconds
    Maximum time in seconds to wait for Unity to complete. Default: 3600 (60 minutes).

.EXAMPLE
    ./SyncAndBuild.ps1
    # Syncs and builds using BuildMethodEditor.BuildStandaloneWindows64

.EXAMPLE
    ./SyncAndBuild.ps1 -Framework Shell
    # Resolves build method from frameworks.yml for Shell framework

.EXAMPLE
    ./SyncAndBuild.ps1 -Framework tow -Steam
    # Builds Turn of War with Steam integration

.EXAMPLE
    ./SyncAndBuild.ps1 -BuildMethod "BuildMethodTest.ShellBuildValidation" -SkipSync
    # Explicit build method, skip sync

.EXAMPLE
    ./SyncAndBuild.ps1 -Framework Shell -SkipSync -SkipCompile
    # Quick rebuild: skip sync and compile, just run the build
#>

param(
    [string]$BuildMethod = "",
    [string]$Framework = "",
    [switch]$Steam,
    [string]$Suffix = "-BackgroundWorker",
    [string]$InstanceName = "",
    [switch]$SkipSync,
    [switch]$SkipCompile,
    [switch]$Verbose,
    [int]$TimeoutSeconds = 3600
)

$ErrorActionPreference = "Stop"

# Dot-source common functions (same folder)
. "$PSScriptRoot/BackgroundProjectCommon.ps1"

# ============================================================================
# Framework Resolution
# ============================================================================

function Resolve-BuildMethod {
    param(
        [string]$Framework,
        [string]$ExplicitMethod,
        [bool]$UseSteam
    )

    # If an explicit method was provided, use it directly
    if ($ExplicitMethod) {
        return $ExplicitMethod
    }

    # If no framework specified, use the simple default
    if (-not $Framework) {
        if ($UseSteam) {
            return "BuildMethodEditor.BuildSteamWindows64"
        }
        return "BuildMethodEditor.BuildStandaloneWindows64"
    }

    # Try to load from ProfileLoader / frameworks.yml
    $profileLoaderPath = $null
    $projectRoot = Get-BackgroundProjectRoot -ScriptRoot $PSScriptRoot -WorkingDirectory $PWD.Path
    $candidatePath = Join-Path $projectRoot "automation/ProfileLoader.ps1"
    if (Test-Path $candidatePath) {
        $profileLoaderPath = $candidatePath
    }

    if ($profileLoaderPath) {
        try {
            . $profileLoaderPath
            $config = Get-FrameworkConfig -Framework $Framework
            $frameworkName = $config['id']

            Write-BackgroundProjectLog "Resolved framework '$Framework' -> id: $frameworkName" "INFO"

            # Load build method mappings. Consumers can provide their own mappings
            # via a background-project-config.json file in the ~ps/ folder.
            $methodMap = $null

            # Try loading from config file first
            $configPath = Join-Path $PSScriptRoot "background-project-config.json"
            if (Test-Path $configPath) {
                try {
                    $configData = Get-Content $configPath -Raw | ConvertFrom-Json -ErrorAction Stop
                    if ($configData.buildMethodMap) {
                        $methodMap = @{}
                        foreach ($prop in $configData.buildMethodMap.PSObject.Properties) {
                            $methodMap[$prop.Name] = @{
                                validation = $prop.Value.validation
                                steam = $prop.Value.steam
                            }
                        }
                        Write-BackgroundProjectLog "Loaded build method map from config file" "INFO"
                    }
                } catch {
                    Write-BackgroundProjectLog "WARNING: Could not parse build method config: $($_.Exception.Message)" "WARN"
                }
            }

            # If config file provided a method map, try to resolve from it
            if ($methodMap) {
                if ($methodMap.ContainsKey($frameworkName)) {
                    $variant = if ($UseSteam) { "steam" } else { "validation" }
                    $resolvedMethod = $methodMap[$frameworkName][$variant]
                    Write-BackgroundProjectLog "Resolved build method: $resolvedMethod (variant: $variant)" "INFO"
                    return $resolvedMethod
                } else {
                    Write-BackgroundProjectLog "No build method mapping for framework id '$frameworkName' in config, using naming convention" "WARN"
                }
            } else {
                Write-BackgroundProjectLog "No background-project-config.json found, using naming convention fallback" "WARN"
            }

            # Default: use the framework name directly as the build method class name
            $variant = if ($UseSteam) { "Build" } else { "BuildValidation" }
            $resolvedMethod = "BuildMethod.$($frameworkName)$($variant)"
            Write-BackgroundProjectLog "Resolved build method via naming convention: $resolvedMethod" "INFO"
            return $resolvedMethod
        } catch {
            Write-BackgroundProjectLog "Could not load ProfileLoader: $($_.Exception.Message)" "WARN"
            Write-BackgroundProjectLog "Falling back to default build method" "WARN"
        }
    } else {
        Write-BackgroundProjectLog "ProfileLoader not found at: $candidatePath" "WARN"
        Write-BackgroundProjectLog "Falling back to default build method (profile system not available)" "WARN"
    }

    # Fallback: simple BuildMethodEditor methods
    if ($UseSteam) {
        return "BuildMethodEditor.BuildSteamWindows64"
    }
    return "BuildMethodEditor.BuildStandaloneWindows64"
}

function Resolve-FrameworkEnvVars {
    param(
        [string]$Framework,
        [string]$ProjectRoot
    )

    $envVars = @{}

    if (-not $Framework) {
        return $envVars
    }

    $profileLoaderPath = Join-Path $ProjectRoot "automation/ProfileLoader.ps1"
    if (-not (Test-Path $profileLoaderPath)) {
        # No profile system -- just set FRAMEWORK
        $envVars["FRAMEWORK"] = $Framework
        return $envVars
    }

    try {
        . $profileLoaderPath
        $config = Get-FrameworkConfig -Framework $Framework

        $envVars["FRAMEWORK"] = $Framework
        $envVars["PREFIX"] = $config['prefix']

        if ($config.ContainsKey('steam') -and $config['steam']) {
            $envVars["STEAM_APP_ID"] = $config['steam']['app_id']
        }

        if ($config.ContainsKey('id')) {
            # Resolve primary submodule from profile if possible
            $profileBasePath = Join-Path $ProjectRoot "config/submodule-profiles/$($config['id'])"
            if (Test-Path $profileBasePath) {
                $profiles = Get-ChildItem $profileBasePath -Directory -ErrorAction SilentlyContinue
                if ($profiles.Count -gt 0) {
                    # Use first available profile
                    $profileYml = Join-Path $profiles[0].FullName "profile.yml"
                    if (Test-Path $profileYml) {
                        $content = Get-Content $profileYml -Raw
                        if ($content -match 'primary_submodule:\s*(.+)') {
                            $envVars["PRIMARY_SUBMODULE"] = $matches[1].Trim()
                        }
                    }
                }
            }
        }
    } catch {
        Write-BackgroundProjectLog "Could not resolve framework env vars: $($_.Exception.Message)" "WARN"
        $envVars["FRAMEWORK"] = $Framework
    }

    return $envVars
}

# ============================================================================
# Main Script
# ============================================================================

# Determine paths first (needed for lock)
$projectRoot = Get-BackgroundProjectRoot -ScriptRoot $PSScriptRoot -WorkingDirectory $PWD.Path
$destinationPath = Get-BackgroundProjectPath -ProjectRoot $projectRoot -Suffix $Suffix -InstanceName $InstanceName

# Resolve build method
$resolvedBuildMethod = Resolve-BuildMethod -Framework $Framework -ExplicitMethod $BuildMethod -UseSteam $Steam.IsPresent

# Acquire lock before any operations
$operationDesc = "SyncAndBuild ($resolvedBuildMethod)"
if (-not (New-BackgroundProjectLock -DestinationPath $destinationPath -Operation $operationDesc)) {
    exit 1
}

try {
    Write-BackgroundProjectLog "=== Sync and Build ===" "INFO"
    Write-BackgroundProjectLog "Source: $projectRoot" "INFO"
    Write-BackgroundProjectLog "Background: $destinationPath" "INFO"
    Write-BackgroundProjectLog "Build Method: $resolvedBuildMethod" "INFO"
    if ($Framework) {
        Write-BackgroundProjectLog "Framework: $Framework" "INFO"
    }
    Write-BackgroundProjectLog "Steam: $($Steam.IsPresent)" "INFO"
    Write-BackgroundProjectLog "Timeout: $TimeoutSeconds seconds" "INFO"
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
        $compileResult = Invoke-UnityProcess -UnityExe $unityExe -Arguments $compileArgs -WorkingDirectory $destinationPath -TimeoutSeconds 1800 -ShowOutput:$Verbose

        if ($compileResult.ExitCode -ne 0) {
            Write-BackgroundProjectLog "=== COMPILE CHECK FAILED ===" "ERROR"
            Write-BackgroundProjectLog "Exit code: $($compileResult.ExitCode)" "ERROR"

            if ($compileResult.Stdout) {
                $lines = $compileResult.Stdout -split "`n"
                $displayLines = if ($lines.Count -gt 100) { $lines[-100..-1] } else { $lines }
                Write-Host ($displayLines -join "`n") -ForegroundColor Red
            }

            $script:exitCode = $compileResult.ExitCode
            exit $script:exitCode
        }

        Write-BackgroundProjectLog "Compile check passed" "SUCCESS"
        Write-BackgroundProjectLog ""
    } else {
        Write-BackgroundProjectLog "Step 2: Skipping compile check (SkipCompile flag set)" "INFO"
        Write-BackgroundProjectLog ""
    }

    # Step 3: Run build
    Write-BackgroundProjectLog "Step 3: Running build..." "INFO"

    # Resolve environment variables for the framework
    $frameworkEnvVars = Resolve-FrameworkEnvVars -Framework $Framework -ProjectRoot $projectRoot

    # Set environment variables for the Unity process
    foreach ($key in $frameworkEnvVars.Keys) {
        $value = $frameworkEnvVars[$key]
        [System.Environment]::SetEnvironmentVariable($key, $value, "Process")
        Write-BackgroundProjectLog "  env: $key=$value" "INFO"
    }

    # Set a local build run number (use timestamp-based if not in CI)
    if (-not $env:GITHUB_RUN_NUMBER) {
        $localRunNumber = Get-Date -Format "yyyyMMdd-HHmm"
        [System.Environment]::SetEnvironmentVariable("GITHUB_RUN_NUMBER", $localRunNumber, "Process")
        Write-BackgroundProjectLog "  env: GITHUB_RUN_NUMBER=$localRunNumber (local)" "INFO"
    }

    $buildArgs = @(
        "-batchmode",
        "-nographics",
        "-quit",
        "-projectPath",
        "`"$destinationPath`"",
        "-executeMethod",
        $resolvedBuildMethod,
        "-logFile",
        "-"
    )

    Write-BackgroundProjectLog "Running: $unityExe $($buildArgs -join ' ')" "INFO"
    Write-BackgroundProjectLog ""

    $result = Invoke-UnityProcess -UnityExe $unityExe -Arguments $buildArgs -WorkingDirectory $destinationPath -TimeoutSeconds $TimeoutSeconds -ShowOutput:$Verbose

    Write-BackgroundProjectLog ""

    if ($result.ExitCode -eq 0) {
        Write-BackgroundProjectLog "=== BUILD SUCCEEDED ===" "SUCCESS"

        # Try to find and report the build output
        $buildsDir = Join-Path $destinationPath "Builds"
        if (Test-Path $buildsDir) {
            $exeFiles = Get-ChildItem $buildsDir -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3
            if ($exeFiles) {
                Write-BackgroundProjectLog "Build output:" "INFO"
                foreach ($exe in $exeFiles) {
                    $size = [math]::Round($exe.Length / 1MB, 1)
                    Write-BackgroundProjectLog "  $($exe.FullName) ($size MB)" "INFO"
                }
            }
        }

        $script:exitCode = 0
    } else {
        Write-BackgroundProjectLog "=== BUILD FAILED ===" "ERROR"
        Write-BackgroundProjectLog "Exit code: $($result.ExitCode)" "ERROR"

        if ($result.Stdout) {
            # Show last 150 lines of output for build debugging
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
    Copy-BackgroundProjectLogs -ProjectRoot $projectRoot -BackgroundProjectPath $destinationPath -OperationName "SyncAndBuild" -InstanceName $InstanceName

    # Always release the lock
    Remove-BackgroundProjectLock -DestinationPath $destinationPath
}

exit $script:exitCode
