<!-- VersionTag: 2608.B1.V54.1 -->

# VS Code Config AiNge

The VS Code configuration coverage companion discovers Stable and Insiders install defaults, current user settings, and current workspace settings. JSONC comments and trailing commas are accepted. Normalized records redact secret-shaped key paths before they are returned or persisted.

Generate the viewer artifact from the workspace root:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Export-VsCodeConfigCoverage.ps1 -WorkspacePath .
```

Open `XHTML-VsCodeConfigAiNge.xhtml`, choose the generated `~REPORTS/ConfigCoverage/vscode-config-report.json`, and use the three blades to filter source scope, comparison rows, and Config AiNge recommendations.

The companion module is [VsCodeConfigCoverage.psm1](../modules/VsCodeConfigCoverage.psm1). Its public model uses `Scope` values `user`, `workspace`, and `combined`; comparison statuses are `UNCHANGED`, `ADDED`, `REMOVED`, `CHANGED`, and `UNAVAILABLE`.
