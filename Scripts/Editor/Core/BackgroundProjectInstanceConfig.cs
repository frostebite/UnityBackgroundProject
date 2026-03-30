// User direction: "we implemented in background project submodule the ability to register self hosted runners.
// we should be able to do pattern matching by machine name to say specific or patterns of machines that will
// apply the self hosted runner or background project. so it can run on all/some/one machine"

using System;
using System.Text.RegularExpressions;

namespace UnityBackgroundProject
{
    [Serializable]
    public class BackgroundProjectInstanceConfigRoot
    {
        public string primaryInstance;
        public BackgroundProjectInstanceConfigEntry[] instances;
    }

    [Serializable]
    public class BackgroundProjectInstanceConfigEntry
    {
        public string kind;
        public string displayName;
        public string name;
        public string suffix;
        public string path;
        public string workspacePath;
        public BackgroundProjectGitHubRunnerConfig githubRunner;

        /// <summary>
        /// Machine name patterns this instance applies to.
        /// null or empty = all machines (backward compatible).
        /// Supports wildcard patterns: "*" matches all, "BUILD-*" matches any name starting with "BUILD-".
        /// If ANY pattern matches, the instance is included.
        /// </summary>
        public string[] targetMachines;

        /// <summary>
        /// Returns true if this instance should run on the current machine.
        /// </summary>
        public bool MatchesCurrentMachine()
        {
            return MatchesMachine(targetMachines, Environment.MachineName);
        }

        /// <summary>
        /// Checks whether the given machine name matches any of the target machine patterns.
        /// If targetMachines is null or empty, returns true (matches all machines).
        /// Patterns support '*' (any sequence of characters) and '?' (any single character).
        /// Matching is case-insensitive.
        /// </summary>
        public static bool MatchesMachine(string[] targetMachines, string machineName)
        {
            if (targetMachines == null || targetMachines.Length == 0)
                return true;

            if (string.IsNullOrEmpty(machineName))
                return false;

            for (int i = 0; i < targetMachines.Length; i++)
            {
                var pattern = targetMachines[i];
                if (string.IsNullOrEmpty(pattern))
                    continue;

                if (pattern == "*")
                    return true;

                // Convert glob pattern to regex: escape regex chars, then replace glob wildcards
                var regexPattern = "^" + Regex.Escape(pattern).Replace("\\*", ".*").Replace("\\?", ".") + "$";
                if (Regex.IsMatch(machineName, regexPattern, RegexOptions.IgnoreCase))
                    return true;
            }

            return false;
        }
    }

    [Serializable]
    public class BackgroundProjectGitHubRunnerConfig
    {
        public bool enabled;
        public string repository;
        public string repoName;
        public string runnerName;
        public string runnerPath;
        public string workspacePath;
        public string labelsCommaList;
        public string[] labels;
    }
}
