# zotero-bulk-language

`zotero-bulk-language` 是一个 Codex skill，用于批量修改本地 Zotero Desktop 文库中指定条目的 `language` 字段。它适合把英文标题文献统一设置为 `en`，或按标题正则、Zotero item key、条目类型等条件批量设置语言代码。

该 skill 会通过 PowerShell 脚本直接修改 Zotero 的 `zotero.sqlite` 数据库。写入前请务必先运行 `-DryRun`，并在写入时关闭 Zotero，以避免缓存或数据库锁问题。

## 功能

- 将英文标题的顶层文献条目设置为 `en`
- 按标题正则匹配条目
- 按 Zotero item key 精确匹配条目
- 按条目类型限制范围，例如 `journalArticle`、`conferencePaper`、`book`
- 写入前自动备份 `zotero.sqlite`
- 可在任务过程中关闭并重新打开 Zotero

## 安装

将仓库克隆或复制到 Codex skills 目录中：

```powershell
git clone https://github.com/LeeHQ626/zotero-bulk-language.git <codex-home>\skills\zotero-bulk-language
```

如果已经下载到其他位置，也可以直接复制整个目录到：

```text
<codex-home>\skills\zotero-bulk-language
```

目录中至少应包含：

```text
SKILL.md
agents\openai.yaml
scripts\Set-ZoteroLanguage.ps1
```

## 依赖

- Windows PowerShell
- Zotero Desktop
- 可用的 `System.Data.SQLite.dll`

脚本需要通过 `-SQLiteDll` 显式传入 `System.Data.SQLite.dll` 的路径：

```powershell
-SQLiteDll "<path-to-System.Data.SQLite.dll>"
```

如果脚本无法自动定位 Zotero 数据库，也可以显式传入：

```powershell
-DatabasePath "<path-to-zotero.sqlite>"
```

## 推荐流程

1. 先 dry-run，确认会修改哪些条目。
2. 确认结果正确后，再执行写入。
3. 写入时使用 `-CloseZotero` 关闭 Zotero。
4. 写入后使用 `-ReopenZotero` 重新打开 Zotero。
5. 保留脚本生成的数据库备份，直到确认 Zotero 中结果无误。

## 常用命令

预览英文标题条目中哪些还不是 `en`：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Set-ZoteroLanguage.ps1 `
  -Language en `
  -TitleLanguage English `
  -SQLiteDll "<path-to-System.Data.SQLite.dll>" `
  -DryRun
```

将英文标题条目设置为 `en`：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Set-ZoteroLanguage.ps1 `
  -Language en `
  -TitleLanguage English `
  -SQLiteDll "<path-to-System.Data.SQLite.dll>" `
  -CloseZotero `
  -ReopenZotero
```

按 Zotero item key 精确更新：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Set-ZoteroLanguage.ps1 `
  -Language en `
  -Keys "ABCD1234,EFGH5678" `
  -SQLiteDll "<path-to-System.Data.SQLite.dll>" `
  -CloseZotero `
  -ReopenZotero
```

只处理指定条目类型：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Set-ZoteroLanguage.ps1 `
  -Language en `
  -TitleLanguage English `
  -IncludeItemTypes "journalArticle,conferencePaper,book" `
  -SQLiteDll "<path-to-System.Data.SQLite.dll>" `
  -CloseZotero `
  -ReopenZotero
```

按标题正则预览匹配条目：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Set-ZoteroLanguage.ps1 `
  -Language zh-CN `
  -TitleRegex "<title-regex>" `
  -SQLiteDll "<path-to-System.Data.SQLite.dll>" `
  -DryRun
```

## 默认筛选规则

- 默认处理个人文库：`-LibraryID 1`
- 默认排除附件和笔记
- `-TitleLanguage English` 的判断规则是：标题包含至少一个 ASCII 拉丁字母，且不包含 CJK 字符或其他非 ASCII 字母
- 已经是目标语言代码的条目不会重复更新

## 安全机制

- `-DryRun` 只读数据库，不写入
- 非 dry-run 写入前会创建时间戳备份
- 更新条目后会将 `items.synced` 标记为 `0`，并刷新修改时间，便于 Zotero 后续同步
- 如果 `-CloseZotero` 后 Zotero 仍在运行，脚本会停止并提示手动关闭，不会强制结束进程

## 故障排查

找不到 Zotero 数据库：

- 传入 `-DatabasePath "<path-to-zotero.sqlite>"`
- 确认 Zotero 的数据目录设置正确

找不到 `System.Data.SQLite.dll`：

- 在本机查找该 DLL
- 使用 `-SQLiteDll "<path-to-System.Data.SQLite.dll>"` 显式传入

Zotero 无法关闭：

- 手动关闭 Zotero 后重新执行命令
- 不建议在 Zotero 运行时写入数据库

公开仓库使用注意：

- 不要提交 `zotero.sqlite`、备份文件或个人文库数据
- 不要在命令示例中提交真实本机路径、访问凭证或其他敏感信息
