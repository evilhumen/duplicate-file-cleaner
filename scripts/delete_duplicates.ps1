# Delete duplicate files in batches of at most 10, with immediate verification,
# stopping on the first failure. Recycle Bin is preferred; files whose names
# contain wildcard characters (e.g. [2010]) are moved to a same-volume
# quarantine directory instead, because VB FileIO treats them as wildcards.
#
# ALWAYS run verify_recycle_bin.ps1 first. If the Recycle Bin has no quota,
# SendToRecycleBin will permanently delete files; in that case either accept
# permanent deletion explicitly with the user, or use -QuarantineOnly so all
# deletions are recoverable same-volume moves.
#
# Usage (PowerShell 5.1):
#   powershell -NoProfile -ExecutionPolicy Bypass -File delete_duplicates.ps1 `
#       -Report 'D:\path\dedupe_report.json' `
#       -Log 'D:\path\deletion_log.txt' `
#       [-QuarantineOnly] [-BatchSize 10] [-DryRun]

param(
    [Parameter(Mandatory=$true)][string]$Report,
    [string]$Log = '',
    [switch]$QuarantineOnly,
    [int]$BatchSize = 10,
    [switch]$DryRun
)

Add-Type -AssemblyName Microsoft.VisualBasic

if ([string]::IsNullOrWhiteSpace($Log)) {
    $Log = Join-Path (Split-Path -Parent $Report) 'deletion_log.txt'
}
if ($BatchSize -gt 10) { $BatchSize = 10 }  # hard cap per user safety rule

$data = Get-Content -Raw -Encoding UTF8 $Report | ConvertFrom-Json
$targets = New-Object System.Collections.Generic.List[string]
foreach ($g in $data.duplicate_groups) {
    foreach ($i in $g.delete) {
        # Normalize forward slashes from the JSON report to Windows separators.
        $targets.Add(($i.path -replace '/', '\'))
    }
}

if ($DryRun) {
    Write-Output "DRY_RUN targets=$($targets.Count) (no files touched)"
    exit 0
}

# Quarantine lives on the same volume as the first target, so moves are
# instantaneous renames that consume no extra space and stay recoverable.
$firstDrive = $targets[0].Substring(0, 2)
$quarantine = Join-Path $firstDrive '_dedupe_quarantine'
if (-not (Test-Path -LiteralPath $quarantine)) {
    New-Item -ItemType Directory -Path $quarantine -Force | Out-Null
}

Write-Output "TARGETS $($targets.Count) batch=$BatchSize quarantine=$QuarantineOnly"
Add-Content -Encoding UTF8 $Log "START $(Get-Date -Format o) targets=$($targets.Count)"

$failed = $false
$doneRecycle = 0
$doneQuarantine = 0
$skipped = 0

function Move-ToQuarantine([string]$p, [string]$qroot, [string]$logPath) {
    $rel = $p.Substring(3)  # strip "X:\"
    $dest = Join-Path $qroot $rel
    $destdir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destdir)) {
        New-Item -ItemType Directory -Path $destdir -Force | Out-Null
    }
    Move-Item -LiteralPath $p -Destination $dest
    Add-Content -Encoding UTF8 $logPath "QUARANTINE $p -> $dest"
}

for ($i = 0; $i -lt $targets.Count; $i += $BatchSize) {
    $end = [Math]::Min($i + $BatchSize - 1, $targets.Count - 1)
    $batchFailed = $false
    for ($j = $i; $j -le $end; $j++) {
        $p = $targets[$j]
        if (-not (Test-Path -LiteralPath $p)) {
            $skipped++
            Add-Content -Encoding UTF8 $Log "MISSING $p"
            continue
        }
        $needsQuarantine = $QuarantineOnly -or ($p -match '[\[\]\*\?]')
        $moved = $false
        if ($needsQuarantine) {
            try {
                Move-ToQuarantine $p $quarantine $Log
                $moved = -not (Test-Path -LiteralPath $p)
                if ($moved) { $doneQuarantine++ }
            } catch {
                Add-Content -Encoding UTF8 $Log "FAIL_QUARANTINE $p : $($_.Exception.Message)"
                $batchFailed = $true
                break
            }
        } else {
            try {
                # UIOption.OnlyErrorDialogs suppresses confirmation dialogs;
                # UICancelOption.ThrowException turns cancellation into an error.
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $p,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                    [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException)
                $moved = -not (Test-Path -LiteralPath $p)
                if ($moved) { $doneRecycle++ }
            } catch {
                # Recycle Bin cannot handle this file (wildcard chars, quota,
                # or unsupported volume). Fall back to same-volume quarantine.
                try {
                    Move-ToQuarantine $p $quarantine $Log
                    $moved = -not (Test-Path -LiteralPath $p)
                    if ($moved) { $doneQuarantine++ }
                    Add-Content -Encoding UTF8 $Log "RECYCLE_FALLBACK $p"
                } catch {
                    Add-Content -Encoding UTF8 $Log "FAIL_RECYCLE $p : $($_.Exception.Message)"
                    $batchFailed = $true
                    break
                }
            }
        }
        if (-not $moved) {
            Add-Content -Encoding UTF8 $Log "FAIL_VERIFY $p"
            Write-Output "FAIL_VERIFY $p"
            $batchFailed = $true
            break
        }
    }
    if ($batchFailed) { $failed = $true; break }
    if (($i % 100) -eq 0) {
        Write-Output "PROGRESS recycle=$doneRecycle quarantine=$doneQuarantine skipped=$skipped"
    }
}

if ($failed) {
    Write-Output "STOPPED recycle=$doneRecycle quarantine=$doneQuarantine skipped=$skipped"
    Add-Content -Encoding UTF8 $Log "STOPPED $(Get-Date -Format o) recycle=$doneRecycle quarantine=$doneQuarantine skipped=$skipped"
    exit 1
}
Write-Output "DONE recycle=$doneRecycle quarantine=$doneQuarantine skipped=$skipped"
Add-Content -Encoding UTF8 $Log "DONE $(Get-Date -Format o) recycle=$doneRecycle quarantine=$doneQuarantine skipped=$skipped"
exit 0
