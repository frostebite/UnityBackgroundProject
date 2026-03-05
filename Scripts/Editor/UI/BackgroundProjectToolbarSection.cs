#if HAS_EDITOR_TOOLBAR
using System;
using UnityEditor;
using UnityEngine;
using UnityBackgroundProject;

/// <summary>
/// Toolbar section for background project controls.
/// Implements IEditorToolbar from EditorToolbar module.
///
/// This file is compiled only when the HAS_EDITOR_TOOLBAR scripting define is set.
/// To enable toolbar integration:
///   1. Ensure EditorToolbar assembly is present in your project
///   2. Add "EditorToolbar" to the references in UnityBackgroundProject.editor.asmdef
///   3. Add HAS_EDITOR_TOOLBAR to your project's Scripting Define Symbols
///      (Edit > Project Settings > Player > Scripting Define Symbols)
///   Alternatively, use the auto-setup: see BackgroundProjectEditorToolbarSetup.cs
/// </summary>
[ToolbarSectionAttribute("Background Project")]
public class BackgroundProjectToolbarSection : IEditorToolbar
{
    private string _statusText = "Idle";
    private Color _statusColor = Color.gray;

    public BackgroundProjectToolbarSection()
    {
        var service = BackgroundProjectService.Instance;
        service.OnStatusChanged += OnStatusChanged;
        UpdateStatus();
    }

    public bool ShouldShow()
    {
        return BackgroundProjectSettings.Enabled;
    }

    public void OnGUI()
    {
        try
        {
            EditorGUILayout.BeginHorizontal();

            // Status indicator
            var originalColor = GUI.color;
            GUI.color = _statusColor;
            EditorGUILayout.LabelField(
                new GUIContent($"BG: {_statusText}", GetTooltip()),
                EditorStyles.miniLabel,
                GUILayout.Width(100));
            GUI.color = originalColor;

            // Quick actions
            bool isBusy = BackgroundProjectSettings.IsSyncing ||
                          BackgroundProjectSettings.IsCompiling ||
                          BackgroundProjectSettings.IsRunningTests;

            GUI.enabled = !isBusy;

            if (GUILayout.Button("Sync", EditorStyles.miniButton, GUILayout.Width(40)))
            {
                _ = BackgroundProjectService.Instance.SyncAsync();
            }

            if (GUILayout.Button("...", EditorStyles.miniButton, GUILayout.Width(20)))
            {
                ShowActionsMenu();
            }

            GUI.enabled = true;

            EditorGUILayout.EndHorizontal();
        }
        catch (Exception ex)
        {
            Debug.LogError($"[BackgroundProject] UI Error: {ex.Message}");
        }
    }

    private void OnStatusChanged(string status)
    {
        _statusText = status;
        UpdateStatus();

        // Request repaint
        EditorApplication.delayCall += () =>
        {
            var windows = Resources.FindObjectsOfTypeAll<EditorWindow>();
            foreach (var window in windows)
            {
                if (window != null) window.Repaint();
            }
        };
    }

    private void UpdateStatus()
    {
        if (BackgroundProjectSettings.IsSyncing)
        {
            _statusText = "Syncing...";
            _statusColor = new Color(1f, 0.7f, 0f); // Orange
        }
        else if (BackgroundProjectSettings.IsCompiling)
        {
            _statusText = "Compiling...";
            _statusColor = new Color(1f, 0.7f, 0f); // Orange
        }
        else if (BackgroundProjectSettings.IsRunningTests)
        {
            _statusText = "Testing...";
            _statusColor = new Color(1f, 0.7f, 0f); // Orange
        }
        else if (!string.IsNullOrEmpty(BackgroundProjectSettings.LastSyncError))
        {
            _statusText = "Error";
            _statusColor = new Color(1f, 0.3f, 0.3f); // Red
        }
        else if (BackgroundProjectSettings.LastSyncTime.HasValue)
        {
            var elapsed = DateTime.Now - BackgroundProjectSettings.LastSyncTime.Value;
            if (elapsed.TotalMinutes < 1)
                _statusText = "Synced <1m";
            else if (elapsed.TotalMinutes < 60)
                _statusText = $"Synced {elapsed.TotalMinutes:F0}m";
            else
                _statusText = $"Synced {elapsed.TotalHours:F0}h";

            _statusColor = new Color(0.3f, 1f, 0.3f); // Green
        }
        else
        {
            _statusText = "Not synced";
            _statusColor = Color.gray;
        }
    }

    private string GetTooltip()
    {
        var lines = new System.Collections.Generic.List<string>
        {
            "Background Project Status",
            "",
            $"Path: {BackgroundProjectSettings.GetBackgroundProjectPath()}",
            $"Exists: {(BackgroundProjectSettings.BackgroundProjectExists() ? "Yes" : "No")}",
            ""
        };

        if (BackgroundProjectSettings.LastSyncTime.HasValue)
        {
            lines.Add($"Last Sync: {BackgroundProjectSettings.LastSyncTime.Value:yyyy-MM-dd HH:mm:ss}");
        }

        if (!string.IsNullOrEmpty(BackgroundProjectSettings.LastSyncError))
        {
            lines.Add($"Last Error: {BackgroundProjectSettings.LastSyncError}");
        }

        lines.Add("");
        lines.Add($"Sync Tool: {BackgroundProjectSettings.GetEffectiveSyncTool()}");

        return string.Join("\n", lines);
    }

    private void ShowActionsMenu()
    {
        var menu = new GenericMenu();

        menu.AddItem(new GUIContent("Sync Project"), false, () =>
        {
            _ = BackgroundProjectService.Instance.SyncAsync();
        });

        menu.AddItem(new GUIContent("Compile Check"), false, () =>
        {
            _ = BackgroundProjectService.Instance.CompileCheckAsync();
        });

        menu.AddSeparator("");

        menu.AddItem(new GUIContent("Run Tests/EditMode"), false, () =>
        {
            _ = BackgroundProjectService.Instance.RunTestsAsync("EditMode");
        });

        menu.AddItem(new GUIContent("Run Tests/PlayMode"), false, () =>
        {
            _ = BackgroundProjectService.Instance.RunTestsAsync("PlayMode");
        });

        menu.AddSeparator("");

        menu.AddItem(new GUIContent("Open Background Project"), false, () =>
        {
            BackgroundProjectService.Instance.OpenBackgroundProject();
        });

        menu.AddSeparator("");

        menu.AddItem(new GUIContent("Settings..."), false, () =>
        {
            SettingsService.OpenUserPreferences("Preferences/Unity Background Project");
        });

        menu.ShowAsContext();
    }
}
#endif
