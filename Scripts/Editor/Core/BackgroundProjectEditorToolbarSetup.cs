using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Compilation;
using UnityEngine;

namespace UnityBackgroundProject
{
    /// <summary>
    /// Automatically detects the EditorToolbar assembly and configures this
    /// assembly definition to reference it with the HAS_EDITOR_TOOLBAR define.
    ///
    /// On domain reload, checks whether "EditorToolbar" exists as an assembly
    /// definition in the project. If it does:
    ///   - Adds "EditorToolbar" to the asmdef references (if not already present)
    ///   - Adds HAS_EDITOR_TOOLBAR to Player scripting defines (if not already present)
    ///
    /// If EditorToolbar is removed from the project, the reference and define are
    /// cleaned up on the next domain reload.
    ///
    /// This allows the UnityBackgroundProject to ship with zero hard dependencies
    /// while automatically enabling toolbar integration when EditorToolbar is available.
    /// </summary>
    [InitializeOnLoad]
    internal static class BackgroundProjectEditorToolbarSetup
    {
        private const string EditorToolbarAssemblyName = "EditorToolbar";
        private const string DefineSymbol = "HAS_EDITOR_TOOLBAR";
        private const string AsmdefName = "UnityBackgroundProject.Editor";
        private const string SessionStateKey = "BackgroundProject_ToolbarSetupDone";

        static BackgroundProjectEditorToolbarSetup()
        {
            // Only run once per domain reload to avoid repeated asset database refreshes
            if (SessionState.GetBool(SessionStateKey, false))
                return;

            SessionState.SetBool(SessionStateKey, true);

            // Defer to avoid running during import
            EditorApplication.delayCall += CheckAndConfigure;
        }

        private static void CheckAndConfigure()
        {
            bool editorToolbarExists = DoesAssemblyDefinitionExist(EditorToolbarAssemblyName);
            bool asmdefChanged = EnsureAsmdefReference(editorToolbarExists);
            bool defineChanged = EnsureScriptingDefine(editorToolbarExists);

            if (asmdefChanged || defineChanged)
            {
                string action = editorToolbarExists ? "enabled" : "disabled";
                Debug.Log($"[BackgroundProject] EditorToolbar integration {action}.");

                if (asmdefChanged)
                {
                    AssetDatabase.Refresh();
                }
            }
        }

        private static bool DoesAssemblyDefinitionExist(string assemblyName)
        {
            // Use Unity's CompilationPipeline to check for the assembly
            var assemblies = CompilationPipeline.GetAssemblies(AssembliesType.Editor);
            return assemblies.Any(a => a.name == assemblyName);
        }

        /// <summary>
        /// Ensures the asmdef has (or doesn't have) the EditorToolbar reference.
        /// Returns true if the asmdef was modified.
        /// </summary>
        private static bool EnsureAsmdefReference(bool shouldHaveReference)
        {
            string asmdefPath = FindAsmdefPath();
            if (string.IsNullOrEmpty(asmdefPath))
                return false;

            string json = File.ReadAllText(asmdefPath);
            var asmdef = JsonUtility.FromJson<AsmdefData>(json);

            if (asmdef.references == null)
                asmdef.references = new List<string>();

            bool hasReference = asmdef.references.Contains(EditorToolbarAssemblyName);

            if (shouldHaveReference && !hasReference)
            {
                asmdef.references.Add(EditorToolbarAssemblyName);
                File.WriteAllText(asmdefPath, JsonUtility.ToJson(asmdef, true));
                return true;
            }

            if (!shouldHaveReference && hasReference)
            {
                asmdef.references.Remove(EditorToolbarAssemblyName);
                File.WriteAllText(asmdefPath, JsonUtility.ToJson(asmdef, true));
                return true;
            }

            return false;
        }

        /// <summary>
        /// Ensures the scripting define is present (or absent).
        /// Returns true if defines were modified.
        /// </summary>
        private static bool EnsureScriptingDefine(bool shouldHaveDefine)
        {
            var buildTargetGroup = EditorUserBuildSettings.selectedBuildTargetGroup;
            if (buildTargetGroup == BuildTargetGroup.Unknown)
                buildTargetGroup = BuildTargetGroup.Standalone;

#if UNITY_2021_2_OR_NEWER
            var namedTarget = UnityEditor.Build.NamedBuildTarget.FromBuildTargetGroup(buildTargetGroup);
            string currentDefines = PlayerSettings.GetScriptingDefineSymbols(namedTarget);
#else
            string currentDefines = PlayerSettings.GetScriptingDefineSymbolsForGroup(buildTargetGroup);
#endif

            var defines = new List<string>(
                currentDefines.Split(';')
                    .Select(d => d.Trim())
                    .Where(d => !string.IsNullOrEmpty(d))
            );

            bool hasDefine = defines.Contains(DefineSymbol);

            if (shouldHaveDefine && !hasDefine)
            {
                defines.Add(DefineSymbol);
                string newDefines = string.Join(";", defines);

#if UNITY_2021_2_OR_NEWER
                PlayerSettings.SetScriptingDefineSymbols(namedTarget, newDefines);
#else
                PlayerSettings.SetScriptingDefineSymbolsForGroup(buildTargetGroup, newDefines);
#endif
                return true;
            }

            if (!shouldHaveDefine && hasDefine)
            {
                defines.Remove(DefineSymbol);
                string newDefines = string.Join(";", defines);

#if UNITY_2021_2_OR_NEWER
                PlayerSettings.SetScriptingDefineSymbols(namedTarget, newDefines);
#else
                PlayerSettings.SetScriptingDefineSymbolsForGroup(buildTargetGroup, newDefines);
#endif
                return true;
            }

            return false;
        }

        private static string FindAsmdefPath()
        {
            // Search for our asmdef by name
            var guids = AssetDatabase.FindAssets($"t:asmdef {AsmdefName}");
            foreach (var guid in guids)
            {
                var path = AssetDatabase.GUIDToAssetPath(guid);
                if (Path.GetFileNameWithoutExtension(path) == "UnityBackgroundProject.editor")
                    return path;
            }

            return null;
        }

        /// <summary>
        /// Minimal asmdef structure for JSON serialization.
        /// Uses JsonUtility which requires Serializable fields.
        /// </summary>
        [System.Serializable]
        private class AsmdefData
        {
            public string name;
            public string rootNamespace;
            public List<string> references;
            public List<string> includePlatforms;
            public List<string> excludePlatforms;
            public bool allowUnsafeCode;
            public bool overrideReferences;
            public List<string> precompiledReferences;
            public bool autoReferenced;
            public List<string> defineConstraints;
            public List<VersionDefine> versionDefines;
            public bool noEngineReferences;
        }

        [System.Serializable]
        private class VersionDefine
        {
            public string name;
            public string expression;
            public string define;
        }
    }
}
