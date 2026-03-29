<#
.SYNOPSIS
    Initializes one or more background project instances.

.DESCRIPTION
    Creates configured background project directories and optionally syncs the
    current Unity project into each one. When instances include GitHub runner
    configuration, this script can also provision matching self-hosted runner
    services through the existing WebPlatform runner installer.

    If no config file exists, the script remains backward compatible and
    initializes the single primary background project using the legacy suffix.

.PARAMETER InstanceName
    One or more configured instance names from background-project-config.json.

.PARAMETER All
    Initialize all configured instances instead of only the primary instance.

.PARAMETER SkipSync
    Create/resolve instances without running a sync.

.PARAMETER ConfigureGitHubRunners
    Provision GitHub self-hosted runners for the selected instances whose
    githubRunner block is configured.

.PARAMETER RunnerAction
    Action passed through to InstallGitHubRunnerServices.ps1.

.PARAMETER Suffix
    Legacy fallback suffix when no instance config exists.

.PARAMETER Verbose
    Show detailed sync output.
#>

param(
    [string[]]$InstanceName = @(),
    [switch]$All,
    [switch]$SkipSync,
    [switch]$ConfigureGitHubRunners,
    [ValidateSet("install", "update", "hard-reinstall")]
    [string]$RunnerAction = "install",
    [string]$Suffix = "-BackgroundWorker",
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/BackgroundProjectCommon.ps1"

function Get-SelectedBackgroundProjectInstances {
    param (
        [string]$ProjectRoot,
        [string[]]$RequestedInstanceNames,
        [switch]$SelectAll,
        [string]$DefaultSuffix
    )

    if ($SelectAll) {
        return @(Get-BackgroundProjectInstances -ProjectRoot $ProjectRoot -DefaultSuffix $DefaultSuffix)
    }

    if ($RequestedInstanceNames -and $RequestedInstanceNames.Count -gt 0) {
        $resolved = @()
        foreach ($name in $RequestedInstanceNames) {
            $resolved += Resolve-BackgroundProjectInstance -ProjectRoot $ProjectRoot -InstanceName $name -DefaultSuffix $DefaultSuffix
        }

        return @($resolved | Sort-Object Name -Unique)
    }

    return @(Resolve-BackgroundProjectInstance -ProjectRoot $ProjectRoot -DefaultSuffix $DefaultSuffix)
}

function ConvertTo-GitHubRunnerConfig {
    param (
        [pscustomobject]$Instance,
        [string]$BackgroundProjectPath
    )

    $runner = $Instance.GitHubRunner
    if (-not $runner) {
        return $null
    }

    if ($runner.enabled -eq $false) {
        return $null
    }

    $repository = if ($runner.repository) { $runner.repository } elseif ($runner.repoName) { $runner.repoName } else { $null }
    if (-not $repository) {
        throw "Instance '$($Instance.Name)' has githubRunner config but no repository/repoName value."
    }

    $runnerName = if ($runner.runnerName) { $runner.runnerName } else { "background-$($Instance.Name)" }
    $runnerInstallPath = if ($runner.runnerPath) {
        $runner.runnerPath
    } else {
        Join-Path (Split-Path $BackgroundProjectPath -Parent) "actions-runner-$runnerName"
    }

    $labels = @()
    if ($runner.labels) {
        if ($runner.labels -is [System.Array]) {
            $labels += $runner.labels
        } else {
            $labels += "$($runner.labels)"
        }
    } elseif ($runner.labelsCommaList) {
        $labels += $runner.labelsCommaList -split ","
    } else {
        $labels += @("background", $Instance.Name)
    }

    $labels = $labels |
        ForEach-Object { "$_".Trim() } |
        Where-Object { $_ } |
        Select-Object -Unique

    return [PSCustomObject]@{
        Name = $runnerName
        Path = $runnerInstallPath
        LabelsCommaList = ($labels -join ",")
        RepoName = $repository
        MachineName = $env:COMPUTERNAME
    }
}

$projectRoot = Get-BackgroundProjectRoot -ScriptRoot $PSScriptRoot -WorkingDirectory $PWD.Path
$instances = Get-SelectedBackgroundProjectInstances -ProjectRoot $projectRoot -RequestedInstanceNames $InstanceName -SelectAll:$All -DefaultSuffix $Suffix

Write-BackgroundProjectLog "=== Initialize Background Projects ===" "INFO"
Write-BackgroundProjectLog "Project Root: $projectRoot" "INFO"
Write-BackgroundProjectLog "Selected Instances: $($instances.Name -join ', ')" "INFO"
Write-BackgroundProjectLog "Sync Enabled: $(-not $SkipSync)" "INFO"
Write-BackgroundProjectLog "Configure GitHub Runners: $($ConfigureGitHubRunners.IsPresent)" "INFO"
Write-BackgroundProjectLog "" "INFO"

$runnerConfigs = @()

foreach ($instance in $instances) {
    $destinationPath = Get-BackgroundProjectPath -ProjectRoot $projectRoot -Suffix $Suffix -InstanceName $instance.Name
    $runnerInstallPath = if ($instance.GitHubRunner -and $instance.GitHubRunner.runnerPath) { $instance.GitHubRunner.runnerPath } else { $null }

    Write-BackgroundProjectLog "Instance: $($instance.Name)" "INFO"
    Write-BackgroundProjectLog "  Kind: $($instance.Kind)" "INFO"
    Write-BackgroundProjectLog "  Path: $destinationPath" "INFO"
    Write-BackgroundProjectLog "  Primary: $($instance.IsPrimary)" "INFO"

    if ($runnerInstallPath) {
        Write-BackgroundProjectLog "  Runner Path: $runnerInstallPath" "INFO"
        if (-not (Test-Path $runnerInstallPath)) {
            New-Item -ItemType Directory -Path $runnerInstallPath -Force | Out-Null
            Write-BackgroundProjectLog "  Created runner directory" "SUCCESS"
        }
    }

    if (-not (Test-Path $destinationPath)) {
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        Write-BackgroundProjectLog "  Created directory" "SUCCESS"
    }

    if (-not $SkipSync) {
        Invoke-WithBackgroundProjectLock -DestinationPath $destinationPath -Operation "InitializeBackgroundProject ($($instance.Name))" -ScriptBlock {
            Sync-BackgroundProject -ProjectRoot $projectRoot -DestinationPath $destinationPath -Verbose:$Verbose
        }

        Copy-BackgroundProjectLogs -ProjectRoot $projectRoot -BackgroundProjectPath $destinationPath -OperationName "InitializeBackgroundProjects" -InstanceName $instance.Name
    }

    if ($ConfigureGitHubRunners) {
        $runnerConfig = ConvertTo-GitHubRunnerConfig -Instance $instance -BackgroundProjectPath $destinationPath
        if ($runnerConfig) {
            $runnerConfigs += $runnerConfig
            Write-BackgroundProjectLog "  Prepared GitHub runner config: $($runnerConfig.Name)" "INFO"
        }
    }

    Write-BackgroundProjectLog "" "INFO"
}

if ($ConfigureGitHubRunners) {
    if (-not $runnerConfigs -or $runnerConfigs.Count -eq 0) {
        Write-BackgroundProjectLog "No selected instances contain githubRunner configuration. Skipping runner provisioning." "WARN"
        exit 0
    }

    $runnerInstallerPath = Join-Path $projectRoot "WebPlatform\platform.scripts\InstallGitHubRunnerServices.ps1"
    if (-not (Test-Path $runnerInstallerPath)) {
        throw "GitHub runner installer not found at: $runnerInstallerPath"
    }

    $tempConfigPath = Join-Path $env:TEMP "background-project-runner-config-$PID.json"

    try {
        $runnerConfigs | ConvertTo-Json -Depth 10 | Set-Content -Path $tempConfigPath -Encoding UTF8
        Write-BackgroundProjectLog "Calling runner installer: $runnerInstallerPath" "INFO"
        Write-BackgroundProjectLog "Runner action: $RunnerAction" "INFO"
        Write-BackgroundProjectLog "Runner config: $tempConfigPath" "INFO"

        & $runnerInstallerPath -Action $RunnerAction -RunnerName "all" -ConfigPath $tempConfigPath
        if ($LASTEXITCODE -ne 0) {
            throw "GitHub runner installer exited with code $LASTEXITCODE"
        }
    } finally {
        Remove-Item -Path $tempConfigPath -Force -ErrorAction SilentlyContinue
    }
}
