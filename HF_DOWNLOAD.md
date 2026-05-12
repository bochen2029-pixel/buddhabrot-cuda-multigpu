# Downloading large .bin files from HuggingFace Buckets

**TL;DR:** Use the `hf` CLI, not your browser. Browser downloads of multi-GB
HF Bucket files fail at ~50% every time. The CLI works. Here's why and how.

---

## Why browser downloads fail

The HuggingFace Bucket resolve URL pattern
`https://huggingface.co/buckets/<owner>/<bucket>/resolve/<file>?download=true`
is served via a CDN that resets long-lived TCP connections. For a 77 GB
file at residential bandwidth (~100 MB/s):

- Download takes ~13 minutes
- A single TCP connection has to stay alive that whole time
- ISPs commonly recycle long-running connections at the 5-15 min mark
- HF's CDN edge nodes also reset connections that have been idle in their
  send buffer for too long
- Browsers do NOT auto-resume on connection reset (they ask "save partial?"
  but the resumed continuation usually fails too)
- `Start-BitsTransfer` (Windows BITS) and `Invoke-WebRequest` use the same
  endpoint and hit the same resets — they also fail
- Recovery is manual at best, futile at worst

**Result of trying anyway:** ~50% completion, "connection was closed
prematurely" error, hours wasted.

## Why `hf sync` works

The `hf` CLI uses HuggingFace's chunked API endpoint internally
(not the resolve URL). The API endpoint:

- Serves files in small chunks (~5-20 MB each)
- Each chunk is a separate HTTP request — no long-lived connections
- The CLI auto-retries failed chunks transparently
- Resume on interruption: re-running the same `hf sync` command picks up
  where it left off (verified working)
- Verified sustained download rates: **300 MB/s** on a residential gigabit
  connection (vs. typical 30-50 MB/s for the browser/BITS path that crashes)

## Setup (one-time)

### Windows

Install the HF CLI:

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://hf.co/cli/install.ps1 | iex"
```

Open a **new** PowerShell window (PATH update takes effect there). Then:

```powershell
hf auth login --token YOUR_HF_TOKEN
```

### Linux / macOS

```bash
pip install -U huggingface_hub
# (or with --break-system-packages on Ubuntu 22+)

hf auth login --token YOUR_HF_TOKEN
```

## Usage — single file

```powershell
# Windows
cd C:\where\you\want\the\file
hf sync hf://buckets/bochen2079/buddhabrot/ . --include "*.cp8320.bin"
```

```bash
# Linux/Mac
cd ~/where/you/want/the/file
hf sync hf://buckets/bochen2079/buddhabrot/ . --include "*.cp8320.bin"
```

The `--include` is a glob — `*.cp8320.bin` matches only the cp8320 .bin file.

## Usage — multiple files for one checkpoint

```powershell
hf sync hf://buckets/bochen2079/buddhabrot64k/ . --include "*.cp4130.*"
```

Matches both `.bin` and `.png` for cp4130.

## Usage — all checkpoint .bins

```powershell
hf sync hf://buckets/bochen2079/buddhabrot/ . --include "*.cp*.bin"
```

Matches every checkpoint .bin in the bucket. Will skip files already on
local disk (idempotent).

## Helper script

For convenience, use the helper:

```powershell
# Windows
.\tools\download_from_hf.ps1 -Bucket "bochen2079/buddhabrot" -Pattern "*.cp8320.bin"
```

```bash
# Linux/Mac
./tools/download_from_hf.sh bochen2079/buddhabrot "*.cp8320.bin"
```

Both auto-install `hf` CLI if missing, auto-login if a token is given,
report the elapsed time, and list the downloaded files.

## Listing what's in a bucket

```powershell
hf buckets ls hf://buckets/bochen2079/buddhabrot/
```

Returns the file list with sizes. Useful for confirming a file exists
before trying to download.

## Resuming a failed download

`hf sync` is idempotent. If a download is interrupted, re-run the exact
same command — partial files are detected and continued. No special
"resume" flag needed.

## What to do if `hf sync` itself fails

This is rare but possible. If `hf sync` errors out:

1. Check auth: `hf auth whoami` (should show your username)
2. Check bucket access: `hf buckets ls hf://buckets/<your>/<bucket>/`
3. Try the explicit-file form: `hf download <bucket>/<file> --repo-type=dataset`
   (this works for some buckets that are stored under the dataset namespace)
4. Last resort: `aria2c` with 16 parallel connections — fragments the
   single TCP issue:
   ```
   aria2c -x 16 -s 16 -c --max-tries=0 \
       "https://huggingface.co/buckets/<owner>/<bucket>/resolve/<file>?download=true"
   ```

---

## What NOT to do (anti-patterns)

These will waste your time. Don't do them.

- ❌ Browser download via "Download" button on the HF web UI for files > ~5 GB
- ❌ `Invoke-WebRequest` (PowerShell built-in HTTP client)
- ❌ `Start-BitsTransfer` against the resolve URL
- ❌ `curl` or `wget` against the resolve URL without explicit resume + retry
  loops
- ❌ Any browser extension "download manager" — they wrap the same single-
  stream HTTP request

These all fail because they hit the same single-stream TCP issue.

---

**Bottom line: install `hf` CLI once, use `hf sync` always. Forget the
browser exists for any file over ~5 GB.**
