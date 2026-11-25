---
name: duplicate-file-cleaner
description: Scan one folder tree for content-identical duplicate files and remove the redundant copies, keeping the newest by modification time. Use when a user asks to deduplicate, find/delete duplicate files, or clean repeated files in a specific folder. Handles large trees with a size+fingerprint+hash pipeline, produces a reviewable report before any deletion, deletes in batches of at most 10, and prevents the Windows Recycle Bin quota trap that silently turns "move to recycle bin" into permanent deletion.
agent_created: true
---

# Duplicate File Cleaner

## Overview

Find duplicate files by exact content (SHA-256) inside a single folder tree, keep the newest copy, and delete the rest only after the user confirms a concrete decision list. The workflow is deliberately two-phase: **scan and report first, delete second**. Deletion is never performed implicitly.

## Hard rules

- Process **one top-level folder at a time**. Ask the user which folder if it is not unambiguous. Do not recursively clean multiple drives in one run.
- Confirm three things before scanning: (1) target folder, (2) duplicate criterion — default exact content hash, (3) "newest" definition — default file modification time.
- **Never delete anything before** producing `dedupe_report.json` / `dedupe_decisions.csv`, presenting the decision list to the user, and getting explicit confirmation of the deletion scope.
- Before any destructive action, warn in bold: **"⚠️ 此操作非常危险，可能导致不可逆的数据丢失！"**, summarize affected counts and bytes, and list every affected path (the CSV is the full list).
- Delete in batches of **at most 10 files**, verify after each batch, and **stop immediately on any failure**.
- Prefer recoverable deletion. On Windows, verify Recycle Bin configuration before deleting — see the trap below.
- After deletion, verify: every "delete" path is gone, every "keep" path still exists. Report both numbers.

## Workflow

### Step 1 — Clarify scope

Ask the user (do not assume): target folder path; duplicate criterion (content hash / filename / both); date basis (mtime / filename date / creation time). If the user says "confirm when unsure", always ask.

### Step 2 — Scan (read-only)

Run the bundled scanner:

```bash
python scripts/scan_duplicates.py "<root>" --output "<report-dir>"
```

Useful options: `--skip NAME` (repeatable) to prune system dirs, `--workers N` for I/O parallelism, `--sample-threshold N` (0 = full hash everything), `--min-size N`.

The scanner uses three phases:
1. Walk metadata, group files by exact size. Files with unique sizes cannot be duplicates.
2. Compute a cheap head+tail (64 KiB) SHA-256 fingerprint in parallel to prefilter.
3. Full SHA-256 for fingerprint matches. Files above `--sample-threshold` use an 8-segment strong sample instead of a full read, and are marked `verification: sampled` in the report.

Read `references/windows-gotchas.md` before touching Windows paths.

Outputs:
- `dedupe_report.json` — groups with `keep` (newest mtime; tie-break lexicographic) and `delete` lists.
- `dedupe_decisions.csv` — UTF-8 BOM, one row per keep/delete decision, for human review.

Review the report: number of groups, redundant files, reclaimable bytes, `sampled_groups`, `unresolved`, and errors. Present the CSV to the user.

### Step 3 — Confirm deletion

Show the warning, counts, and per-directory breakdown. Ask the user to confirm:
- deletion scope (exact-only vs include sampled groups), and
- execution mode (batched recycle/quarantine vs per-subfolder).

If sampled groups are included, state clearly that those files were verified by strong sampling, not a byte-for-byte full hash.

### Step 4 — Delete

**On Windows, first run the Recycle Bin pre-flight check:**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_recycle_bin.ps1 -Drive 'G:'
```

If it prints `QUOTA_NOT_CONFIGURED` or `RECYCLED_FILES 0` after a previous deletion, tell the user that `SendToRecycleBin` will/is degrading to **permanent deletion**. Get explicit confirmation before proceeding, or use `-QuarantineOnly` to keep everything recoverable as same-volume moves.

Then delete:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/delete_duplicates.ps1 `
  -Report '<report-dir>\dedupe_report.json' `
  -Log '<report-dir>\deletion_log.txt'
```

Use `-DryRun` first to sanity-check the target count. Use `-QuarantineOnly` when the Recycle Bin is unreliable and recoverability matters. The script caps batches at 10, moves wildcard-containing filenames to a same-volume quarantine folder, verifies each file, and stops on first failure.

On other platforms, implement the same batch/verify/stop semantics with the OS trash mechanism; never use permanent delete by default.

### Step 5 — Verify and report

Run the scanner's verification logic (or a small script) to confirm:
- every `delete` path no longer exists,
- every `keep` path still exists.

Then, on Windows, re-run `verify_recycle_bin.ps1` with `-ExpectFiles <count>`. If recycled file count is far below the deleted count, the files were permanently deleted — say so plainly. Do not claim recoverability that was not verified.

Finally report: groups, files deleted, bytes reclaimed, where deleted files went (Recycle Bin / quarantine / permanent), any unresolved files or failures, and the report/log paths.

## Resources

### scripts/
- `scan_duplicates.py` — three-phase exact duplicate scanner with report + CSV output.
- `delete_duplicates.ps1` — Windows batched deletion with quarantine fallback and per-batch verification.
- `verify_recycle_bin.ps1` — Windows Recycle Bin quota/payload checker, pre- and post-deletion.

### references/
- `windows-gotchas.md` — Recycle Bin quota degradation, wildcard filenames, execution policy, hidden system folders, and path normalization. Read before any Windows deletion.
