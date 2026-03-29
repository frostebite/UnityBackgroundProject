# UnityBackgroundProject

A Unity Editor plugin and PowerShell toolkit that mirrors your project to a sibling directory and runs builds, compile checks, and tests in the background without interrupting the open editor session.

## Overview

UnityBackgroundProject creates a synchronized copy of your Unity project in a sibling directory (the "background worker") and drives Unity batch-mode operations against that copy. The main editor instance continues running normally while the background worker compiles, builds, or runs tests in a separate Unity process. Operations are fully async from the editor side and protected by a file-based lock to prevent concurrent execution.

## Features

- **Project synchronization** — mirrors source to the background worker using rclone (cross-platform) or robocopy (Windows fallback); only changed files are transferred
- **Compile validation** — runs Unity in batch mode against the background copy to verify compilation without touching the open editor
- **Test execution** — runs EditMode or PlayMode tests in isolation; captures `TestResults.xml` and Unity Editor logs and copies them back to the main workspace
- **Background builds** — invokes a configurable C# build method via `-executeMethod`; integrates with the project's submodule profile system to resolve framework-specific build methods automatically
- **Lock file system** — prevents multiple operations from running simultaneously; detects and clears stale locks from dead processes
- **Toolbar integration** — optional status indicator and quick-action menu via [EditorToolbar](https://github.com/frostebite/EditorToolbar); auto-detected at domain reload with no manual setup
- **Git hook integration** — `CompileCheck.ps1` and `SyncAndRunTests.ps1` are designed for use in pre-commit and pre-push hooks
- **Log collection** — after each operation, logs and test artifacts are copied from the background worker back to `UnityFileLogger/BackgroundWorker/` in the main workspace

## Installation

**Unity Package Manager (recommended)**

```json
{
  "dependencies": {
    "com.frostebite.unitybackgroundproject": "https://github.com/frostebite/UnityBackgroundProject.git"
  }
}
```

**Git submodule**

```sh
git submodule add https://github.com/frostebite/UnityBackgroundProject.git Assets/_Game/Submodules/UnityBackgroundProject
```

## Requirements

- Unity 2021.3 or later
- PowerShell 5.1 or later (for the `~ps/` scripts)
- [rclone](https://rclone.org/install/) (recommended) or robocopy (Windows built-in) for project synchronization
- [EditorToolbar](https://github.com/frostebite/EditorToolbar) (optional) for toolbar integration

## Quick Start

### From the Unity Editor

1. Open **Edit > Preferences > Unity Background Project** and enable the feature.
2. Set a project suffix if needed (default: `-BackgroundWorker`).
3. Open **Window > Background Project > Status** or use the toolbar section to sync and run operations.

### From PowerShell

The `~ps/` folder contains standalone scripts that work from git hooks, CI pipelines, or any shell session. Each script auto-detects the Unity project root by walking up from the script location or the working directory.

**Sync project to background worker:**

```powershell
./SyncProject.ps1
```

**Sync a named instance from config:**

```powershell
./SyncProject.ps1 -InstanceName "ci-runner"
```

**Sync and check compilation:**

```powershell
./SyncAndCompileCheck.ps1
```

**Sync and run tests:**

```powershell
./SyncAndRunTests.ps1
```

**Sync and build:**

```powershell
# Use explicit build method
./SyncAndBuild.ps1 -BuildMethod "BuildMethodEditor.BuildStandaloneWindows64"

# Or resolve build method from framework id (requires config/frameworks.yml in the project)
./SyncAndBuild.ps1 -Framework tow -Steam
```

**Initialize multiple configured instances and install their GitHub runners:**

```powershell
./InitializeBackgroundProjects.ps1 -All -ConfigureGitHubRunners
```

**Git pre-commit hook:**

```sh
#!/bin/sh
pwsh -File ./Assets/_Game/Submodules/UnityBackgroundProject/~ps/SyncAndCompileCheck.ps1
```

## Configuration

### Editor Preferences

Open **Edit > Preferences > Unity Background Project**:

| Setting | Default | Description |
|---------|---------|-------------|
| Enabled | false | Master toggle for all background project features |
| Project Suffix | `-BackgroundWorker` | Suffix appended to the project folder name to form the background worker path |
| Sync Tool | Auto | Preferred sync tool: Auto, Rclone, or Robocopy |
| Auto-sync on Pre-commit | true | Automatically sync before running commit hooks |

The background worker is always created as a sibling of the main project folder:

```
C:/Projects/
  MyGame/                   <- main project
  MyGame-BackgroundWorker/  <- background worker (created automatically)
```

### background-project-config.json

The PowerShell scripts support an optional config file at `~ps/background-project-config.json`. Copy `background-project-config.example.json` and customize:

```json
{
    "primaryInstance": "primary",
    "instances": [
        {
            "kind": "unity-worker",
            "displayName": "Primary",
            "name": "primary",
            "suffix": "-BackgroundWorker"
        },
        {
            "kind": "github-runner",
            "displayName": "CI Runner Workspace",
            "name": "ci-runner",
            "githubRunner": {
                "enabled": true,
                "repository": "frostebite/GameClient",
                "runnerName": "unity-background-ci",
                "runnerPath": "D:\\actions-runner-unity-background-ci",
                "workspacePath": "D:\\actions-runner-unity-background-ci\\_work\\GameClient\\GameClient",
                "labels": [ "unity", "dynamic", "background" ]
            }
        }
    ],
    "artifactSubpath": "My Company/My Game",
    "buildMethodMap": {
        "myframework": {
            "validation": "BuildMethodTest.MyFrameworkBuildValidation",
            "steam": "BuildMethodTest.MyFrameworkBuild"
        }
    }
}
```

| Key | Purpose |
|-----|---------|
| `primaryInstance` | Name of the instance treated as the legacy single background worker. Editor UI and scripts without `-InstanceName` use this instance. |
| `instances` | Named background project definitions. Each instance can set `suffix`, explicit `path`, and optional `githubRunner` settings. |
| `artifactSubpath` | Company and product subfolder under `AppData/LocalLow` where Unity writes `TestResults.xml`. Used to locate test artifacts after a test run. |
| `buildMethodMap` | Maps framework IDs to C# build methods. Each entry has a `validation` variant (non-Steam) and a `steam` variant. Used by `SyncAndBuild.ps1` when `-Framework` is specified. |

Without a config file the scripts use sensible defaults. The `artifactSubpath` can also be set via the `BACKGROUND_PROJECT_ARTIFACT_SUBPATH` environment variable.

### Multi-instance behavior

- Existing single-worker usage stays intact. If you do nothing, the package still resolves one primary background project using the legacy suffix approach.
- When `instances` are configured, every script accepts `-InstanceName` to target a specific background project.
- Instances can be regular `unity-worker` copies or `github-runner` workspaces.
- Logs for non-primary instances are copied to `UnityFileLogger/BackgroundWorker/<instance-name>/` so runs do not overwrite each other.
- The editor window and toolbar keep following the configured `primaryInstance`, which preserves the current user-facing workflow.
- The editor now lets you choose the active instance, initialize one or all instances, and initialize a runner-backed instance with service startup.

### GitHub runner integration

Each instance can optionally define a `githubRunner` block. `InitializeBackgroundProjects.ps1 -ConfigureGitHubRunners` converts those blocks into the existing WebPlatform runner configuration shape and then calls `WebPlatform/platform.scripts/InstallGitHubRunnerServices.ps1`.

For `github-runner` instances, the operational background project path is the runner workspace, not the runner installation directory. By default that is derived as `<runnerPath>\_work\<repo>\<repo>`, matching `GITHUB_WORKSPACE` on self-hosted runners. You can override it explicitly with `githubRunner.workspacePath`.

Supported `githubRunner` keys:

| Key | Purpose |
|-----|---------|
| `enabled` | Enables runner provisioning for that instance. |
| `repository` / `repoName` | GitHub repository in `owner/repo` format. |
| `runnerName` | Runner registration name. Defaults to `background-<instance-name>`. |
| `runnerPath` | Installation path for the GitHub runner files. Defaults to a sibling `actions-runner-<runnerName>` directory. |
| `workspacePath` | Optional explicit checkout workspace for the runner-backed background project. |
| `labels` / `labelsCommaList` | Runner labels to register with GitHub. |

Runner provisioning requires the same prerequisites as the existing WebPlatform runner installer, including `PAT_GITHUB`, `nssm`, and the permissions needed to create or update Windows services.

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `UNITY_PROJECT_ROOT` | Override auto-detected project root path |
| `BACKGROUND_PROJECT_PATH` | Override background worker path entirely |
| `UNITY_EDITOR_PATH` | Override Unity executable path |
| `BACKGROUND_PROJECT_ARTIFACT_SUBPATH` | Override artifact subfolder under `AppData/LocalLow` |

## C# API

`BackgroundProjectService` is the core service for editor-driven operations. Access it via `BackgroundProjectService.Instance`:

```csharp
var service = BackgroundProjectService.Instance;

// Sync
var syncResult = await service.SyncAsync();
if (syncResult.Success)
    Debug.Log($"Synced in {syncResult.Duration.TotalSeconds:F1}s");

// Compile check
var compileResult = await service.CompileCheckAsync();
if (!compileResult.Success)
    Debug.LogError($"Compile failed: {compileResult.Error}");

// Run tests
var testResult = await service.RunTestsAsync("EditMode", testCategory: "Trusted");

// Open the background project in a second editor instance
service.OpenBackgroundProject();
```

Subscribe to status events for UI updates:

```csharp
BackgroundProjectService.Instance.OnStatusChanged += status =>
    Debug.Log($"[BackgroundProject] {status}");

BackgroundProjectService.Instance.OnOperationCompleted += result =>
    Debug.Log($"[BackgroundProject] completed — success: {result.Success}, duration: {result.Duration.TotalSeconds:F1}s");
```

## Operation Timeouts

| Operation | Timeout |
|-----------|---------|
| Sync | 5 minutes |
| Compile check | 10 minutes |
| Test execution | 30 minutes |
| Build | 60 minutes |

## Excluded Paths

The following are excluded from sync automatically:

**Folders:** `Library`, `Temp`, `Logs`, `obj`, `Obj`, `Builds`, `Build`, `UserSettings`, `MemoryCaptures`, `bin`, `.vs`, `.vscode`, `.idea`, `.gradle`, `DerivedData`, `.git`

**Files:** `*.csproj`, `*.sln`, `*.csproj.user`, `.DS_Store`, `Thumbs.db`

## Troubleshooting

**"rclone not found"** — Install rclone from https://rclone.org/install/ and ensure it is on `PATH`, or set Sync Tool to Robocopy in Preferences.

**Compile check hangs** — Open `UnityFileLogger/BackgroundWorker/` in the main project and inspect the Unity Editor log. Asset import failures are the most common cause.

**Tests not running** — Ensure the background project exists and has been synced at least once. Verify that your test assembly references are correct.

**Lock file blocks operations** — If a previous operation was interrupted, a stale lock file may remain at `<background-worker>/.background-worker.lock`. The scripts detect stale locks automatically (process no longer exists or lock is older than 2 hours). Delete the lock file manually if needed.

**Permission errors on Windows** — Ensure the background worker directory is not read-only. On some machines, running the editor as administrator is required for the first sync.

## License

See LICENSE file.
