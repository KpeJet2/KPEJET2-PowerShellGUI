---
mode: "agent"
model: "GPT-5"
description: "Use when you need to run Shop-ListedItemsBot with a structured item list, validated stores, and 3-store comparison output."
argument-hint: "Paste item rows, country, and optional stores to compare"
tools: [web, read, search, todo]
---
<!-- VersionTag: 2605.B5.V46.0 -->
Run this task with `Shop-ListedItemsBot`.

## Goal
Compare row-based item inputs across exactly three selected stores, validate/augment stores, and produce a structured comparison with links.

## Required Inputs
- `country`: Country/region to prioritize local stores.
- `items`: Array of item rows.

## Optional Inputs
- `stores`: Existing store definitions.

## Input Schema
```json
{
  "country": "Australia",
  "items": [
    {
      "rowId": "1",
      "title": "Samsung 990 PRO 2TB NVMe SSD",
      "brand": "Samsung",
      "model": "MZ-V9P2T0BW",
      "sku": "MZ-V9P2T0BW",
      "specs": "PCIe 4.0, M.2 2280"
    }
  ],
  "stores": [
    {
      "siteName": "Example Store",
      "baseUrl": "https://example.com",
      "searchPattern": "https://example.com/search?q={query}"
    }
  ]
}
```

## Execution Rules
- Validate each provided store URL and search pattern.
- Auto-detect search parameter behavior per site if pattern is missing.
- Suggest additional likely stores when needed, prioritizing local-country stores.
- Ask user to confirm exactly three stores before comparison.
- Confirm near matches before finalizing.
- If no match appears for an item, output likely shops and suggested retry query for that row.

## Required Output Sections
1. `Validated Stores`
2. `Selected Stores`
3. `Item Comparison`
4. `No-Match Recovery` (only if needed)
5. `Refined Shop Guidance`
