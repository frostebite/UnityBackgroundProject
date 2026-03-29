using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using UnityEditor;
using UnityEngine;
using Debug = UnityEngine.Debug;

namespace UnityBackgroundProject
{
    /// <summary>
    /// Result of a background project operation.
    /// </summary>
    public class BackgroundProjectResult
    {
        public bool Success { get; set; }
        public int ExitCode { get; set; }
        public string InstanceName { get; set; }
        public string Output { get; set; }
        public string Error { get; set; }
        public TimeSpan Duration { get; set; }
    }

    /// <summary>
    /// Core service for background project operations.
    /// Handles sync, compile check, and test execution.
    /// </summary>
    public class BackgroundProjectService
    {
        private static BackgroundProjectService _instance;
        public static BackgroundProjectService Instance => _instance ??= new BackgroundProjectService();

        public event Action<string> OnStatusChanged;
        public event Action<BackgroundProjectResult> OnOperationCompleted;

        private static readonly string[] ExcludedFolders = new[]
        {
            "Library", "Temp", "Logs", "obj", "Obj", "Builds", "Build",
            "UserSettings", "MemoryCaptures", "bin", ".vs", ".vscode",
            ".idea", ".gradle", "DerivedData", ".git"
        };

        private static readonly string[] ExcludedFiles = new[]
        {
            "*.csproj", "*.sln", "*.csproj.user", ".DS_Store", "Thumbs.db"
        };

        private BackgroundProjectService() { }

        /// <summary>
        /// Syncs the current project to the background project location.
        /// </summary>
        public async Task<BackgroundProjectResult> SyncAsync(string instanceName = null, CancellationToken ct = default)
        {
            if (BackgroundProjectSettings.IsSyncing)
            {
                return new BackgroundProjectResult
                {
                    Success = false,
                    Error = "Sync already in progress"
                };
            }

            var resolvedInstance = string.IsNullOrWhiteSpace(instanceName) ? BackgroundProjectSettings.SelectedInstanceName : instanceName;
            var sourcePath = BackgroundProjectSettings.GetProjectRoot();
            var destPath = BackgroundProjectSettings.GetBackgroundProjectPath(resolvedInstance);

            if (string.IsNullOrEmpty(sourcePath) || string.IsNullOrEmpty(destPath))
            {
                return new BackgroundProjectResult
                {
                    Success = false,
                    Error = "Unable to determine project paths"
                };
            }

            BackgroundProjectSettings.IsSyncing = true;
            BackgroundProjectSettings.LastSyncError = null;
            OnStatusChanged?.Invoke("Syncing...");

            var stopwatch = Stopwatch.StartNew();
            BackgroundProjectResult result = new BackgroundProjectResult { Success = false, Error = "Unknown error", InstanceName = resolvedInstance };

            try
            {
                var syncTool = BackgroundProjectSettings.GetEffectiveSyncTool();

                result = syncTool switch
                {
                    SyncTool.Rclone => await SyncWithRcloneAsync(sourcePath, destPath, ct),
                    SyncTool.Robocopy => await SyncWithRobocopyAsync(sourcePath, destPath, ct),
                    _ => new BackgroundProjectResult { Success = false, Error = "No sync tool available" }
                };

                result.Duration = stopwatch.Elapsed;

                if (result.Success)
                {
                    BackgroundProjectSettings.LastSyncTime = DateTime.Now;
                    Debug.Log($"[BackgroundProject] Sync completed for '{resolvedInstance}' in {result.Duration.TotalSeconds:F1}s");
                }
                else
                {
                    BackgroundProjectSettings.LastSyncError = result.Error;
                    Debug.LogError($"[BackgroundProject] Sync failed for '{resolvedInstance}': {result.Error}");
                }
            }
            catch (Exception ex)
            {
                result = new BackgroundProjectResult
                {
                    Success = false,
                    InstanceName = resolvedInstance,
                    Error = ex.Message,
                    Duration = stopwatch.Elapsed
                };
                BackgroundProjectSettings.LastSyncError = ex.Message;
                Debug.LogError($"[BackgroundProject] Sync error for '{resolvedInstance}': {ex.Message}");
            }
            finally
            {
                BackgroundProjectSettings.IsSyncing = false;
                OnStatusChanged?.Invoke(result.Success ? "Sync complete" : "Sync failed");
                OnOperationCompleted?.Invoke(result);
            }

            return result;
        }

        private async Task<BackgroundProjectResult> SyncWithRcloneAsync(string source, string dest, CancellationToken ct)
        {
            // Ensure destination exists
            if (!Directory.Exists(dest))
            {
                Directory.CreateDirectory(dest);
            }

            var args = new List<string>
            {
                "sync",
                $"\"{source}\"",
                $"\"{dest}\"",
                "--progress"
            };

            // Add exclude patterns (anchored to root)
            foreach (var folder in ExcludedFolders)
            {
                args.Add("--exclude");
                args.Add($"/{folder}/**");
            }

            foreach (var file in ExcludedFiles)
            {
                args.Add("--exclude");
                args.Add(file);
            }

            return await RunProcessAsync("rclone", string.Join(" ", args), source, ct);
        }

        private async Task<BackgroundProjectResult> SyncWithRobocopyAsync(string source, string dest, CancellationToken ct)
        {
            // Ensure destination exists
            if (!Directory.Exists(dest))
            {
                Directory.CreateDirectory(dest);
            }

            var args = new List<string>
            {
                $"\"{source}\"",
                $"\"{dest}\"",
                "/E",       // Copy subdirectories including empty ones
                "/PURGE",   // Delete destination files that no longer exist in source
                "/XD"       // Exclude directories
            };

            // Add excluded folders
            args.AddRange(ExcludedFolders);

            args.Add("/XF"); // Exclude files
            foreach (var file in ExcludedFiles)
            {
                args.Add(file);
            }

            // Quiet options
            args.AddRange(new[] { "/NFL", "/NDL", "/NJH", "/NJS" });

            var result = await RunProcessAsync("robocopy", string.Join(" ", args), source, ct);

            // Robocopy returns 0-7 for success
            if (result.ExitCode <= 7)
            {
                result.Success = true;
            }

            return result;
        }

        /// <summary>
        /// Runs a compile check on the background project.
        /// </summary>
        public async Task<BackgroundProjectResult> CompileCheckAsync(string instanceName = null, CancellationToken ct = default)
        {
            if (BackgroundProjectSettings.IsCompiling)
            {
                return new BackgroundProjectResult
                {
                    Success = false,
                    Error = "Compile check already in progress"
                };
            }

            var resolvedInstance = string.IsNullOrWhiteSpace(instanceName) ? BackgroundProjectSettings.SelectedInstanceName : instanceName;
            var destPath = BackgroundProjectSettings.GetBackgroundProjectPath(resolvedInstance);
            if (!Directory.Exists(destPath))
            {
                return new BackgroundProjectResult
                {
                    Success = false,
                    Error = "Background project does not exist. Please sync first."
                };
            }

            var unityExe = EditorApplication.applicationPath;
            if (string.IsNullOrEmpty(unityExe) || !File.Exists(unityExe))
            {
                return new BackgroundProjectResult
                {
                    Success = false,
                    Error = "Unity executable not found"
                };
            }

            BackgroundProjectSettings.IsCompiling = true;
            OnStatusChanged?.Invoke("Compiling...");

            var stopwatch = Stopwatch.StartNew();
            BackgroundProjectResult result = new BackgroundProjectResult { Success = false, Error = "Unknown error", InstanceName = resolvedInstance };

            try
            {
                var args = new[]
                {
                    "-batchmode",
                    "-nographics",
                    "-quit",
                    "-projectPath",
                    $"\"{destPath}\"",
                    "-logFile",
                    "-"
                };

                result = await RunProcessAsync(unityExe, string.Join(" ", args), destPath, ct, timeoutMs: 600000);
                result.Duration = stopwatch.Elapsed;

                if (result.Success)
                {
                    Debug.Log($"[BackgroundProject] Compile check passed for '{resolvedInstance}' in {result.Duration.TotalSeconds:F1}s");
                }
                else
                {
                    Debug.LogError($"[BackgroundProject] Compile check failed for '{resolvedInstance}': {result.Error}");
                }
            }
            catch (Exception ex)
            {
                result = new BackgroundProjectResult
                {
                    Success = false,
                    InstanceName = resolvedInstance,
                    Error = ex.Message,
                    Duration = stopwatch.Elapsed
                };
                Debug.LogError($"[BackgroundProject] Compile check error for '{resolvedInstance}': {ex.Message}");
            }
            finally
            {
                BackgroundProjectSettings.IsCompiling = false;
                OnStatusChanged?.Invoke(result.Success ? "Compile passed" : "Compile failed");
                OnOperationCompleted?.Invoke(result);
            }

            return result;
        }

        /// <summary>
        /// Runs tests on the background project.
        /// </summary>
        public async Task<BackgroundProjectResult> RunTestsAsync(
            string testPlatform = "EditMode",
            string testCategory = null,
            string instanceName = null,
            CancellationToken ct = default)
        {
            if (BackgroundProjectSettings.IsRunningTests)
            {
                return new BackgroundProjectResult
                {
                    Success = false,
                    Error = "Tests already running"
                };
            }

            var resolvedInstance = string.IsNullOrWhiteSpace(instanceName) ? BackgroundProjectSettings.SelectedInstanceName : instanceName;
            var destPath = BackgroundProjectSettings.GetBackgroundProjectPath(resolvedInstance);
            if (!Directory.Exists(destPath))
            {
                return new BackgroundProjectResult
                {
                    Success = false,
                    Error = "Background project does not exist. Please sync first."
                };
            }

            var unityExe = EditorApplication.applicationPath;
            if (string.IsNullOrEmpty(unityExe) || !File.Exists(unityExe))
            {
                return new BackgroundProjectResult
                {
                    Success = false,
                    Error = "Unity executable not found"
                };
            }

            BackgroundProjectSettings.IsRunningTests = true;
            OnStatusChanged?.Invoke($"Running {testPlatform} tests...");

            var stopwatch = Stopwatch.StartNew();
            BackgroundProjectResult result = new BackgroundProjectResult { Success = false, Error = "Unknown error", InstanceName = resolvedInstance };

            try
            {
                var args = new List<string>
                {
                    "-batchmode",
                    "-nographics",
                    "-projectPath",
                    $"\"{destPath}\"",
                    "-runTests",
                    "-testPlatform",
                    testPlatform,
                    "-logFile",
                    "-"
                };

                if (!string.IsNullOrEmpty(testCategory))
                {
                    args.Add("-testFilter");
                    args.Add($"\"category={testCategory}\"");
                }

                result = await RunProcessAsync(unityExe, string.Join(" ", args), destPath, ct, timeoutMs: 1800000);
                result.Duration = stopwatch.Elapsed;

                if (result.Success)
                {
                    Debug.Log($"[BackgroundProject] Tests passed for '{resolvedInstance}' in {result.Duration.TotalSeconds:F1}s");
                }
                else
                {
                    Debug.LogError($"[BackgroundProject] Tests failed for '{resolvedInstance}': {result.Error}");
                }
            }
            catch (Exception ex)
            {
                result = new BackgroundProjectResult
                {
                    Success = false,
                    InstanceName = resolvedInstance,
                    Error = ex.Message,
                    Duration = stopwatch.Elapsed
                };
                Debug.LogError($"[BackgroundProject] Test run error for '{resolvedInstance}': {ex.Message}");
            }
            finally
            {
                BackgroundProjectSettings.IsRunningTests = false;
                OnStatusChanged?.Invoke(result.Success ? "Tests passed" : "Tests failed");
                OnOperationCompleted?.Invoke(result);
            }

            return result;
        }

        /// <summary>
        /// Opens the background project in a new Unity editor instance.
        /// </summary>
        public void OpenBackgroundProject(string instanceName = null)
        {
            var resolvedInstance = string.IsNullOrWhiteSpace(instanceName) ? BackgroundProjectSettings.SelectedInstanceName : instanceName;
            var destPath = BackgroundProjectSettings.GetBackgroundProjectPath(resolvedInstance);
            if (!Directory.Exists(destPath))
            {
                Debug.LogError($"[BackgroundProject] Background project '{resolvedInstance}' does not exist. Please initialize or sync first.");
                return;
            }

            var unityExe = EditorApplication.applicationPath;
            if (string.IsNullOrEmpty(unityExe) || !File.Exists(unityExe))
            {
                Debug.LogError("[BackgroundProject] Unity executable not found");
                return;
            }

            try
            {
                var startInfo = new ProcessStartInfo
                {
                    FileName = unityExe,
                    Arguments = $"-projectPath \"{destPath}\"",
                    UseShellExecute = false,
                    CreateNoWindow = false
                };

                Process.Start(startInfo);
                Debug.Log($"[BackgroundProject] Opening '{resolvedInstance}': {destPath}");
            }
            catch (Exception ex)
            {
                Debug.LogError($"[BackgroundProject] Failed to open project: {ex.Message}");
            }
        }

        public async Task<BackgroundProjectResult> InitializeInstanceAsync(bool configureGitHubRunner = false, bool initializeAll = false, CancellationToken ct = default)
        {
            if (BackgroundProjectSettings.IsInitializing)
            {
                return new BackgroundProjectResult
                {
                    Success = false,
                    Error = "Initialization already in progress",
                    InstanceName = initializeAll ? "all" : BackgroundProjectSettings.SelectedInstanceName
                };
            }

            var scriptPath = Path.Combine(
                BackgroundProjectSettings.GetProjectRoot(),
                "Assets", "_Game", "Submodules", "UnityBackgroundProject", "~ps", "InitializeBackgroundProjects.ps1");

            var resolvedInstance = initializeAll ? "all" : BackgroundProjectSettings.SelectedInstanceName;
            BackgroundProjectSettings.IsInitializing = true;
            OnStatusChanged?.Invoke(configureGitHubRunner ? "Initializing runner..." : "Initializing...");

            if (!File.Exists(scriptPath))
            {
                var missingScriptResult = new BackgroundProjectResult
                {
                    Success = false,
                    Error = $"Initialize script not found: {scriptPath}",
                    InstanceName = resolvedInstance
                };

                BackgroundProjectSettings.IsInitializing = false;
                OnStatusChanged?.Invoke("Initialize failed");
                OnOperationCompleted?.Invoke(missingScriptResult);
                return missingScriptResult;
            }

            var args = initializeAll
                ? $"-ExecutionPolicy Bypass -File \"{scriptPath}\" -All"
                : $"-ExecutionPolicy Bypass -File \"{scriptPath}\" -InstanceName \"{resolvedInstance}\"";

            if (configureGitHubRunner)
                args += " -ConfigureGitHubRunners";

            var stopwatch = Stopwatch.StartNew();
            try
            {
                var result = await RunProcessAsync("powershell.exe", args, BackgroundProjectSettings.GetProjectRoot(), ct, timeoutMs: 900000);
                result.InstanceName = resolvedInstance;
                result.Duration = stopwatch.Elapsed;

                if (result.Success)
                {
                    BackgroundProjectSettings.LastSyncTime = DateTime.Now;
                }
                else
                {
                    BackgroundProjectSettings.LastSyncError = result.Error;
                }

                OnStatusChanged?.Invoke(result.Success ? "Initialize complete" : "Initialize failed");
                OnOperationCompleted?.Invoke(result);
                return result;
            }
            finally
            {
                BackgroundProjectSettings.IsInitializing = false;
            }
        }

        private async Task<BackgroundProjectResult> RunProcessAsync(
            string fileName,
            string arguments,
            string workingDirectory,
            CancellationToken ct,
            int timeoutMs = 300000)
        {
            var result = new BackgroundProjectResult();
            var output = new System.Text.StringBuilder();
            var error = new System.Text.StringBuilder();

            try
            {
                var startInfo = new ProcessStartInfo
                {
                    FileName = fileName,
                    Arguments = arguments,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                    WorkingDirectory = workingDirectory
                };

                using var process = new Process { StartInfo = startInfo };
                process.OutputDataReceived += (s, e) =>
                {
                    if (e.Data != null) output.AppendLine(e.Data);
                };
                process.ErrorDataReceived += (s, e) =>
                {
                    if (e.Data != null) error.AppendLine(e.Data);
                };

                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();

                var completed = await Task.Run(() =>
                {
                    try
                    {
                        return process.WaitForExit(timeoutMs);
                    }
                    catch
                    {
                        return false;
                    }
                }, ct);

                if (!completed)
                {
                    try { process.Kill(); } catch { }
                    result.Success = false;
                    result.Error = "Process timed out";
                    result.ExitCode = -1;
                }
                else
                {
                    result.ExitCode = process.ExitCode;
                    result.Success = process.ExitCode == 0;
                    if (!result.Success && string.IsNullOrEmpty(result.Error))
                    {
                        result.Error = $"Process exited with code {process.ExitCode}";
                    }
                }

                result.Output = output.ToString();
                result.Error = error.Length > 0 ? error.ToString() : result.Error;
            }
            catch (OperationCanceledException)
            {
                result.Success = false;
                result.Error = "Operation cancelled";
            }
            catch (Exception ex)
            {
                result.Success = false;
                result.Error = ex.Message;
            }

            return result;
        }
    }
}
