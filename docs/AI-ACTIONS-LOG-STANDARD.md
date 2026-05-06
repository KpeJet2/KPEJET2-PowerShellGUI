# VersionTag: 2605.B2.V31.7

## AI Actions Log Standard

## Purpose

This standard records AI and agent file-change work in a single canonical log so the workspace can:

- show who started and finished change actions
- capture which files were created, modified, or deleted
- detect duplicate starts, missing stops, invalid stop ordering, and failed actions
- archive live and test-tagged action records separately

## Storage

- Live JSONL: `logs/ai-actions/live/ai-actions-YYYYMMdd.jsonl`
- Test JSONL: `logs/ai-actions/test/ai-actions-test-YYYYMMdd.jsonl`
- Summary report: `~REPORTS/ai-actions/ai-actions-summary.json`
- Archives: `logs/archive/ai-actions/live/` and `logs/archive/ai-actions/test/`

## Record Types

### Start

```json
{
  "schema": "PwShGUI-AiActionLog/1.0",
  "ts": "2026-05-06T06:12:00.0000000Z",
  "recordType": "start",
  "actionId": "copilot-20260506-001",
  "actionName": "Implement AI action log workflow",
  "agentId": "GitHub Copilot",
  "summary": "Begin workspace changes for AI action logging",
  "files": [
    { "path": "modules/PwShGUI-AiActionLog.psm1", "change": "modified" }
  ],
  "isTest": false
}
```

### Finish

```json
{
  "schema": "PwShGUI-AiActionLog/1.0",
  "ts": "2026-05-06T06:16:00.0000000Z",
  "recordType": "finish",
  "actionId": "copilot-20260506-001",
  "actionName": "Implement AI action log workflow",
  "agentId": "GitHub Copilot",
  "summary": "Completed workspace changes for AI action logging",
  "result": "success",
  "files": [
    { "path": "modules/PwShGUI-AiActionLog.psm1", "change": "created" },
    { "path": "XHTML-ChangelogViewer.xhtml", "change": "modified" }
  ],
  "isTest": false
}
```

### Logging Error

```json
{
  "schema": "PwShGUI-AiActionLog/1.0",
  "ts": "2026-05-06T06:17:00.0000000Z",
  "recordType": "logging-error",
  "actionId": "copilot-20260506-001",
  "actionName": "Implement AI action log workflow",
  "agentId": "GitHub Copilot",
  "summary": "AI action log write failed",
  "errorMessage": "7-Zip not found",
  "isTest": false
}
```

## Rules

1. Agents must write a `start` record before changing files.
2. Agents must write a `finish` record after changes complete or fail.
3. Finish records must include the final file list with `created`, `modified`, `deleted`, or `unknown` change kinds.
4. Test fixtures must set `isTest=true` and must be written to the test storage path.
5. Archives must produce:
   - one plain `.zip`
   - one AES-encrypted `.zip` using password `ddMMyyyy!`

## Metrics Produced

- unique agents
- total actions logged
- total records
- successful started-and-stopped actions
- started with no stop recorded
- multiple starts with no stop recorded
- actions with multiple starts and one logical stop
- actions with multiple logical stops
- actions with invalid stop ordering
- total failed actions
- total logging failures/errors
- file-change totals by change kind
- unique files touched
