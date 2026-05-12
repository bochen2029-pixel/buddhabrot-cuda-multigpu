<#
.SYNOPSIS
    Reliable downloader for large files from HuggingFace Buckets on Windows.

.DESCRIPTION
    Downloads HuggingFace Bucket files using the `hf sync` CLI — the ONLY
    verified-reliable path for multi-gigabyte files. Browser, BITS, and
    Invoke-WebRequest all fail at ~50% on 77 GB files because:

      - Browser downloads use a single TCP stream with no auto-resume
      - HF's resolve-URL endpoint is fronted by a CDN that resets long-lived
        connections (or the user's ISP does)
      - BITS/Invoke-WebRequest stream from the same URL and hit the same issue

    `hf sync` uses HF's chunked API endpoint internally, which handles 77 GB+
    files cleanly and resumes automatically across network glitches. Verified
    300 MB/s sustained downloads on a residential gigabit connection.

.PARAMETER Bucket
    Bucket path, e.g. "bochen2079/buddhabrot" or "bochen2079/buddhabrot64k"

.PARAMETER Pattern
    File glob to download, e.g. "*.cp8320.bin" or "*.cp4130.*"

.PARAMETER LocalDir
    Where to put the downloaded files. Defaults to current directory.

.PARAMETER Token
    HF token. If omitted, uses cached login from a prior `hf auth login`.

.EXAMPLE
    # Single .bin file
    .\download_from_hf.ps1 -Bucket "bochen2079/buddhabrot" -Pattern "*.cp8320.bin"

.EXAMPLE
    # All cp files (bin + png) for a specific checkpoint
    .\download_from_hf.ps1 -Bucket "bochen2079/buddhabrot64k" -Pattern "*.cp4130.*"

.EXAMPLE
    # Custom output directory
    .\download_from_hf.ps1 -Bucket "bochen2079/buddhabrot" -Pattern "*.bin" -LocalDir "D:\renders"

.NOTES
    Do NOT use the HuggingFace web UI download buttons for files > ~5 GB.
    Do NOT use Start-BitsTransfer or Invoke-WebRequest on the resolve URL.
    Both will fail mid-download. Use this script.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Bucket,

    [Parameter(Mandatory=$true)]
    [string]$Pattern,

    [string]$LocalDir = ".",

    [string]$Token = ""
)

$ErrorActionPreference = "Stop"

Write-Host "===========================================" -ForegroundColor Cyan
Write-Host "HuggingFace Bucket downloader" -ForegroundColor Cyan
Write-Host "===========================================" -ForegroundColor Cyan
Write-Host "Bucket:    hf://buckets/$Bucket/"
Write-Host "Pattern:   $Pattern"
Write-Host "Local dir: $LocalDir"
Write-Host ""

# Step 1: verify hf CLI is installed
$hfCmd = Get-Command hf -ErrorAction SilentlyContinue
if (-not $hfCmd) {
    Write-Host "[1/4] hf CLI not found; installing..." -ForegroundColor Yellow
    Write-Host "  (one-time install via official PowerShell installer)"
    powershell -ExecutionPolicy ByPass -c "irm https://hf.co/cli/install.ps1 | iex"
    Write-Host ""
    Write-Host "WARNING: hf CLI was just installed in this session." -ForegroundColor Yellow
    Write-Host "         PATH update applies to NEW terminals only."
    Write-Host "         If 'hf' is not found below, close + reopen PowerShell"
    Write-Host "         and re-run this script."
    Write-Host ""
} else {
    Write-Host "[1/4] hf CLI found at: $($hfCmd.Source)" -ForegroundColor Green
}

# Step 2: ensure logged in
if ($Token) {
    Write-Host "[2/4] logging in with provided token..." -ForegroundColor Yellow
    hf auth login --token $Token
} else {
    Write-Host "[2/4] checking existing auth..." -ForegroundColor Yellow
    $whoami = hf auth whoami 2>&1
    if ($LASTEXITCODE -ne 0 -or $whoami -match "Not logged in") {
        Write-Host "ERROR: not logged in to HF. Run one of:" -ForegroundColor Red
        Write-Host "  hf auth login --token YOUR_HF_TOKEN"
        Write-Host "  .\download_from_hf.ps1 -Bucket $Bucket -Pattern '$Pattern' -Token YOUR_HF_TOKEN"
        exit 1
    }
    Write-Host "  auth OK: $whoami" -ForegroundColor Green
}

# Step 3: ensure local directory exists
if (-not (Test-Path $LocalDir)) {
    Write-Host "[3/4] creating local dir: $LocalDir" -ForegroundColor Yellow
    New-Item -Path $LocalDir -ItemType Directory | Out-Null
}
$absLocal = (Resolve-Path $LocalDir).Path
Write-Host "[3/4] local dir: $absLocal" -ForegroundColor Green

# Step 4: download via hf sync (the verified-reliable path)
Write-Host ""
Write-Host "[4/4] downloading..." -ForegroundColor Yellow
Write-Host "  Command: hf sync hf://buckets/$Bucket/ $LocalDir --include `"$Pattern`""
Write-Host ""

$start = Get-Date
hf sync "hf://buckets/$Bucket/" $LocalDir --include $Pattern

$exitCode = $LASTEXITCODE
$elapsed = (Get-Date) - $start

Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "===========================================" -ForegroundColor Green
    Write-Host "Download complete in $([math]::Round($elapsed.TotalMinutes, 1)) min" -ForegroundColor Green
    Write-Host "===========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Files in $absLocal matching '$Pattern':"
    Get-ChildItem -Path $LocalDir -Filter $Pattern | ForEach-Object {
        $sizeGB = [math]::Round($_.Length / 1GB, 2)
        Write-Host "  $($_.Name)  ($sizeGB GB)"
    }
} else {
    Write-Host "===========================================" -ForegroundColor Red
    Write-Host "Download FAILED (exit code $exitCode)" -ForegroundColor Red
    Write-Host "===========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Common causes:"
    Write-Host "  - Wrong bucket name or token doesn't have access"
    Write-Host "  - Pattern doesn't match any files in the bucket"
    Write-Host "  - Network dropped mid-transfer (re-run; hf sync resumes)"
    Write-Host ""
    Write-Host "Verify bucket contents with:"
    Write-Host "  hf buckets ls hf://buckets/$Bucket/"
    exit $exitCode
}
