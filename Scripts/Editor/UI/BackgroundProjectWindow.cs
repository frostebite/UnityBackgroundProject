using System;
using UnityEditor;
using UnityEngine;

namespace UnityBackgroundProject
{

/// <summary>
/// Editor window for background project management.
/// Provides full UI independent of toolbar integration.
/// </summary>
public class BackgroundProjectWindow : EditorWindow
{
    private Vector2 _scrollPosition;
    private string _outputLog = "";

    [MenuItem("Window/Background Project/Status")]
    public static void ShowWindow()
    {
        var window = GetWindow<BackgroundProjectWindow>();
        window.titleContent = new GUIContent("Background Project");
        window.minSize = new Vector2(400, 300);
        window.Show();
    }

    private void OnEnable()
    {
        BackgroundProjectService.Instance.OnStatusChanged += OnStatusChanged;
        BackgroundProjectService.Instance.OnOperationCompleted += OnOperationCompleted;
    }

    private void OnDisable()
    {
        BackgroundProjectService.Instance.OnStatusChanged -= OnStatusChanged;
        BackgroundProjectService.Instance.OnOperationCompleted -= OnOperationCompleted;
    }

    private void OnStatusChanged(string status)
    {
        _outputLog += $"[{DateTime.Now:HH:mm:ss}] {status}\n";
        Repaint();
    }

    private void OnOperationCompleted(BackgroundProjectResult result)
    {
        if (!string.IsNullOrEmpty(result.InstanceName))
        {
            _outputLog += $"[{DateTime.Now:HH:mm:ss}] Instance: {result.InstanceName}\n";
        }
        if (!result.Success && !string.IsNullOrEmpty(result.Error))
        {
            _outputLog += $"[{DateTime.Now:HH:mm:ss}] Error: {result.Error}\n";
        }
        if (result.Duration.TotalSeconds > 0)
        {
            _outputLog += $"[{DateTime.Now:HH:mm:ss}] Duration: {result.Duration.TotalSeconds:F1}s\n";
        }
        Repaint();
    }

    private void OnGUI()
    {
        _scrollPosition = EditorGUILayout.BeginScrollView(_scrollPosition);

        DrawStatusSection();
        EditorGUILayout.Space(10);
        DrawSettingsSection();
        EditorGUILayout.Space(10);
        DrawActionsSection();
        EditorGUILayout.Space(10);
        DrawOutputSection();

        EditorGUILayout.EndScrollView();
    }

    private void DrawStatusSection()
    {
        EditorGUILayout.LabelField("Status", EditorStyles.boldLabel);

        using (new EditorGUILayout.VerticalScope(EditorStyles.helpBox))
        {
            var selected = BackgroundProjectSettings.GetSelectedInstance();
            var projectPath = BackgroundProjectSettings.GetBackgroundProjectPath();
            var exists = BackgroundProjectSettings.BackgroundProjectExists();

            EditorGUILayout.LabelField("Selected Instance:", BackgroundProjectSettings.GetInstanceDisplayName(selected));
            EditorGUILayout.LabelField("Instance Kind:", BackgroundProjectSettings.GetSelectedInstanceKind());
            EditorGUILayout.LabelField("Background Project Path:", projectPath ?? "(unknown)");
            EditorGUILayout.LabelField("Exists:", exists ? "Yes" : "No");

            EditorGUILayout.Space(5);

            // Current operation status
            string currentOp = "Idle";
            if (BackgroundProjectSettings.IsInitializing) currentOp = "Initializing...";
            else if (BackgroundProjectSettings.IsSyncing) currentOp = "Syncing...";
            else if (BackgroundProjectSettings.IsCompiling) currentOp = "Compiling...";
            else if (BackgroundProjectSettings.IsRunningTests) currentOp = "Running Tests...";

            EditorGUILayout.LabelField("Current Operation:", currentOp);

            if (BackgroundProjectSettings.LastSyncTime.HasValue)
            {
                var elapsed = DateTime.Now - BackgroundProjectSettings.LastSyncTime.Value;
                var timeText = elapsed.TotalMinutes < 60
                    ? $"{elapsed.TotalMinutes:F0} minutes ago"
                    : $"{elapsed.TotalHours:F1} hours ago";
                EditorGUILayout.LabelField("Last Sync:", $"{BackgroundProjectSettings.LastSyncTime.Value:HH:mm:ss} ({timeText})");
            }

            if (!string.IsNullOrEmpty(BackgroundProjectSettings.LastSyncError))
            {
                EditorGUILayout.Space(5);
                EditorGUILayout.HelpBox($"Last Error: {BackgroundProjectSettings.LastSyncError}", MessageType.Warning);
            }
        }
    }

    private void DrawSettingsSection()
    {
        EditorGUILayout.LabelField("Settings", EditorStyles.boldLabel);

        using (new EditorGUILayout.VerticalScope(EditorStyles.helpBox))
        {
            BackgroundProjectSettings.Enabled = EditorGUILayout.Toggle("Enabled", BackgroundProjectSettings.Enabled);

            EditorGUI.BeginDisabledGroup(!BackgroundProjectSettings.Enabled);

            var instances = BackgroundProjectSettings.GetInstanceConfigs();
            var selectedIndex = Array.FindIndex(instances, instance => string.Equals(instance.name, BackgroundProjectSettings.SelectedInstanceName, StringComparison.Ordinal));
            selectedIndex = selectedIndex < 0 ? 0 : selectedIndex;
            var labels = new string[instances.Length];
            for (var i = 0; i < instances.Length; i++)
            {
                labels[i] = BackgroundProjectSettings.GetInstanceDisplayName(instances[i]);
            }

            var nextIndex = EditorGUILayout.Popup("Active Instance", selectedIndex, labels);
            if (nextIndex >= 0 && nextIndex < instances.Length)
            {
                BackgroundProjectSettings.SelectedInstanceName = instances[nextIndex].name;
            }

            BackgroundProjectSettings.Suffix = EditorGUILayout.TextField("Project Suffix", BackgroundProjectSettings.Suffix);
            BackgroundProjectSettings.PreferredSyncTool = (SyncTool)EditorGUILayout.EnumPopup("Sync Tool", BackgroundProjectSettings.PreferredSyncTool);

            var effectiveTool = BackgroundProjectSettings.GetEffectiveSyncTool();
            EditorGUILayout.LabelField("Effective Tool:", effectiveTool.ToString());

            EditorGUILayout.Space(5);

            EditorGUILayout.LabelField("Tool Availability:", EditorStyles.miniLabel);
            EditorGUI.indentLevel++;
            EditorGUILayout.LabelField("rclone:", BackgroundProjectSettings.IsRcloneAvailable() ? "Available" : "Not found");
            EditorGUILayout.LabelField("robocopy:", BackgroundProjectSettings.IsRobocopyAvailable() ? "Available" : "Not found");
            EditorGUI.indentLevel--;

            EditorGUI.EndDisabledGroup();

            EditorGUILayout.Space(5);

            if (GUILayout.Button("Open Preferences"))
            {
                SettingsService.OpenUserPreferences("Preferences/Unity Background Project");
            }
        }
    }

    private void DrawActionsSection()
    {
        EditorGUILayout.LabelField("Actions", EditorStyles.boldLabel);

        bool isBusy = BackgroundProjectSettings.IsInitializing ||
                      BackgroundProjectSettings.IsSyncing ||
                      BackgroundProjectSettings.IsCompiling ||
                      BackgroundProjectSettings.IsRunningTests;

        EditorGUI.BeginDisabledGroup(isBusy || !BackgroundProjectSettings.Enabled);

        using (new EditorGUILayout.HorizontalScope())
        {
            if (GUILayout.Button("Initialize", GUILayout.Height(30)))
            {
                _outputLog += $"[{DateTime.Now:HH:mm:ss}] Initializing instance...\n";
                _ = BackgroundProjectService.Instance.InitializeInstanceAsync();
            }

            if (GUILayout.Button("Initialize All", GUILayout.Height(30)))
            {
                _outputLog += $"[{DateTime.Now:HH:mm:ss}] Initializing all instances...\n";
                _ = BackgroundProjectService.Instance.InitializeInstanceAsync(initializeAll: true);
            }
        }

        using (new EditorGUILayout.HorizontalScope())
        {
            if (GUILayout.Button("Sync Project", GUILayout.Height(30)))
            {
                _outputLog += $"[{DateTime.Now:HH:mm:ss}] Starting sync...\n";
                _ = BackgroundProjectService.Instance.SyncAsync();
            }

            if (GUILayout.Button("Compile Check", GUILayout.Height(30)))
            {
                _outputLog += $"[{DateTime.Now:HH:mm:ss}] Starting compile check...\n";
                _ = BackgroundProjectService.Instance.CompileCheckAsync();
            }
        }

        using (new EditorGUILayout.HorizontalScope())
        {
            if (GUILayout.Button("Run EditMode Tests", GUILayout.Height(25)))
            {
                _outputLog += $"[{DateTime.Now:HH:mm:ss}] Starting EditMode tests...\n";
                _ = BackgroundProjectService.Instance.RunTestsAsync("EditMode");
            }

            if (GUILayout.Button("Run PlayMode Tests", GUILayout.Height(25)))
            {
                _outputLog += $"[{DateTime.Now:HH:mm:ss}] Starting PlayMode tests...\n";
                _ = BackgroundProjectService.Instance.RunTestsAsync("PlayMode");
            }
        }

        if (BackgroundProjectSettings.SelectedInstanceSupportsRunnerLifecycle())
        {
            using (new EditorGUILayout.HorizontalScope())
            {
                if (GUILayout.Button("Initialize + Start Runner", GUILayout.Height(25)))
                {
                    _outputLog += $"[{DateTime.Now:HH:mm:ss}] Initializing runner instance...\n";
                    _ = BackgroundProjectService.Instance.InitializeInstanceAsync(configureGitHubRunner: true);
                }
            }
        }

        EditorGUI.EndDisabledGroup();

        EditorGUILayout.Space(5);

        EditorGUI.BeginDisabledGroup(!BackgroundProjectSettings.BackgroundProjectExists());

        if (GUILayout.Button("Open Background Project in Unity"))
        {
            BackgroundProjectService.Instance.OpenBackgroundProject();
        }

        EditorGUI.EndDisabledGroup();
    }

    private void DrawOutputSection()
    {
        EditorGUILayout.BeginHorizontal();
        EditorGUILayout.LabelField("Output Log", EditorStyles.boldLabel);
        if (GUILayout.Button("Clear", GUILayout.Width(50)))
        {
            _outputLog = "";
        }
        EditorGUILayout.EndHorizontal();

        using (new EditorGUILayout.VerticalScope(EditorStyles.helpBox, GUILayout.MinHeight(100)))
        {
            EditorGUILayout.SelectableLabel(_outputLog, EditorStyles.textArea, GUILayout.ExpandHeight(true));
        }
    }
}
}
