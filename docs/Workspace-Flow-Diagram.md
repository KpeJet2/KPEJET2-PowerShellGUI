# Workspace Flow Diagram

This diagram maps the complete operational flow for the PowerShellGUI workspace, including launch paths, core runtime services, UI surfaces, governance, testing, and artifact outputs.

```mermaid
flowchart TD
    U[User or Operator]

    subgraph EP[Entry Points]
        L1[Launch-AllServices.bat]
        L2[Launch-GUI.bat and other launchers]
        L3[Direct script actions]
    end

    subgraph ORCH[Runtime Orchestration]
        S1[scripts/Start-LocalWebEngineService.ps1]
        S2[scripts/Start-LocalWebEngine.ps1]
        S3[scripts/Invoke-EngineServiceMonitor.ps1]
        S4[scripts/Invoke-CronProcessor.ps1]
    end

    subgraph CORE[Core Services]
        C1[Local Web Engine :8042]
        C2[Service Cluster Dashboard :8099]
        C3[Tray Host and Bootstrap Quick Access]
        C4[Cron Processor x2]
    end

    subgraph UX[UI and Web Surfaces]
        X1[XHTML-WorkspaceHub.xhtml]
        X2[XHTML-ServiceClusterController.xhtml]
        X3[XHTML-DataRelationalViz.xhtml]
        X4[pages/*.xhtml and tools UI]
    end

    subgraph MOD[Modules and Shared Logic]
        M1[modules/PwShGUICore.psm1]
        M2[modules/PwShGUI-TrayHost.psm1]
        M3[modules/SINGovernance.psm1]
        M4[modules/PwShGUI-AiActionLog.psm1]
    end

    subgraph GOV[Governance and Quality Gates]
        G1[SIN Pattern Rules P001-P033]
        G2[Static scans and integrity checks]
        G3[VersionTag and encoding compliance]
    end

    subgraph QA[Testing and Verification]
        T1[tests/Invoke-PreCommitValidation.ps1]
        T2[tests/Start-LocalWebEngineIntegration.Tests.ps1]
        T3[tests/Test-WebEngineSustained.ps1]
        T4[tests/Invoke-SINPatternScanner.ps1]
    end

    subgraph OUT[Artifacts and Outputs]
        O1[logs/* and crash-quarantine/*]
        O2[reports/ and ~REPORTS/]
        O3[checkpoints/ and todo/]
        O4[sin_registry/*]
        O5[config/*.json]
    end

    U --> L1
    U --> L2
    U --> L3

    L1 --> S1
    L1 --> C2
    L1 --> S4

    L2 --> S1
    L3 --> S1
    L3 --> S2
    L3 --> S3
    L3 --> S4

    S1 --> S2
    S1 --> C3
    S1 --> S3

    S2 --> C1
    S3 --> C1
    S4 --> C4

    C1 --> X1
    C1 --> X2
    C1 --> X3
    C1 --> X4

    X1 --> M1
    X2 --> M2
    X3 --> M1
    X4 --> M1

    S1 --> M2
    S2 --> M1
    S4 --> M3

    M1 --> G2
    M2 --> G2
    M3 --> G1
    M4 --> O2

    G1 --> G3
    G2 --> G3

    G3 --> T1
    G3 --> T2
    G3 --> T3
    G3 --> T4

    T1 --> O1
    T2 --> O1
    T3 --> O1
    T4 --> O4

    C1 --> O1
    C2 --> O1
    C3 --> O1
    C4 --> O1

    S4 --> O3
    S4 --> O2
    G3 --> O5
    O1 --> O2
```
