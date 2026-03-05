using System;
using System.IO;
using UnityEditor;
using UnityEngine;

namespace UnityBackgroundProject
{
    public enum SyncTool
    {
        Auto,
        Rclone,
        Robocopy
    }

    /// <summary>
    /// Centralized settings for background project functionality.
    /// Stores preferences in EditorPrefs and provides computed paths.
    /// </summary>
    public static class BackgroundProjectSettings
    {
        private const string Prefix = "UnityBackgroundProject_";
        private const string DefaultSuffix = "-BackgroundWorker";

        // Persisted settings
        public static bool Enabled
        {
            get => EditorPrefs.GetBool($"{Prefix}Enabled", false);
            set => EditorPrefs.SetBool($"{Prefix}Enabled", value);
        }

        public static string Suffix
        {
            get => EditorPrefs.GetString($"{Prefix}Suffix", DefaultSuffix);
            set => EditorPrefs.SetString($"{Prefix}Suffix", value);
        }

        public static SyncTool PreferredSyncTool
        {
            get => (SyncTool)EditorPrefs.GetInt($"{Prefix}SyncTool", (int)SyncTool.Auto);
            set => EditorPrefs.SetInt($"{Prefix}SyncTool", (int)value);
        }

        public static bool AutoSyncOnPreCommit
        {
            get => EditorPrefs.GetBool($"{Prefix}AutoSyncOnPreCommit", true);
            set => EditorPrefs.SetBool($"{Prefix}AutoSyncOnPreCommit", value);
        }

        // Runtime status (not persisted)
        public static DateTime? LastSyncTime { get; set; }
        public static string LastSyncError { get; set; }
        public static bool IsSyncing { get; set; }
        public static bool IsCompiling { get; set; }
        public static bool IsRunningTests { get; set; }

        /// <summary>
        /// Gets the current Unity project root path.
        /// </summary>
        public static string GetProjectRoot()
        {
            return Path.GetDirectoryName(Application.dataPath);
        }

        /// <summary>
        /// Gets the background project path based on current settings.
        /// </summary>
        public static string GetBackgroundProjectPath()
        {
            var projectRoot = GetProjectRoot();
            if (string.IsNullOrEmpty(projectRoot))
                return null;

            var projectName = Path.GetFileName(projectRoot);
            var parentDir = Path.GetDirectoryName(projectRoot);

            if (string.IsNullOrEmpty(parentDir))
                return null;

            return Path.Combine(parentDir, projectName + Suffix);
        }

        /// <summary>
        /// Checks if the background project directory exists.
        /// </summary>
        public static bool BackgroundProjectExists()
        {
            var path = GetBackgroundProjectPath();
            return !string.IsNullOrEmpty(path) && Directory.Exists(path);
        }

        /// <summary>
        /// Checks if rclone is available on the system.
        /// </summary>
        public static bool IsRcloneAvailable()
        {
            try
            {
                var startInfo = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "rclone",
                    Arguments = "version",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                };

                using (var process = System.Diagnostics.Process.Start(startInfo))
                {
                    if (process != null)
                    {
                        process.WaitForExit(5000);
                        return process.ExitCode == 0;
                    }
                }
            }
            catch
            {
                // Silently fail
            }

            return false;
        }

        /// <summary>
        /// Checks if robocopy is available (Windows only).
        /// </summary>
        public static bool IsRobocopyAvailable()
        {
            if (Application.platform != RuntimePlatform.WindowsEditor)
                return false;

            try
            {
                var startInfo = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "robocopy",
                    Arguments = "/?",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                };

                using (var process = System.Diagnostics.Process.Start(startInfo))
                {
                    if (process != null)
                    {
                        process.WaitForExit(5000);
                        // Robocopy returns 16 for usage/help
                        return process.ExitCode <= 16;
                    }
                }
            }
            catch
            {
                // Silently fail
            }

            return false;
        }

        /// <summary>
        /// Determines which sync tool to use based on settings and availability.
        /// </summary>
        public static SyncTool GetEffectiveSyncTool()
        {
            var preferred = PreferredSyncTool;

            if (preferred == SyncTool.Rclone && IsRcloneAvailable())
                return SyncTool.Rclone;

            if (preferred == SyncTool.Robocopy && IsRobocopyAvailable())
                return SyncTool.Robocopy;

            if (preferred == SyncTool.Auto)
            {
                if (IsRcloneAvailable())
                    return SyncTool.Rclone;
                if (IsRobocopyAvailable())
                    return SyncTool.Robocopy;
            }

            // Return preferred even if not available - let caller handle error
            return preferred == SyncTool.Auto ? SyncTool.Rclone : preferred;
        }

        [SettingsProvider]
        public static SettingsProvider CreateSettingsProvider()
        {
            return new SettingsProvider("Preferences/Unity Background Project", SettingsScope.User)
            {
                label = "Background Project",
                guiHandler = searchContext =>
                {
                    EditorGUILayout.Space(10);

                    EditorGUILayout.LabelField("Background Project Settings", EditorStyles.boldLabel);
                    EditorGUILayout.Space(5);

                    Enabled = EditorGUILayout.Toggle("Enabled", Enabled);

                    EditorGUI.BeginDisabledGroup(!Enabled);

                    Suffix = EditorGUILayout.TextField("Project Suffix", Suffix);

                    var path = GetBackgroundProjectPath();
                    EditorGUILayout.LabelField("Background Path", path ?? "(unable to determine)");

                    var exists = BackgroundProjectExists();
                    EditorGUILayout.LabelField("Status", exists ? "Exists" : "Not created yet");

                    EditorGUILayout.Space(10);
                    EditorGUILayout.LabelField("Sync Settings", EditorStyles.boldLabel);

                    PreferredSyncTool = (SyncTool)EditorGUILayout.EnumPopup("Sync Tool", PreferredSyncTool);

                    var effectiveTool = GetEffectiveSyncTool();
                    var rcloneAvailable = IsRcloneAvailable();
                    var robocopyAvailable = IsRobocopyAvailable();

                    EditorGUILayout.LabelField("Effective Tool", effectiveTool.ToString());
                    EditorGUILayout.LabelField("rclone", rcloneAvailable ? "Available" : "Not found");
                    EditorGUILayout.LabelField("robocopy", robocopyAvailable ? "Available" : "Not found (Windows only)");

                    if (!rcloneAvailable && !robocopyAvailable)
                    {
                        EditorGUILayout.HelpBox(
                            "No sync tool available. Please install rclone from https://rclone.org/install/",
                            MessageType.Error);
                    }

                    EditorGUILayout.Space(10);
                    AutoSyncOnPreCommit = EditorGUILayout.Toggle("Auto-sync on Pre-commit", AutoSyncOnPreCommit);

                    EditorGUI.EndDisabledGroup();

                    EditorGUILayout.Space(10);
                    if (LastSyncTime.HasValue)
                    {
                        EditorGUILayout.LabelField("Last Sync", LastSyncTime.Value.ToString("yyyy-MM-dd HH:mm:ss"));
                    }

                    if (!string.IsNullOrEmpty(LastSyncError))
                    {
                        EditorGUILayout.HelpBox($"Last Error: {LastSyncError}", MessageType.Warning);
                    }
                },
                keywords = new[] { "background", "project", "sync", "worker", "rclone", "robocopy" }
            };
        }
    }
}
