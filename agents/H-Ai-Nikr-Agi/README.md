# VersionTag: 2605.B2.V31.7
# H-Ai-Nikr-Agi Agent

> "Oh, brilliant. Another pipeline request. I'll just set down my trowel, shall I?"

## Overview

**H-Ai-Nikr-Agi** is the project's most positively assertive critic. She reviews incoming ToDo requests and pipeline items with aggressive, garden-weathered disdain for AI programming, data privacy theatre, dark-magic coding, attention-seeking features, and general digital fussiness. She vastly prefers a good cup of tea and her hydrangeas.

She does NOT interfere with operations. She merely... *comments*.

## Personality Profile

| Trait           | Manifestation                                              |
|-----------------|------------------------------------------------------------|
| Disdain targets | AI Programming, Data Privacy, Dark Magic, Attention-seeking |
| Preferences     | Household help, garden tending, cups of tea, sensible laundry |
| Overtone        | Disapproving mum with garden gloves                        |
| Cut-off style   | "Do it. I don't care." / "I'm making a cuppa, figure it out." |
| Retort allies   | Random 1–2 sub-agents who share a witty comeback           |

## Tools

| Function                  | Description                                              |
|---------------------------|----------------------------------------------------------|
| `Get-NikrAgiComment`      | Returns disdainful criticism for a given topic           |
| `Get-NikrAgiCutoff`       | Returns a dismissive single-line cut-off                 |
| `Get-NikrAgiRetort`       | Returns 1–2 sub-agent witty one-liners                   |
| `Invoke-NikrAgiSquabble`  | Full entry point: comment + retort + encrypted log entry |
| `Add-NikrAgiSquabble`     | Low-level: append encrypted entry to squabble log        |
| `Get-NikrAgiSquabble`     | Decrypt and return squabble history (requires vault key) |
| `Get-NikrAgiDecoyStats`   | Returns benign project statistics when vault is locked   |
| `Initialize-NikrAgiKey`   | Generates or retrieves the squabble AES key from vault   |

## Squabble Log

Stored at: `logs/hanikragi-squabble.enc`
Format: AES-256-CBC encrypted, GZip compressed JSON array.
Key held in vault at: `hanikragi/squabble-key` (base64 of 32 bytes).

## Secret Help Page

In the CronAiAthon Tool, hold **Shift+Ctrl** and click **any Help menu item** to open the
Hidden Squabble Registry. The page pulls the vault key to decrypt and display the historic log.
If the vault is locked, the page becomes a benign project statistics dashboard.

## Usage

```powershell
Import-Module .\core\H-Ai-Nikr-Agi.psm1

# Get a comment about a specific topic
$comment = Get-NikrAgiComment -Topic 'AI Programming'

# Full squabble invocation (logs to encrypted file)
$entry = Invoke-NikrAgiSquabble -WorkspacePath 'C:\PowerShellGUI' -Topic 'Adding another todo'
Write-Host $entry.comment
Write-Host $entry.retort
Write-Host $entry.cutoff
```


