# Windows Gotchas for File Deduplication

Lessons learned from a real large-volume cleanup. Read this before any Windows deletion.

## 1. Recycle Bin quota degradation (most important)

`[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(path, OnlyErrorDialogs, SendToRecycleBin, ThrowException)` **reports success but permanently deletes** when the volume's Recycle Bin has no quota configured or the payload exceeds the quota. There is no exception, no dialog, and the original path disappears — so a naive `Test-Path` check passes and the operator wrongly believes files are recoverable.

Detection:
- Check `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\*`. If no key with `MaxCapacity` matches the volume, the Quota Bin is effectively unconfigured.
- Run `scripts/verify_recycle_bin.ps1` before deletion, and again after deletion with `-ExpectFiles <n>`.
- Compare free space before/after: a large increase consistent with deleted bytes means files were removed from the volume entirely, which is expected for permanent deletion but **not** for a real Recycle Bin move (Recycle Bin contents still occupy space).

Mitigation:
- Use `-QuarantineOnly` in `delete_duplicates.ps1` to move files to a same-volume quarantine folder. Renames on the same volume are instantaneous, consume no extra space, and are fully recoverable.
- If files were permanently deleted, say so explicitly. Recovery requires third-party data recovery software and avoiding further writes to the volume.

Why the Recycle Bin may appear empty even after "successful" deletion:
- `G:\$RECYCLE.BIN` is a hidden + system folder; Explorer hides it by default.
- Each user SID has its own subfolder; payload files are named `$R<random>.<ext>` with `$I<random>.<ext>` metadata.
- Genuine zero payload files (`$R*`) means nothing is actually in the bin.

## 2. Wildcard characters in filenames

VB `FileSystem.DeleteFile` treats `[`, `]`, `*`, `?` in the path as wildcards. A file named `foo[2010].pdf` fails with "这个系统不支持该功能" / "路径中具有非法字符", while a normal filename on the same volume succeeds.

Mitigation: detect `[\[\]\*\?]` in the path and move it with `Move-Item -LiteralPath` into the quarantine folder instead of calling `DeleteFile`. The bundled deletion script does this automatically, including as a fallback when `DeleteFile` throws.

## 3. PowerShell execution policy

On locked-down machines, running a `.ps1` file is blocked with "无法加载文件 ... 因为在此系统上禁止运行脚本". Use a **process-scoped** bypass, not a persistent machine-wide change:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
& 'path\to\script.ps1'
```

Or invoke a fresh PowerShell: `powershell -NoProfile -ExecutionPolicy Bypass -File script.ps1 ...`.

## 4. Literal paths

Use `-LiteralPath` for `Test-Path`, `Get-Item`, `Get-ChildItem`, `Move-Item`. Plain `-Path` interprets brackets and wildcards. JSON reports use forward slashes (`G:/dir/file`); normalize to backslashes before passing to PowerShell APIs: `$p -replace '/', '\'`.

## 5. PowerShell 5.1 syntax differences

- `Set-Content` uses `-Value`, not `-Text`.
- No `&&` / `||` chaining; use `;` and `$?` checks.
- Write scripts as ASCII-only files; read UTF-8 data (JSON reports, Chinese paths) with `Get-Content -Encoding UTF8` rather than embedding non-ASCII literals in the script.

## 6. Hashing performance on very large trees

For ~100k files with many GB-sized videos, full SHA-256 of all candidates is impractical:
- Group by exact file size first; unique-size files cannot be duplicates.
- Fast head+tail fingerprint (64 KiB each) reduces candidates massively.
- Use a thread pool (8–16 workers) for I/O-bound hashing; latency dominates throughput on HDDs.
- For files above a threshold (e.g. 256 MiB), 8 evenly-spaced 512 KiB segments plus head/tail give a near-certain match without reading the whole file. Mark such groups `sampled` and disclose this to the user before deleting them.
- Persist intermediate results (JSON/JSONL) so a long-running scan can be resumed after interruption.

## 7. Safety sequence recap

1. Read-only scan → report.
2. Present report + bold danger warning + explicit confirmation.
3. Recycle Bin pre-flight check.
4. Delete in batches ≤ 10, verify each, stop on failure.
5. Verify keep/delete paths and Recycle Bin payload; report honestly.
