---
name: zotero-bulk-language
description: Bulk update Zotero item language fields for selected subsets of a local Zotero Desktop library. Use when the user asks to set or normalize Zotero/Zetero/Zotero Desktop language values, such as setting all English-title items to "en", changing items matched by title regex, item keys, item types, or a described library subset, and when Codex may need to safely close/reopen Zotero, back up zotero.sqlite, inspect Zotero's local data directory, and verify database changes.
---

# Zotero Bulk Language

Use this skill to batch-edit the `language` field in a local Zotero Desktop library.

Prefer the bundled PowerShell script for database edits:

```powershell
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\Set-ZoteroLanguage.ps1 -Language en -TitleLanguage English -DryRun
```

## Workflow

1. Resolve the active Zotero data directory from profile preferences when possible. If ambiguous, inspect `prefs.js` for `extensions.zotero.dataDir` and confirm the active `zotero.sqlite`.
2. Run a dry run first unless the user has already explicitly requested the exact write.
3. Treat Zotero writes as sensitive:
   - close Zotero before writing to avoid cache or WAL conflicts;
   - create a timestamped backup before modifying `zotero.sqlite`;
   - update `items.synced = 0` and modification timestamps for changed items;
   - reopen Zotero after the write if it was open or if the user asks.
4. Verify after writing with a read-only query and report the changed count, backup path, and remaining mismatches.

## Common Commands

Set all top-level personal-library items with English titles to `en`:

```powershell
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\Set-ZoteroLanguage.ps1 -Language en -TitleLanguage English -SQLiteDll "<path-to-System.Data.SQLite.dll>" -CloseZotero -ReopenZotero
```

Preview items whose titles match a regex:

```powershell
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\Set-ZoteroLanguage.ps1 -Language zh-CN -TitleRegex "中文|中国|Chinese" -DryRun
```

Update explicit Zotero item keys:

```powershell
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\Set-ZoteroLanguage.ps1 -Language en -Keys "ABCD1234,EFGH5678" -CloseZotero -ReopenZotero
```

Restrict item types:

```powershell
powershell -ExecutionPolicy Bypass -File <skill-dir>\scripts\Set-ZoteroLanguage.ps1 -Language en -TitleLanguage English -IncludeItemTypes "journalArticle,conferencePaper,book"
```

## Selection Rules

- Default scope is the personal library (`libraryID = 1`), top-level items only.
- Attachments and notes are excluded unless `-IncludeAttachments` or `-IncludeNotes` is passed.
- `-TitleLanguage English` means the title contains at least one ASCII Latin letter and contains no CJK characters or non-ASCII letters.
- Use `-Keys` for exact item-key targeting when the user supplies Zotero item keys.
- Use `-TitleRegex` for custom user-described subsets that map cleanly to title matching.

## Safety Notes

- The local Zotero HTTP API is read-only for item updates; use it only for probing and inventory. Use database edits only with backups.
- If a write command targets a database outside the workspace, request escalated permission.
- If Zotero remains running after a graceful close request, stop and ask the user to close it manually. Do not force-kill Zotero unless the user explicitly approves.
- The script requires `System.Data.SQLite.dll`; pass its path with `-SQLiteDll`. Do not download dependencies without approval.
