using System;

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
