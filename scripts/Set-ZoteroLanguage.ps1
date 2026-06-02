param(
    [string]$DatabasePath = "",
    [string]$Language = "en",
    [ValidateSet("Any", "English")]
    [string]$TitleLanguage = "Any",
    [string]$TitleRegex = "",
    [string]$Keys = "",
    [string]$IncludeItemTypes = "",
    [string]$ExcludeItemTypes = "",
    [int]$LibraryID = 1,
    [switch]$IncludeAttachments,
    [switch]$IncludeNotes,
    [switch]$DryRun,
    [switch]$CloseZotero,
    [switch]$ReopenZotero,
    [string]$BackupDir = "",
    [string]$SQLiteDll = "",
    [string]$ZoteroExe = "C:\Program Files\Zotero\zotero.exe"
)

$ErrorActionPreference = "Stop"

function Resolve-ZoteroDatabasePath {
    if ($DatabasePath -and (Test-Path -LiteralPath $DatabasePath)) {
        return (Resolve-Path -LiteralPath $DatabasePath).Path
    }

    $prefsRoots = @(
        (Join-Path $env:APPDATA "Zotero\Zotero\Profiles"),
        (Join-Path $env:APPDATA "Zotero\Profiles")
    )
    foreach ($root in $prefsRoots) {
        if (!(Test-Path -LiteralPath $root)) { continue }
        $prefs = Get-ChildItem -LiteralPath $root -Recurse -Filter "prefs.js" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (!$prefs) { continue }
        $text = Get-Content -LiteralPath $prefs.FullName -Raw
        if ($text -match 'user_pref\("extensions\.zotero\.dataDir",\s*"([^"]+)"\)') {
            $dir = ($matches[1] -replace '\\\\', '\')
            $db = Join-Path $dir "zotero.sqlite"
            if (Test-Path -LiteralPath $db) { return $db }
        }
    }

    $fallback = Join-Path $env:USERPROFILE "Zotero\zotero.sqlite"
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    throw "Could not resolve Zotero database path. Pass -DatabasePath explicitly."
}

function Resolve-SQLiteAssembly {
    if ($SQLiteDll -and (Test-Path -LiteralPath $SQLiteDll)) {
        return (Resolve-Path -LiteralPath $SQLiteDll).Path
    }
    throw "Could not find System.Data.SQLite.dll in known locations. Pass -SQLiteDll explicitly."
}

function Test-EnglishTitle {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    if ($Title -notmatch "[A-Za-z]") { return $false }
    if ($Title -match "[\p{IsCJKUnifiedIdeographs}\p{IsCJKCompatibilityIdeographs}\p{IsHiragana}\p{IsKatakana}\p{IsHangulSyllables}]") { return $false }
    if (($Title -match "[^\x00-\x7F]") -and ($Title -match "\p{L}")) { return $false }
    return $true
}

function Split-List {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function New-DbCommand {
    param(
        [System.Data.SQLite.SQLiteConnection]$Connection,
        [string]$Sql
    )
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Sql
    return $cmd
}

$dbPath = Resolve-ZoteroDatabasePath
$sqliteAssembly = Resolve-SQLiteAssembly
$wasRunning = @(Get-Process | Where-Object { $_.ProcessName -match "^zotero$" }).Count -gt 0

if ($CloseZotero) {
    $zoteroProcesses = @(Get-Process | Where-Object { $_.ProcessName -match "^zotero$" })
    foreach ($process in $zoteroProcesses) {
        if ($process.MainWindowHandle -ne 0) {
            [void]$process.CloseMainWindow()
        }
    }
    if ($zoteroProcesses.Count -gt 0) { Start-Sleep -Seconds 8 }
    $remaining = @(Get-Process | Where-Object { $_.ProcessName -match "^zotero$" })
    if ($remaining.Count -gt 0) {
        $ids = ($remaining | Select-Object -ExpandProperty Id) -join ", "
        throw "Zotero is still running after a graceful close request. Close it manually and rerun. Remaining process IDs: $ids"
    }
}

Add-Type -Path $sqliteAssembly
$mode = if ($DryRun) { "ReadOnly" } else { "ReadWrite" }
$conn = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$dbPath;Version=3;Mode=$mode;")
$conn.Open()

try {
    $select = New-DbCommand $conn @"
select i.itemID, i.key, it.typeName, titlev.value as title, langv.value as language
from items i
join itemTypes it on it.itemTypeID = i.itemTypeID
join itemData td on td.itemID = i.itemID and td.fieldID = 1
join itemDataValues titlev on titlev.valueID = td.valueID
left join itemData ld on ld.itemID = i.itemID and ld.fieldID = 15
left join itemDataValues langv on langv.valueID = ld.valueID
where i.libraryID = $LibraryID
  and i.itemID not in (select itemID from deletedItems)
order by titlev.value
"@
    $reader = $select.ExecuteReader()
    $includeTypes = Split-List $IncludeItemTypes
    $excludeTypes = Split-List $ExcludeItemTypes
    $targetKeys = Split-List $Keys
    $targets = New-Object System.Collections.Generic.List[object]

    while ($reader.Read()) {
        $itemID = $reader.GetInt32(0)
        $key = $reader.GetString(1)
        $type = $reader.GetString(2)
        $title = $reader.GetString(3)
        $currentLanguage = if ($reader.IsDBNull(4)) { "" } else { $reader.GetString(4) }

        if (!$IncludeAttachments -and $type -eq "attachment") { continue }
        if (!$IncludeNotes -and $type -eq "note") { continue }
        if ($includeTypes.Count -gt 0 -and $includeTypes -notcontains $type) { continue }
        if ($excludeTypes.Count -gt 0 -and $excludeTypes -contains $type) { continue }
        if ($targetKeys.Count -gt 0 -and $targetKeys -notcontains $key) { continue }
        if ($TitleLanguage -eq "English" -and !(Test-EnglishTitle $title)) { continue }
        if ($TitleRegex -and $title -notmatch $TitleRegex) { continue }
        if ($currentLanguage -eq $Language) { continue }

        $targets.Add([pscustomobject]@{
            itemID = $itemID
            key = $key
            type = $type
            title = $title
            oldLanguage = $currentLanguage
            newLanguage = $Language
        })
    }
    $reader.Close()

    $backupPath = ""
    if (!$DryRun -and $targets.Count -gt 0) {
        if (!$BackupDir) {
            $BackupDir = Join-Path (Split-Path -Parent $dbPath) "codex-backups"
        }
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
        $backupPath = Join-Path $BackupDir ("zotero.sqlite.backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
        Copy-Item -LiteralPath $dbPath -Destination $backupPath -Force

        $tx = $conn.BeginTransaction()
        try {
            $insertValue = $conn.CreateCommand()
            $insertValue.Transaction = $tx
            $insertValue.CommandText = "insert or ignore into itemDataValues(value) values (@language)"
            [void]$insertValue.Parameters.Add("@language", [System.Data.DbType]::String)
            $insertValue.Parameters["@language"].Value = $Language
            [void]$insertValue.ExecuteNonQuery()

            $getValue = $conn.CreateCommand()
            $getValue.Transaction = $tx
            $getValue.CommandText = "select valueID from itemDataValues where value = @language"
            [void]$getValue.Parameters.Add("@language", [System.Data.DbType]::String)
            $getValue.Parameters["@language"].Value = $Language
            $languageValueID = [int]$getValue.ExecuteScalar()

            $updateExisting = $conn.CreateCommand()
            $updateExisting.Transaction = $tx
            $updateExisting.CommandText = "update itemData set valueID = @valueID where itemID = @itemID and fieldID = 15"
            [void]$updateExisting.Parameters.Add("@valueID", [System.Data.DbType]::Int32)
            [void]$updateExisting.Parameters.Add("@itemID", [System.Data.DbType]::Int32)
            $updateExisting.Parameters["@valueID"].Value = $languageValueID

            $insertMissing = $conn.CreateCommand()
            $insertMissing.Transaction = $tx
            $insertMissing.CommandText = "insert or ignore into itemData(itemID, fieldID, valueID) values (@itemID, 15, @valueID)"
            [void]$insertMissing.Parameters.Add("@itemID", [System.Data.DbType]::Int32)
            [void]$insertMissing.Parameters.Add("@valueID", [System.Data.DbType]::Int32)
            $insertMissing.Parameters["@valueID"].Value = $languageValueID

            $markChanged = $conn.CreateCommand()
            $markChanged.Transaction = $tx
            $markChanged.CommandText = "update items set dateModified = CURRENT_TIMESTAMP, clientDateModified = CURRENT_TIMESTAMP, synced = 0 where itemID = @itemID"
            [void]$markChanged.Parameters.Add("@itemID", [System.Data.DbType]::Int32)

            foreach ($item in $targets) {
                $updateExisting.Parameters["@itemID"].Value = $item.itemID
                $updated = $updateExisting.ExecuteNonQuery()
                if ($updated -eq 0) {
                    $insertMissing.Parameters["@itemID"].Value = $item.itemID
                    [void]$insertMissing.ExecuteNonQuery()
                }
                $markChanged.Parameters["@itemID"].Value = $item.itemID
                [void]$markChanged.ExecuteNonQuery()
            }
            $tx.Commit()
        }
        catch {
            $tx.Rollback()
            throw
        }
    }

    [pscustomobject]@{
        dryRun = [bool]$DryRun
        database = $dbPath
        backup = $backupPath
        language = $Language
        matchedForUpdate = $targets.Count
        items = $targets
    } | ConvertTo-Json -Depth 5
}
finally {
    $conn.Close()
    if ($ReopenZotero -and ($wasRunning -or $CloseZotero)) {
        if (Test-Path -LiteralPath $ZoteroExe) {
            Start-Process -FilePath $ZoteroExe
        }
    }
}
